import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'settings/app_prefs.dart';
import 'ui/auth_screens.dart';
import 'ui/screens.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPrefs.instance.load();
  final controller = AppController();
  runApp(TimPosApp(controller: controller));
  await controller.start();
}

class TimPosApp extends StatelessWidget {
  const TimPosApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final prefs = AppPrefs.instance;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => MaterialApp(
      title: 'TIM-POS',
      debugShowCheckedModeBanner: false,
      themeMode: prefs.themeMode,
      theme: buildTheme(Brightness.light, fontFamily: prefs.fontFamily),
      darkTheme: buildTheme(Brightness.dark, fontFamily: prefs.fontFamily),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final factor = (mq.textScaler.scale(1) * prefs.textFactor).clamp(0.8, 2.0).toDouble();
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(factor)),
          child: Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => controller.touch(), child: child),
        );
      },
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => switch (controller.phase) {
          AppPhase.starting => const SplashScreen(),
          AppPhase.needsActivation => ActivationScreen(controller: controller),
          AppPhase.needsLogin => LoginScreen(controller: controller),
          AppPhase.locked => LockedScreen(controller: controller),
          AppPhase.ready => HomeScreen(controller: controller),
        },
      ),
      ),
    );
  }
}
