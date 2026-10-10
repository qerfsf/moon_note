// 验证桌面端「新建笔记」这一条真实交互路径:
//   点 + 号之后 → ① 笔记真的建出来了 ② 笔记页真的打开了 ③ 光标已经落在
//   标题框里(可以直接打字起名) ④ 打字确实写进了标题
//
// 数据安全:测试**不碰**用户的真实数据库 —— 先把真实库复制一份到临时目录,
// 再用 DatabaseHelper.debugOverrideDatabasePath 指过去,结束时删掉临时目录。
// 也不调用 app.main():那样会起 HTTP 服务、初始化通知、并在 2 秒后触发一次
// 自动同步(可能把测试笔记推到手机)。这里只 pump HomePage 本体。
//
// 跑法(先关掉正在运行的电脑端):
//   flutter test integration_test/new_note_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:moon_note/database.dart';
import 'package:moon_note/home_page.dart';
import 'package:moon_note/note_page.dart';

/// 标题输入框:带固定 key 的那个(见 note_page 的 note_title_field)。
/// 注意 skipOffstage:false —— 这个桌面布局在测试树里被判成 offstage,
/// 用默认值会一个都找不到。
Finder get _titleField =>
    find.byKey(const ValueKey('note_title_field'), skipOffstage: false);

TextField _titleWidget(WidgetTester tester) =>
    tester.widget<TextField>(_titleField.first);

/// 焦点是不是在标题框上。
///
/// 判据是「全局焦点节点 == 标题框自己的 FocusNode」,不依赖 offstage,
/// 也不用 find.descendant(它内部的匹配器仍然按 skipOffstage=true 过滤)。
bool _titleHasFocus(WidgetTester tester) {
  if (_titleField.evaluate().isEmpty) return false;
  final node = _titleWidget(tester).focusNode;
  if (node == null) return false;
  return identical(FocusManager.instance.primaryFocus, node);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUpAll(() async {
    // 0) 桌面端数据库要先装 ffi 工厂 —— 平时这一步在 main() 里做,
    //    这个测试刻意不走 main(),所以要自己来。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // 1) 先取真实库路径(这一步会把真实路径缓存下来)
    final realPath = await DatabaseHelper.resolvedDatabasePath;
    final realFile = File(realPath);

    // 2) 复制到临时目录,并把 app 指过去
    tmpDir = await Directory.systemTemp.createTemp('moon_note_it_');
    final copyPath = '${tmpDir.path}${Platform.pathSeparator}moon_note.db';
    if (await realFile.exists()) {
      await realFile.copy(copyPath);
      // ignore: avoid_print
      print('[测试] 已把真实库复制到临时目录: $copyPath');
    } else {
      // ignore: avoid_print
      print('[测试] 没有真实库,用空库跑: $copyPath');
    }
    DatabaseHelper.debugOverrideDatabasePath(copyPath);

    // 3) 断掉「上次连接」的 WiFi 回退同步,免得测试里意外连上手机
    final db = await DatabaseHelper.instance.database;
    await db.delete('app_settings',
        where: 'key IN (?, ?)', whereArgs: ['sync_host', 'sync_port']);
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
    try {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    } catch (e) {
      // ignore: avoid_print
      print('[测试] 临时目录没删掉(不影响结果): $e');
    }
  });

  testWidgets('新建笔记:自动打开,且光标已在标题框里', (tester) async {
    // 直接 pump 主界面本体(绕开 main() 的同步服务/通知初始化)
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final db = await DatabaseHelper.instance.database;
    final before =
        (await db.query('nodes', where: "type = 'note' AND is_deleted = 0"))
            .length;

    final fab = find.byIcon(Icons.add);
    // ignore: avoid_print
    print('[测试] 新建按钮个数: ${fab.evaluate().length}');
    expect(fab, findsWidgets, reason: '主界面应当有新建笔记的按钮');
    await tester.tap(fab.first);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // ① 笔记建出来了
    final after =
        (await db.query('nodes', where: "type = 'note' AND is_deleted = 0"))
            .length;
    // ignore: avoid_print
    print('[测试] 笔记数: $before -> $after');
    expect(after, before + 1, reason: '应当新建了一条笔记');

    // ② 笔记被打开了
    // ignore: avoid_print
    print('[测试] NotePage 个数: ${find.byType(NotePage).evaluate().length}'
        ' (skipOffstage=false: '
        '${find.byType(NotePage, skipOffstage: false).evaluate().length})');
    expect(find.byType(NotePage), findsWidgets, reason: '新建后应当自动打开这条笔记');

    // ③ 光标已经在标题框里(轮询,顺便测出多快生效)
    final sw = Stopwatch()..start();
    var focused = _titleHasFocus(tester);
    while (!focused && sw.elapsedMilliseconds < 3000) {
      await tester.pump(const Duration(milliseconds: 100));
      focused = _titleHasFocus(tester);
    }
    sw.stop();
    final titleWidget = _titleWidget(tester);
    // 诊断:到底是谁拿着焦点(顺着 primaryFocus 向上走几层)
    final pf = FocusManager.instance.primaryFocus;
    // ignore: avoid_print
    print('[测试] primaryFocus: label=${pf?.debugLabel} '
        'hasFocus=${pf?.hasFocus} canRequest=${pf?.canRequestFocus}');
    final chain = <String>[];
    pf?.context?.visitAncestorElements((e) {
      chain.add(e.widget.runtimeType.toString());
      return chain.length < 8;
    });
    // ignore: avoid_print
    print('[测试] primaryFocus 所在 widget: ${chain.join(" < ")}');
    // ignore: avoid_print
    print('[测试] 标题框 focusNode: ${titleWidget.focusNode} '
        'hasFocus=${titleWidget.focusNode?.hasFocus} '
        'canRequest=${titleWidget.focusNode?.canRequestFocus}');
    // ignore: avoid_print
    print('[测试] 标题框: 文本=${titleWidget.controller?.text} '
        'hint=${titleWidget.decoration?.hintText} '
        'autofocus=${titleWidget.autofocus}');
    // ignore: avoid_print
    print('[测试] 标题框是否已获得焦点: $focused (耗时 ${sw.elapsedMilliseconds}ms)');
    expect(focused, isTrue, reason: '新建后光标应当已经在标题框里,可以直接打字');

    // ④ 打字就落到标题上。
    //    不走 tester.enterText:它内部按 skipOffstage=true 找 EditableText,
    //    在这个布局下会报 "Bad state: No element"。
    //    这里直接喂 updateEditingValue —— 真实键盘输入走的就是它,会触发
    //    onChanged,和手打完全同一条保存路径。
    final ctrl = titleWidget.controller!;
    final editable = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller == ctrl,
      skipOffstage: false,
    );
    // ignore: avoid_print
    print('[测试] EditableText 个数: ${editable.evaluate().length}');
    expect(editable, findsWidgets, reason: '标题框应当有对应的 EditableText');
    tester.state<EditableTextState>(editable.first).updateEditingValue(
          const TextEditingValue(
            text: '这是一次新建测试',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final newest = await db.query('nodes',
        where: "type = 'note' AND is_deleted = 0",
        orderBy: 'created_at DESC',
        limit: 1);
    final title = newest.first['title'] as String;
    // ignore: avoid_print
    print('[测试] 最新笔记的标题: $title');
    expect(title, '这是一次新建测试', reason: '标题输入框应当能直接接收输入');
    // ignore: avoid_print
    print('[测试] 结论: 新建 → 自动打开 → 标题框已聚焦 → 打字进标题,全部成立');
  });
}
