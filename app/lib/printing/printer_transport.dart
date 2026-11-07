import 'dart:typed_data';

/// A printer the phone knows about (paired in Android's Bluetooth settings).
class PrinterDevice {
  const PrinterDevice({required this.name, required this.address});
  final String name;
  final String address;
}

class PrinterError implements Exception {
  PrinterError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How bytes reach a printer. The app uses Bluetooth (bluetooth_transport.dart); tests use a fake.
abstract class PrinterTransport {
  /// Printers already paired with this phone.
  Future<List<PrinterDevice>> pairedDevices();

  /// Connects, sends [bytes], and disconnects. Throws [PrinterError] with a message the cashier can act on.
  Future<void> send(String address, Uint8List bytes);
}
