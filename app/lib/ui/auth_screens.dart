import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../auth/auth_repository.dart';
import '../l10n/strings.dart';
import '../share/whatsapp.dart';
import 'about_screen.dart';
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

  Future<void> _forgotPin(LoginUser u) async {
    final c = widget.controller;
    final auth = c.authRepository();
    if (auth == null) return;
    final key = c.licence.payload?.recoveryKey ?? '';
    final challenge = await auth.pendingPinRecovery() ?? await auth.startPinRecovery();
    if (!mounted) return;
    final code = TextEditingController();
    final pin = TextEditingController();
    String? error;
    var busy = false;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Forgot PIN'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('For ${u.name}. Only the shop owner or manager should do this.'),
              const SizedBox(height: 10),
              const Text('1. Send this number to your supplier:'),
              Center(child: Text(challenge, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 3))),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.chat),
                  label: const Text('Send on WhatsApp'),
                  onPressed: () => openOrCopy(
                    ctx,
                    whatsappLink('PIN reset for ${c.licence.payload?.shopName ?? 'my shop'}, ${u.name}. Number: $challenge', phone: AboutScreen.supportPhone),
                    'PIN reset number: $challenge',
                  ),
                ),
              ),
              const Text('2. Type the 8-digit code they give you, then choose a new PIN:'),
              TextField(controller: code, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(labelText: 'Code from supplier')),
              TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'New PIN (4 to 8 digits)')),
              if (error != null) Text(error!, style: const TextStyle(color: Brand.coral)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() { busy = true; error = null; });
                      try {
                        await auth.recoverPin(userId: u.id, recoveryKey: key, code: code.text, newPin: pin.text.trim());
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } on AuthError catch (e) {
                        setD(() { busy = false; error = e.message; });
                      }
                    },
              child: const Text('Set new PIN'),
            ),
          ],
        ),
      ),
    );
    if (done == true && mounted) {
      setState(() { _pin = ''; _error = 'PIN changed. Enter your new PIN.'; });
    }
  }

  String _clock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _roleName(String? r) {
    if (r == null || r.isEmpty) return '';
    final t = r.replaceAll('_', ' ');
    return t[0].toUpperCase() + t.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final shop = widget.controller.licence.payload?.shopName ?? 'TIM-POS';
    final picked = _picked;
    return Scaffold(
      backgroundColor: Brand.background,
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 24, 24, 26),
          decoration: const BoxDecoration(color: Brand.teal, borderRadius: BorderRadius.vertical(bottom: Radius.circular(28))),
          child: Column(children: [
            const BrandLogo(size: 84),
            const SizedBox(height: 12),
            Text(shop, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(picked == null ? tr('Who is working?') : 'Hello, ${picked.name}. Enter your PIN.', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (picked == null) ...[
                    if (_users.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Loading...', textAlign: TextAlign.center)),
                    for (final u in _users)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: CircleAvatar(
                              radius: 26,
                              backgroundColor: Brand.teal.withValues(alpha: 0.15),
                              child: Text(u.name.isEmpty ? '?' : u.name.substring(0, 1).toUpperCase(), style: const TextStyle(color: Brand.teal, fontSize: 22, fontWeight: FontWeight.w800)),
                            ),
                            title: Text(u.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            subtitle: Text(_roleName(u.role)),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => setState(() { _picked = u; _pin = ''; _error = null; }),
                          ),
                        ),
                      ),
                  ] else ...[
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
                        Padding(padding: const EdgeInsets.all(7), child: Icon(i < _pin.length ? Icons.circle : Icons.circle_outlined, size: 22, color: Brand.navy)),
                    ]),
                    if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.coral))),
                    const SizedBox(height: 14),
                    GridView.count(
                      crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.5,
                      children: [
                        for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'back', '0', 'ok'])
                          k == 'back'
                              ? OutlinedButton(onPressed: () => setState(() { if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1); }), child: const Icon(Icons.backspace_outlined))
                              : k == 'ok'
                                  ? FilledButton(onPressed: _pin.length >= 4 && !_busy ? _submit : null, child: const Icon(Icons.check, size: 28))
                                  : OutlinedButton(style: OutlinedButton.styleFrom(backgroundColor: Colors.white), onPressed: () => _digit(k), child: Text(k, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
                      ],
                    ),
                    TextButton(onPressed: () => setState(() { _picked = null; _pin = ''; _error = null; }), child: Text(tr('Not you? Go back'))),
                    TextButton(onPressed: () => _forgotPin(picked), child: Text(tr('Forgot PIN?'))),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
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
    } catch (e) {
      // Never fail silently: show what went wrong so it can be sent to support.
      setState(() => _message = 'Could not do that. Please send this to support (More, then Help and contact): $e');
    }
    await _load();
  }

  Future<void> _add() async {
    final limit = widget.controller.maxUsers;
    final active = _staff.where((u) => u['is_active'] == 1).length;
    if (limit > 0 && active >= limit) {
      setState(() => _message = 'Your plan allows up to $limit people. To add more, ask your supplier to move you to a bigger plan (More, then Help and contact).');
      return;
    }
    if (_roles.isEmpty) {
      setState(() => _message = 'No roles were found on this phone, so a person cannot be added yet. Sync once while online and try again.');
      return;
    }
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
          if (widget.controller.maxUsers > 0)
            Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text('${_staff.where((u) => u['is_active'] == 1).length} of ${widget.controller.maxUsers} people on your plan', style: const TextStyle(color: Colors.grey))),
          if (_message != null) Padding(padding: const EdgeInsets.all(10), child: Text(_message!, style: const TextStyle(color: Brand.coral))),
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
