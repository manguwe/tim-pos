import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/l10n/strings.dart';
import 'package:tim_pos/settings/app_prefs.dart';

void main() {
  test('both languages cover the same phrases, with no empty text', () {
    expect(shona.keys.toSet(), ndebele.keys.toSet());
    for (final m in [shona, ndebele]) {
      for (final e in m.entries) {
        expect(e.value.trim(), isNotEmpty, reason: e.key);
      }
    }
  });

  test('tr() follows the chosen language and falls back to English', () {
    final p = AppPrefs.instance;
    p.language = 'sn';
    expect(tr('Today'), 'Nhasi');
    expect(tr('Something not translated'), 'Something not translated');
    p.language = 'nd';
    expect(tr('Today'), 'Namhla');
    p.language = 'en';
    expect(tr('Today'), 'Today');
  });
}
