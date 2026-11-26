import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/rates/rates_service.dart';
import 'package:tim_pos/sync/api_client.dart';

import 'support/ffi_db.dart';

class _Fake implements ApiTransport {
  _Fake(this.reply);
  final Object reply;
  @override
  Future<ApiResponse> send(String method, String path, {Object? body, bool signedIn = true}) async {
    if (reply is ApiResponse) return reply as ApiResponse;
    throw reply;
  }
}

void main() {
  const live = LiveRates(rates: {'USD': 1, 'ZMW': 27.0, 'ZWG': 26.0, 'ZAR': 18.0}, fetchedAt: 5);

  test('rates between any two currencies come from the USD table', () {
    expect(live.rate('USD', 'ZMW'), 27.0);
    expect(live.rate('ZMW', 'USD'), closeTo(1 / 27, 1e-12));
    expect(live.rate('ZMW', 'ZiG'), closeTo(26 / 27, 1e-12)); // the app calls it ZiG
    expect(live.rate('USD', 'XYZ'), isNull);
    expect(live.rateMicro('USD', 'ZiG'), 26000000);
  });

  test('an order priced in kwacha is shown in dollars and Zimbabwe Gold', () {
    expect(live.convertMinor(270000, 'ZMW', 'USD'), 10000); // K2,700.00 = $100.00
    expect(live.convertMinor(270000, 'ZMW', 'ZiG'), 260000);
    expect(live.convertMinor(100, 'USD', 'XYZ'), isNull);
  });

  test('the last good rates are kept, and a failure gives a plain message', () async {
    final db = await openTestDb();
    final ok = RatesService(_Fake(const ApiResponse(200, {'rates': {'USD': 1, 'ZMW': 27.5}, 'fetched_at': 9})), db);
    expect(await ok.cached(), isNull);
    expect((await ok.refresh()).rate('USD', 'ZMW'), 27.5);
    expect((await ok.cached())!.fetchedAt, 9);
    final off = RatesService(_Fake(NetworkException('no signal')), db);
    await expectLater(off.refresh(), throwsA(isA<RatesError>().having((e) => e.message, 'message', contains('internet'))));
    expect((await off.cached())!.rate('USD', 'ZMW'), 27.5);
    final notReady = RatesService(_Fake(const ApiResponse(503, {'error': {'code': 'rates_unavailable', 'message': 'x'}})), db);
    await expectLater(notReady.refresh(), throwsA(isA<RatesError>()));
  });
}
