import '../reports/report_repository.dart';

String _m(int minor, String cur) => '$cur ${(minor / 100).toStringAsFixed(2)}';

/// A short report that can be sent by WhatsApp. Same facts as the owner's server report message.
String reportText({
  required String shopName,
  required String periodLabel,
  required SalesSummary summary,
  required List<ProductRow> top,
}) {
  final c = summary.baseCurrency;
  final lines = <String>[
    '$shopName: $periodLabel report',
    'Sales: ${summary.sales}',
    'Revenue: ${_m(summary.revenueMinor, c)}',
    'Profit: ${_m(summary.profitMinor, c)}${summary.linesWithoutCost > 0 ? ' (some items have no cost set)' : ''}',
  ];
  if (top.isNotEmpty) {
    lines.add('Top: ${top.take(3).map((p) => '${p.name} (${_m(p.revenueMinor, c)})').join(', ')}');
  }
  return lines.join('\n');
}
