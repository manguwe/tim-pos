import 'package:flutter/material.dart';

import '../setup/setup_repository.dart';
import 'theme.dart';

/// A row of chips for choosing a department: "All", then one chip per department. Used on the till and the product list.
class DepartmentChips extends StatelessWidget {
  const DepartmentChips({super.key, required this.departments, required this.selected, required this.onSelect, this.showNone = false});

  /// Each item has `id` and `name`.
  final List<Map<String, Object?>> departments;

  /// null means "All". [noDepartment] means products that have none.
  final String? selected;
  final ValueChanged<String?> onSelect;
  final bool showNone;

  @override
  Widget build(BuildContext context) {
    if (departments.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        children: [
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: const Text('All'), selected: selected == null, onSelected: (_) => onSelect(null))),
          for (final d in departments)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(d['name'] as String), selected: selected == d['id'], onSelected: (_) => onSelect(d['id'] as String)),
            ),
          if (showNone)
            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: const Text('No department'), selected: selected == noDepartment, onSelected: (_) => onSelect(noDepartment))),
        ],
      ),
    );
  }
}

/// Add, rename and remove departments such as Groceries or Accessories.
class DepartmentsScreen extends StatefulWidget {
  const DepartmentsScreen({super.key, required this.repo});
  final SetupRepository repo;
  @override
  State<DepartmentsScreen> createState() => _DepartmentsScreenState();
}

class _DepartmentsScreenState extends State<DepartmentsScreen> {
  List<Map<String, Object?>> _rows = [];
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.repo.listCategories();
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (mounted) setState(() => _message = done);
    } on SetupError catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not save. Please send this to support (More, then Help and contact): $e');
    }
    await _load();
  }

  Future<void> _edit(Map<String, Object?>? row) async {
    final c = TextEditingController(text: row == null ? '' : row['name'] as String);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(row == null ? 'New department' : 'Rename department'),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Department name', hintText: 'For example: Groceries')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))],
      ),
    );
    final name = c.text;
    c.dispose();
    if (ok == true) await _run(() => widget.repo.saveCategory(id: row?['id'] as String?, name: name), done: row == null ? '${name.trim()} added' : 'Renamed');
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final n = (row['products'] as num).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${row['name']}?'),
        content: Text(n == 0 ? 'No products are in this department.' : '$n product(s) stay in your shop. They just will not belong to a department.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove'))],
      ),
    );
    if (ok == true) await _run(() => widget.repo.deleteCategory(row['id'] as String), done: 'Removed');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Departments')),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('New department')),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 90), children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Departments group your products, for example Groceries or Accessories. On the till you can tap a department to see only those items.'),
          ),
          if (_message != null) Padding(padding: const EdgeInsets.all(8), child: Text(_message!, style: const TextStyle(color: Brand.teal, fontWeight: FontWeight.w600))),
          if (_rows.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('No departments yet.', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Add common departments'),
                    onPressed: () => _run(() async { await widget.repo.addSuggestedCategories(); }, done: 'Added. Rename or remove any you do not need.'),
                  ),
                ]),
              ),
            ),
          for (final r in _rows)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(backgroundColor: Brand.teal.withValues(alpha: 0.15), child: const Icon(Icons.category_outlined, color: Brand.teal)),
                title: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${r['products']} product(s)'),
                onTap: () => _edit(r),
                trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
              ),
            ),
          if (_rows.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.playlist_add),
              label: const Text('Add common departments'),
              onPressed: () => _run(() async { await widget.repo.addSuggestedCategories(); }, done: 'Added the ones that were missing.'),
            ),
        ]),
      );
}
