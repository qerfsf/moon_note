import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/chunked_editor.dart';
import 'package:moon_note/editor_chunks.dart';
import 'package:moon_note/outline.dart';

/// 分块编辑器的测试。最关键的一条:**编辑和折叠都不能改动正文本身**。
///
/// 断言方式说明:每块的文本包含它前后的换行(切块是按字符范围切的),所以不能用
/// find.text(要求完全相等)。统一按「某个输入框的内容里含不含这段文字」来找。

/// 测试宿主:自己持有折叠状态和全文,模拟 note_page 的接线方式。
class _Host extends StatefulWidget {
  const _Host({required this.initial, this.initialFolded = const <String>{}});

  final String initial;
  final Set<String> initialFolded;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String text = widget.initial;
  late Set<String> folded = widget.initialFolded;

  /// 模拟「外部换掉正文」(撤销、查找替换、拖拽…)。
  void applyExternal(String t) => setState(() => text = t);

  @override
  Widget build(BuildContext context) {
    final nodes = parseOutlineAuto(text);
    return SizedBox(
      width: 500,
      height: 600,
      child: ChunkedEditor(
        markdown: text,
        nodes: nodes,
        foldedIds: folded,
        onFoldedChanged: (f) => setState(() => folded = f),
        onTextChanged: (t) => setState(() => text = t),
        textStyle: const TextStyle(fontSize: 16),
        hintText: '开始写点什么...',
      ),
    );
  }
}

Finder _fieldWith(String snippet) => find.byWidgetPredicate(
      (w) => w is TextField && (w.controller?.text.contains(snippet) ?? false),
      description: '内容含「$snippet」的输入框',
    );

void expectChunk(String snippet) =>
    expect(_fieldWith(snippet), findsOneWidget, reason: '应显示含「$snippet」的块');

void expectNoChunk(String snippet) =>
    expect(_fieldWith(snippet), findsNothing, reason: '不该显示含「$snippet」的块');

Future<_HostState> _pumpHost(
  WidgetTester tester, {
  required String text,
  Set<String> folded = const <String>{},
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: _Host(initial: text, initialFolded: folded)),
  ));
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

const _doc = '# 第一章\n第一章正文。\n\n## 一节\n一节的正文。\n\n## 二节\n二节的正文。\n\n# 第二章\n第二章正文。\n';

String _idOf(String md, String title) {
  final nodes = parseOutlineAuto(md);
  final node = flattenNodes(nodes).firstWhere((n) => n.text == title);
  return outlineIdentities(nodes)[node.lineIndex]!;
}

