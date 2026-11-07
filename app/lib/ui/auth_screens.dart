import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../auth/auth_repository.dart';
import 'theme.dart';

/// Who is working? Tap your name, then enter your PIN. Works offline; wrong PINs lock the name for a while on this phone.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<LoginUser> _users = [];
  LoginUser? _picked;
  String _pin = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.authRepository()?.listLoginUsers().then((u) {
      if (mounted) setState(() => _users = u);
    });
  }

  Future<void> _digit(String d) async {
    if (_busy || _picked == null || _pin.length >= 8) return;
    setState(() { _pin += d; _error = null; });
  }

  Future<void> _submit() async {
    final u = _picked;
    if (u == null || _pin.length < 4 || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.controller.signIn(u.id, _pin);
    } on AuthError catch (e) {
      final left = e.detail['attempts_left'];
      final until = e.detail['until'];
      setState(() {
        _pin = '';
        _error = e.code == 'locked' && until is int
            ? 'Too many wrong PINs. Try again at ${_clock(until)}.'
            : left != null ? '${e.message} $left ${left == 1 ? 'try' : 'tries'} left.' : e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final shop = widget.controller.licence.payload?.shopName ?? 'TIM-POS';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(shop, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Brand.teal, fontWeight: FontWeight.w800)),
                const SizedBox(height: 20),
                if (_picked == null) ...[
                  Text('Who is working?', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  for (final u in _users)
                    Card(child: ListTile(leading: const Icon(Icons.person_outline), title: Text(u.name), subtitle: Text(u.role ?? ''), onTap: () => setState(() { _picked = u; _pin = ''; _error = null; }))),
                ] else ...[
                  Text(_picked!.name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
                      Padding(padding: const EdgeInsets.all(6), child: Icon(i < _pin.length ? Icons.circle : Icons.circle_outlined, size: 18, color: Brand.navy)),
                  ]),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.coral))),
                  const SizedBox(height: 12),
                  GridView.count(
                    crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.6,
                    children: [
                      for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'back', '0', 'ok'])
                        k == 'back'
                            ? OutlinedButton(onPressed: () => setState(() { if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1); }), child: const Icon(Icons.backspace_outlined))
                            : k == 'ok'
                                ? FilledButton(onPressed: _pin.length >= 4 && !_busy ? _submit : null, child: const Icon(Icons.check))
                                : OutlinedButton(onPressed: () => _digit(k), child: Text(k, style: const TextStyle(fontSize: 22))),
                    ],
                  ),
                  TextButton(onPressed: () => setState(() { _picked = null; _pin = ''; _error = null; }), child: const Text('Not you?')),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Staff list for the owner or anyone with the user.manage permission: add people, change roles, reset a PIN, switch off.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<Map<String, Object?>> _staff = [];
  List<Map<String, Object?>> _roles = [];
  String? _message;

  AuthRepository get auth => widget.controller.authRepository()!;
  String get me => widget.controller.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await auth.listStaff();
    final r = await auth.listRoles();
    if (mounted) setState(() { _staff = s; _roles = r; });
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      setState(() => _message = done);
    } on AuthError catch (e) {
      setState(() => _message = e.message);
    }
    await _load();
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final pin = TextEditingController();
    String? role = _roles.isEmpty ? null : _roles.firstWhere((r) => r['name'] == 'Cashier', orElse: () => _roles.first)['id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add a person'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(initialValue: role, decoration: const InputDecoration(labelText: 'Role'), items: [for (final r in _roles) DropdownMenuItem(value: r['id'] as String, child: Text(r['name'] as String))], onChanged: (v) => setD(() => role = v)),
            const SizedBox(height: 8),
            TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'PIN (4 to 8 digits)')),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add'))],
        ),
      ),
    );
    if (ok == true && role != null) {
      await _run(() async { await auth.createUser(me, name: name.text, roleId: role!, pin: pin.text); }, done: '${name.text.trim()} added');
    }
    name.dispose();
    pin.dispose();
  }

  Future<void> _resetPin(String id) async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New PIN'),
        content: TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'New PIN (4 to 8 digits)')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Set PIN'))],
      ),
    );
    if (ok == true) await _run(() => auth.resetPin(me, id, pin.text), done: 'PIN changed');
    pin.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Staff'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
        floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.person_add_alt), label: const Text('Add person')),
        body: Column(children: [
          if (_message != null) Padding(padding: const EdgeInsets.all(10), child: Text(_message!)),
          Expanded(
            child: ListView.separated(
              itemCount: _staff.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final u = _staff[i];
                final active = u['is_active'] == 1;
                return ListTile(
                  title: Text(u['name'] as String, style: TextStyle(decoration: active ? null : TextDecoration.lineThrough)),
                  subtitle: Text((u['role'] as String?) ?? 'No role'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      final id = u['id'] as String;
                      if (v == 'pin') _resetPin(id);
                      if (v == 'toggle') _run(() => auth.setActive(me, id, !active), done: active ? 'Switched off' : 'Switched on');
                      if (v.startsWith('role:')) _run(() => auth.changeRole(me, id, v.substring(5)), done: 'Role changed');
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'pin', child: Text('Reset PIN')),
                      PopupMenuItem(value: 'toggle', child: Text(active ? 'Switch off' : 'Switch on')),
                      for (final r in _roles) PopupMenuItem(value: 'role:${r['id']}', child: Text('Make ${r['name']}')),
                    ],
                  ),
                );
              },
            ),
          ),
        ]),
      );
}
