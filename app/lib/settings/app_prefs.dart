import 'package:flutter/material.dart';

import '../photos/photo_store.dart';

/// How this phone looks and behaves. Kept on the phone only (not synced), so each person can set up their own phone.
/// Anything that cannot be read or saved falls back to the normal setting, and the till carries on.
class AppPrefs extends ChangeNotifier {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  /// Text size choices. 1.0 is the phone's own size.
  static const textSizes = <String, double>{'small': 0.9, 'normal': 1.0, 'large': 1.15, 'xlarge': 1.3};

  /// Fonts that already exist on every Android phone, so nothing has to be downloaded.
  static const fonts = <String, ({String label, String? family})>{
    'standard': (label: 'Standard', family: null),
    'serif': (label: 'Serif', family: 'serif'),
    'condensed': (label: 'Narrow', family: 'sans-serif-condensed'),
    'casual': (label: 'Casual', family: 'casual'),
  };

  ThemeMode themeMode = ThemeMode.system;
  String textSize = 'normal';
  String font = 'standard';
  bool tillGrid = true;
  bool tapFeedback = true;
  bool sendPictures = true;

  double get textFactor => textSizes[textSize] ?? 1.0;
  String? get fontFamily => (fonts[font] ?? fonts['standard']!).family;

  Future<void> load() async {
    final t = await PhonePrefs.read('theme_mode');
    themeMode = t == 'light' ? ThemeMode.light : t == 'dark' ? ThemeMode.dark : ThemeMode.system;
    final ts = await PhonePrefs.read('text_size');
    textSize = textSizes.containsKey(ts) ? ts! : 'normal';
    final f = await PhonePrefs.read('font');
    font = fonts.containsKey(f) ? f! : 'standard';
    tillGrid = (await PhonePrefs.read('till_layout')) != 'list';
    tapFeedback = (await PhonePrefs.read('tap_feedback')) != 'off';
    sendPictures = (await PhonePrefs.read('send_pictures')) != 'off';
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await PhonePrefs.write('theme_mode', m == ThemeMode.light ? 'light' : m == ThemeMode.dark ? 'dark' : 'system');
  }

  Future<void> setTextSize(String s) async {
    if (!textSizes.containsKey(s)) return;
    textSize = s;
    notifyListeners();
    await PhonePrefs.write('text_size', s);
  }

  Future<void> setFont(String f) async {
    if (!fonts.containsKey(f)) return;
    font = f;
    notifyListeners();
    await PhonePrefs.write('font', f);
  }

  Future<void> setTillGrid(bool v) async {
    tillGrid = v;
    notifyListeners();
    await PhonePrefs.write('till_layout', v ? 'grid' : 'list');
  }

  Future<void> setTapFeedback(bool v) async {
    tapFeedback = v;
    notifyListeners();
    await PhonePrefs.write('tap_feedback', v ? 'on' : 'off');
  }

  Future<void> setSendPictures(bool v) async {
    sendPictures = v;
    notifyListeners();
    await PhonePrefs.write('send_pictures', v ? 'on' : 'off');
  }

  /// Back to how the app came.
  Future<void> resetLook() async {
    await setThemeMode(ThemeMode.system);
    await setTextSize('normal');
    await setFont('standard');
  }
}
