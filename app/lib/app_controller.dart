import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'auth/auth_repository.dart';
import 'barcodes/barcode_repository.dart';
import 'config.dart';
import 'core/b64url.dart';
import 'core/uuid7.dart';
import 'data/key_value_store.dart';
import 'customers/customer_repository.dart';
import 'data/local_db.dart';
import 'printing/bluetooth_transport.dart';
import 'returns/return_repository.dart';
import 'purchasing/purchasing_repository.dart';
import 'reports/report_repository.dart';
import 'fiscal/fiscal_repository.dart';
import 'settings/settings_repository.dart';
import 'shifts/shift_repository.dart';
import 'stock/stock_repository.dart';
import 'printing/print_service.dart';
import 'printing/printer_transport.dart';
import 'licence/licence.dart';
import 'licence/licence_guard.dart';
import 'selling/cart_controller.dart';
import 'setup/setup_repository.dart';
import 'selling/catalog.dart';
import 'selling/selling.dart';
import 'sync/api_client.dart';
import 'sync/sync_engine.dart';

enum AppPhase { starting, needsActivation, needsLogin, ready, locked }

/// Holds the app's state and ties the parts together: database, licence, server calls and sync.
/// Screens listen to it and call its methods; they never touch the database or the network directly.
class AppController extends ChangeNotifier {
  AppController({KeyValueStore? store, PrinterTransport? printerTransport})
      : store = store ?? const SecureKeyValueStore(),
        printerTransport = printerTransport ?? BluetoothTransport();

  final KeyValueStore store;
  final PrinterTransport printerTransport;
  late final LicenceGuard guard;
  late final ApiClient api;
  LocalDatabase? database;
  SyncEngine? engine;
  Timer? _ticker;
  Timer? _idleTimer;

  /// Who is signed in on this phone right now (null on the login screen).
  SignedIn? currentUser;
  bool _hasUsers = false;
  DateTime _lastActivity = DateTime.now();

  /// The till locks itself after this long without a touch, so a cashier walking away does not leave it open.
  static const Duration idleLimit = Duration(minutes: 5);

  AppPhase phase = AppPhase.starting;
  LicenceView licence = const LicenceView(LicenceState.notActivated());
  bool busy = false;

  /// A short message for the screen: the last problem, or null.
  String? message;
  int? lastSyncedAt;
  int waitingChanges = 0;

