import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'database.dart';
import 'image_service.dart';

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

  void addPendingDelete(String id) {
    if (!_pendingDeleteIds.contains(id)) {
      _pendingDeleteIds.add(id);
    }
  }

  void addPendingDeletes(List<String> ids) {
    for (final id in ids) {
      if (!_pendingDeleteIds.contains(id)) {
        _pendingDeleteIds.add(id);
      }
    }
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

  Future<Map<String, dynamic>> pullFrom(String host, int port) async {
    statusNotifier.value = SyncStatus.syncing;
    messageNotifier.value = '正在拉取变更...';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
    try {
      final lastSync = await _getLastSyncTime();
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

  Future<Map<String, dynamic>> pushTo(String host, int port) async {
    statusNotifier.value = SyncStatus.syncing;
    messageNotifier.value = '正在推送变更...';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
    try {
      final lastSync = await _getLastSyncTime();
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
      final fts = await db.rawQuery(
        'SELECT fc.* FROM fts_content fc INNER JOIN nodes n ON n.id = fc.note_id WHERE n.modified_at > ?',
        [lastSync],
      );

      final deletedCount = nodes.where((n) => n['is_deleted'] == 1).length;
      print('[PUSH] 推送 ${nodes.length} 节点 (含 $deletedCount 已删除), ${content.length} 内容, lastSync=$lastSync');

      // Include image metadata
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
        'fts': fts,
        'images': images,
        'sync_key': await _getSyncKey(),
      };
      final pendingDeletes = List<String>.from(_pendingDeleteIds);
      if (pendingDeletes.isNotEmpty) {
        payload['deleted_ids'] = pendingDeletes;
        print('[PUSH] 包含 ${pendingDeletes.length} 个永久删除 ID');
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
      if (data['nodes'] != null) {
        await _mergeRemoteData(data);
      }
      if (pendingDeletes.isNotEmpty) {
        _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
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

      await pushTo(host, port);
      await pullFrom(host, port);
      // Sync image files after metadata
      await _downloadMissingImages(host, port);
      await _uploadMissingImages(host, port);
      if (saveConnection) {
        await saveLastConnection(host, port);
      }
      statusNotifier.value = SyncStatus.idle;
      print('[SYNC] fullSync 完成: $host:$port');
      return 0;
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '连接失败: $e';
      print('[SYNC] fullSync 失败: $e');
      rethrow;
    }
  }

  Future<int> _mergeRemoteData(Map<String, dynamic> data) async {
    final db = await DatabaseHelper.instance.database;
    int merged = 0;

    if (data['deleted_ids'] != null && (data['deleted_ids'] as List).isNotEmpty) {
      final deletedIds = data['deleted_ids'] as List;
      print('[SERVER] 处理 ${deletedIds.length} 个永久删除');
      for (final id in deletedIds) {
        await db.delete('note_content', where: 'note_id = ?', whereArgs: [id]);
        await db.delete('fts_content', where: 'note_id = ?', whereArgs: [id]);
        await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
      }
      merged += deletedIds.length;
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

    if (data['fts'] != null && (data['fts'] as List).isNotEmpty) {
      final batch = db.batch();
      for (final f in (data['fts'] as List)) {
        batch.rawInsert(
          'INSERT OR REPLACE INTO fts_content(note_id, title, content) VALUES(?, ?, ?)',
          [f['note_id'], f['title'], f['content']],
        );
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
      'version': '3.0.0',
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
    final fts = await db.rawQuery(
      'SELECT fc.* FROM fts_content fc INNER JOIN nodes n ON n.id = fc.note_id WHERE n.modified_at > ?',
      [lastSync],
    );

    final deletedCount = nodes.where((n) => n['is_deleted'] == 1).length;
    print('[SERVER] 响应拉取 since=$lastSync: ${nodes.length} 节点 (含 $deletedCount 已删除)');

    final clientKey = req['sync_key'] as String? ?? '';
    final myKey = await _getSyncKey();

    final images = await ImageService.instance.getImagesModifiedAfter(lastSync);

    final pullPayload = <String, dynamic>{
      'nodes': nodes,
      'content': content,
      'fts': fts,
      'images': images,
      'server_time': DateTime.now().millisecondsSinceEpoch,
      'sync_key': myKey,
      'sync_key_mismatch': clientKey.isNotEmpty && myKey.isNotEmpty && clientKey != myKey,
    };
    final pendingDeletes = List<String>.from(_pendingDeleteIds);
    if (pendingDeletes.isNotEmpty) {
      pullPayload['deleted_ids'] = pendingDeletes;
      print('[SERVER] 拉取响应包含 ${pendingDeletes.length} 个永久删除 ID');
    }
    _sendJson(request.response, pullPayload);
    if (pendingDeletes.isNotEmpty) {
      _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
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
    final newFts = await db.rawQuery(
      'SELECT fc.* FROM fts_content fc INNER JOIN nodes n ON n.id = fc.note_id WHERE n.modified_at > ?',
      [oldLastSync],
    );

    // Update last_sync_time so future push responses only send recent changes
    await _setLastSyncTime(DateTime.now().millisecondsSinceEpoch);

    final newImages = await ImageService.instance.getImagesModifiedAfter(oldLastSync);

    final responsePayload = <String, dynamic>{
      'merged': merged,
      'server_time': DateTime.now().millisecondsSinceEpoch,
      'nodes': newNodes,
      'content': newContent,
      'fts': newFts,
      'images': newImages,
      'sync_key': myKey,
      'sync_key_mismatch': keyMismatch,
    };
    final pendingDeletes = List<String>.from(_pendingDeleteIds);
    if (pendingDeletes.isNotEmpty) {
      responsePayload['deleted_ids'] = pendingDeletes;
      print('[SERVER] 响应包含 ${pendingDeletes.length} 个永久删除 ID');
    }
    _sendJson(request.response, responsePayload);
    if (pendingDeletes.isNotEmpty) {
      _pendingDeleteIds.removeWhere((id) => pendingDeletes.contains(id));
    }
  }

  void _sendJson(HttpResponse response, Map<String, dynamic> data,
      {int status = 200}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
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

  /// Download missing images from remote after a successful pull.
  Future<int> _downloadMissingImages(String host, int port) async {
    final db = await DatabaseHelper.instance.database;
    final images = await db.query('note_images');
    int downloaded = 0;

    for (final img in images) {
      final imageId = img['id'] as String;
      final localPath = await ImageService.instance.getImagePath(imageId);
      if (localPath != null) continue; // already have the file

      // Need to download this image
      final noteId = img['note_id'] as String;
      final filename = img['filename'] as String;
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client.getUrl(
          Uri(scheme: 'http', host: host, port: port, path: '/sync/image/$imageId'),
        );
        final res = await req.close().timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final bytes = await res.fold<List<int>>(
              <int>[], (prev, chunk) => prev..addAll(chunk));
          await ImageService.instance.saveImageBytes(noteId, filename, bytes);
          downloaded++;
        }
      } catch (e) {
        print('[IMAGE] 下载图片 $imageId 失败: $e');
      } finally {
        client.close();
      }
    }

    if (downloaded > 0) {
      print('[IMAGE] 下载了 $downloaded 张缺失的图片');
    }
    return downloaded;
  }

  /// Upload missing images to remote after a successful push.
  Future<int> _uploadMissingImages(String host, int port) async {
    final db = await DatabaseHelper.instance.database;
    final images = await db.query('note_images');
    int uploaded = 0;

    for (final img in images) {
      final imageId = img['id'] as String;
      final bytes = await ImageService.instance.readImageBytes(imageId);
      if (bytes == null) continue;

      // We don't know if the remote already has this image.
      // For simplicity, upload all images (under 2MB) every time.
      // A better approach would track which images have been synced.
      if (bytes.length > 2 * 1024 * 1024) continue; // skip large images for now

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      try {
        final payload = jsonEncode({
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

        final req = await client.postUrl(
          Uri(scheme: 'http', host: host, port: port, path: '/sync/image'),
        );
        req.headers.contentType = ContentType.json;
        req.write(payload);
        final res = await req.close().timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          uploaded++;
        }
      } catch (e) {
        print('[IMAGE] 上传图片 $imageId 失败: $e');
      } finally {
        client.close();
      }
    }

    if (uploaded > 0) {
      print('[IMAGE] 上传了 $uploaded 张图片');
    }
    return uploaded;
  }
}
