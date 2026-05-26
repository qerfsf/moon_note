import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database.dart';
import 'home_page.dart';
import 'notification_service.dart';
import 'sync_service.dart';

final ValueNotifier<ThemeMode> themeNotifier =
    ValueNotifier(ThemeMode.system);

Future<void> loadTheme() async {
  final db = await DatabaseHelper.instance.database;
  final result = await db.query(
    'app_settings',
    where: 'key = ?',
    whereArgs: ['theme'],
  );
  if (result.isNotEmpty) {
    final v = result.first['value'] as String;
    switch (v) {
      case 'light':
        themeNotifier.value = ThemeMode.light;
        break;
      case 'dark':
        themeNotifier.value = ThemeMode.dark;
        break;
      default:
        themeNotifier.value = ThemeMode.system;
    }
  }
}

const _lightOnSurface = Color(0xFF37352F);
const _lightOnSurfaceVariant = Color(0xFF6B6B67);
const _lightOutline = Color(0xFF9B9A97);
const _lightOutlineVariant = Color(0xFFEDEDEB);
const _lightSurfaceContainerHighest = Color(0xFFF1F1EF);
const _lightError = Color(0xFFE03E3E);

const _darkSurface = Color(0xFF1E1E1E);
const _darkOnSurface = Color(0xFFE0E0DC);
const _darkOnSurfaceVariant = Color(0xFF9B9A97);
const _darkOutline = Color(0xFF6B6B67);
const _darkOutlineVariant = Color(0xFF2D2D2D);
const _darkSurfaceContainerHighest = Color(0xFF252525);

ColorScheme _lightScheme() => ColorScheme.fromSeed(
      seedColor: _lightOnSurface,
      brightness: Brightness.light,
      surface: Colors.white,
      onSurface: _lightOnSurface,
      onSurfaceVariant: _lightOnSurfaceVariant,
      outline: _lightOutline,
      outlineVariant: _lightOutlineVariant,
      surfaceContainerHighest: _lightSurfaceContainerHighest,
      error: _lightError,
    );

ColorScheme _darkScheme() => ColorScheme.fromSeed(
      seedColor: _darkOnSurface,
      brightness: Brightness.dark,
      surface: _darkSurface,
      onSurface: _darkOnSurface,
      onSurfaceVariant: _darkOnSurfaceVariant,
      outline: _darkOutline,
      outlineVariant: _darkOutlineVariant,
      surfaceContainerHighest: _darkSurfaceContainerHighest,
      error: _lightError,
    );

ThemeData _theme(ColorScheme cs) => ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      scaffoldBackgroundColor: cs.surface,
      dividerColor: cs.outlineVariant,
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: cs.surface,
        filled: true,
        border: InputBorder.none,
        hintStyle: TextStyle(color: cs.outline, fontSize: 17),
      ),
    );

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await DatabaseHelper.instance.database;
  await loadTheme();
  await NotificationService.instance.init();
  await NotificationService.instance.requestPermission();
  await NotificationService.instance.showPersistent();
  try {
    await SyncService.instance.startServer();
  } catch (_) {}
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    SyncService.instance.onAdbDeviceConnected = (host, port) async {
      await SyncService.instance.tryUsbSync();
    };
    SyncService.instance.startAdbMonitor();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const _title = 'Moon Note';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: _title,
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: _theme(_lightScheme()),
          darkTheme: _theme(_darkScheme()),
          home: const HomePage(),
        );
      },
    );
  }
}
