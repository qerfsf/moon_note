import 'dart:convert';

import 'database.dart';

/// 一次同步中单个变更项(对应需求里的一个"文件")。
class SyncChangeItem {
  final String id; // 笔记/文件夹的 node id
  final String path; // 展示用名称(相对路径语义:标题)
  final String type; // 'added' | 'modified' | 'deleted'
  final int size; // 内容字节数(近似,可选)

  const SyncChangeItem({
    required this.id,
    required this.path,
    required this.type,
    this.size = 0,
  });

  String get typeLabel {
    switch (type) {
      case 'added':
        return '新增';
      case 'deleted':
        return '删除';
      default:
        return '修改';
    }
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'path': path, 'type': type, 'size': size};

  factory SyncChangeItem.fromJson(Map<String, dynamic> json) =>
      SyncChangeItem(
        id: json['id'] as String? ?? '',
        path: json['path'] as String? ?? '未命名',
        type: json['type'] as String? ?? 'modified',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

/// 一轮同步的结果(带变更明细),用于通知与面板。
class SyncRoundResult {
  final int timestamp;
  final List<SyncChangeItem> items;

  const SyncRoundResult({required this.timestamp, required this.items});

  int get totalChanges => items.length;
}

/// 变更日志存储:每轮有变更的同步写一条记录,保留最近 30 天。
class SyncHistoryStore {
  SyncHistoryStore._();
  static final SyncHistoryStore instance = SyncHistoryStore._();

  static const int _keepDays = 30;
  static const int _keepMs = _keepDays * 24 * 60 * 60 * 1000;

  /// 记录一轮同步(仅当 items 非空时由调用方调用),并清理过期记录。
  Future<void> addRound(int timestamp, List<SyncChangeItem> items) async {
    if (items.isEmpty) return;
    final db = await DatabaseHelper.instance.database;
    final id =
        'sync_${timestamp}_${items.length}_${DateTime.now().microsecondsSinceEpoch}';
    await db.insert('sync_history', {
      'id': id,
      'timestamp': timestamp,
      'total_changes': items.length,
      'items_json': jsonEncode(items.map((e) => e.toJson()).toList()),
    });
    // 保留最近 30 天,超出自动清理
    await db.delete(
      'sync_history',
      where: 'timestamp < ?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch - _keepMs],
    );
  }

  /// 按时间倒序取历史记录(P2 历史页备用)。
  Future<List<Map<String, dynamic>>> getRecentRounds({int limit = 100}) async {
    final db = await DatabaseHelper.instance.database;
    return await db.query('sync_history',
        orderBy: 'timestamp DESC', limit: limit);
  }
}
