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
if 'usesCleartextTraffic="true"' in m:
    sys.exit('cleartext traffic is on; the server must use HTTPS')
manifest.write_text(m)
print('android settings applied')
