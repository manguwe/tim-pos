import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/core/uuid7.dart';

void main() {
  final shape = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  test('has the UUIDv7 shape and carries the time in its first 48 bits', () {
    final g = Uuid7Generator(clock: () => 0x018F1234ABCD, random: Random(1));
    final id = g.next();
    expect(id, matches(shape));
    expect(id.replaceAll('-', '').substring(0, 12), '018f1234abcd');
  });

  test('IDs made in order sort in order, even within one millisecond or when the clock steps back', () {
    var now = 1000000;
    final g = Uuid7Generator(clock: () => now, random: Random(2));
    final ids = <String>[];
    for (var i = 0; i < 50; i++) {
      ids.add(g.next()); // same millisecond
    }
    now -= 5000; // clock moved back
    for (var i = 0; i < 50; i++) {
      ids.add(g.next());
    }
    now += 9000;
    ids.add(g.next());
    final sorted = [...ids]..sort();
    expect(ids, sorted);
    expect(ids.toSet().length, ids.length);
  });

  test('a counter that runs out moves on to the next millisecond instead of repeating', () {
    final g = Uuid7Generator(clock: () => 5000, random: Random(3));
    final ids = List.generate(6000, (_) => g.next());
    expect(ids.toSet().length, 6000);
    expect([...ids]..sort(), ids);
  });

  test('newId gives valid, different IDs', () {
    final a = newId();
    final b = newId();
    expect(a, matches(shape));
    expect(a, isNot(b));
  });
}
