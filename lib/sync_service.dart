import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'database.dart';

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
  static const _adbSyncCooldownMs = 10000;
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
    if (_adbSyncPending) {
      _adbSyncPending = false;
      _adbSyncLock = true;
      _runAdbSync();
    }
  }

  Future<bool> tryUsbSync() async {
    if (_adbSyncLock) return false;
    _adbSyncLock = true;
    try {
      final devices = await getAdbDevices();
      if (devices.isEmpty) {
        messageNotifier.value = 'USB: 未检测到设备';
        return false;
      }
      await removeAdbForward(localPort: 9091);
      final ok = await setupAdbForward(localPort: 9091, remotePort: 9090);
      if (!ok) {
        messageNotifier.value = 'USB: 端口转发失败';
        return false;
      }
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
            } catch (_) {}
            if (i == 0) await Future.delayed(const Duration(milliseconds: 300));
          }
        } finally {
          checkClient?.close();
        }
        if (!connected) {
          messageNotifier.value = 'USB: 无法连接到手机服务';
          return false;
        }
        await fullSync('127.0.0.1', 9091, saveConnection: false);
        try {
          final wifiIp = await _getDeviceWifiIp(devices.first);
          if (wifiIp != null) {
            await saveLastConnection(wifiIp, 9090);
          }
        } catch (_) {}
        return true;
      } finally {
        await removeAdbForward(localPort: 9091);
      }
    } catch (e) {
      messageNotifier.value = 'USB 同步失败: $e';
      return false;
    } finally {
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
      final request = await client.postUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/pull'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'last_sync': lastSync}));
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
      messageNotifier.value = '拉取完成，合并 $merged 项';
      statusNotifier.value = SyncStatus.idle;
      return data;
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '拉取失败: $e';
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

      final request = await client.postUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/push'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'nodes': nodes,
        'content': content,
        'fts': fts,
      }));
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
      messageNotifier.value =
          '推送完成 (${nodes.length} 节点)';
      statusNotifier.value = SyncStatus.idle;
      return data;
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '推送失败: $e';
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<int> fullSync(String host, int port, {bool saveConnection = true}) async {
    statusNotifier.value = SyncStatus.connecting;
    messageNotifier.value = '正在检查连接...';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 1);
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
    } catch (e) {
      client.close();
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '连接失败: $e';
      rethrow;
    }
    client.close();

    await pushTo(host, port);
    await pullFrom(host, port);
    if (saveConnection) {
      await saveLastConnection(host, port);
    }
    statusNotifier.value = SyncStatus.idle;
    return 0;
  }

  Future<int> _mergeRemoteData(Map<String, dynamic> data) async {
    final db = await DatabaseHelper.instance.database;
    int merged = 0;

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

    return merged;
  }

  Map<String, dynamic> _toDbMap(Map<String, dynamic> map) {
    final db = <String, dynamic>{};
    for (final entry in map.entries) {
      if (entry.value != null) {
        db[entry.key] = entry.value;
      }
    }
    return db;
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
    _sendJson(request.response, {
      'version': '1.0.0',
      'device': Platform.localHostname,
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

    _sendJson(request.response, {
      'nodes': nodes,
      'content': content,
      'fts': fts,
      'server_time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _handlePush(HttpRequest request) async {
    final bytes = await request.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    final body = utf8.decode(bytes);
    final data = jsonDecode(body) as Map<String, dynamic>;
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

    _sendJson(request.response, {
      'merged': merged,
      'server_time': DateTime.now().millisecondsSinceEpoch,
      'nodes': newNodes,
      'content': newContent,
      'fts': newFts,
    });
  }

  void _sendJson(HttpResponse response, Map<String, dynamic> data,
      {int status = 200}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }
}
