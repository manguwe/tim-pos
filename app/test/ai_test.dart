import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/ai/ai_service.dart';
import 'package:tim_pos/sync/api_client.dart';

class _Fake implements ApiTransport {
  _Fake(this.reply);
  final Object reply; // an ApiResponse, or an exception to throw
  String? lastPath;
  Object? lastBody;
  @override
  Future<ApiResponse> send(String method, String path, {Object? body, bool signedIn = true}) async {
    lastPath = path;
    lastBody = body;
    if (reply is ApiResponse) return reply as ApiResponse;
    throw reply;
  }
}

void main() {
  test('a suggestion comes back as name and brand', () async {
    final f = _Fake(const ApiResponse(200, {'name': 'Cooking oil 2L', 'brand': 'Olivine'}));
    final s = await AiService(f).suggestProduct([1, 2, 3]);
    expect(s.name, 'Cooking oil 2L');
    expect(s.brand, 'Olivine');
    expect(f.lastPath, '/v1/ai/suggest-product');
  });

  test('offline gives a plain message', () async {
    final ai = AiService(_Fake(NetworkException('no signal')));
    expect(() => ai.ask('hi', includeSales: false), throwsA(isA<AiError>().having((e) => e.message, 'message', contains('internet'))));
  });

  test('plan and limit errors are explained', () async {
    final notIncluded = AiService(_Fake(const ApiResponse(403, {'error': {'code': 'ai_not_included', 'message': 'x'}})));
    expect(() => notIncluded.ask('hi', includeSales: true), throwsA(isA<AiError>().having((e) => e.message, 'message', contains('plan'))));
    final limit = AiService(_Fake(const ApiResponse(429, {'error': {'code': 'ai_limit_reached', 'message': 'x'}})));
    expect(() => limit.ask('hi', includeSales: true), throwsA(isA<AiError>().having((e) => e.message, 'message', contains('limit'))));
  });

  test('sales are only requested when allowed', () async {
    final f = _Fake(const ApiResponse(200, {'answer': 'ok'}));
    await AiService(f).ask('how did we do', includeSales: true);
    expect((f.lastBody as Map)['include_sales'], true);
    await AiService(f).ask('price?', includeSales: false);
    expect((f.lastBody as Map)['include_sales'], false);
  });
}
