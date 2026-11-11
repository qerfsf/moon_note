// 同步冲突:两端都改过同一条笔记时,**不能替用户决定**。
//
// 以前是纯 LWW:谁的 modified_at 新就留谁,旧的那个直接被覆盖掉,界面上只有
// 一句"保留较新的操作",用户完全没得选 —— 感觉就是"我的修改被吞了/被复制了"。
//
// 现在:
//   1. 合并时发现"本地这份还没推出去,对端也有一份不同的" → 判为冲突;
//   2. **不写库**,把两边的内容都留在 [ConflictStore] 里,谁都不丢;
//   3. 界面上把两边内容摆出来让用户选:
//        用我这边的 / 用对方的 / 两边都留
//   4. 选完把该动的那条 modified_at 推到 now,于是下一次同步就会传播出去。
import 'package:flutter/material.dart';

import 'database.dart';

/// 用户对一条冲突的选择。
enum ConflictChoice {
  /// 用本机版本覆盖对端
  keepLocal,

  /// 用对端版本覆盖本机
  useRemote,

  /// 两边都留:本机版本照常传播,对端版本另存为一条新笔记
  keepBoth,
}

class SyncConflict {
  final String noteId;
  final String localTitle;
  final String remoteTitle;
  final int localTime;
  final int remoteTime;
  final String localContent;
  final String remoteContent;

  const SyncConflict({
    required this.noteId,
    required this.localTitle,
    required this.remoteTitle,
    required this.localTime,
    required this.remoteTime,
    required this.localContent,
    required this.remoteContent,
  });

  /// 展示用标题(取本机标题,为空用对端)
  String get displayTitle =>
      localTitle.trim().isNotEmpty ? localTitle : remoteTitle;
}

/// 待处理冲突的集中存放处。
///
/// 只放在内存里:冲突本身就意味着"两端数据不一致",应用重启后下一轮同步会
/// 重新检测出来,不需要持久化(也避免持久化出一份过期的内容快照)。
class ConflictStore {
  static final ConflictStore instance = ConflictStore._();
  ConflictStore._();

  final ValueNotifier<List<SyncConflict>> conflicts =
      ValueNotifier<List<SyncConflict>>(<SyncConflict>[]);

  List<SyncConflict> get pending => conflicts.value;

  /// 记一条冲突。同一个 note 只留一条(后到的覆盖先到的,因为内容更新)。
  void add(SyncConflict c) {
    final list = List<SyncConflict>.from(conflicts.value);
    final idx = list.indexWhere((e) => e.noteId == c.noteId);
    if (idx >= 0) {
      list[idx] = c;
    } else {
      list.add(c);
    }
    conflicts.value = list;
  }

  void remove(String noteId) {
    conflicts.value = conflicts.value
        .where((e) => e.noteId != noteId)
        .toList(growable: false);
  }

  void clear() => conflicts.value = <SyncConflict>[];

  /// 按用户选择落库。
  ///
  /// 关键:无论选哪种,都要把涉及的那条记录的 `modified_at` 推到 now ——
  /// 否则它低于推送水位线,下一次同步不会传播出去,等于白选。
  Future<void> resolve(SyncConflict c, ConflictChoice choice) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    switch (choice) {
      case ConflictChoice.keepLocal:
        // 本机内容不动,只把时间推到 now → 下一次同步由本机版本覆盖对端
        await db.update('nodes', {'modified_at': now},
            where: 'id = ?', whereArgs: [c.noteId]);
        await db.update('note_content', {'modified_at': now},
            where: 'note_id = ?', whereArgs: [c.noteId]);
      case ConflictChoice.useRemote:
        // 用对端版本覆盖本机(标题 + 正文),时间推到 now → 再传播回对端
        await db.update(
          'nodes',
          {'title': c.remoteTitle, 'modified_at': now},
          where: 'id = ?',
          whereArgs: [c.noteId],
        );
        await _writeContent(db, c.noteId, c.remoteContent, now);
      case ConflictChoice.keepBoth:
        // 本机版本照常传播;对端那份另存成一条新笔记,谁都不丢
        final newId = '${DateTime.now().microsecondsSinceEpoch}';
        final parentRow = await db.query('nodes',
            columns: ['parent_id'], where: 'id = ?', whereArgs: [c.noteId]);
        final parentId =
            parentRow.isEmpty ? null : parentRow.first['parent_id'] as String?;
        await db.insert('nodes', {
          'id': newId,
          'type': 'note',
          'parent_id': parentId,
          'title': '${c.remoteTitle} (来自另一台设备)',
          'sort_order': now.toDouble(),
          'is_pinned': 0,
          'pin_order': 0,
          'is_expanded': 0,
          'is_deleted': 0,
          'is_system': 0,
          'created_at': now,
          'modified_at': now,
          'content_modified_at': now,
        });
        await db.insert('note_content', {
          'note_id': newId,
          'content': c.remoteContent,
          'modified_at': now,
        });
        await db.update('nodes', {'modified_at': now},
            where: 'id = ?', whereArgs: [c.noteId]);
        await db.update('note_content', {'modified_at': now},
            where: 'note_id = ?', whereArgs: [c.noteId]);
    }
    remove(c.noteId);
  }

  Future<void> _writeContent(
      dynamic db, String noteId, String content, int now) async {
    final existing = await db.query('note_content',
        where: 'note_id = ?', whereArgs: [noteId], limit: 1);
    if (existing.isEmpty) {
      await db.insert('note_content',
          {'note_id': noteId, 'content': content, 'modified_at': now});
    } else {
      await db.update(
          'note_content', {'content': content, 'modified_at': now},
          where: 'note_id = ?', whereArgs: [noteId]);
    }
  }
}

/// 冲突对比 + 选择对话框:左右两栏摆出两个版本,底下三个按钮。
Future<void> showConflictDialog(BuildContext context, SyncConflict c) async {
  final choice = await showDialog<ConflictChoice>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text('「${c.displayTitle}」两端都改过',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 720,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '两边的内容不一样,这次不自动覆盖 —— 你选哪一边。',
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _VersionPane(
                        label: '本机版本',
                        time: c.localTime,
                        content: c.localContent,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _VersionPane(
                        label: '对端(手机)版本',
                        time: c.remoteTime,
                        content: c.remoteContent,
                        color: cs.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('先不处理'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ConflictChoice.useRemote),
            child: const Text('用对方的覆盖'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ConflictChoice.keepBoth),
            child: const Text('两边都保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ConflictChoice.keepLocal),
            child: const Text('用我的覆盖'),
          ),
        ],
      );
    },
  );
  if (choice == null) return;
  await ConflictStore.instance.resolve(c, choice);
}

String _fmtTime(int ms) {
  if (ms <= 0) return '未知时间';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class _VersionPane extends StatelessWidget {
  const _VersionPane({
    required this.label,
    required this.time,
    required this.content,
    required this.color,
  });

  final String label;
  final int time;
  final String content;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Text('修改于 ${_fmtTime(time)}',
                style: TextStyle(fontSize: 11, color: cs.outline)),
          ),
          Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                content.trim().isEmpty ? '(空)' : content,
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: cs.onSurface),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
