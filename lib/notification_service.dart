import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  VoidCallback? onQuickNote;
  bool _hasPendingQuickNote = false;

  /// 平台通知插件是否已初始化。桌面端 [init] 不会初始化插件（只用系统托盘），
  /// 因此在任何插件调用前必须检查，否则插件会抛
  /// "Flutter Local Notifications must be initialized before use"。
  bool _pluginReady = false;

  static const _channelId = 'moon_note_quick';
  static const _channelName = '快速记录';
  static const _notifyId = 1;
  static const _channel = MethodChannel('com.example.moon_note/service');

  Future<void> init() async {
    // Listen for quick-note commands from native (Quick Settings tile, etc.)
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onQuickNote') {
        if (onQuickNote != null) {
          onQuickNote!.call();
        } else {
          _hasPendingQuickNote = true;
        }
      }
    });

    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    if (!isDesktop) {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      final initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(settings: initSettings);

      const androidChannel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      // Check if app was launched via Quick Settings tile
      final hasPending =
          await _channel.invokeMethod('checkPendingQuickNote');
      if (hasPending == true) {
        _hasPendingQuickNote = true;
      }
      _pluginReady = true;
    }
  }

  /// Call this after the UI is ready to handle any pending quick-note action.
  void drainPendingQuickNote() {
    if (_hasPendingQuickNote && onQuickNote != null) {
      _hasPendingQuickNote = false;
      onQuickNote!.call();
    }
  }

  Future<bool> requestPermission() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  Future<void> startForeground() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (_) {}
  }

  Future<void> stopForeground() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (_) {}
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations')
          as bool? ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestBatteryOptimization() async {
    try {
      await _channel.invokeMethod('requestBatteryOptimization');
    } catch (_) {}
  }

  Future<void> openBackgroundPopupPermission() async {
    try {
      await _channel.invokeMethod('openBackgroundPopupPermission');
    } catch (_) {}
  }

  Future<void> showPersistent() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    // Start foreground service instead of just showing a notification
    await startForeground();
  }

  Future<void> cancel() async {
    if (_pluginReady) {
      await _plugin.cancel(id: _notifyId);
    }
    await stopForeground();
  }

  // ── Reminder notifications ─────────────────────────────────

  static const _reminderChannelId = 'moon_note_reminders';
  static const _reminderChannelName = '笔记提醒';

  Future<void> initReminderChannel() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    const androidChannel = AndroidNotificationChannel(
      _reminderChannelId,
      _reminderChannelName,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> showReminderNotification({
    required int id,
    required String noteTitle,
    required String body,
    String? noteId,
  }) async {
    // Fire in-app dialog callback on all platforms
    onReminderFired?.call(noteTitle, body, noteId);
  }

  void Function(String title, String body, String? noteId)? onReminderFired;

  // ── Todo notification ───────────────────────────────────────

  static const _todoChannelId = 'moon_note_todos';
  static const _todoChannelName = '待办事项';
  static const _todoNotifyId = 2;

  bool _todoNotificationVisible = true;

  Future<void> initTodoChannel() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    const androidChannel = AndroidNotificationChannel(
      _todoChannelId,
      _todoChannelName,
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  bool get isTodoNotificationVisible => _todoNotificationVisible;

  void setTodoNotificationVisible(bool visible) {
    _todoNotificationVisible = visible;
    if (!visible) {
      cancelTodoNotification();
    }
  }

  Future<void> showTodoNotification({required String title, required String body}) async {
    if (!_pluginReady || !_todoNotificationVisible) return;
    final android = AndroidNotificationDetails(
      _todoChannelId,
      _todoChannelName,
      channelDescription: '显示未完成的待办事项',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
    );
    await _plugin.show(
      id: _todoNotifyId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: android),
    );
  }

  /// 桌面端没有这个常驻通知（[showTodoNotification] 同样直接返回），
  /// 插件未初始化时也必须直接返回，否则会抛
  /// "Flutter Local Notifications must be initialized before use"，
  /// 而笔记列表每次刷新都会调到这里（home_page._updateTodoNotification）。
  Future<void> cancelTodoNotification() async {
    if (!_pluginReady) return;
    await _plugin.cancel(id: _todoNotifyId);
  }
}
