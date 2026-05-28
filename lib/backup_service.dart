import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'database.dart';

class BackupService {
  static final BackupService instance = BackupService._();
  BackupService._();

  static const _tables = [
    'nodes',
    'note_content',
    'fts_content',
    'reminders',
    'note_links',
    'app_settings',
  ];

  Future<String> exportToFile() async {
    final db = await DatabaseHelper.instance.database;
    final data = <String, dynamic>{
      'version': 1,
      'app_version': '3.0.0',
      'exported_at': DateTime.now().toIso8601String(),
      'tables': <String, dynamic>{},
    };

    for (final table in _tables) {
      final rows = await db.query(table);
      final serialized = rows.map((row) {
        final m = <String, dynamic>{};
        for (final entry in row.entries) {
          m[entry.key] = entry.value;
        }
        return m;
      }).toList();
      data['tables'][table] = serialized;
    }

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await _exportDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}${Platform.pathSeparator}moon_note_backup_$timestamp.json');
    await file.writeAsString(jsonStr, flush: true);
    return file.path;
  }

  Future<int> importFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('文件不存在: $filePath');
    }

    final jsonStr = await file.readAsString();
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final tables = data['tables'] as Map<String, dynamic>?;
    if (tables == null) {
      throw Exception('无效的备份文件格式');
    }

    final db = await DatabaseHelper.instance.database;
    int total = 0;

    await db.transaction((txn) async {
      // Clear existing data in reverse dependency order
      await txn.delete('note_links');
      await txn.delete('reminders');
      await txn.delete('fts_content');
      await txn.delete('note_content');
      await txn.delete('nodes');
      await txn.delete('app_settings');

      // Import in dependency order
      for (final table in _tables) {
        final rows = tables[table] as List?;
        if (rows == null) continue;
        for (final row in rows) {
          if (row is Map<String, dynamic>) {
            await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
            total++;
          }
        }
      }
    });

    return total;
  }

  Future<Directory> _exportDir() async {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Download');
    }
    return await getApplicationDocumentsDirectory();
  }
}
