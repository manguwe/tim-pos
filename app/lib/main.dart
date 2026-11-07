import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/auth_screens.dart';
import 'ui/screens.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(TimPosApp(controller: controller));
  await controller.start();
}

class TimPosApp extends StatelessWidget {
  const TimPosApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TIM-POS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      builder: (context, child) => Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => controller.touch(), child: child),
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
    );
  }
}
