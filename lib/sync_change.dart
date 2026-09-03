import 'dart:convert';

import 'database.dart';

/// 一次同步中单个变更项(对应需求里的一个"文件")。
class SyncChangeItem {
  final String id; // 笔记/文件夹的 node id
  final String path; // 展示用名称(相对路径语义:标题)
  final String type; // 'added' | 'modified' | 'deleted' | 'conflict'
  final int size; // 内容字节数(近似,可选)

  /// 同步前的内容快照(本机在被合并覆盖前的内容)。
  /// 'modified'/'deleted'/'conflict' 且本地存在时记录;否则为 null。
  final String? oldContent;

  /// 同步后的内容快照(对端收到的/推送后的内容)。
  /// 对端内容随拉取/推送数据可得时记录;否则为 null。
  final String? newContent;

  /// 旧版本(同步前/本机)的修改时间,ms;无旧版本时为 0。
  final int oldTime;

  /// 新版本(同步后/对端/优先版本)的修改时间,ms;无则为 0。
  final int newTime;

  const SyncChangeItem({
    required this.id,
    required this.path,
    required this.type,
    this.size = 0,
    this.oldContent,
    this.newContent,
    this.oldTime = 0,
    this.newTime = 0,
  });

  /// 内容快照是否足够做对比(两侧任一存在即展示,单侧也允许)。
  bool get hasSnapshot => oldContent != null || newContent != null;

  /// 对外展示的时间(取新版本的修改时间;删除取删除时间)。
  int get displayTime => newTime > 0 ? newTime : oldTime;

  String get typeLabel {
    switch (type) {
      case 'added':
        return '新增';
      case 'deleted':
        return '删除';
      case 'conflict':
        return '冲突';
      default:
        return '修改';
    }
  }

  /// 单侧内容超长时截断,避免日志表无限膨胀(30 天保留)。
  static String? _cap(String? s) {
    if (s == null) return null;
    if (s.length <= 30000) return s;
    return '${s.substring(0, 30000)}\n…(内容过长已截断)';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'type': type,
        'size': size,
        'oldContent': _cap(oldContent),
        'newContent': _cap(newContent),
        'oldTime': oldTime,
        'newTime': newTime,
      };

  factory SyncChangeItem.fromJson(Map<String, dynamic> json) =>
      SyncChangeItem(
        id: json['id'] as String? ?? '',
        path: json['path'] as String? ?? '未命名',
        type: json['type'] as String? ?? 'modified',
        size: (json['size'] as num?)?.toInt() ?? 0,
        oldContent: json['oldContent'] as String?,
        newContent: json['newContent'] as String?,
        oldTime: (json['oldTime'] as num?)?.toInt() ?? 0,
        newTime: (json['newTime'] as num?)?.toInt() ?? 0,
      );
}

/// 一轮同步的结果(带变更明细),用于通知与面板。
class SyncRoundResult {
  final int timestamp;
  final List<SyncChangeItem> items;

  /// 本轮清理回收站的永久删除条数(清空回收站/永久删除,经 deleted_ids 传播)。
  final int hardDeletes;

  const SyncRoundResult(
      {required this.timestamp, required this.items, this.hardDeletes = 0});

  int get totalChanges => items.length;

  /// 文件(笔记/文件夹)变更:新增/修改/冲突。
  List<SyncChangeItem> get fileItems =>
      items.where((e) => e.type != 'deleted').toList();

  /// 回收站相关:软删除(移入回收站)条目。
  List<SyncChangeItem> get trashItems =>
      items.where((e) => e.type == 'deleted').toList();

  /// 是否涉及回收站(软删除 + 永久清理)。
  bool get hasTrashOps => trashItems.isNotEmpty || hardDeletes > 0;

  /// 是否存在并发编辑等"有差异"项(本地与远端同改,未能干净合并)。
  bool get hasConflict => items.any((e) => e.type == 'conflict');

  List<SyncChangeItem> get conflicts =>
      items.where((e) => e.type == 'conflict').toList();
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