  Future<void> start() async {
    try {
      if (kLicencePublicKey.isEmpty) {
        throw StateError('This build has no licence key. Build the app with TIMPOS_LICENCE_PUBLIC_KEY.');
      }
      guard = LicenceGuard(store: store, publicKey: b64uDecode(kLicencePublicKey));
      api = ApiClient(baseUrl: kServerUrl, store: store);
      database = await LocalDatabase.open(store);
      final manifest = jsonDecode(await rootBundle.loadString('assets/sql/schema_manifest.json')) as Map<String, dynamic>;
      engine = SyncEngine(
        db: database!.sql,
        api: api,
        kinds: {for (final e in manifest.entries) e.key: (e.value as Map<String, dynamic>)['kind'] as String},
      );
      await recheck();
      // Expiry and the clock rule are checked every minute, so a licence ending mid-shift is noticed.
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) => recheck());
      _idleTimer = Timer.periodic(const Duration(seconds: 15), (_) => _checkIdle());
    } catch (e) {
      // Never leave the person on a blank screen: say what is wrong.
      message = e is StateError ? e.message : 'The app could not start: $e';
      phase = AppPhase.locked;
      notifyListeners();
    }
  }

  Future<void> recheck() async {
    licence = await guard.check();
    _hasUsers = await authRepository()?.hasUsers() ?? false;
    phase = switch (licence.state.status) {
      LicenceStatus.notActivated => AppPhase.needsActivation,
      LicenceStatus.locked => AppPhase.locked,
      _ => (_hasUsers && currentUser == null) ? AppPhase.needsLogin : AppPhase.ready,
    };
    final e = engine;
    if (e != null) {
      final s = await e.status();
      lastSyncedAt = s.lastSuccessAt;
      waitingChanges = s.waiting;
    }
    notifyListeners();
  }

  /// First-time set-up. Needs a data connection once; after that the phone works offline.
  Future<bool> activate(String licenceKey, String deviceName) async {
    if (busy) return false;
    busy = true;
    message = null;
    notifyListeners();
    try {
      var fingerprint = await store.read(Keys.fingerprint);
      if (fingerprint == null) {
        fingerprint = newId(); // random and kept in the Keystore: identifies this install, no phone details needed
        await store.write(Keys.fingerprint, fingerprint);
      }
      final res = await api.send('POST', '/v1/activate', signedIn: false, body: {
        'licence_key': licenceKey.trim(),
        'fingerprint': fingerprint,
        'device_name': deviceName.trim().isEmpty ? 'Till' : deviceName.trim(),
        'platform': defaultTargetPlatform.name,
        'app_version': kAppVersion,
      });
      if (res.status != 201) {
        message = res.errorMessage.isNotEmpty ? res.errorMessage : 'Activation failed (${res.status}).';
        return false;
      }
      await store.write(Keys.deviceId, res.json['device_id'] as String);
      await store.write(Keys.deviceSecret, res.json['device_secret'] as String);
      if (!await guard.acceptToken(res.json['licence_token'] as String)) {
        message = 'The server sent a licence this app cannot verify. Check that the app and server use the same key.';
        await store.delete(Keys.deviceId);
        await store.delete(Keys.deviceSecret);
        return false;
      }
      return true;
    } on NetworkException {
      message = 'Cannot reach the server. Activation needs a data connection once.';
      return false;
    } finally {
      busy = false;
      await recheck();
    }
  }

  /// Gets a fresh licence, then sends and fetches changes. Costs a few kilobytes when nothing has changed.
  Future<void> syncNow() async {
    final e = engine;
    if (busy || e == null) return;
    busy = true;
    message = null;
    notifyListeners();
    try {
      final r = await api.send('POST', '/v1/licence/refresh');
      if (r.status != 200) {
        await _handleRefusal(r);
        return;
      }
      await guard.acceptToken(r.json['licence_token'] as String);
      final report = await e.sync();
      if (report.rejected.isNotEmpty) {
        message = '${report.rejected.length} change(s) were refused by the server. They are kept on this phone.';
      }
    } on SyncException catch (ex) {
      await _handleRefusal(ex.response);
    } on NetworkException {
      message = 'No connection. Your work is safe on this phone and will sync later.';
    } finally {
      busy = false;
      await recheck();
    }
  }

  AuthRepository? authRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return AuthRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId);
  }

  /// Call on any touch. Keeps the idle lock from firing while someone is working.
  void touch() => _lastActivity = DateTime.now();

  void _checkIdle() {
    if (currentUser != null && DateTime.now().difference(_lastActivity) > idleLimit) lock();
  }

  /// Signs the user out. The next person enters their own PIN.
  void lock() {
    currentUser = null;
    recheck();
  }

  /// Checks a PIN. Throws [AuthError] with a message the screen can show.
  Future<void> signIn(String userId, String pin) async {
    final auth = authRepository();
    if (auth == null) throw AuthError('unavailable', 'The app is not ready.');
    currentUser = await auth.login(userId, pin);
    _lastActivity = DateTime.now();
    await recheck();
  }

  bool can(String permission) => currentUser?.can(permission) ?? false;

  /// Set-up and catalogue writes for this phone, or null until the licence and database are ready.
  SetupRepository? setupRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return SetupRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  ReturnRepository? returnRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return ReturnRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, receiptPrefix: p.receiptPrefix, userId: currentUser?.id);
  }

  ReportRepository? reportRepository() {
    final db = database;
    if (db == null || !licence.state.canWork) return null;
    return ReportRepository(db.sql);
  }

  /// ZIMRA fiscalisation (see fiscal/fiscal_repository.dart). The gateway and signer stay unset until the HTTPS client and the
  /// signing code, written from ZIMRA's official text, are installed. Until then receipts wait in the queue and nothing is lost.
  Gateway? fiscalGateway;
  Signer fiscalSigner = const UnavailableSigner();

  FiscalRepository? fiscalRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return FiscalRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  bool get zimraLicensed => licence.payload?.hasFeature('zimra') ?? false;

  SettingsRepository? settingsRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return SettingsRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  StockRepository? stockRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return StockRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  BarcodeRepository? barcodeRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return BarcodeRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  PurchasingRepository? purchasingRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return PurchasingRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, receiptPrefix: p.receiptPrefix, userId: currentUser?.id);
  }

  ShiftRepository? shiftRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return ShiftRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, userId: currentUser?.id);
  }

  CustomerRepository? customerRepository() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return CustomerRepository(db: db.sql, shopId: p.shopId, deviceId: p.deviceId, receiptPrefix: p.receiptPrefix, userId: currentUser?.id);
  }

  PrintService? printService() {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    return PrintService(db: db.sql, transport: printerTransport, deviceId: p.deviceId);
  }

  Future<bool> shopIsSetUp() async => await setupRepository()?.isSetUp() ?? false;

  /// Builds a till for this phone. Returns null while the shop has no branch or currencies yet (set-up comes first).
  Future<CartController?> openTill() async {
    final db = database;
    final p = licence.payload;
    if (db == null || p == null || !licence.state.canWork) return null;
    final catalog = CatalogRepository(db.sql);
    final setup = await catalog.setup();
    if (setup == null || setup.currencies.isEmpty) {
      message = 'The shop is not set up yet: it needs a branch and currencies before selling.';
      notifyListeners();
      return null;
    }
    final engine = SellingEngine(db: db.sql, context: SaleContext(shopId: p.shopId, deviceId: p.deviceId, receiptPrefix: p.receiptPrefix));
    return CartController(engine: engine, catalog: catalog, setup: setup, userId: currentUser?.id);
  }

  Future<void> _handleRefusal(ApiResponse r) async {
    if (r.isLocked) {
      await guard.markServerRefused(r.errorCode);
      message = r.errorMessage;
    } else {
      message = r.errorMessage.isNotEmpty ? r.errorMessage : 'The server refused the request (${r.status}).';
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _idleTimer?.cancel();
    database?.close();
    super.dispose();
  }
}
