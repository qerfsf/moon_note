// 独立窗口的排版宽度。
//
// 用户开独立窗口是为了「看得更多」:正文版心得比主窗口明显宽,但**不占满** ——
// 界面是简约风,居中 + 两侧留白。主窗口 800、独立窗口 1100。
// 这里用真实的 NotePage 渲染后量两个东西:
//   1) 版心盒子(ConstrainedBox)的实际宽度 —— 证明留白;
//   2) 标题输入框宽度 —— 它横跨整栏,证明正文确实变宽了。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:moon_note/database.dart';
import 'package:moon_note/note_page.dart';

const _wide = Size(1600, 900);

Finder get _titleField =>
    find.byKey(const ValueKey('note_title_field'), skipOffstage: false);

/// 版心盒子:标题框最近的 ConstrainedBox 祖先就是它。
Finder get _bodyBox =>
    find.ancestor(of: _titleField.first, matching: find.byType(ConstrainedBox));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;
  late String noteId;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 用临时库,绝不碰用户真实数据
    tmpDir = await Directory.systemTemp.createTemp('moon_note_width_');
    DatabaseHelper.debugOverrideDatabasePath(
        '${tmpDir.path}${Platform.pathSeparator}moon_note.db');
    final db = await DatabaseHelper.instance.database;
    noteId = 'test-note-1';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('nodes', {
      'id': noteId,
      'type': 'note',
      'parent_id': null,
      'title': '宽度测试',
      'sort_order': 1.0,
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
      'note_id': noteId,
      'content': '# 标题\n\n正文\n',
      'modified_at': now,
    });
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
    try {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(WidgetTester tester, {required bool standalone}) async {
    tester.view.physicalSize = _wide;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: NotePage(
        noteId: noteId,
        initialTitle: '宽度测试',
        standalone: standalone,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // sqflite 的查询是真实异步的,而 pumpAndSettle 只等帧不等它;用 runAsync
    // 让它跑完,否则测试结束时会残留 sqflite 内部的 10 秒锁超时定时器,
    // 报 "A Timer is still pending even after the widget tree was disposed"。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  }

  testWidgets('主窗口嵌入面板:版心 800,标题框明显更窄', (tester) async {
    await pumpPage(tester, standalone: false);
    expect(_titleField, findsWidgets);
    final boxW = tester.getSize(_bodyBox.first).width;
    final fieldW = tester.getSize(_titleField.first).width;
    // ignore: avoid_print
    print('[测试] 嵌入面板: 版心 ${boxW.toStringAsFixed(1)}px, '
        '标题框 ${fieldW.toStringAsFixed(1)}px (窗口 1600px)');
    expect(boxW, closeTo(800, 0.5), reason: '主窗口版心应当是 800');
    expect(boxW, lessThan(_wide.width), reason: '界面必须留白,不能占满窗口');
  });

  testWidgets('独立窗口:版心更宽(1100)但仍居中留白', (tester) async {
    await pumpPage(tester, standalone: true);
    expect(_titleField, findsWidgets);
    final boxW = tester.getSize(_bodyBox.first).width;
    final fieldW = tester.getSize(_titleField.first).width;
    // ignore: avoid_print
    print('[测试] 独立窗口: 版心 ${boxW.toStringAsFixed(1)}px, '
        '标题框 ${fieldW.toStringAsFixed(1)}px (窗口 1600px)');
    expect(boxW, closeTo(1100, 0.5),
        reason: '独立窗口版心 1100:比主窗口宽得多,又不会拉成一整屏');
    expect(boxW, lessThan(_wide.width - 200),
        reason: '1600px 窗口里两侧要留出留白');
    expect(fieldW, greaterThan(700),
        reason: '正文列应当明显宽于主窗口里约 540px 的那一列');
  });
}
