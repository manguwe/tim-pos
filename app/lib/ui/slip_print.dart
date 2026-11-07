import 'package:flutter/material.dart';

import '../printing/print_service.dart';
import '../printing/slips.dart';

/// Prints a slip if this phone has a printer. A failure never undoes what was saved; the person is told and can print again.
/// Returns true when a slip was sent to the printer.
Future<bool> printSlipSafely(BuildContext context, PrintService? svc, Future<SlipData> Function(PrintService s) load, {bool copy = false, bool quietWhenNoPrinter = true}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (svc == null) return false;
  try {
    if (await svc.printer() == null) {
      if (!quietWhenNoPrinter) messenger.showSnackBar(const SnackBar(content: Text('No printer is set up on this phone yet.')));
      return false;
    }
    await svc.printSlip(await load(svc), copy: copy);
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Saved, but the slip did not print: $e. Use Print slip to try again.')));
    return false;
  }
}
