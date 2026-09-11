import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'database.dart';
import 'image_service.dart';
import 'sync_change.dart';

enum SyncStatus { idle, connecting, syncing, error }


class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  HttpServer? _server;
  bool _isServerRunning = false;
  int _port = 9090;

  final ValueNotifier<SyncStatus> statusNotifier =
      ValueNotifier(SyncStatus.idle);
  final ValueNotifier<String> messageNotifier = ValueNotifier('');
  final ValueNotifier<int> lastSyncTimeNotifier = ValueNotifier(0);
  final ValueNotifier<int> dataVersionNotifier = ValueNotifier(0);

  /// 最近一轮【有变更】的同步结果,供 UI 弹出通知与详情面板。
  final ValueNotifier<SyncRoundResult?> roundResultNotifier =
      ValueNotifier<SyncRoundResult?>(null);

  /// 每完成一轮 fullSync 递增(无论有无变更)。
  int _roundSeq = 0;
  int get roundSeq => _roundSeq;

  /// 本轮累计的变更项(在 fullSync 内使用)。
  final List<SyncChangeItem> _roundItems = [];

  /// 本轮涉及的回收站永久删除条数(发送 + 收到的 deleted_ids)。
  int _roundHardDeletes = 0;

  Process? _adbMonitorProcess;
  final _knownAdbDevices = <String>{};
  bool _adbSyncLock = false;
  bool _adbSyncPending = false;
  Timer? _adbDebounce;
  final List<String> _adbPendingLines = [];
  int _lastAdbSyncTime = 0;
  int _lockAcquiredAt = 0;
  static const _adbSyncCooldownMs = 10000;
  static const _lockWatchdogMs = 60000;
  final List<String> _pendingDeleteIds = [];
  bool _pendingLoaded = false;
  static const _pendingDeletesKey = 'pending_deletes_json';

  /// 从数据库恢复上次未传播完的永久删除(清空回收站后重启不丢失)。
  Future<void> _ensurePendingLoaded() async {
    if (_pendingLoaded) return;
    _pendingLoaded = true;
    try {
      final db = await DatabaseHelper.instance.database;
      final res = await db.query('app_settings',
          where: 'key = ?', whereArgs: [_pendingDeletesKey]);
      if (res.isNotEmpty) {
        final raw = res.first['value'] as String;
        if (raw.isNotEmpty && raw != '[]') {
          final list = jsonDecode(raw) as List;
          for (final id in list) {
            if (id is String && !_pendingDeleteIds.contains(id)) {
              _pendingDeleteIds.add(id);
            }
          }
          if (_pendingDeleteIds.isNotEmpty) {
            print('[SYNC] 恢复待传播的永久删除: ${_pendingDeleteIds.length} 项');
          }
        }
      }
    } catch (e) {
      print('[SYNC] 加载永久删除记录失败: $e');
    }
  }

  /// 把当前待传播的永久删除列表写入数据库,保证重启不丢失。
  Future<void> _persistPendingDeletes() async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.rawInsert(
        'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
        [_pendingDeletesKey, jsonEncode(_pendingDeleteIds)],
      );
    } catch (e) {
      print('[SYNC] 保存永久删除记录失败: $e');
    }
  }

  void addPendingDelete(String id) {
    _ensurePendingLoaded();
    if (!_pendingDeleteIds.contains(id)) {
      _pendingDeleteIds.add(id);
      _persistPendingDeletes();
    }
  }

  void addPendingDeletes(List<String> ids) {
    _ensurePendingLoaded();
    var changed = false;
    for (final id in ids) {
      if (!_pendingDeleteIds.contains(id)) {
        _pendingDeleteIds.add(id);
        changed = true;
      }
    }
    if (changed) _persistPendingDeletes();
  }
  void Function(String host, int port)? onAdbDeviceConnected;

  bool get isServerRunning => _isServerRunning;
  int get port => _port;

  Future<void> startServer({int port = 9090}) async {
    if (_isServerRunning) return;
    _port = port;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isServerRunning = true;
      _server!.listen(_handleRequest);
      messageNotifier.value = '服务已启动，端口 $port';
    } catch (e) {
      messageNotifier.value = '启动失败: 端口 $port 被占用或无权限';
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _isServerRunning = false;
    messageNotifier.value = '服务已停止';
  }

  Future<List<String>> getLocalIps() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          ips.add(addr.address);
        }
      }
    } catch (_) {}
    return ips;
  }

  bool isOwnAddress(String host) {
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return true;
    }
    return false;
  }

  String get _adbPath {
    final androidHome =
        Platform.environment['ANDROID_HOME'] ?? Platform.environment['ANDROID_SDK_ROOT'];
    if (androidHome != null) {
      final path = '$androidHome${Platform.pathSeparator}platform-tools${Platform.pathSeparator}adb${Platform.isWindows ? '.exe' : ''}';
      if (File(path).existsSync()) return path;
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      final path = '$localAppData${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk${Platform.pathSeparator}platform-tools${Platform.pathSeparator}adb${Platform.isWindows ? '.exe' : ''}';
      if (File(path).existsSync()) return path;
    }
    // Fallback: try common locations
    final fallbacks = Platform.isWindows ? [
      'C:\\Users\\${Platform.environment['USERNAME']}\\AppData\\Local\\Android\\Sdk\\platform-tools\\adb.exe',
      'C:\\Android\\Sdk\\platform-tools\\adb.exe',
      'D:\\Android\\Sdk\\platform-tools\\adb.exe',
    ] : <String>[];
    for (final fb in fallbacks) {
      if (File(fb).existsSync()) return fb;
    }
    return 'adb';
  }

  Future<List<String>> getAdbDevices() async {
    try {
      final result = await Process.run(_adbPath, ['devices']).timeout(
        const Duration(seconds: 5),
        onTimeout: () => ProcessResult(0, 0, '', ''),
      );
      final lines = (result.stdout as String).split('\n');
      final devices = <String>[];
      for (final line in lines.skip(1)) {
        if (line.trim().isNotEmpty && line.contains('\tdevice')) {
          devices.add(line.split('\t').first.trim());
        }
      }
      return devices;
    } catch (_) {
      return [];
    }
  }

  Future<bool> setupAdbReverse({int port = 9090}) async {
    try {
      final result =
          await Process.run(_adbPath, ['reverse', 'tcp:$port', 'tcp:$port']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removeAdbReverse({int port = 9090}) async {
    try {
      final result = await Process.run(
          _adbPath, ['reverse', '--remove', 'tcp:$port']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setupAdbForward({int localPort = 9091, int remotePort = 9090}) async {
    try {
      final result = await Process.run(
          _adbPath, ['forward', 'tcp:$localPort', 'tcp:$remotePort']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _getDeviceWifiIp(String deviceId) async {
    try {
      final result = await Process.run(
          _adbPath, ['-s', deviceId, 'shell', 'ip', 'addr', 'show', 'wlan0']);
      final output = result.stdout as String;
      final match = RegExp(r'inet (\d+\.\d+\.\d+\.\d+)/').firstMatch(output);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<bool> removeAdbForward({int localPort = 9091}) async {
    try {
      final result = await Process.run(
          _adbPath, ['forward', '--remove', 'tcp:$localPort']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> startAdbMonitor() async {
    if (_adbMonitorProcess != null) return;
    try {
      final adb = _adbPath;
      _adbMonitorProcess = await Process.start(adb, ['track-devices']);
      _knownAdbDevices.clear();
      var isFirst = true;

      _adbMonitorProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _adbPendingLines.add(line);
        _adbDebounce?.cancel();
        _adbDebounce = Timer(const Duration(milliseconds: 80), () {
          final lines = List<String>.from(_adbPendingLines);
          _adbPendingLines.clear();
          final output = lines.join('\n');
          if (isFirst) {
            isFirst = false;
            _updateDeviceListInitial(output);
          } else {
            _updateDeviceList(output);
          }
        });
      });

      _adbMonitorProcess!.stderr
          .transform(utf8.decoder)
          .listen((_) {}); // ignore stderr

      messageNotifier.value = 'ADB 监听已启动';
    } catch (_) {}
  }

  void _updateDeviceListInitial(String output) {
    final lines = output.split('\n');
    bool hasDevice = false;
    for (final line in lines) {
      if (line.trim().isNotEmpty && line.contains('\tdevice')) {
        _knownAdbDevices.add(line.split('\t').first.trim());
        hasDevice = true;
      }
    }
    if (hasDevice) {
      _adbSyncLock = false;
      _adbSyncPending = false;
      // Delay initial sync to ensure phone server is ready
      Future.delayed(const Duration(seconds: 2), () {
        _runAdbSync();
      });
    }
  }

  void _updateDeviceList(String output) {
    final currentIds = <String>{};
    final lines = output.split('\n');
    for (final line in lines) {
      if (line.trim().isNotEmpty && line.contains('\tdevice')) {
        currentIds.add(line.split('\t').first.trim());
      }
    }

    for (final id in currentIds) {
      if (!_knownAdbDevices.contains(id)) {
        messageNotifier.value = '检测到 USB 设备: $id';
        if (_adbSyncLock) {
          _adbSyncPending = true;
        } else {
          _adbSyncPending = false;
          _runAdbSync();
        }
      }
    }

    _knownAdbDevices.clear();
    _knownAdbDevices.addAll(currentIds);
  }

  void _runAdbSync() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAdbSyncTime < _adbSyncCooldownMs) return;
    _lastAdbSyncTime = now;
    onAdbDeviceConnected?.call('127.0.0.1', 9091);
  }

  void releaseAdbSyncLock() {
    _adbSyncLock = false;
    _lockAcquiredAt = 0;
    if (_adbSyncPending) {
      _adbSyncPending = false;
      _adbSyncLock = true;
      _lockAcquiredAt = DateTime.now().millisecondsSinceEpoch;
      _runAdbSync();
    }
  }

  Future<bool> tryUsbSync() async {
    // Watchdog: force-release if lock stuck for too long
    if (_adbSyncLock) {
      final heldMs = DateTime.now().millisecondsSinceEpoch - _lockAcquiredAt;
      if (heldMs > _lockWatchdogMs) {
        print('[USB] 锁已被持有 ${heldMs}ms，强制释放');
        _adbSyncLock = false;
      } else {
        print('[USB] 跳过: 锁被持有中 (${heldMs}ms)');
        return false;
      }
    }
    _adbSyncLock = true;
    _lockAcquiredAt = DateTime.now().millisecondsSinceEpoch;
    print('[USB] 获取锁，开始同步');
    try {
      final devices = await getAdbDevices().timeout(
        const Duration(seconds: 5),
        onTimeout: () => <String>[],
      );
      if (devices.isEmpty) {
        print('[USB] 未检测到设备');
        messageNotifier.value = 'USB: 未检测到设备';
        return false;
      }
      print('[USB] 检测到设备: ${devices.first}');
      await removeAdbForward(localPort: 9091);
      final ok = await setupAdbForward(localPort: 9091, remotePort: 9090);
      if (!ok) {
        print('[USB] 端口转发失败');
        messageNotifier.value = 'USB: 端口转发失败';
        return false;
      }
      print('[USB] 端口转发已建立: 9091 → 9090');
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        bool connected = false;
        HttpClient? checkClient;
        try {
          for (int i = 0; i < 2; i++) {
            checkClient = HttpClient();
            checkClient.connectionTimeout = const Duration(seconds: 1);
            try {
              final req = await checkClient.getUrl(
                Uri(scheme: 'http', host: '127.0.0.1', port: 9091, path: '/sync/status'),
              );
              final res = await req.close().timeout(const Duration(seconds: 1));
              if (res.statusCode == 200) {
                connected = true;
                break;
              }
            } catch (e) {
              print('[USB] 连接检查 $i 失败: $e');
            }
            if (i == 0) await Future.delayed(const Duration(milliseconds: 300));
          }
        } finally {
          checkClient?.close();
        }
        if (!connected) {
          print('[USB] 无法连接到手机服务');
          messageNotifier.value = 'USB: 无法连接到手机服务';
          return false;
        }
        print('[USB] 连接成功，执行全量同步');
        await fullSync('127.0.0.1', 9091, saveConnection: false)
            .timeout(const Duration(seconds: 20), onTimeout: () {
          print('[USB] fullSync 超时');
          return -1;
        });
        try {
          final wifiIp = await _getDeviceWifiIp(devices.first).timeout(
            const Duration(seconds: 3),
            onTimeout: () => null,
          );
          if (wifiIp != null) {
            await saveLastConnection(wifiIp, 9090);
            print('[USB] 已保存 WiFi IP: $wifiIp');
          }
        } catch (_) {}
        print('[USB] 同步成功');
        return true;
      } finally {
        print('[USB] 清理端口转发');
        await removeAdbForward(localPort: 9091);
      }
    } catch (e) {
      print('[USB] 同步失败: $e');
      messageNotifier.value = 'USB 同步失败: $e';
      return false;
    } finally {
      _adbSyncLock = false;
      _lockAcquiredAt = 0;
      print('[USB] 释放锁');
      releaseAdbSyncLock();
    }
  }

  void stopAdbMonitor() {
    _adbDebounce?.cancel();
    _adbDebounce = null;
    _adbPendingLines.clear();
    _adbMonitorProcess?.kill();
    _adbMonitorProcess = null;
    _knownAdbDevices.clear();
  }

  Future<String> _getSyncKey() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sync_key'],
    );
    return result.isNotEmpty ? result.first['value'] as String : '';
  }

  Future<int> _getLastSyncTime() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['last_sync_time'],
    );
    if (result.isNotEmpty) {
      return int.tryParse(result.first['value'] as String) ?? 0;
    }
    return 0;
  }

  Future<void> _setLastSyncTime(int time) async {
    lastSyncTimeNotifier.value = time;
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['last_sync_time', time.toString()],
    );
  }

  Future<Map<String, String?>> getLastConnection() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query('app_settings',
        where: 'key IN (?, ?)',
        whereArgs: ['sync_host', 'sync_port']);
    String? host;
    String? port;
    for (final row in result) {
      if (row['key'] == 'sync_host') host = row['value'] as String;
      if (row['key'] == 'sync_port') port = row['value'] as String;
    }
    return {'host': host, 'port': port};
  }

  Future<void> saveLastConnection(String host, int port) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['sync_host', host],
    );
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['sync_port', port.toString()],
    );
  }

  Future<Map<String, dynamic>> pullFrom(String host, int port,
      {int? since}) async {
    statusNotifier.value = SyncStatus.syncing;
    messageNotifier.value = '正在拉取变更...';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
    try {
      final lastSync = since ?? await _getLastSyncTime();
      print('[PULL] 拉取 since=$lastSync');
      final request = await client.postUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/pull'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'last_sync': lastSync,
        'sync_key': await _getSyncKey(),
      }));
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode != 200) {
        throw Exception('服务器返回 ${response.statusCode}');
      }
      final body = await utf8.decodeStream(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final incoming = await _diffIncomingNodes(
          data['nodes'] as List?, data['content'] as List?, lastSync);
      if (incoming.isNotEmpty) {
        _roundItems.addAll(incoming);
        print('[PULL] 收到 ${incoming.length} 项变更');
      }
      final recvDel = data['deleted_ids'] as List?;
      if (recvDel != null && recvDel.isNotEmpty) {
        _roundHardDeletes += recvDel.length;
        print('[PULL] 对端清理回收站 ${recvDel.length} 项');
      }
      final merged = await _mergeRemoteData(data);
      await _setLastSyncTime(data['server_time'] as int);
      print('[PULL] 完成: 合并 $merged 项');
      if (data['sync_key_mismatch'] == true) {
        messageNotifier.value = '拉取完成，合并 $merged 项（注意: sync_key 不匹配）';
      } else {
        messageNotifier.value = '拉取完成，合并 $merged 项';
      }
      statusNotifier.value = SyncStatus.idle;
      return data;
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '拉取失败: $e';
      print('[PULL] 失败: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> pushTo(String host, int port,
      {int? since}) async {
    statusNotifier.value = SyncStatus.syncing;
    messageNotifier.value = '正在推送变更...';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
    try {
      final lastSync = since ?? await _getLastSyncTime();
      final db = await DatabaseHelper.instance.database;

      final nodes = await db.query(
        'nodes',
        where: 'modified_at > ?',
        whereArgs: [lastSync],
      );
      final content = await db.rawQuery(
        'SELECT nc.* FROM note_content nc INNER JOIN nodes n ON n.id = nc.note_id WHERE n.modified_at > ?',
        [lastSync],
      );
      // Sync reminders and todos
      final reminders = await db.query(
        'reminders',
        where: 'modified_at > ?',
        whereArgs: [lastSync],
      );
      final todos = await db.query(
        'todos',
        where: 'modified_at > ?',
        whereArgs: [lastSync],
      );

      final deletedCount = nodes.where((n) => n['is_deleted'] == 1).length;
      print('[PUSH] 推送 ${nodes.length} 节点 (含 $deletedCount 已删除), ${content.length} 内容, lastSync=$lastSync');

      // Include image metadata only — actual files downloaded separately
      final images = await ImageService.instance.getImagesModifiedAfter(lastSync);
      if (images.isNotEmpty) {
        print('[PUSH] 包含 ${images.length} 张图片元数据');
      }

      final request = await client.postUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/push'),
      );
      request.headers.contentType = ContentType.json;
      final payload = <String, dynamic>{
        'nodes': nodes,
        'content': content,
        'images': images,
        'reminders': reminders,
        'todos': todos,
        'sync_key': await _getSyncKey(),
      };
      await _ensurePendingLoaded();
      final pendingDeletes = List<String>.from(_pendingDeleteIds);
      if (pendingDeletes.isNotEmpty) {
        payload['deleted_ids'] = pendingDeletes;
        print('[PUSH] 包含 ${pendingDeletes.length} 个永久删除 ID');
      }
      final pendingImageDeletes = await ImageService.pendingImageDeletes();
      if (pendingImageDeletes.isNotEmpty) {
        payload['deleted_image_ids'] = pendingImageDeletes;
        print('[PUSH] 包含 ${pendingImageDeletes.length} 个图片删除');
      }
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode != 200) {
        throw Exception('服务器返回 ${response.statusCode}');
      }
      final body = await utf8.decodeStream(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['server_time'] != null) {
        await _setLastSyncTime(data['server_time'] as int);
      }
      if (data['nodes'] != null) {
        await _mergeRemoteData(data);
      }
      if (pendingDeletes.isNotEmpty) {
        _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
        await _persistPendingDeletes();
      }
      if (pendingImageDeletes.isNotEmpty) {
        // 已成功送达,清空待传播的图片删除
        await ImageService.clearPendingImageDeletes();
      }
      // 记录本轮变更明细:推送出去的本地变更 + 服务器回传的变更
      try {
        if (pendingDeletes.isNotEmpty) {
          _roundHardDeletes += pendingDeletes.length; // 本端清理回收站并发出
        }
        final recvDel = data['deleted_ids'] as List?;
        if (recvDel != null && recvDel.isNotEmpty) {
          _roundHardDeletes += recvDel.length; // 对端清理,本端执行删除
        }
        final sent = await _diffSentNodes(nodes, content, lastSync);
        _roundItems.addAll(sent);
        final incoming = await _diffIncomingNodes(
            data['nodes'] as List?, data['content'] as List?, lastSync);
        _roundItems.addAll(incoming);
      } catch (e) {
        print('[PUSH] 变更明细统计失败: $e');
      }
      // Upload image files for newly pushed images
      if (images.isNotEmpty) {
        int uploaded = 0;
        for (final img in images) {
          final imageId = img['id'] as String;
          final bytes = await ImageService.instance.readImageBytes(imageId);
          if (bytes == null) continue;
          try {
            final upClient = HttpClient();
            upClient.connectionTimeout = const Duration(seconds: 3);
            try {
              final upPayload = jsonEncode({
                'id': imageId,
                'note_id': img['note_id'],
                'filename': img['filename'],
                'width': img['width'],
                'height': img['height'],
                'file_size': img['file_size'],
                'created_at': img['created_at'],
                'modified_at': img['modified_at'],
                'data': base64Encode(bytes),
              });
              final upReq = await upClient.postUrl(
                Uri(scheme: 'http', host: host, port: port, path: '/sync/image'),
              );
              upReq.headers.contentType = ContentType.json;
              upReq.write(upPayload);
              final upRes = await upReq.close().timeout(const Duration(seconds: 15));
              if (upRes.statusCode == 200) uploaded++;
            } finally {
              upClient.close();
            }
          } catch (e) {
            print('[PUSH] 上传图片 $imageId 失败: $e');
          }
        }
        if (uploaded > 0) print('[PUSH] 上传了 $uploaded 张图片到远端');
      }
      print('[PUSH] 完成 (${nodes.length} 节点)');
      if (data['sync_key_mismatch'] == true) {
        messageNotifier.value = '推送完成 (${nodes.length} 节点)（注意: sync_key 不匹配）';
      } else {
        messageNotifier.value = '推送完成 (${nodes.length} 节点)';
      }
      statusNotifier.value = SyncStatus.idle;
      return data;
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '推送失败: $e';
      print('[PUSH] 失败: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<int> fullSync(String host, int port, {bool saveConnection = true}) async {
    statusNotifier.value = SyncStatus.connecting;
    messageNotifier.value = '正在检查连接...';
    print('[SYNC] fullSync 开始: $host:$port');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
    try {
      try {
        final statusReq = await client.getUrl(
          Uri(scheme: 'http', host: host, port: port, path: '/sync/status'),
        );
        final statusRes = await statusReq.close().timeout(
              const Duration(seconds: 1),
            );
        if (statusRes.statusCode != 200) {
          throw Exception('无法连接到同步服务');
        }
      } finally {
        client.close();
      }

      // Capture the sync watermark ONCE at the start of this round.
      //
      // Both directions query and send changes newer than this same
      // watermark. Do NOT let the pull advance last_sync_time before the push
      // runs (or vice versa), otherwise the second direction would only see
      // changes newer than "now" and would skip everything that existed when
      // the round started:
      //   - a fresh install (watermark = 0) must pull the remote's full
      //     history first, or its notes never arrive ("cannot pair");
      //   - local changes made before this round must still be pushed, or
      //     they silently never reach the other device.
      final since = await _getLastSyncTime();
      print('[SYNC] 本轮同步水位线 since=$since');
      bool pullOk = false;
      bool pushOk = false;
      try {
        await pullFrom(host, port, since: since);
        pullOk = true;
      } catch (e) {
        print('[SYNC] pull 失败: $e');
      }
      try {
        await pushTo(host, port, since: since);
        pushOk = true;
      } catch (e) {
        print('[SYNC] push 失败: $e');
      }

      // Only keep the advanced watermark if BOTH directions succeeded.
      // pullFrom/pushTo each move last_sync_time forward when they complete;
      // if one direction failed, that watermark would silently skip every
      // local/remote change made before this round ("stranded" changes that
      // never sync again). Rolling back to `since` makes the next round
      // re-exchange them — the merge is last-writer-wins by modified_at, so
      // re-pulling/re-pushing the same rows is idempotent.
      if (!(pullOk && pushOk)) {
        final now = await _getLastSyncTime();
        if (now > since) {
          print('[SYNC] 本轮未完全成功，回滚水位线 $now -> $since');
          await _setLastSyncTime(since);
        }
      }

      // Download missing image files — non-critical, catch errors independently
      try {
        final db = await DatabaseHelper.instance.database;
        final allImages = await db.query('note_images');
        if (allImages.isNotEmpty) {
          await _fetchMissingImages(host, port, allImages);
        }
      } catch (e) {
        print('[SYNC] 图片下载出错 (不影响笔记同步): $e');
      }
      if (saveConnection) {
        await saveLastConnection(host, port);
      }

      // 汇总本轮变更:去重后落库,并通知 UI 弹出提示
      _roundSeq++;
      final byId = <String, SyncChangeItem>{};
      for (final it in _roundItems) {
        byId.putIfAbsent(it.id, () => it);
      }
      _roundItems.clear();
      final hardDeletes = _roundHardDeletes;
      _roundHardDeletes = 0;
      if (byId.isNotEmpty || hardDeletes > 0) {
        final items = byId.values.toList();
        final ts = DateTime.now().millisecondsSinceEpoch;
        if (items.isNotEmpty) {
          try {
            await SyncHistoryStore.instance.addRound(ts, items);
          } catch (e) {
            print('[SYNC] 变更记录存储失败: $e');
          }
        }
        print('[SYNC] 本轮变更 ${items.length} 项, 回收站清理 $hardDeletes 项');
        roundResultNotifier.value = SyncRoundResult(
            timestamp: ts, items: items, hardDeletes: hardDeletes);
      }

      statusNotifier.value = SyncStatus.idle;
      print('[SYNC] fullSync 完成: $host:$port');
      return 1;
    } catch (e) {
      _roundItems.clear();
      _roundHardDeletes = 0;
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '连接失败: $e';
      print('[SYNC] fullSync 失败: $e');
      rethrow;
    }
  }

  String _changePath(Map row) {
    final t = row['title'] as String?;
    return (t == null || t.trim().isEmpty) ? '未命名' : t;
  }

  /// 对端发来的节点相对本地的变更分类(新增/修改/删除/冲突)。
  /// 只统计会实际落地的项:本地不存在→新增;远端较新→修改;
  /// is_deleted=1→删除。若本地也在本轮水位线之后改过且远端更新,
  /// 属于两端并发编辑,标记为"冲突"(差异)。
  Future<List<SyncChangeItem>> _diffIncomingNodes(
      List? rawNodes, List? rawContents, int since) async {
    final items = <SyncChangeItem>[];
    if (rawNodes == null || rawNodes.isEmpty) return items;
    try {
      final nodes = rawNodes.cast<Map<String, dynamic>>();
      final contents = (rawContents == null)
          ? <Map<String, dynamic>>[]
          : rawContents.cast<Map<String, dynamic>>();
      final db = await DatabaseHelper.instance.database;
      final ids = nodes.map((n) => n['id'] as String).toList();
      Map<String, Map<String, dynamic>> localById = {};
      if (ids.isNotEmpty) {
        final placeholders = ids.map((_) => '?').join(',');
        final rows = await db.rawQuery(
            'SELECT id, modified_at FROM nodes WHERE id IN ($placeholders)',
            ids);
        localById = {for (final r in rows) r['id'] as String: r};
      }
      // 本地已有节点的旧内容快照(合并前)
      Map<String, String> oldContents = {};
      if (localById.isNotEmpty) {
        final ph = localById.keys.map((_) => '?').join(',');
        final crows = await db.rawQuery(
            'SELECT note_id, content FROM note_content WHERE note_id IN ($ph)',
            localById.keys.toList());
        oldContents = {
          for (final r in crows)
            r['note_id'] as String: (r['content'] as String? ?? '')
        };
      }
      // 对端内容(新版本)与长度
      final newContents = <String, String>{};
      for (final c in contents) {
        final s = c['content'] as String? ?? '';
        newContents[c['note_id'] as String] = s;
      }
      for (final n in nodes) {
        final id = n['id'] as String;
        final remoteModified = (n['modified_at'] as num?)?.toInt() ?? 0;
        final remoteDeletedAt = (n['deleted_at'] as num?)?.toInt() ?? 0;
        final isDeleted = (n['is_deleted'] as num?)?.toInt() == 1;
        final local = localById[id];
        final localModified =
            local == null ? 0 : (local['modified_at'] as num).toInt();
        final String type;
        if (isDeleted) {
          type = 'deleted';
        } else if (local == null) {
          type = 'added';
        } else if (remoteModified > localModified) {
          // 本地也在此轮水位线之后被修改过 → 两端并发编辑
          type = (localModified > since) ? 'conflict' : 'modified';
        } else {
          continue;
        }
        final oldContent = oldContents[id];
        final newContent = newContents[id];
        final oldTime = (type == 'added') ? 0 : localModified;
        final newTime = isDeleted
            ? (remoteDeletedAt > 0 ? remoteDeletedAt : remoteModified)
            : remoteModified;
        final size = newContent?.length ?? oldContent?.length ?? 0;
        items.add(SyncChangeItem(
            id: id,
            path: _changePath(n),
            type: type,
            size: size,
            oldContent: oldContent,
            newContent: newContent,
            oldTime: oldTime,
            newTime: newTime));
      }
    } catch (e) {
      print('[SYNC] 变更统计(pull)异常: $e');
    }
    return items;
  }

  /// 本轮推送出去的本地节点分类(删除/新增/修改)。
  Future<List<SyncChangeItem>> _diffSentNodes(
      List<dynamic> nodes, List<dynamic> contents, int since) async {
    final items = <SyncChangeItem>[];
    if (nodes.isEmpty) return items;
    try {
      final db = await DatabaseHelper.instance.database;
      final ids = <String>[];
      for (final e in nodes) {
        ids.add((e as Map)['id'] as String);
      }
      final placeholders = ids.map((_) => '?').join(',');
      final rows = await db.rawQuery(
          'SELECT id FROM nodes WHERE modified_at <= ? AND id IN ($placeholders)',
          [since, ...ids]);
      final existing = {for (final r in rows) r['id'] as String};
      // 推送出去的内容(新版本快照)
      final newContents = <String, String>{};
      for (final e in contents) {
        final c = e as Map;
        final s = c['content'] as String? ?? '';
        newContents[c['note_id'] as String] = s;
      }
      for (final e in nodes) {
        final n = e as Map;
        final id = n['id'] as String;
        final modified = (n['modified_at'] as num?)?.toInt() ?? 0;
        final deletedAt = (n['deleted_at'] as num?)?.toInt() ?? 0;
        final isDeleted = (n['is_deleted'] as num?)?.toInt() == 1;
        final String type;
        if (isDeleted) {
          type = 'deleted';
        } else if (existing.contains(id)) {
          type = 'modified';
        } else {
          type = 'added';
        }
        final newContent = newContents[id];
        items.add(SyncChangeItem(
            id: id,
            path: _changePath(n),
            type: type,
            size: newContent?.length ?? 0,
            newContent: newContent,
            newTime: isDeleted
                ? (deletedAt > 0 ? deletedAt : modified)
                : modified));
      }
    } catch (e) {
      print('[SYNC] 变更统计(push)异常: $e');
    }
    return items;
  }

  Future<int> _mergeRemoteData(Map<String, dynamic> data) async {
    final db = await DatabaseHelper.instance.database;
    int merged = 0;

    if (data['deleted_ids'] != null && (data['deleted_ids'] as List).isNotEmpty) {
      final deletedIds = data['deleted_ids'] as List;
      print('[SERVER] 处理 ${deletedIds.length} 个永久删除');
      for (final id in deletedIds) {
        await db.delete('note_content', where: 'note_id = ?', whereArgs: [id]);
        await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
      }
      merged += deletedIds.length;
    }

    // 图片删除传播:让两端图片记录保持一致
    if (data['deleted_image_ids'] != null &&
        (data['deleted_image_ids'] as List).isNotEmpty) {
      final deletedImageIds = data['deleted_image_ids'] as List;
      print('[SYNC] 处理 ${deletedImageIds.length} 个图片删除');
      for (final id in deletedImageIds) {
        if (id is String && id.isNotEmpty) {
          await ImageService.instance.applyRemoteDelete(id);
          merged++;
        }
      }
    }

    if (data['nodes'] != null && (data['nodes'] as List).isNotEmpty) {
      final nodes = data['nodes'] as List;
      // Batch load existing nodes
      final ids = nodes.map((n) => n['id'] as String).toList();
      final placeholders = ids.map((_) => '?').join(',');
      final existingRows = await db.rawQuery(
        'SELECT id, modified_at FROM nodes WHERE id IN ($placeholders)',
        ids,
      );
      final existingMap = {for (final r in existingRows) r['id'] as String: r['modified_at'] as int};

      final batch = db.batch();
      for (final node in nodes) {
        final id = node['id'] as String;
        final remoteModified = node['modified_at'] as int;
        final localModified = existingMap[id];
        if (localModified == null) {
          batch.insert('nodes', _toDbMap(node));
          merged++;
        } else if (remoteModified > localModified) {
          batch.update('nodes', _toDbMap(node), where: 'id = ?', whereArgs: [id]);
          merged++;
        }
      }
      await batch.commit(noResult: true);
    }

    if (data['content'] != null && (data['content'] as List).isNotEmpty) {
      final contentList = data['content'] as List;
      final noteIds = contentList.map((c) => c['note_id'] as String).toList();
      final placeholders = noteIds.map((_) => '?').join(',');
      final existingRows = await db.rawQuery(
        'SELECT note_id, modified_at FROM note_content WHERE note_id IN ($placeholders)',
        noteIds,
      );
      final existingMap = {for (final r in existingRows) r['note_id'] as String: r['modified_at'] as int};

      final batch = db.batch();
      for (final c in contentList) {
        final noteId = c['note_id'] as String;
        final remoteModified = c['modified_at'] as int;
        final localModified = existingMap[noteId];
        if (localModified == null) {
          batch.insert('note_content', _toDbMap(c));
          merged++;
        } else if (remoteModified > localModified) {
          batch.update('note_content', _toDbMap(c), where: 'note_id = ?', whereArgs: [noteId]);
          merged++;
        }
      }
      await batch.commit(noResult: true);
    }

    if (data['images'] != null && (data['images'] as List).isNotEmpty) {
      final imagesList = data['images'] as List;
      for (final img in imagesList) {
        await ImageService.instance.upsertImageMeta(
          Map<String, dynamic>.from(img as Map),
        );
      }
      merged += imagesList.length;
    }

    if (data['reminders'] != null && (data['reminders'] as List).isNotEmpty) {
      final remindersList = data['reminders'] as List;
      final remIds = remindersList.map((r) => r['id'] as String).toList();
      final placeholders = remIds.map((_) => '?').join(',');
      final existingRows = await db.rawQuery(
        'SELECT id, modified_at FROM reminders WHERE id IN ($placeholders)',
        remIds,
      );
      final existingMap = {for (final r in existingRows) r['id'] as String: r['modified_at'] as int};

      final batch = db.batch();
      for (final r in remindersList) {
        final id = r['id'] as String;
        final remoteModified = r['modified_at'] as int? ?? 0;
        final localModified = existingMap[id];
        if (localModified == null) {
          batch.insert('reminders', _toDbMap(r));
          merged++;
        } else if (remoteModified > localModified) {
          batch.update('reminders', _toDbMap(r), where: 'id = ?', whereArgs: [id]);
          merged++;
        }
      }
      await batch.commit(noResult: true);
    }

    if (data['todos'] != null && (data['todos'] as List).isNotEmpty) {
      final todosList = data['todos'] as List;
      final todoIds = todosList.map((t) => t['id'] as String).toList();
      final placeholders = todoIds.map((_) => '?').join(',');
      final existingRows = await db.rawQuery(
        'SELECT id, modified_at FROM todos WHERE id IN ($placeholders)',
        todoIds,
      );
      final existingMap = {for (final r in existingRows) r['id'] as String: r['modified_at'] as int};

      final batch = db.batch();
      for (final t in todosList) {
        final id = t['id'] as String;
        final remoteModified = t['modified_at'] as int? ?? 0;
        final localModified = existingMap[id];
        if (localModified == null) {
          batch.insert('todos', _toDbMap(t));
          merged++;
        } else if (remoteModified > localModified) {
          batch.update('todos', _toDbMap(t), where: 'id = ?', whereArgs: [id]);
          merged++;
        }
      }
      await batch.commit(noResult: true);
    }

    return merged;
  }

  Map<String, dynamic> _toDbMap(Map<String, dynamic> map) {
    // Keep null values — sqflite batch.update sets columns to null when present
    return Map<String, dynamic>.from(map);
  }

  void _maybeSaveRemoteHost(HttpRequest request) {
    final addr = request.connectionInfo?.remoteAddress;
    if (addr == null || addr.isLoopback) return;
    final host = addr.address;
    saveLastConnection(host, _port);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      switch (path) {
        case '/sync/status':
          await _handleStatus(request);
          break;
        case '/sync/summary':
          await _handleSummary(request);
          break;
        case '/sync/manifest':
          await _handleManifest(request);
          break;
        case '/sync/pull':
          _maybeSaveRemoteHost(request);
          await _handlePull(request);
          break;
        case '/sync/push':
          _maybeSaveRemoteHost(request);
          await _handlePush(request);
          break;
        default:
          if (path.startsWith('/sync/image/')) {
            final imageId = path.substring('/sync/image/'.length);
            if (imageId.isNotEmpty) {
              if (request.method == 'GET') {
                await _handleImageDownload(request, imageId);
              } else {
                request.response.statusCode = 405;
                await request.response.close();
              }
            } else {
              request.response.statusCode = 400;
              await request.response.close();
            }
            break;
          }
          if (path == '/sync/image' && request.method == 'POST') {
            await _handleImageUpload(request);
            break;
          }
          request.response.statusCode = 404;
          await request.response.close();
      }
    } catch (e) {
      _sendJson(request.response, {'error': e.toString()},
          status: 500);
    }
  }

  Future<void> _handleStatus(HttpRequest request) async {
    final db = await DatabaseHelper.instance.database;
    final count = await db.rawQuery(
      'SELECT COUNT(*) as c FROM nodes WHERE is_deleted = 0',
    );
    final settings = await db.query('app_settings');
    String getSetting(String key) =>
        settings.where((r) => r['key'] == key).firstOrNull?['value'] as String? ?? '';
    _sendJson(request.response, {
      'version': '3.2.1',
      'device': Platform.localHostname,
      'sync_key': getSetting('sync_key'),
      'device_name': getSetting('device_name'),
      'node_count': count.first['c'],
      'time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _handlePull(HttpRequest request) async {
    final bytes = await request.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    final body = utf8.decode(bytes);
    final req = jsonDecode(body) as Map<String, dynamic>;
    final lastSync = req['last_sync'] as int? ?? 0;

    final db = await DatabaseHelper.instance.database;
    final nodes = await db.query(
      'nodes',
      where: 'modified_at > ?',
      whereArgs: [lastSync],
    );
    final content = await db.rawQuery(
      'SELECT nc.* FROM note_content nc INNER JOIN nodes n ON n.id = nc.note_id WHERE n.modified_at > ?',
      [lastSync],
    );
    final reminders = await db.query(
      'reminders',
      where: 'modified_at > ?',
      whereArgs: [lastSync],
    );
    final todos = await db.query(
      'todos',
      where: 'modified_at > ?',
      whereArgs: [lastSync],
    );

    final deletedCount = nodes.where((n) => n['is_deleted'] == 1).length;
    print('[SERVER] 响应拉取 since=$lastSync: ${nodes.length} 节点 (含 $deletedCount 已删除)');

    final clientKey = req['sync_key'] as String? ?? '';
    final myKey = await _getSyncKey();

    final images = await ImageService.instance.getImagesModifiedAfter(lastSync);

    final pullPayload = <String, dynamic>{
      'nodes': nodes,
      'content': content,
      'images': images,
      'reminders': reminders,
      'todos': todos,
      'server_time': DateTime.now().millisecondsSinceEpoch,
      'sync_key': myKey,
      'sync_key_mismatch': clientKey.isNotEmpty && myKey.isNotEmpty && clientKey != myKey,
    };
    await _ensurePendingLoaded();
    final pendingDeletes = List<String>.from(_pendingDeleteIds);
    if (pendingDeletes.isNotEmpty) {
      pullPayload['deleted_ids'] = pendingDeletes;
      print('[SERVER] 拉取响应包含 ${pendingDeletes.length} 个永久删除 ID');
    }
    final pendingImageDeletes = await ImageService.pendingImageDeletes();
    if (pendingImageDeletes.isNotEmpty) {
      pullPayload['deleted_image_ids'] = pendingImageDeletes;
      print('[SERVER] 拉取响应包含 ${pendingImageDeletes.length} 个图片删除');
    }
    _sendJson(request.response, pullPayload);
    if (pendingDeletes.isNotEmpty) {
      _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
      await _persistPendingDeletes();
    }
    if (pendingImageDeletes.isNotEmpty) {
      await ImageService.clearPendingImageDeletes();
    }
  }

  Future<void> _handlePush(HttpRequest request) async {
    final bytes = await request.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    final body = utf8.decode(bytes);
    final data = jsonDecode(body) as Map<String, dynamic>;
    final nodes = data['nodes'] as List? ?? [];
    final clientKey = data['sync_key'] as String? ?? '';
    final myKey = await _getSyncKey();
    final keyMismatch = clientKey.isNotEmpty && myKey.isNotEmpty && clientKey != myKey;
    if (keyMismatch) {
      print('[SERVER] 警告: sync_key 不匹配 (client=$clientKey, server=$myKey)');
    }
    final deletedCount = nodes.where((n) => n['is_deleted'] == 1).length;
    print('[SERVER] 收到推送: ${nodes.length} 节点 (含 $deletedCount 已删除)');
    final merged = await _mergeRemoteData(data);
    if (merged > 0) dataVersionNotifier.value++;

    // Also send back any newer local changes the client might need
    final db = await DatabaseHelper.instance.database;
    final oldLastSync = await _getLastSyncTime();
    final newNodes = await db.query(
      'nodes',
      where: 'modified_at > ?',
      whereArgs: [oldLastSync],
    );
    final newContent = await db.rawQuery(
      'SELECT nc.* FROM note_content nc INNER JOIN nodes n ON n.id = nc.note_id WHERE n.modified_at > ?',
      [oldLastSync],
    );
    final newReminders = await db.query(
      'reminders',
      where: 'modified_at > ?',
      whereArgs: [oldLastSync],
    );
    final newTodos = await db.query(
      'todos',
      where: 'modified_at > ?',
      whereArgs: [oldLastSync],
    );

    // Update last_sync_time so future push responses only send recent changes
    await _setLastSyncTime(DateTime.now().millisecondsSinceEpoch);

    final newImages = await ImageService.instance.getImagesModifiedAfter(oldLastSync);

    final responsePayload = <String, dynamic>{
      'merged': merged,
      'server_time': DateTime.now().millisecondsSinceEpoch,
      'nodes': newNodes,
      'content': newContent,
      'images': newImages,
      'reminders': newReminders,
      'todos': newTodos,
      'sync_key': myKey,
      'sync_key_mismatch': keyMismatch,
    };
    await _ensurePendingLoaded();
    final pendingDeletes = List<String>.from(_pendingDeleteIds);
    if (pendingDeletes.isNotEmpty) {
      responsePayload['deleted_ids'] = pendingDeletes;
      print('[SERVER] 响应包含 ${pendingDeletes.length} 个永久删除 ID');
    }
    final pendingImageDeletes = await ImageService.pendingImageDeletes();
    if (pendingImageDeletes.isNotEmpty) {
      responsePayload['deleted_image_ids'] = pendingImageDeletes;
      print('[SERVER] 响应包含 ${pendingImageDeletes.length} 个图片删除');
    }
    _sendJson(request.response, responsePayload);
    if (pendingDeletes.isNotEmpty) {
      _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
      await _persistPendingDeletes();
    }
    if (pendingImageDeletes.isNotEmpty) {
      await ImageService.clearPendingImageDeletes();
    }
  }

  void _sendJson(HttpResponse response, Map<String, dynamic> data,
      {int status = 200}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }

  // ── 一致性检查 ─────────────────────────────────────────────
  // 思路:先比对"计数 + 指纹"(本地 O(n) 计算,一次请求完成),
  // 指纹一致即认为两端每个笔记/文件夹/回收站条目/正文/图片完全一致;
  // 只有指纹不同时才拉取清单(manifest)定位到具体差异项,
  // 从而避免每次都逐文件比较。

  int _fnv1a32(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
      hash ^= (unit >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  String _hex(int v) => v.toRadixString(16).padLeft(8, '0');

  /// 本机数据摘要:计数 + 三类指纹 + 水位线 + 最近同步变更记录。
  Future<Map<String, dynamic>> buildLocalSummary() async {
    final db = await DatabaseHelper.instance.database;

    final nodes = await db.rawQuery(
        'SELECT id, type, title, parent_id, is_deleted, deleted_at, modified_at, sort_order, is_pinned, created_at FROM nodes ORDER BY id');
    final nodeBuf = StringBuffer();
    int activeNotes = 0, folders = 0, deleted = 0;
    for (final r in nodes) {
      nodeBuf.writeln([
        r['id'],
        r['title'],
        r['parent_id'],
        r['is_deleted'],
        r['deleted_at'],
        r['modified_at'],
        r['sort_order'],
        r['is_pinned'],
        r['created_at'],
      ].join('|'));
      final isDel = (r['is_deleted'] as num?)?.toInt() == 1;
      if (isDel) {
        deleted++;
      } else if (r['type'] == 'folder') {
        folders++;
      } else {
        activeNotes++;
      }
    }

    final contents = await db.rawQuery(
        'SELECT note_id, content, modified_at FROM note_content ORDER BY note_id');
    final contentBuf = StringBuffer();
    for (final r in contents) {
      contentBuf.writeln('${r['note_id']}|${r['modified_at']}|${r['content']}');
    }

    final images = await db.rawQuery(
        'SELECT id, note_id, filename, file_size, modified_at FROM note_images ORDER BY id');
    final imageBuf = StringBuffer();
    for (final r in images) {
      imageBuf.writeln(
          '${r['id']}|${r['note_id']}|${r['filename']}|${r['file_size']}|${r['modified_at']}');
    }

    final watermark = await _getLastSyncTime();

    // 最近几轮同步变更记录(修改记录区),用于快速追溯最近改了什么
    final recent = <Map<String, dynamic>>[];
    try {
      final rows =
          await db.query('sync_history', orderBy: 'timestamp DESC', limit: 5);
      for (final r in rows) {
        final items = (jsonDecode(r['items_json'] as String) as List)
            .map((e) => e as Map)
            .map((e) => {'id': e['id'], 'type': e['type'], 'path': e['path']})
            .toList();
        recent.add({
          'timestamp': r['timestamp'],
          'total': r['total_changes'],
          'items': items,
        });
      }
    } catch (_) {}

    return {
      'version': '3.2.1',
      'device': Platform.localHostname,
      'sync_key': await _getSyncKey(),
      'watermark': watermark,
      'counts': {
        'nodes': nodes.length,
        'notes': activeNotes,
        'folders': folders,
        'recycle_bin': deleted,
        'content': contents.length,
        'images': images.length,
      },
      'fp_nodes': _hex(_fnv1a32(nodeBuf.toString())),
      'fp_content': _hex(_fnv1a32(contentBuf.toString())),
      'fp_images': _hex(_fnv1a32(imageBuf.toString())),
      'recent_changes': recent,
    };
  }

  /// 差异清单:所有条目的 id/时间戳/删除标记,仅在指纹不一致时拉取。
  Future<Map<String, dynamic>> buildLocalManifest() async {
    final db = await DatabaseHelper.instance.database;
    final nodes = await db.rawQuery(
        'SELECT id, title, is_deleted, modified_at FROM nodes ORDER BY id');
    final contents = await db.rawQuery(
        'SELECT note_id, length(content) AS len, modified_at FROM note_content ORDER BY note_id');
    final images = await db.rawQuery(
        'SELECT id, note_id, filename, modified_at FROM note_images ORDER BY id');
    return {
      'device': Platform.localHostname,
      'nodes': nodes
          .map((r) =>
              '${r['id']}|${r['modified_at']}|${r['is_deleted']}|${r['title']}')
          .toList(),
      'content': contents
          .map((r) => '${r['note_id']}|${r['modified_at']}|${r['len']}')
          .toList(),
      'images': images
          .map((r) => '${r['id']}|${r['modified_at']}|${r['filename']}')
          .toList(),
    };
  }

  Future<void> _handleSummary(HttpRequest request) async {
    final summary = await buildLocalSummary();
    _sendJson(request.response, summary);
  }

  Future<void> _handleManifest(HttpRequest request) async {
    final manifest = await buildLocalManifest();
    _sendJson(request.response, manifest);
  }

  /// 与对端通信的目标:优先 USB(adb 端口转发),否则用上次保存的 WiFi 地址。
  Future<bool> _withRemoteTarget(
      Future<bool> Function(String host, int port) action) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        final devices = await getAdbDevices();
        if (devices.isNotEmpty) {
          await removeAdbForward(localPort: 9091);
          final ok = await setupAdbForward(localPort: 9091, remotePort: 9090);
          if (ok) {
            try {
              return await action('127.0.0.1', 9091);
            } finally {
              await removeAdbForward(localPort: 9091);
            }
          }
        }
      } catch (_) {}
    }
    try {
      final info = await getLastConnection();
      final host = info['host'];
      final port = int.tryParse(info['port'] ?? '') ?? 9090;
      if (host != null && host.isNotEmpty) {
        return await action(host, port);
      }
    } catch (_) {}
    return false;
  }

  /// 拉取对端摘要;失败返回 null(例如对端版本较旧没有该接口)。
  Future<Map<String, dynamic>?> fetchRemoteSummary() async {
    Map<String, dynamic>? result;
    await _withRemoteTarget((host, port) async {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client.getUrl(
            Uri(scheme: 'http', host: host, port: port, path: '/sync/summary'));
        final res = await req.close().timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) return false;
        final body = await utf8.decodeStream(res);
        result = jsonDecode(body) as Map<String, dynamic>;
        return true;
      } catch (e) {
        print('[VERIFY] 获取对端摘要失败: $e');
        return false;
      } finally {
        client.close();
      }
    });
    return result;
  }

  /// 拉取对端差异清单;失败返回 null。
  Future<Map<String, dynamic>?> fetchRemoteManifest() async {
    Map<String, dynamic>? result;
    await _withRemoteTarget((host, port) async {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client.getUrl(
            Uri(scheme: 'http', host: host, port: port, path: '/sync/manifest'));
        final res = await req.close().timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return false;
        final body = await utf8.decodeStream(res);
        result = jsonDecode(body) as Map<String, dynamic>;
        return true;
      } catch (e) {
        print('[VERIFY] 获取对端清单失败: $e');
        return false;
      } finally {
        client.close();
      }
    });
    return result;
  }

  /// 用同一目标(USB 或 WiFi)执行一次完整同步,供"一致性检查"页使用。
  Future<bool> syncWithRemote() async {
    var ok = false;
    await _withRemoteTarget((host, port) async {
      try {
        await fullSync(host, port);
        ok = true;
        return true;
      } catch (e) {
        print('[VERIFY] 同步失败: $e');
        return false;
      }
    });
    return ok;
  }

  Future<void> _handleImageDownload(HttpRequest request, String imageId) async {
    try {
      final bytes = await ImageService.instance.readImageBytes(imageId);
      if (bytes == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.binary;
      request.response.add(bytes);
      await request.response.close();
    } catch (e) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  Future<void> _handleImageUpload(HttpRequest request) async {
    try {
      final bytes = await request.fold<List<int>>(
          <int>[], (prev, chunk) => prev..addAll(chunk));
      final body = utf8.decode(bytes);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final imageId = data['id'] as String;
      final noteId = data['note_id'] as String;
      final filename = data['filename'] as String;
      final base64Data = data['data'] as String;
      final imageBytes = base64Decode(base64Data);

      await ImageService.instance.saveImageBytes(noteId, filename, imageBytes);

      final meta = Map<String, dynamic>.from(data);
      meta.remove('data');
      meta['file_size'] = imageBytes.length;
      await ImageService.instance.upsertImageMeta(meta);

      request.response.statusCode = 200;
      _sendJson(request.response, {'status': 'ok', 'id': imageId});
    } catch (e) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  /// Download images listed in the sync payload that are missing locally.
  Future<int> _fetchMissingImages(String host, int port, List imagesMeta) async {
    int downloaded = 0;
    for (final img in imagesMeta) {
      final map = img as Map<String, dynamic>;
      final imageId = map['id'] as String;

      // Skip if we already have the file
      final localPath = await ImageService.instance.getImagePath(imageId);
      if (localPath != null) continue;

      final noteId = map['note_id'] as String;
      final filename = map['filename'] as String;
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client.getUrl(
          Uri(scheme: 'http', host: host, port: port, path: '/sync/image/$imageId'),
        );
        final res = await req.close().timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final bytes = await res.fold<List<int>>(
              <int>[], (prev, chunk) => prev..addAll(chunk));
          await ImageService.instance.saveImageBytes(noteId, filename, bytes);
          downloaded++;
          print('[IMAGE] 下载成功: $imageId (${bytes.length} bytes)');
        } else {
          print('[IMAGE] 下载失败 $imageId: HTTP ${res.statusCode}');
        }
      } catch (e) {
        print('[IMAGE] 下载异常 $imageId: $e');
      } finally {
        client.close();
      }
    }
    if (downloaded > 0) {
      print('[IMAGE] 本次下载了 $downloaded 张图片');
    }
    return downloaded;
  }
}
