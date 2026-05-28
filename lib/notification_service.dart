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
    await _plugin.cancel(id: _notifyId);
    await stopForeground();
  }
}
