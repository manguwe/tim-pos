import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../licence/licence.dart';
import '../reports/report_repository.dart';
import '../selling/catalog.dart' show CurrencyInfo;
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
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Brand.teal,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: const [
            BrandLogo(size: 120),
            SizedBox(height: 20),
            Text('TIM-POS', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 1)),
            SizedBox(height: 6),
            Text('Simple point of sale', style: TextStyle(color: Colors.white70)),
            SizedBox(height: 28),
            SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
          ]),
        ),
      );
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

/// The main screen: five tabs at the bottom. Each person only sees the tabs they are allowed to use.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  AppController get c => widget.controller;

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    await c.recheck();
  }

  Future<void> _startSelling() async {
    final nav = Navigator.of(context);
    final till = await c.openTill();
    if (till != null) await nav.push(MaterialPageRoute<void>(builder: (_) => TillScreen(cart: till, printing: c.printService(), customers: c.customerRepository(), shifts: c.shiftRepository(), barcodes: c.barcodeRepository())));
    await c.recheck();
  }

  String _when(int? ms) {
    if (ms == null) return 'Not synced yet';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Last synced ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _today(BuildContext context) {
    final lic = c.licence;
    final st = lic.state;
    final banner = switch (st.status) {
      LicenceStatus.grace => 'Licence expired. ${st.graceDaysLeft} day(s) left to renew before the app locks.',
      LicenceStatus.active when st.expiresSoon => 'Licence ends in ${st.daysLeft} day(s). Renew soon.',
      _ => null,
    };
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (banner != null) Card(color: Brand.amber.withValues(alpha: 0.18), child: Padding(padding: const EdgeInsets.all(14), child: Text(banner))),
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
            if (c.can('sale.create'))
              SizedBox(
                height: 76,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Brand.teal, textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  icon: const Icon(Icons.point_of_sale, size: 30),
                  label: const Text('Start selling'),
                  onPressed: _startSelling,
                ),
              ),
            const SizedBox(height: 14),
            if (c.can('report.view') && c.reportRepository() != null) _TodayCard(key: ValueKey('${c.waitingChanges}-${c.lastSyncedAt}'), repo: c.reportRepository()!),
          ]);
        },
      ),
      const SizedBox(height: 4),
      Card(
        child: ListTile(
          leading: const Icon(Icons.sync, color: Brand.teal),
          title: Text(_when(c.lastSyncedAt)),
          subtitle: Text(c.waitingChanges == 0 ? 'Everything is sent' : '${c.waitingChanges} change(s) waiting to send'),
          trailing: TextButton(onPressed: c.busy ? null : c.syncNow, child: Text(c.busy ? 'Syncing…' : 'Sync now')),
        ),
      ),
      if (c.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(c.message!, style: const TextStyle(color: Brand.coral))),
    ]);
  }

  Widget _list(List<Widget> tiles, String empty) => ListView(padding: const EdgeInsets.all(16), children: tiles.isEmpty ? [Padding(padding: const EdgeInsets.all(24), child: Text(empty))] : tiles);

  @override
  Widget build(BuildContext context) {
    final p = c.licence.payload!;
    final productTiles = <Widget>[
      if (c.can('product.edit') || c.can('stock.receive'))
        _HomeTile(icon: Icons.inventory_2_outlined, color: Brand.teal, label: 'Products', hint: 'Add items, prices and stock', onTap: () => _open(ProductsScreen(controller: c))),
      if (c.can('stock.adjust') && c.stockRepository() != null)
        _HomeTile(icon: Icons.fact_check_outlined, color: Brand.orange, label: 'Stock count', hint: 'Count the shelf, fix stock', onTap: () => _open(StockScreen(repo: c.stockRepository()!, barcodes: c.barcodeRepository()))),
    ];
    final peopleTiles = <Widget>[
      if (c.can('sale.create') && c.customerRepository() != null)
        _HomeTile(icon: Icons.groups_outlined, color: Brand.orange, label: 'Customers', hint: 'Who owes you, laybys', onTap: () => _open(CustomersScreen(repo: c.customerRepository()!, canEdit: c.can('customer.manage'), printing: c.printService()))),
      if (c.can('stock.receive') && c.purchasingRepository() != null)
        _HomeTile(icon: Icons.local_shipping_outlined, color: Brand.navy, label: 'Suppliers and buying', hint: 'Orders, deliveries, what you owe', onTap: () => _open(SuppliersScreen(repo: c.purchasingRepository()!, canPay: c.can('supplier.pay')))),
      if (c.can('user.manage'))
        _HomeTile(icon: Icons.badge_outlined, color: Brand.teal, label: 'Staff', hint: 'Add people and PINs', onTap: () => _open(StaffScreen(controller: c))),
    ];
    final reportTiles = <Widget>[
      if (c.can('report.view') && c.reportRepository() != null)
        _HomeTile(icon: Icons.bar_chart_outlined, color: Brand.green, label: 'Sales reports', hint: 'Sales, profit, stock', onTap: () => _open(ReportScreen(repo: c.reportRepository()!))),
      if (c.can('shift.manage') && c.shiftRepository() != null)
        _HomeTile(icon: Icons.account_balance_wallet_outlined, color: Brand.teal, label: 'Cash-up', hint: 'Count the cash at end of day', onTap: () => _open(ShiftScreen(repo: c.shiftRepository()!, printing: c.printService()))),
      if (c.can('sale.create') && c.returnRepository() != null && c.authRepository() != null)
        _HomeTile(icon: Icons.assignment_return_outlined, color: Brand.coral, label: 'Returns', hint: 'Customer brings an item back', onTap: () => _open(ReturnScreen(repo: c.returnRepository()!, auth: c.authRepository()!, userId: c.currentUser?.id, printing: c.printService()))),
    ];
    final moreTiles = <Widget>[
      if (c.can('rate.edit'))
        _HomeTile(icon: Icons.currency_exchange, color: Brand.navy, label: 'Exchange rate', hint: 'Set today\'s rate', onTap: () => showRateDialog(context, c)),
      if (c.can('sale.create') && c.printService() != null)
        _HomeTile(icon: Icons.print_outlined, color: Brand.navy, label: 'Receipt printer', hint: 'Connect your printer', onTap: () => _open(PrinterScreen(printing: c.printService()!))),
      if (c.can('settings.edit') && c.settingsRepository() != null)
        _HomeTile(icon: Icons.settings_outlined, color: Brand.navy, label: 'Settings', hint: 'Shop name, receipt, options', onTap: () => _open(SettingsScreen(repo: c.settingsRepository()!))),
      if (c.can('settings.edit') && c.zimraLicensed && c.fiscalRepository() != null)
        _HomeTile(icon: Icons.receipt_long_outlined, color: Brand.navy, label: 'ZIMRA fiscal', hint: 'Tax receipts', onTap: () => _open(FiscalScreen(repo: c.fiscalRepository()!, gateway: c.fiscalGateway, signer: c.fiscalSigner))),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('This phone', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Receipt numbers start with ${p.receiptPrefix}-'),
            Text('Plan: ${p.plan ?? 'Standard'}'),
          ]),
        ),
      ),
    ];

    // Only the tabs this person can use. Today and More are always there.
    final pages = <({String label, IconData icon, IconData selected, Widget body})>[
      (label: 'Today', icon: Icons.home_outlined, selected: Icons.home, body: _today(context)),
      if (productTiles.isNotEmpty) (label: 'Products', icon: Icons.inventory_2_outlined, selected: Icons.inventory_2, body: _list(productTiles, '')),
      if (peopleTiles.isNotEmpty) (label: 'People', icon: Icons.groups_outlined, selected: Icons.groups, body: _list(peopleTiles, '')),
      if (reportTiles.isNotEmpty) (label: 'Reports', icon: Icons.bar_chart_outlined, selected: Icons.bar_chart, body: _list(reportTiles, '')),
      (label: 'More', icon: Icons.more_horiz, selected: Icons.more_horiz, body: _list(moreTiles, '')),
    ];
    final tab = _tab < pages.length ? _tab : 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.shopName),
        actions: [
          if (c.currentUser != null)
            TextButton.icon(
              onPressed: c.lock,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              icon: const Icon(Icons.swap_horiz),
              label: Text('${c.currentUser!.name} - switch'),
            ),
        ],
      ),
      body: pages[tab].body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [for (final pg in pages) NavigationDestination(icon: Icon(pg.icon), selectedIcon: Icon(pg.selected), label: pg.label)],
      ),
    );
  }
}

