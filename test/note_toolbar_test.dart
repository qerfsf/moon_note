// 编辑工具栏:用户要求的两个改动不能退化。
//   1) 「1」「2」= 一级/二级标题(# / ##)
//   2) 插入图片搬进「更多」,工具栏上不再有重复的「切换阅读模式」
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:moon_note/database.dart';
import 'package:moon_note/note_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;
  late String noteId;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmpDir = await Directory.systemTemp.createTemp('moon_note_toolbar_');
    DatabaseHelper.debugOverrideDatabasePath(
        '${tmpDir.path}${Platform.pathSeparator}moon_note.db');
    final db = await DatabaseHelper.instance.database;
    noteId = 'toolbar-note';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('nodes', {
      'id': noteId,
      'type': 'note',
      'parent_id': null,
      'title': '工具栏测试',
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
    await db.insert('note_content',
        {'note_id': noteId, 'content': '', 'modified_at': now});
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
    try {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: NotePage(noteId: noteId, initialTitle: '工具栏测试'),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
  }

  testWidgets('工具栏上有「1」「2」两个标题按钮', (tester) async {
    await pumpPage(tester);
    expect(find.byIcon(Icons.looks_one_outlined), findsOneWidget,
        reason: '一级标题按钮(数字 1)');
    expect(find.byIcon(Icons.looks_two_outlined), findsOneWidget,
        reason: '二级标题按钮(数字 2)');
  });

  testWidgets('工具栏上不再有「切换阅读模式」,图片搬进了更多菜单', (tester) async {
    await pumpPage(tester);
    // 工具栏里的阅读模式图标已移除(AppBar 右上角那个仍然存在,所以这里只看
    // 正文编辑区里是否还有 edit/visibility 的切换按钮)
    final toolbarToggle = find.descendant(
      of: find.byType(ListView).first,
      matching: find.byIcon(Icons.visibility_outlined),
      skipOffstage: false,
    );
    expect(toolbarToggle, findsNothing, reason: '工具栏里不该再有阅读模式切换');

    // 打开「更多」菜单,应当能看到「插入图片」
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('插入图片'), findsOneWidget);
  });
}
