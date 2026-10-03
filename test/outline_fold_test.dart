import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 正文折叠(参考 Obsidian 的标题折叠)的测试。
///
/// 折叠状态是目录和正文**共用**的,所以这里既测纯函数(怎么切正文),
/// 也测预览里的标题 builder(切完之后每个标题有没有认回正确的节点)。

const _doc = '''
# 第一章
第一章的正文。

## 一节
一节的正文。

### 小节
小节的正文。

## 二节
二节的正文。

# 第二章
第二章的正文。
''';

String _idOf(List<OutlineNode> nodes, String text) {
  final node = headingsInOrder(nodes).firstWhere((n) => n.text == text);
  return outlineIdentities(nodes)[node.lineIndex]!;
}

void main() {
  group('ancestorIdentities 祖先链', () {
    test('返回从根到父的标识集合', () {
      final nodes = parseOutline(_doc);
      final xiao = headingsInOrder(nodes).firstWhere((n) => n.text == '小节');
      final anc = ancestorIdentities(nodes, xiao);
      expect(anc, contains('h1|第一章'));
      expect(anc, contains('h2|一节'));
      expect(anc, isNot(contains('h3|小节'))); // 不含自己
    });

    test('根标题没有祖先', () {
      final nodes = parseOutline(_doc);
      final root = headingsInOrder(nodes).firstWhere((n) => n.text == '第一章');
      expect(ancestorIdentities(nodes, root), isEmpty);
    });
  });

  group('foldSectionsForPreview 切正文', () {
    test('没折任何节时原样返回', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, const <String>{});
      expect(r.text, _doc);
      expect(r.headings.map((n) => n.text),
          ['第一章', '一节', '小节', '二节', '第二章']);
    });

    test('折掉 H1:只留它的标题行,正文和子标题全部不渲染', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, {_idOf(nodes, '第一章')});

      expect(r.text, contains('# 第一章'));
      expect(r.text, isNot(contains('第一章的正文。')));
      expect(r.text, isNot(contains('## 一节')));
      expect(r.text, isNot(contains('## 二节')));
      // 兄弟节点不受影响
      expect(r.text, contains('# 第二章'));
      expect(r.headings.map((n) => n.text), ['第一章', '第二章']);
    });

    test('折掉 H2:只影响它自己那一节,H1 和兄弟都还在', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, {_idOf(nodes, '一节')});

      expect(r.text, contains('第一章的正文。'));
      expect(r.text, contains('## 一节'));
      expect(r.text, isNot(contains('一节的正文。')));
      expect(r.text, isNot(contains('### 小节')));
      expect(r.text, contains('## 二节'));
      expect(r.text, contains('二节的正文。'));
      expect(r.headings.map((n) => n.text),
          ['第一章', '一节', '二节', '第二章']);
    });

    test('折最深的 H3 只吃掉它自己的正文', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, {_idOf(nodes, '小节')});
      expect(r.text, contains('一节的正文。'));
      expect(r.text, isNot(contains('小节的正文。')));
      expect(r.text, contains('## 二节'));
    });

    test('同时折外层和内层:展开外层后内层仍是折的', () {
      // 内层的标识还在集合里,所以不是「白折了」
      final nodes = parseOutline(_doc);
      final both = {_idOf(nodes, '第一章'), _idOf(nodes, '一节')};
      final r1 = foldSectionsForPreview(_doc, nodes, both);
      expect(r1.headings.map((n) => n.text), ['第一章', '第二章']);

      // 只展开外层
      final r2 = foldSectionsForPreview(_doc, nodes, {_idOf(nodes, '一节')});
      expect(r2.headings.map((n) => n.text),
          ['第一章', '一节', '二节', '第二章']);
      expect(r2.text, isNot(contains('一节的正文。'))); // 内层还是折的
    });

    test('对不上的标识被忽略(标题被删或被改名)', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, {'h1|这标题早没了'});
      expect(r.text, _doc);
    });

    test('没有子节点的标题折了也没变化', () {
      final nodes = parseOutline(_doc);
      // 二节 下面没有子标题、但有自己的正文,所以折它是有意义的;
      // 用一个真没有内容的标题来试
      const md = '# 甲\n# 乙\n乙的正文\n';
      final n2 = parseOutline(md);
      final r = foldSectionsForPreview(md, n2, {_idOf(n2, '甲')});
      expect(r.text, md); // 甲 没内容可折
    });

    test('折叠后重新解析出来的标题数量与可见列表一致', () {
      final nodes = parseOutline(_doc);
      final r = foldSectionsForPreview(_doc, nodes, {_idOf(nodes, '一节')});
      expect(headingsInOrder(parseOutline(r.text)).length, r.headings.length);
    });

    test('围栏代码块里的 # 不会被误折(它本来就不是标题)', () {
      const md = '# 甲\n```\n# 不是标题\n```\n## 乙\n乙正文\n';
      final nodes = parseOutline(md);
      final r = foldSectionsForPreview(md, nodes, {_idOf(nodes, '乙')});
      expect(r.text, contains('# 不是标题')); // 代码块内容保留
      expect(r.text, isNot(contains('乙正文')));
    });
  });

  group('FoldableHeadingBuilder 预览标题', () {
    /// 用真实的 MarkdownBody 渲染,验证折叠箭头认到了正确的节点。
    Future<List<OutlineNode>> pumpMd(
      WidgetTester tester, {
      required String md,
      required Set<String> folded,
      void Function(OutlineNode)? onToggle,
    }) async {
      final nodes = parseOutline(md);
      final keys = <GlobalKey>[];
      final foldedResult = foldSectionsForPreview(md, nodes, folded);
      final ids = outlineIdentities(nodes);
      // 六个标签共用一个实例,和 note_page 里的用法保持一致
      final builder = FoldableHeadingBuilder(
        keys: keys,
        visibleHeadings: foldedResult.headings,
        isFoldable: (n) => foldedResult.foldable
            .contains(outlineIdentities(nodes)[n.lineIndex]),
        isFolded: (n) => folded.contains(ids[n.lineIndex]),
        onToggleFold: (n) => onToggle?.call(n),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: foldedResult.text,
              builders: {
                for (final tag in const ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
                  tag: builder,
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return foldedResult.headings;
    }

    testWidgets('有内容的标题都有折叠箭头', (tester) async {
      await pumpMd(tester, md: _doc, folded: const <String>{});
      // _doc 里五个标题各自都有正文,所以五个都能折 ——
      // 判据是「标题行之后有没有内容」,不是「有没有子标题」
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(5));
      for (final t in ['第一章', '一节', '小节', '二节', '第二章']) {
        expect(find.text(t), findsOneWidget, reason: '$t 应该渲染出来');
      }
    });

    testWidgets('空标题不画箭头(点了没反应比没有箭头更让人困惑)', (tester) async {
      // 甲 后面紧跟 乙,自己没有正文 => 不可折;乙 有正文 => 可折
      const md = '# 甲\n# 乙\n乙的正文\n';
      await pumpMd(tester, md: md, folded: const <String>{});
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('箭头认的是正确的节点(六个标签共用一个实例的回归)', (tester) async {
      // 这条能抓住「每个标签各建一个 builder」的 bug:那样计数器都从 0 开始,
      // h2 会认成 h1 的节点,还会和 h1 抢同一个 GlobalKey 直接抛异常。
      final toggled = <String>[];
      await pumpMd(
        tester,
        md: _doc,
        folded: const <String>{},
        onToggle: (n) => toggled.add(n.text),
      );

      // 第二个箭头属于「一节」
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).at(1));
      await tester.pumpAndSettle();
      expect(toggled, ['一节']);
    });

    testWidgets('第一个箭头属于第一个标题', (tester) async {
      final toggled = <String>[];
      await pumpMd(
        tester,
        md: _doc,
        folded: const <String>{},
        onToggle: (n) => toggled.add(n.text),
      );
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      expect(toggled, ['第一章']);
    });

    testWidgets('已折叠的标题显示向右箭头,且它的内容不渲染', (tester) async {
      final nodes = parseOutline(_doc);
      final id = _idOf(nodes, '一节');
      await pumpMd(tester, md: _doc, folded: {id});

      expect(find.text('一节的正文。'), findsNothing);
      expect(find.text('小节'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget); // 一节 折着
    });

    testWidgets('折叠之后锚点仍然指向正确的标题', (tester) async {
      // 折掉「一节」这一节之后可见标题少了一个(小节 不再渲染),
      // 锚点必须跟着重排 —— 否则点目录会滚到别的标题上。
      final nodes = parseOutline(_doc);
      final keys = <GlobalKey>[];
      final folded = {_idOf(nodes, '一节')};
      final r = foldSectionsForPreview(_doc, nodes, folded);
      final ids = outlineIdentities(nodes);
      final builder = FoldableHeadingBuilder(
        keys: keys,
        visibleHeadings: r.headings,
        isFoldable: (n) =>
            r.foldable.contains(outlineIdentities(nodes)[n.lineIndex]),
        isFolded: (n) => folded.contains(ids[n.lineIndex]),
        onToggleFold: (_) {},
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: r.text,
              builders: {
                for (final tag in const ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
                  tag: builder,
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(r.headings.map((n) => n.text), ['第一章', '一节', '二节', '第二章']);
      expect(keys.length, r.headings.length);
      // 每个锚点都落在它对应的那个标题上
      for (var i = 0; i < r.headings.length; i++) {
        expect(
          find.descendant(
            of: find.byKey(keys[i]),
            matching: find.text(r.headings[i].text),
          ),
          findsOneWidget,
          reason: '第 $i 个锚点应该对应「${r.headings[i].text}」',
        );
      }
    });
  });
}