/// Today's sales at a glance, shown on the Today tab. It reads the same figures as the reports.
class _TodayCard extends StatefulWidget {
  const _TodayCard({super.key, required this.repo});
  final ReportRepository repo;
  @override
  State<_TodayCard> createState() => _TodayCardState();
}

class _TodayCardState extends State<_TodayCard> {
  SalesSummary? _s;
  Map<String, CurrencyInfo> _cur = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final now = DateTime.now();
      final offset = now.timeZoneOffset.inMinutes;
      final midnight = DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch - offset * 60000;
      final rows = await widget.repo.db.query('select code, symbol, minor_units from currencies where deleted_at is null order by code');
      final cur = {for (final r in rows) r['code'] as String: CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, (r['minor_units'] as num).toInt())};
      final s = await widget.repo.salesSummary(DateRange(midnight, midnight + 86400000));
      if (mounted) setState(() { _s = s; _cur = cur; });
    } catch (_) {
      // The card is a convenience. If it cannot load, the rest of the screen still works.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) return const SizedBox.shrink();
    final base = _cur[s.baseCurrency];
    String money(int m) => base == null ? '$m' : base.format(m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Today', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(money(s.revenueMinor), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Brand.teal)),
          Text(s.sales == 0 ? 'No sales yet today' : '${s.sales} ${s.sales == 1 ? 'sale' : 'sales'}'),
        ]),
      ),
    );
  }
}

/// One big, easy-to-read row on the home screen: an icon, a plain name, and one line saying what it is for.
class _HomeTile extends StatelessWidget {
  const _HomeTile({required this.icon, required this.color, required this.label, required this.hint, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            leading: CircleAvatar(radius: 24, backgroundColor: color.withValues(alpha: 0.14), child: Icon(icon, color: color, size: 26)),
            title: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            subtitle: Text(hint),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        ),
      );
}
