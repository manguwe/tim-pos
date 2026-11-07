import 'dart:math';

/// Makes UUIDv7 IDs: the first 48 bits are the time in milliseconds, so IDs made later sort later,
/// which keeps database indexes tidy. Two IDs made in the same millisecond still come out in order.
class Uuid7Generator {
  Uuid7Generator({Random? random, int Function()? clock})
      : _random = random ?? Random.secure(),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Random _random;
  final int Function() _clock;
  int _lastMs = 0;
  int _counter = 0;

  String next() {
    final now = _clock();
    if (now > _lastMs) {
      _lastMs = now;
      _counter = _random.nextInt(0x800); // start low so a burst in one millisecond has room to count up
    } else {
      // Same millisecond, or the clock stepped back: keep the last time and count up so order is kept.
      _counter++;
      if (_counter > 0xFFF) {
        _lastMs++;
        _counter = _random.nextInt(0x800);
      }
    }
    final b = List<int>.filled(16, 0);
    var t = _lastMs;
    for (var i = 5; i >= 0; i--) {
      b[i] = t % 256;
      t ~/= 256;
    }
    b[6] = 0x70 | (_counter ~/ 256); // version 7 + top 4 bits of the counter
    b[7] = _counter % 256;
    b[8] = 0x80 | _random.nextInt(0x40); // variant 10
    for (var i = 9; i < 16; i++) {
      b[i] = _random.nextInt(256);
    }
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}

final Uuid7Generator _shared = Uuid7Generator();

/// A new ID for any row this phone creates.
String newId() => _shared.next();
