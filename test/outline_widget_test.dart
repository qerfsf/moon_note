import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 把 OutlinePanel 塞进最小可用的 MaterialApp 里渲染。
Future<void> pumpPanel(
  WidgetTester tester, {
  required List<OutlineNode> nodes,
  void Function(OutlineNode)? onTapNode,
  VoidCallback? onClose,
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
