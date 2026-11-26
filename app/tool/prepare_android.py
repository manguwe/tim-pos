#!/usr/bin/env python3
"""Applies TIM-POS's required Android settings to the android/ folder that `flutter create` made.
Run from the app folder after `flutter create`. Safe to run twice. Fails loudly if a file looks different than expected."""
import pathlib, re, shutil, sys

root = pathlib.Path('android')
gradle = next((p for p in (root / 'app' / 'build.gradle.kts', root / 'app' / 'build.gradle') if p.exists()), None)
manifest = root / 'app' / 'src' / 'main' / 'AndroidManifest.xml'
if gradle is None or not manifest.exists():
    sys.exit('android/ project not found. Run flutter create first.')

shutil.copy('android_setup/proguard-rules.pro', root / 'app' / 'proguard-rules.pro')

g = gradle.read_text()
kts = gradle.suffix == '.kts'
g = re.sub(r'minSdk(Version)?\s*=?\s*(flutter\.minSdkVersion|\d+)', 'minSdk = 23' if kts else 'minSdkVersion 23', g)
if 'proguard-rules.pro' not in g:
    rule = ('proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")' if kts
            else 'proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"')
    g2 = re.sub(r'(release\s*\{)', r'\1\n            ' + rule + ('\n            isMinifyEnabled = true' if kts else '\n            minifyEnabled true'), g, count=1)
    if g2 == g:
        sys.exit('could not find the release build type in ' + str(gradle))
    g = g2
gradle.write_text(g)

m = manifest.read_text()
if 'android:allowBackup' not in m:
    m = m.replace('<application', '<application\n        android:allowBackup="false"\n        android:fullBackupContent="false"', 1)
if 'android.permission.INTERNET' not in m:
    m = m.replace('<application', '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
for perm, extra in [('android.permission.BLUETOOTH', ' android:maxSdkVersion="30"'), ('android.permission.BLUETOOTH_ADMIN', ' android:maxSdkVersion="30"'),
                    ('android.permission.BLUETOOTH_CONNECT', ''), ('android.permission.BLUETOOTH_SCAN', ' android:usesPermissionFlags="neverForLocation"')]:
    if perm not in m:
        m = m.replace('<application', '<uses-permission android:name="' + perm + '"' + extra + '/>\n    <application', 1)
if 'android.permission.RECORD_AUDIO' not in m:
    m = m.replace('<application', '<uses-permission android:name="android.permission.RECORD_AUDIO"/>\n    <application', 1)
# Voice questions use the phone's own speech recogniser. Android 11+ needs to be told it may look for one.
if 'android.speech.RecognitionService' not in m:
    m = m.replace('<application', '<queries>\n        <intent><action android:name="android.speech.RecognitionService"/></intent>\n    </queries>\n    <application', 1)
if 'usesCleartextTraffic="true"' in m:
    sys.exit('cleartext traffic is on; the server must use HTTPS')
manifest.write_text(m)

# App icon and name. Replaces the default Flutter icon in every size and uses the name TIM-POS under the icon.
res = root / 'app' / 'src' / 'main' / 'res'
icons = pathlib.Path('android_setup') / 'icons'
for d in sorted(icons.glob('mipmap-*')):
    target = res / d.name
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy(d / 'ic_launcher.png', target / 'ic_launcher.png')
# an adaptive icon file, if the template made one, would hide ours on newer phones
for stale in res.glob('mipmap-anydpi*/ic_launcher*.xml'):
    stale.unlink()
m = manifest.read_text()
m = re.sub(r'android:label="[^"]*"', 'android:label="TIM-POS"', m, count=1)
manifest.write_text(m)
print('android settings applied')
