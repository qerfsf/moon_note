import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database.dart';
import 'home_page.dart';
import 'notification_service.dart';
import 'sync_service.dart';

import 'app_navigator.dart';
import 'note_window.dart';

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

ColorScheme lightScheme() => ColorScheme.fromSeed(
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

ColorScheme darkScheme() => ColorScheme.fromSeed(
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

ThemeData appTheme(ColorScheme cs) => ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
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

/// 从命令行参数里取 `--key value` 形式的值。
String? _argValue(List<String> args, String key) {
  final i = args.indexOf(key);
  if (i < 0 || i + 1 >= args.length) return null;
  final v = args[i + 1].trim();
  return v.isEmpty ? null : v;
}

/// 公开版,给单元测试用:判断这次启动是不是「独立笔记窗口」模式,
/// 是的话返回笔记 id。
String? standaloneNoteIdFromArgs(List<String> args) => _argValue(args, '--note');

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await DatabaseHelper.instance.database;

  // ── 单独窗口模式 ──
  // 桌面端「一个笔记一个窗口」是用**独立进程**实现的:
  //   moon_note.exe --note <笔记id>
  // 每个进程一个窗口,天然支持同时开多篇。这样不用引入多引擎/多窗口的第三方
  // 插件,也不会让两个窗口共享一套内存状态。代价是各窗口之间不会互相刷新,
  // 改完一篇要回到列表刷新一下才看到(数据库是共享的,数据本身不会丢)。
  //
  // 注意:笔记窗口**不起 HTTP 服务、不初始化通知、不监视 adb** ——
  // 那些只该由主窗口做,否则 9090 端口冲突、通知重复弹。
  final standaloneNoteId = standaloneNoteIdFromArgs(args);
  if (standaloneNoteId != null) {
    await loadTheme();
    runApp(NoteWindowApp(noteId: standaloneNoteId));
    return;
  }

  await loadTheme();
  await NotificationService.instance.init();
  await NotificationService.instance.requestPermission();
  await NotificationService.instance.showPersistent();
  await NotificationService.instance.initReminderChannel();
  await NotificationService.instance.initTodoChannel();
  try {
    await SyncService.instance.startServer();
  } catch (_) {}
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    SyncService.instance.onAdbDeviceConnected = (host, port) async {
      await SyncService.instance.tryUsbSync();
    };
    SyncService.instance.startAdbMonitor();
    Future.delayed(const Duration(seconds: 2), () {
      SyncService.instance.tryUsbSync();
    });
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
          navigatorKey: navigatorKey,
          title: _title,
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: appTheme(lightScheme()),
          darkTheme: appTheme(darkScheme()),
          home: const HomePage(),
        );
      },
    );
  }
}
