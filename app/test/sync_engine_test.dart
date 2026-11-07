import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/sync/api_client.dart';
import 'package:tim_pos/sync/sync_engine.dart';

import 'support/ffi_db.dart';

typedef Handler = Future<ApiResponse> Function(String method, String path, Object? body);

class FakeServer implements ApiTransport {
  FakeServer(this.handler);
  Handler handler;
  final calls = <({String method, String path, Object? body})>[];

  @override
  Future<ApiResponse> send(String method, String path, {Object? body, bool signedIn = true}) {
    calls.add((method: method, path: path, body: body));
    return handler(method, path, body);
  }
}

ApiResponse ok(Map<String, dynamic> j) => ApiResponse(200, j);

void main() {
  final manifest = jsonDecode(File('assets/sql/schema_manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final kinds = {for (final e in manifest.entries) e.key: (e.value as Map<String, dynamic>)['kind'] as String};

  late SqlDb db;
  late FakeServer server;
  late SyncEngine engine;
  var clock = 1000;

  setUp(() async {
    db = await openTestDb();
    clock = 1000;
    server = FakeServer((m, p, b) async => ok({'accepted': 0, 'skipped': 0, 'rejected': []}));
    engine = SyncEngine(db: db, api: server, kinds: kinds, clock: () => clock++);
  });

  Future<void> seed() async {
    await db.exec("insert into branches (id, shop_id, created_at, updated_at, name) values ('branch-01', 'shop', 1, 1, 'Main')");
    await db.exec("insert into products (id, shop_id, created_at, updated_at, name) values ('product-01', 'shop', 1, 1, 'Bread')");
    await db.exec("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, type, qty_milli) values ('move-0001', 'shop', 1, 'branch-01', 'product-01', 'purchase', 9000)");
  }

  test('push sends what is waiting once, then nothing', () async {
    await seed();
    server.handler = (m, p, b) async => ok({'accepted': 3, 'skipped': 0, 'rejected': []});
    final r = await engine.push();
    expect(r.pushed, 3);
    final body = server.calls.single.body as Map<String, dynamic>;
    expect((body['changes'] as List).map((c) => (c as Map)['table']), ['branches', 'products', 'stock_movements']);
    expect((await engine.status()).waiting, 0);
    await engine.push();
    expect(server.calls.length, 1, reason: 'nothing new, so no call');
  });

  test('a push cut off after the server answered is resent identically, even if a row changed meanwhile', () async {
    await seed();
    server.handler = (m, p, b) async => throw NetworkException('connection lost');
    await expectLater(engine.push(), throwsA(isA<NetworkException>()));
    await db.exec("update products set name = 'Bread, edited', version = 2, updated_at = 5 where id = 'product-01'");

    server.handler = (m, p, b) async => ok({'accepted': 3, 'skipped': 0, 'rejected': []});
    await engine.push();
    final first = server.calls[0].body as Map<String, dynamic>;
    final second = server.calls[1].body as Map<String, dynamic>;
    expect(second['batch_id'], first['batch_id']);
    expect(jsonEncode(second['changes']), jsonEncode(first['changes']));
    // the edit made while waiting goes out as its own batch
    final third = server.calls[2].body as Map<String, dynamic>;
    expect(third['batch_id'], isNot(first['batch_id']));
    expect((third['changes'] as List).single['version'], 2);
    expect((await engine.status()).waiting, 0);
  });

  test('pull applies other phones rows, keeps stock right, and does not queue them to be sent back', () async {
    server.handler = (m, p, b) async => ok({
          'next_seq': 7,
          'has_more': false,
          'epoch': 'e1',
          'changes': [
            {'seq': 5, 'table': 'branches', 'row_id': 'branch-01', 'op': 'insert', 'version': 1, 'data': {'id': 'branch-01', 'shop_id': 'shop', 'created_at': 1, 'updated_at': 1, 'version': 1, 'name': 'Main'}},
            {'seq': 6, 'table': 'products', 'row_id': 'product-01', 'op': 'insert', 'version': 1, 'data': {'id': 'product-01', 'shop_id': 'shop', 'created_at': 1, 'updated_at': 1, 'version': 1, 'name': 'Bread', 'colour_from_the_future': 'red', 'is_active': true}},
            {'seq': 7, 'table': 'stock_movements', 'row_id': 'move-0001', 'op': 'insert', 'version': 1, 'data': {'id': 'move-0001', 'shop_id': 'shop', 'created_at': 1, 'branch_id': 'branch-01', 'product_id': 'product-01', 'type': 'purchase', 'qty_milli': 4000}},
            {'seq': 7, 'table': 'table_from_the_future', 'row_id': 'x-00000001', 'op': 'insert', 'version': 1, 'data': {'id': 'x-00000001'}},
            {'seq': 7, 'table': 'products"; drop table sales; --', 'row_id': 'x-00000002', 'op': 'insert', 'version': 1, 'data': {}},
          ],
        });
    final r = await engine.pull();
    expect(r.pulled, 5);
    expect((await db.query('select qty_milli from stock_levels')).single['qty_milli'], 4000);
    expect((await db.query("select is_active from products")).single['is_active'], 1);
    expect((await db.query('select count(*) c from change_log')).single['c'], 0);
    final st = (await db.query('select last_pull_seq, epoch, applying from sync_state')).single;
    expect(st, {'last_pull_seq': 7, 'epoch': 'e1', 'applying': 0});
  });

  test('a rows higher version wins, a lower one is ignored, and a tie goes to the later edit', () async {
    await seed();
    await db.exec("update products set name = 'v3', version = 3, updated_at = 30 where id = 'product-01'");
    ApiResponse page(int version, int updatedAt, String name) => ok({
          'next_seq': 1, 'has_more': false, 'epoch': 'e1',
          'changes': [
            {'seq': 1, 'table': 'products', 'row_id': 'product-01', 'op': 'update', 'version': version, 'data': {'id': 'product-01', 'shop_id': 'shop', 'created_at': 1, 'updated_at': updatedAt, 'version': version, 'name': name}},
          ],
        });
    Future<String> nameAfter(ApiResponse r) async {
      server.handler = (m, p, b) async => r;
      await engine.pull();
      return (await db.query("select name from products where id = 'product-01'")).single['name'] as String;
    }

    expect(await nameAfter(page(2, 99, 'older version, newer clock')), 'v3');
    expect(await nameAfter(page(3, 20, 'tie, earlier')), 'v3');
    expect(await nameAfter(page(3, 40, 'tie, later')), 'tie, later');
    expect(await nameAfter(page(4, 1, 'higher version')), 'higher version');
  });

  test('after a server restore the phone starts again from the beginning and asks for its own rows too', () async {
    var n = 0;
    server.handler = (m, p, b) async {
      n++;
      if (n == 1) {
        return const ApiResponse(409, {'error': {'code': 'epoch_changed', 'message': 'restored', 'epoch': 'e2'}});
      }
      return ok({'next_seq': 0, 'has_more': false, 'epoch': 'e2', 'changes': []});
    };
    await db.exec("update sync_state set last_pull_seq = 40, epoch = 'e1' where id = 1");
    final r = await engine.pull();
    expect(r.restarted, isTrue);
    expect(server.calls[0].path, contains('since=40'));
    expect(server.calls[0].path, contains('epoch=e1'));
    expect(server.calls[1].path, contains('since=0'));
    expect(server.calls[1].path, contains('include_own=1'));
    expect((await db.query('select epoch from sync_state')).single['epoch'], 'e2');
  });

  test('a refusal from the server is reported and the work stays queued', () async {
    await seed();
    server.handler = (m, p, b) async => const ApiResponse(403, {'error': {'code': 'licence_suspended', 'message': 'suspended', 'locked': true}});
    await expectLater(engine.push(), throwsA(isA<SyncException>().having((e) => e.response.isLocked, 'locked', isTrue)));
    expect((await engine.status()).waiting, 3);
    expect((await engine.status()).lastError, 'push 403 licence_suspended');
  });
}