void main() {
  group('渲染与折叠', () {
    testWidgets('没折叠时每块一个输入框,内容都在', (tester) async {
      await _pumpHost(tester, text: _doc);
      for (final t in ['# 第一章', '第一章正文。', '## 一节', '## 二节', '# 第二章']) {
        expectChunk(t);
      }
    });

    testWidgets('折起一节:它的正文和子标题的块消失,标题行还在', (tester) async {
      await _pumpHost(tester, text: _doc, folded: {_idOf(_doc, '第一章')});

      expectChunk('# 第一章');
      expectNoChunk('第一章正文。');
      expectNoChunk('## 一节');
      expectNoChunk('## 二节');
      // 兄弟不受影响
      expectChunk('# 第二章');
      expectChunk('第二章正文。');
      expect(find.textContaining('已折叠'), findsOneWidget);
    });

    testWidgets('折 H2 只收它自己那一节', (tester) async {
      await _pumpHost(tester, text: _doc, folded: {_idOf(_doc, '一节')});
      expectChunk('# 第一章');
      expectChunk('第一章正文。');
      expectChunk('## 一节');
      expectNoChunk('一节的正文。');
      expectChunk('## 二节');
      expectChunk('二节的正文。');
    });

    testWidgets('标题行左边的三角能折叠、也能展开', (tester) async {
      final host = await _pumpHost(tester, text: _doc);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(4));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      expectNoChunk('第一章正文。');
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(host.folded, isNotEmpty);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expectChunk('第一章正文。');
      expect(host.folded, isEmpty);
    });

    testWidgets('列表项也能折(嵌套子项跟着收)', (tester) async {
      const md = '# 甲\n- 父项\n  - 子项一\n  - 子项二\n- 另一个\n';
      await _pumpHost(tester, text: md, folded: {_idOf(md, '父项')});
      expectChunk('- 父项');
      expectNoChunk('子项一');
      expectChunk('- 另一个');
    });

    testWidgets('纯散文(段落兜底)也能折', (tester) async {
      const md = '第一段\n第一段的第二行\n\n第二段\n\n第三段\n';
      final nodes = parseOutlineAuto(md);
      final ids = outlineIdentities(nodes);
      await _pumpHost(
          tester, text: md, folded: {ids[nodes.first.lineIndex]!});

      expectChunk('第一段'); // 头块(首行)还在
      expectNoChunk('第一段的第二行');
      expectChunk('第二段');
      expectChunk('第三段');
    });
  });

  group('编辑不改内容(内容安全)', () {
    testWidgets('在某块里打字:其它块一字不变', (tester) async {
      final host = await _pumpHost(tester, text: _doc);
      await tester.enterText(_fieldWith('第一章正文。'), '\n第一章正文。补充一句。\n\n');
      await tester.pumpAndSettle();

      expect(host.text, contains('第一章正文。补充一句。'));
      expect(host.text, contains('## 一节\n一节的正文。'));
      expect(host.text, contains('# 第二章\n第二章正文。'));
      expect(host.text, startsWith('# 第一章\n'));
    });

    testWidgets('折叠状态下拼回去的全文仍然完整', (tester) async {
      final host = await _pumpHost(
        tester,
        text: _doc,
        folded: {_idOf(_doc, '第一章')},
      );
      // 折起来之后什么都不做,正文必须和原文逐字符一致
      expect(host.text, _doc);

      // 在可见块里改字,被折叠的部分必须原样保留
      await tester.enterText(_fieldWith('第二章正文。'), '\n第二章改过了。\n');
      await tester.pumpAndSettle();
      expect(host.text, contains('第二章改过了。'));
      expect(host.text, contains('# 第一章\n第一章正文。\n'));
      expect(host.text, contains('## 一节\n一节的正文。'));
    });

    testWidgets('折叠再展开,正文逐字符不变', (tester) async {
      final host = await _pumpHost(tester, text: _doc);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(host.text, _doc);
    });

    testWidgets('空内容不崩', (tester) async {
      final host = await _pumpHost(tester, text: '');
      expect(host.text, '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('只有一行的短文本不崩、也没三角(没东西可折)', (tester) async {
      await _pumpHost(tester, text: '就一行');
      expectChunk('就一行');
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('外部换掉正文(模拟撤销)后,输入框跟着更新', (tester) async {
      final host = await _pumpHost(tester, text: _doc);
      expectChunk('第一章正文。');

      // 模拟撤销:直接把 markdown 换成旧内容
      host.applyExternal('# 第一章\n旧的内容\n');
      await tester.pumpAndSettle();
      expectChunk('旧的内容');
      expectNoChunk('第一章正文。');
    });
  });

  group('划分不变量(与纯函数层同一套保证)', () {
    testWidgets('各种文档下,所有块拼起来都等于全文', (tester) async {
      for (final md in [
        _doc,
        '第一段\n\n第二段\n',
        '# 甲\n- 一\n  - 二\n',
        '前言\n\n# 甲\n正文\n\n# 乙\n- 列表\n  - 子项\n',
      ]) {
        final nodes = parseOutlineAuto(md);
        final chunks = buildEditorChunks(md, nodes, outlineIdentities(nodes));
        final all = [for (final c in chunks) md.substring(c.start, c.end)];
        expect(joinChunkTexts(chunks, all), md);
      }
    });
  });
}
