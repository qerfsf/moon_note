// 冲突处理:三种选择落到数据库上的效果。
//
// 用户的原话是"应该给我区别,让我选一个进行覆盖,而不是给我复制",
// 所以这里逐条验证:
//   keepLocal  -> 本机内容不变,时间推进(下次同步覆盖对端)
//   useRemote  -> 本机被对端版本覆盖
//   keepBoth   -> 本机内容不变 + 另存一条对端版本(这是用户**主动选的**,不是自动复制)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:moon_note/database.dart';
import 'package:moon_note/sync_conflict.dart';

void main() {
  late Directory tmpDir;
  late dynamic db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmpDir = await Directory.systemTemp.createTemp('moon_note_conflict_');
    DatabaseHelper.debugOverrideDatabasePath(
        '${tmpDir.path}${Platform.pathSeparator}moon_note.db');
    db = await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
    try {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> seedNote(String title, String content) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('nodes', {
      'id': id,
      'type': 'note',
      'parent_id': null,
      'title': title,
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
    await db.insert('note_content',
        {'note_id': id, 'content': content, 'modified_at': now});
    return id;
  }

  Future<Map<String, Object?>> nodeRow(String id) async {
    final r = await db.query('nodes', where: 'id = ?', whereArgs: [id]);
    return r.first;
  }

  Future<String> contentOf(String id) async {
    final r = await db.query('note_content',
        where: 'note_id = ?', whereArgs: [id], limit: 1);
    return (r.first['content'] as String?) ?? '';
  }

  SyncConflict conflictFor(String id, String localTitle, String localContent) {
    return SyncConflict(
      noteId: id,
      localTitle: localTitle,
      remoteTitle: '手机上的标题',
      localTime: DateTime.now().millisecondsSinceEpoch - 5000,
      remoteTime: DateTime.now().millisecondsSinceEpoch,
      localContent: localContent,
      remoteContent: '手机上的正文',
    );
  }

  test('用我的覆盖:本机内容不动,时间推进到 now(下次同步覆盖对端)', () async {
    final id = await seedNote('本机标题', '本机正文');
    final before = (await nodeRow(id))['modified_at'] as int;

    ConflictStore.instance.add(conflictFor(id, '本机标题', '本机正文'));
    await ConflictStore.instance
        .resolve(conflictFor(id, '本机标题', '本机正文'), ConflictChoice.keepLocal);

    expect((await nodeRow(id))['title'], '本机标题');
    expect(await contentOf(id), '本机正文');
    expect((await nodeRow(id))['modified_at'] as int, greaterThan(before),
        reason: '时间必须推进,否则低于推送水位线、永远不会传播出去');
    expect(ConflictStore.instance.pending, isEmpty, reason: '处理完应当从待办里移除');
  });

  test('用对方的覆盖:本机标题与正文都被对端版本替换,并推进时间', () async {
    final id = await seedNote('本机标题', '本机正文');
    final before = (await nodeRow(id))['modified_at'] as int;

    await ConflictStore.instance
        .resolve(conflictFor(id, '本机标题', '本机正文'), ConflictChoice.useRemote);

    expect((await nodeRow(id))['title'], '手机上的标题');
    expect(await contentOf(id), '手机上的正文');
    expect((await nodeRow(id))['modified_at'] as int, greaterThan(before));
  });

  test('两边都保留:本机不动,另存一条对端版本,原来那条推进时间', () async {
    final id = await seedNote('本机标题', '本机正文');
    final before = (await nodeRow(id))['modified_at'] as int;
    final countBefore = (await db.query('nodes',
            where: "type = 'note' AND is_deleted = 0"))
        .length;

    await ConflictStore.instance
        .resolve(conflictFor(id, '本机标题', '本机正文'), ConflictChoice.keepBoth);

    expect(await contentOf(id), '本机正文', reason: '本机版本不能被改');
    expect((await nodeRow(id))['modified_at'] as int, greaterThan(before));

    final after =
        (await db.query('nodes', where: "type = 'note' AND is_deleted = 0"))
            .length;
    expect(after, countBefore + 1, reason: '应当多出一条笔记');

    final copy = await db.query('nodes',
        where: "type = 'note' AND title LIKE ?",
        whereArgs: ['%来自另一台设备%']);
    expect(copy, isNotEmpty, reason: '新笔记应当标明来自另一台设备');
    expect(await contentOf(copy.first['id'] as String), '手机上的正文');
  });
}
