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

  String? get _adbPath {
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
    return 'adb';
  }

  Future<List<String>> getAdbDevices() async {
    try {
      final result = await Process.run(_adbPath!, ['devices']);
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
          await Process.run(_adbPath!, ['reverse', 'tcp:$port', 'tcp:$port']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removeAdbReverse({int port = 9090}) async {
    try {
      final result = await Process.run(
          _adbPath!, ['reverse', '--remove', 'tcp:$port']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
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
    try {
      final lastSync = await _getLastSyncTime();
      final client = HttpClient();
      final request = await client.postUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/pull'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'last_sync': lastSync}));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw Exception('服务器返回 ${response.statusCode}');
      }
      final body = await utf8.decodeStream(response);
      client.close();
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
    }
  }

  Future<Map<String, dynamic>> pushTo(String host, int port) async {
    statusNotifier.value = SyncStatus.syncing;
    messageNotifier.value = '正在推送变更...';
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

      final client = HttpClient();
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
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw Exception('服务器返回 ${response.statusCode}');
      }
      final body = await utf8.decodeStream(response);
      client.close();
      final data = jsonDecode(body) as Map<String, dynamic>;
      // Server may return additional updates to merge
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
    }
  }

  Future<int> fullSync(String host, int port) async {
    statusNotifier.value = SyncStatus.connecting;
    messageNotifier.value = '正在检查连接...';
    try {
      // Check connectivity
      final client = HttpClient();
      final statusReq = await client.getUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/sync/status'),
      );
      final statusRes = await statusReq.close().timeout(
            const Duration(seconds: 5),
          );
      if (statusRes.statusCode != 200) {
        throw Exception('无法连接到同步服务');
      }
      client.close();
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      messageNotifier.value = '连接失败: $e';
      rethrow;
    }

    await pushTo(host, port);
    await pullFrom(host, port);
    await saveLastConnection(host, port);
    statusNotifier.value = SyncStatus.idle;
    return 0;
  }

  Future<int> _mergeRemoteData(Map<String, dynamic> data) async {
    final db = await DatabaseHelper.instance.database;
    int merged = 0;

    if (data['nodes'] != null) {
      for (final node in (data['nodes'] as List)) {
        final existing = await db.query(
          'nodes',
          where: 'id = ?',
          whereArgs: [node['id']],
        );
        if (existing.isEmpty) {
          await db.insert('nodes', _toDbMap(node));
          merged++;
        } else {
          final localModified = existing.first['modified_at'] as int;
          final remoteModified = node['modified_at'] as int;
          if (remoteModified > localModified) {
            await db.update(
              'nodes',
              _toDbMap(node),
              where: 'id = ?',
              whereArgs: [node['id']],
            );
            merged++;
          }
        }
      }
    }

    if (data['content'] != null) {
      for (final c in (data['content'] as List)) {
        final existing = await db.query(
          'note_content',
          where: 'note_id = ?',
          whereArgs: [c['note_id']],
        );
        if (existing.isEmpty) {
          await db.insert('note_content', _toDbMap(c));
          merged++;
        } else {
          final localModified = existing.first['modified_at'] as int;
          final remoteModified = c['modified_at'] as int;
          if (remoteModified > localModified) {
            await db.update(
              'note_content',
              _toDbMap(c),
              where: 'note_id = ?',
              whereArgs: [c['note_id']],
            );
            merged++;
          }
        }
      }
    }

    if (data['fts'] != null) {
      for (final f in (data['fts'] as List)) {
        await db.rawInsert(
          'INSERT OR REPLACE INTO fts_content(note_id, title, content) VALUES(?, ?, ?)',
          [f['note_id'], f['title'], f['content']],
        );
      }
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

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      switch (path) {
        case '/sync/status':
          await _handleStatus(request);
          break;
        case '/sync/pull':
          await _handlePull(request);
          break;
        case '/sync/push':
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

    // Also send back any newer local changes the client might need
    final db = await DatabaseHelper.instance.database;
    final lastSync = await _getLastSyncTime();
    final newNodes = await db.query(
      'nodes',
      where: 'modified_at > ?',
      whereArgs: [lastSync],
    );
    final newContent = await db.rawQuery(
      'SELECT nc.* FROM note_content nc INNER JOIN nodes n ON n.id = nc.note_id WHERE n.modified_at > ?',
      [lastSync],
    );
    final newFts = await db.rawQuery(
      'SELECT fc.* FROM fts_content fc INNER JOIN nodes n ON n.id = fc.note_id WHERE n.modified_at > ?',
      [lastSync],
    );

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
