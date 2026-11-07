import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../licence/licence.dart';
import 'theme.dart';
import 'auth_screens.dart';
import 'setup_screens.dart';
import 'customer_screens.dart';
import 'printer_screens.dart';
import 'purchasing_screens.dart';
import 'report_screens.dart';
import 'return_screens.dart';
import 'fiscal_screens.dart';
import 'settings_screens.dart';
import 'shift_screens.dart';
import 'stock_screens.dart';
import 'till_screen.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _key = TextEditingController();
  final _name = TextEditingController(text: 'Till 1');

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('TIM-POS', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Brand.teal, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text('Enter the licence key your supplier gave you. You need data for this step only once.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _key,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'Licence key'),
                  ),
                  const SizedBox(height: 14),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name of this device', helperText: 'For example Till 1 or Back office')),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: c.busy ? null : () => c.activate(_key.text, _name.text),
                    child: c.busy ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Text('Activate'),
                  ),
                  if (c.message != null) ...[
                    const SizedBox(height: 16),
                    Text(c.message!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.coral)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String lockText(LockReason? r) => switch (r) {
      LockReason.expired => 'Your licence has expired. Renew it with your supplier, then connect to the internet to unlock.',
      LockReason.syncOverdue => 'This phone has been offline for too long. Connect to the internet to unlock it. Your sales are safe.',
      LockReason.clockBehind => 'The phone clock is behind. Fix the date and time, then connect to the internet to unlock.',
      LockReason.invalidToken => 'This licence cannot be verified. Connect to the internet; if this stays, contact your supplier.',
      LockReason.serverRefused => 'Your supplier has stopped this licence or removed this device. Contact them to unlock.',
      null => 'This app is locked.',
    };

class LockedScreen extends StatelessWidget {
  const LockedScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Brand.amber),
                const SizedBox(height: 16),
                Text('TIM-POS is locked', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(c.message ?? lockText(c.licence.state.reason), textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (c.engine != null)
                  FilledButton.icon(
                    onPressed: c.busy ? null : c.syncNow,
                    icon: const Icon(Icons.sync),
                    label: Text(c.busy ? 'Connecting…' : 'Connect and unlock'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  String _when(int? ms) {
    if (ms == null) return 'Not synced yet';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Last synced ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final lic = c.licence;
    final p = lic.payload!;
    final st = lic.state;
    final banner = switch (st.status) {
      LicenceStatus.grace => 'Licence expired. ${st.graceDaysLeft} day(s) left to renew before the app locks.',
      LicenceStatus.active when st.expiresSoon => 'Licence ends in ${st.daysLeft} day(s). Renew soon.',
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(p.shopName),
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        actions: [
          if (c.currentUser != null) Center(child: Text(c.currentUser!.name)),
          if (c.currentUser != null) IconButton(tooltip: 'Lock', icon: const Icon(Icons.lock_outline), onPressed: c.lock),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (banner != null)
            Card(
              color: Brand.amber.withValues(alpha: 0.18),
              child: Padding(padding: const EdgeInsets.all(14), child: Text(banner)),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync, color: Brand.teal),
              title: Text(_when(c.lastSyncedAt)),
              subtitle: Text(c.waitingChanges == 0 ? 'Everything is sent' : '${c.waitingChanges} change(s) waiting to send'),
              trailing: TextButton(onPressed: c.busy ? null : c.syncNow, child: Text(c.busy ? 'Syncing…' : 'Sync now')),
            ),
          ),
          if (c.message != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(c.message!, style: const TextStyle(color: Brand.coral))),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('This device', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text('Receipt numbers start with ${p.receiptPrefix}-'),
                Text('Plan: ${p.plan ?? 'Standard'}'),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder<bool>(
            future: c.shopIsSetUp(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
              if (snap.data != true) {
                return FilledButton.icon(
                  icon: const Icon(Icons.storefront),
                  label: const Text('Set up your shop'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => ShopSetupScreen(controller: c)));
                    await c.recheck();
                  },
                );
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (c.can('sale.create')) FilledButton.icon(
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Open till'),
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    final till = await c.openTill();
                    if (till != null) await nav.push(MaterialPageRoute<void>(builder: (_) => TillScreen(cart: till, printing: c.printService(), customers: c.customerRepository(), shifts: c.shiftRepository(), barcodes: c.barcodeRepository())));
                    await c.recheck();
                  },
                ),
                const SizedBox(height: 10),
                if (c.can('product.edit') || c.can('stock.receive')) OutlinedButton.icon(
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('Products and stock'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProductsScreen(controller: c)));
                    await c.recheck();
                  },
                ),
                const SizedBox(height: 10),
                if (c.can('sale.create') && c.returnRepository() != null && c.authRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('Returns and voids'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReturnScreen(repo: c.returnRepository()!, auth: c.authRepository()!, userId: c.currentUser?.id, printing: c.printService()))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('stock.receive') && c.purchasingRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: const Text('Suppliers and purchasing'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SuppliersScreen(repo: c.purchasingRepository()!, canPay: c.can('supplier.pay')))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('stock.adjust') && c.stockRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('Stock adjust and count'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StockScreen(repo: c.stockRepository()!, barcodes: c.barcodeRepository()))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('settings.edit') && c.settingsRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Settings'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(repo: c.settingsRepository()!))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('settings.edit') && c.zimraLicensed && c.fiscalRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('ZIMRA fiscal'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FiscalScreen(repo: c.fiscalRepository()!, gateway: c.fiscalGateway, signer: c.fiscalSigner))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('report.view') && c.reportRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.bar_chart_outlined),
                    label: const Text('Reports'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReportScreen(repo: c.reportRepository()!))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('shift.manage') && c.shiftRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.account_balance_wallet_outlined),
                    label: const Text('Shift and cash-up'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShiftScreen(repo: c.shiftRepository()!, printing: c.printService()))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('sale.create') && c.customerRepository() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.groups_outlined),
                    label: const Text('Customers'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomersScreen(repo: c.customerRepository()!, canEdit: c.can('customer.manage'), printing: c.printService()))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('sale.create') && c.printService() != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Receipt printer'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrinterScreen(printing: c.printService()!))),
                  ),
                  const SizedBox(height: 10),
                ],
                if (c.can('rate.edit')) OutlinedButton.icon(
                  icon: const Icon(Icons.currency_exchange),
                  label: const Text('Exchange rate'),
                  onPressed: () => showRateDialog(context, c),
                ),
                if (c.can('user.manage')) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.badge_outlined),
                    label: const Text('Staff'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StaffScreen(controller: c))),
                  ),
                ],
              ]);
            },
          ),
        ],
      ),
    );
  }
}
