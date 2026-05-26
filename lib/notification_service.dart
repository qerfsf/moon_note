import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  VoidCallback? onQuickNote;

  static const _channelId = 'moon_note_quick';
  static const _channelName = '快速记录';
  static const _notifyId = 1;

  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windowsInit = WindowsInitializationSettings(
      appName: 'Moon Note',
      appUserModelId: 'com.example.moon_note',
      guid: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    );
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final initSettings = InitializationSettings(
      android: androidInit,
      windows: windowsInit,
    );
    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.notificationResponseType ==
            NotificationResponseType.selectedNotification) {
          onQuickNote?.call();
        }
      },
    );

    if (!isDesktop) {
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

  Future<void> showPersistent() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) return;
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      priority: Priority.low,
      importance: Importance.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      icon: '@mipmap/ic_launcher',
      visibility: NotificationVisibility.public,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: _notifyId,
      title: 'Moon Note',
      body: '点击快速记录',
      notificationDetails: details,
    );
  }

  Future<void> cancel() async {
    await _plugin.cancel(id: _notifyId);
  }
}
