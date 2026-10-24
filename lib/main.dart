import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/pronunciation_screen.dart';

const appVersion = '1.3.5+9';
const appWindowTitle = 'Simulateur de prononciation française';

const _kWinX = 'french-window-x';
const _kWinY = 'french-window-y';
const _kWinW = 'french-window-w';
const _kWinH = 'french-window-h';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();

    const minSize = Size(700, 500);
    var size = const Size(1200, 860);
    Offset? position;
    var center = true;

    try {
      final p = await SharedPreferences.getInstance();
      final w = p.getDouble(_kWinW);
      final h = p.getDouble(_kWinH);
      final x = p.getDouble(_kWinX);
      final y = p.getDouble(_kWinY);
      if (w != null && h != null && w >= minSize.width && h >= minSize.height) {
        size = Size(w, h);
      }
      if (x != null && y != null) {
        position = Offset(x, y);
        center = false;
      }
    } catch (_) {}

    final options = WindowOptions(
      size: size,
      minimumSize: minSize,
      center: center,
      title: appWindowTitle,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      if (position != null) {
        try {
          await windowManager.setPosition(position);
        } catch (_) {}
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const FrenchApp());
}

class FrenchApp extends StatefulWidget {
  const FrenchApp({super.key});

  @override
  State<FrenchApp> createState() => _FrenchAppState();
}

class _FrenchAppState extends State<FrenchApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      // Нужно, чтобы onWindowClose вызывался до фактического закрытия.
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _saveWindowBounds() async {
    if (!Platform.isWindows) return;
    try {
      final bounds = await windowManager.getBounds();
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kWinX, bounds.left);
      await p.setDouble(_kWinY, bounds.top);
      await p.setDouble(_kWinW, bounds.width);
      await p.setDouble(_kWinH, bounds.height);
    } catch (_) {}
  }

  @override
  void onWindowMoved() {
    _saveWindowBounds();
  }

  @override
  void onWindowResized() {
    _saveWindowBounds();
  }

  @override
  void onWindowClose() async {
    await _saveWindowBounds();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appWindowTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF002654),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const PronunciationScreen(),
    );
  }
}
