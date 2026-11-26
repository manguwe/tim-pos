import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/reports/report_repository.dart';
import 'package:tim_pos/share/report_text.dart';

void main() {
  test('the shared report names the shop and its figures', () {
    final s = SalesSummary(
      baseCurrency: 'USD', byCurrency: const [], sales: 12, returns: 0, revenueMinor: 45050, taxMinor: 0,
      costMinor: 30000, profitMinor: 15050, linesWithoutCost: 1, averageSaleMinor: 3754, openLayby: const [],
    );
    final p = ProductRow('p1', 'Bread')..revenueMinor = 9000;
    final t = reportText(shopName: 'Tendai Shop', periodLabel: 'Today', summary: s, top: [p]);
    expect(t, contains('Tendai Shop: Today report'));
    expect(t, contains('Revenue: USD 450.50'));
    expect(t, contains('Profit: USD 150.50 (some items have no cost set)'));
    expect(t, contains('Top: Bread (USD 90.00)'));
  });
}
