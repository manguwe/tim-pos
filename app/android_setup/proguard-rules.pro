# SQLCipher is reached through native code, so the release build must not strip or rename it.
-keep class net.sqlcipher.** { *; }
-keep class net.zetetic.** { *; }
