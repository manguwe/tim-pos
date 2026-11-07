import 'dart:typed_data';

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'printer_transport.dart';

/// Classic Bluetooth (SPP) to the small receipt printers sold in Zimbabwe. This is the only file that touches the plugin.
/// The printer must first be paired once in Android's Bluetooth settings (the PIN is usually 0000 or 1234).
class BluetoothTransport implements PrinterTransport {
  @override
  Future<List<PrinterDevice>> pairedDevices() async {
    await _ready();
    final list = await PrintBluetoothThermal.pairedBluetooths;
    return [for (final d in list) PrinterDevice(name: d.name, address: d.macAdress)];
  }

  @override
  Future<void> send(String address, Uint8List bytes) async {
    await _ready();
    var connected = await PrintBluetoothThermal.connectionStatus;
    if (!connected) {
      connected = await PrintBluetoothThermal.connect(macPrinterAddress: address);
    }
    if (!connected) throw PrinterError('Could not reach the printer. Check that it is switched on and close to the phone.');
    final ok = await PrintBluetoothThermal.writeBytes(bytes);
    if (!ok) {
      await PrintBluetoothThermal.disconnect;
      throw PrinterError('The printer did not accept the receipt. Switch it off and on, then try again.');
    }
    // Leave the connection open: the next sale prints faster, and a closed link is re-opened above.
  }

  Future<void> _ready() async {
    if (!await PrintBluetoothThermal.isPermissionBluetoothGranted) {
      throw PrinterError('Allow Bluetooth for TIM-POS in the phone settings, then try again.');
    }
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      throw PrinterError('Bluetooth is switched off. Turn it on and try again.');
    }
  }
}
