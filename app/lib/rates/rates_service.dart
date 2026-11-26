import 'dart:convert';

import '../data/sql_db.dart';
import '../sync/api_client.dart';

class RatesError implements Exception {
  RatesError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Rates relative to USD as the server last fetched them, with the time that was.
class LiveRates {
  const LiveRates({required this.rates, required this.fetchedAt});
  final Map<String, double> rates;
  final int fetchedAt;

  factory LiveRates.fromJson(Map<String, dynamic> j) => LiveRates(
        rates: {for (final e in (j['rates'] as Map<String, dynamic>).entries) e.key: (e.value as num).toDouble()},
        fetchedAt: (j['fetched_at'] as num).toInt(),
      );

  Map<String, Object?> toJson() => {'rates': rates, 'fetched_at': fetchedAt};

  /// The currency code the rate provider uses for one of the app's codes (the app says ZiG, providers say ZWG).
  static String providerCode(String code) => code == 'ZiG' ? 'ZWG' : code;

  bool has(String code) => rates.containsKey(providerCode(code));

  /// How many [to] one [from] is worth, or null if either is missing.
  double? rate(String from, String to) {
    final a = rates[providerCode(from)], b = rates[providerCode(to)];
    if (a == null || b == null || a <= 0) return null;
    return b / a;
  }

  /// The same, as the app stores it: millionths of [to] per one [from].
  int? rateMicro(String from, String to) {
    final r = rate(from, to);
    if (r == null) return null;
    final micro = (r * 1000000).round();
    return micro <= 0 || micro > 100000000 ? null : micro;
  }

  /// [amountMinor] of [from] expressed in [to], in minor units, rounded half up. An estimate for planning, not a till rate.
  int? convertMinor(int amountMinor, String from, String to, {int fromUnits = 2, int toUnits = 2}) {
    final r = rate(from, to);
    if (r == null) return null;
    final major = amountMinor / _pow10(fromUnits);
    return (major * r * _pow10(toUnits)).round();
  }

  static int _pow10(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }
}

/// Gets live rates from the shop's server and keeps the last good copy, so the converter still works offline.
class RatesService {
  RatesService(this.api, this.db);
  final ApiTransport api;
  final SqlDb db;

  Future<LiveRates?> cached() async {
    final r = await db.query("select value from device_state where key = 'live_rates'");
    if (r.isEmpty) return null;
    try {
      return LiveRates.fromJson(jsonDecode(r.first['value'] as String) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<LiveRates> refresh() async {
    final ApiResponse res;
    try {
      res = await api.send('GET', '/v1/rates');
    } on NetworkException {
      throw RatesError('You need internet to get live rates.');
    }
    if (res.status != 200) {
      throw RatesError(res.errorCode == 'rates_unavailable' ? 'Live rates are not ready on the server yet. Try again in a few minutes.' : 'Could not get live rates (error ${res.status}).');
    }
    final live = LiveRates.fromJson(res.json);
    await db.exec(
      "insert into device_state (key, value) values ('live_rates', ?) on conflict (key) do update set value = excluded.value",
      [jsonEncode(live.toJson())],
    );
    return live;
  }
}
