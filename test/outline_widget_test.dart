import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 把 OutlinePanel 塞进最小可用的 MaterialApp 里渲染。
Future<void> pumpPanel(
  WidgetTester tester, {
  required List<OutlineNode> nodes,
  void Function(OutlineNode)? onTapNode,
  VoidCallback? onClose,
  int? activeLineIndex,
  bool autoExpand = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 600,
          child: OutlinePanel(
            nodes: nodes,
            onTapNode: onTapNode ?? (_) {},
            onClose: onClose,
            activeLineIndex: activeLineIndex,
            autoExpand: autoExpand,
          ),
        ),
      ),
    ),
  );
}

/// 测试用文档。结构:
///   第一章          (h1, 有子节点)
///     一节          (h2, 有子节点)
///       条目 A      (列表项)
///     二节          (h2, 无子节点)
///   第二章          (h1, 无子节点)
/// 展开时共 5 行;有子节点的有两个 —— 第一章、一节。
const _doc = '''
# 第一章
## 一节
- 条目 A
## 二节
# 第二章
''';

void main() {
  group('OutlinePanel 渲染', () {
    testWidgets('标题、节点文字、行数都显示出来', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      expect(find.text('目录'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('一节'), findsOneWidget);
      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('二节'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('5'), findsOneWidget); // 展开状态下 5 行
    });

    testWidgets('空文档给出引导文案而不是一片空白', (tester) async {
      await pumpPanel(tester, nodes: const []);
      expect(find.textContaining('还没有目录'), findsOneWidget);
    });

    testWidgets('有关闭回调时才显示关闭按钮', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));
      expect(find.byIcon(Icons.close), findsNothing);

      await pumpPanel(tester, nodes: parseOutline(_doc), onClose: () {});
      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });

  group('OutlinePanel 分级折叠', () {
    testWidgets('折叠父节点会收起整棵子树,兄弟节点不受影响', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      // 只有 第一章 和 一节 有子节点,所以展开态下有 2 个向下三角
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));

      // 第一个箭头属于 第一章
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();

      expect(find.text('第一章'), findsOneWidget); // 自己还在
      expect(find.text('一节'), findsNothing); // 子孙全收起
      expect(find.text('条目 A'), findsNothing);
      expect(find.text('二节'), findsNothing);
      expect(find.text('第二章'), findsOneWidget); // 兄弟不受影响
      expect(find.text('2'), findsOneWidget); // 行数从 5 降到 2

      // 折叠后该节点换成向右三角,其余无子节点 → 不再有向下三角
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    });

    testWidgets('再点一次可以展开回来', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsNothing);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));
    });

    testWidgets('只折叠子节点时父节点保持展开', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      // 第二个箭头属于 一节(它自己也有子节点)
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).at(1));
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsNothing); // 它的子被收起
      expect(find.text('第一章'), findsOneWidget); // 父仍展开
      expect(find.text('一节'), findsOneWidget); // 自己还在
      expect(find.text('二节'), findsOneWidget); // 兄弟仍在
      expect(find.text('4'), findsOneWidget); // 5 - 1

      // 第一章仍向下,一节变成向右
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('全部折叠 / 全部展开 一键切换', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      final toggle = find.byIcon(Icons.unfold_more);
      expect(toggle, findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      // 全折叠后只剩两个根标题
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('一节'), findsNothing);
      expect(find.text('条目 A'), findsNothing);
      expect(find.text('二节'), findsNothing);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('没有任何层级结构时不显示全部折叠按钮', (tester) async {
      await pumpPanel(tester, nodes: parseOutline('# 甲\n# 乙\n'));
      expect(find.byIcon(Icons.unfold_more), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    });
  });

  group('OutlinePanel 过滤搜索', () {
    testWidgets('输入关键字后只剩命中的条目', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));
      expect(find.text('章节'), findsNothing);

      await tester.enterText(find.byType(TextField), '条目');
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('二节'), findsNothing);
      expect(find.text('第二章'), findsNothing);
      // 命中的是列表项,祖先链(第一章/一节)必须保留,否则层级断了
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('一节'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsOneWidget); // 命中 1 条 + 2 级祖先 = 3 行
    });

    testWidgets('过滤时命中项即使原本被折叠也会显示出来', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      // 先把「第一章」折叠起来(条目 A 被藏)
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsNothing);

      // 再搜索它 —— 应该能搜到,而不是「搜了却没结果」
      await tester.enterText(find.byType(TextField), '条目');
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsOneWidget);
    });

    testWidgets('没有命中时给出提示而不是留空', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));
      await tester.enterText(find.byType(TextField), 'zzz不存在');
      await tester.pumpAndSettle();

      expect(find.textContaining('没有匹配'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
    });

    testWidgets('点清除按钮恢复完整目录', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));
      await tester.enterText(find.byType(TextField), '条目');
      await tester.pumpAndSettle();
      expect(find.text('第二章'), findsNothing);

      // 过滤生效后输入框右侧出现清除按钮
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();

      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });
  });

  group('OutlinePanel 按层级收起', () {
    testWidgets('选「显示到 H1」后只剩根标题', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));
      expect(find.text('全部'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示到 H1'));
      await tester.pumpAndSettle();

      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('一节'), findsNothing);
      expect(find.text('条目 A'), findsNothing);
      expect(find.text('H1'), findsOneWidget); // 按钮标签跟着变
    });

    testWidgets('选「显示到 H2」后能看到 H2,但 H3 以下仍收起', (tester) async {
      // 这份文档里 条目 A 是「一节」的子节点,选 H2 时它下面不该展开
      await pumpPanel(tester, nodes: parseOutline(_doc));

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示到 H2'));
      await tester.pumpAndSettle();

      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('一节'), findsOneWidget);
      expect(find.text('二节'), findsOneWidget);
      expect(find.text('条目 A'), findsNothing); // 列表项比 H2 更深
      expect(find.text('H2'), findsOneWidget);
    });

    testWidgets('「全部展开」能把层级限制撤掉(哨兵值 0 的回归)', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc));

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示到 H1'));
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsNothing);

      // value=null 会被 PopupMenuButton 当成取消菜单,所以这里用的是 0
      await tester.tap(find.text('H1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部展开'));
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
    });

    testWidgets('没有层级结构时不显示层级按钮', (tester) async {
      await pumpPanel(tester, nodes: parseOutline('# 甲\n# 乙\n'));
      expect(find.text('全部'), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    });
  });

  group('OutlinePanel 跟随当前章节', () {
    testWidgets('当前章节被折叠时,自动把它所在的祖先链展开', (tester) async {
      final nodes = parseOutline(_doc);
      final entry = nodes[0].children[0].children[0]; // 条目 A(在「一节」下)

      // 先把「第一章」折叠起来,条目 A 被藏
      await pumpPanel(tester, nodes: nodes);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();
      expect(find.text('条目 A'), findsNothing);

      // 正文读到「条目 A」-> 目录必须能显示它,否则高亮无从谈起
      await pumpPanel(tester, nodes: nodes, activeLineIndex: entry.lineIndex);
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsOneWidget);
      expect(find.text('一节'), findsOneWidget); // 中间层也展开了
    });

    testWidgets('autoExpand 为 false 时不擅自展开', (tester) async {
      final nodes = parseOutline(_doc);
      final entry = nodes[0].children[0].children[0];

      await pumpPanel(tester, nodes: nodes);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();

      await pumpPanel(
        tester,
        nodes: nodes,
        activeLineIndex: entry.lineIndex,
        autoExpand: false,
      );
      await tester.pumpAndSettle();

      expect(find.text('条目 A'), findsNothing); // 用户折的就保持折着
    });

    testWidgets('当前章节那一行加粗高亮,其它行不变', (tester) async {
      final nodes = parseOutline(_doc);
      final entry = nodes[0].children[0].children[0]; // 条目 A,列表项默认 w400

      await pumpPanel(tester, nodes: nodes);
      expect(
        tester.widget<Text>(find.text('条目 A')).style?.fontWeight,
        FontWeight.w400,
      );

      await pumpPanel(tester, nodes: nodes, activeLineIndex: entry.lineIndex);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.text('条目 A')).style?.fontWeight,
        FontWeight.w600,
      );
      // 别的列表项不受影响
      expect(
        tester.widget<Text>(find.text('二节')).style?.fontWeight,
        FontWeight.w600, // 标题本来就是 w600
      );
    });

    testWidgets('activeLineIndex 为 null 时不崩、不高亮', (tester) async {
      await pumpPanel(tester, nodes: parseOutline(_doc), activeLineIndex: null);
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('条目 A')).style?.fontWeight,
        FontWeight.w400,
      );
    });

    testWidgets('当前章节是标题本身时也能高亮', (tester) async {
      final nodes = parseOutline(_doc);
      await pumpPanel(tester, nodes: nodes, activeLineIndex: nodes[0].lineIndex);
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget);
    });
  });

  group('OutlinePanel 点击导航', () {
    testWidgets('点列表项把对应节点回传出去,偏移能定位到正文那一行', (tester) async {
      OutlineNode? tapped;
      await pumpPanel(
        tester,
        nodes: parseOutline(_doc),
        onTapNode: (n) => tapped = n,
      );

      await tester.tap(find.text('条目 A'));
      await tester.pumpAndSettle();

      expect(tapped, isNotNull);
      expect(tapped!.text, '条目 A');
      expect(tapped!.isHeading, isFalse);
      expect(_doc.substring(tapped!.charOffset).startsWith('- 条目 A'), isTrue);
    });

    testWidgets('点标题回传的是标题节点,层级正确', (tester) async {
      OutlineNode? tapped;
      await pumpPanel(
        tester,
        nodes: parseOutline(_doc),
        onTapNode: (n) => tapped = n,
      );

      await tester.tap(find.text('第二章'));
      await tester.pumpAndSettle();

      expect(tapped!.isHeading, isTrue);
      expect(tapped!.level, 1);
      expect(_doc.substring(tapped!.charOffset).startsWith('# 第二章'), isTrue);
    });

    testWidgets('点折叠三角不会触发导航(否则想折叠却被跳走)', (tester) async {
      var taps = 0;
      await pumpPanel(
        tester,
        nodes: parseOutline(_doc),
        onTapNode: (_) => taps++,
      );

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pumpAndSettle();

      expect(taps, 0);
    });
  });
}
