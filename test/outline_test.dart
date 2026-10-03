import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 把大纲树压成 "缩进+文字" 的字符串,便于断言结构。
String dump(List<OutlineNode> nodes, [int depth = 0]) {
  final sb = StringBuffer();
  for (final n in nodes) {
    sb.write('${'  ' * depth}${n.isHeading ? 'H${n.level}' : 'L${n.level}'}'
        ':${n.text}@${n.charOffset}\n');
    sb.write(dump(n.children, depth + 1));
  }
  return sb.toString();
}

void main() {
  group('parseOutline', () {
    test('标题分层:# > ## > ###', () {
      final md = '# A\n## B\n### C\n## D\n# E\n';
      expect(
        dump(parseOutline(md)),
        'H1:A@0\n'
        '  H2:B@4\n'
        '    H3:C@9\n'
        '  H2:D@15\n'
        'H1:E@20\n',
      );
    });

    test('列表项挂在最近的标题下,并按缩进分父子', () {
      final md = '## 章节\n- 一级\n  - 二级\n    - 三级\n- 一级2\n';
      final out = dump(parseOutline(md));
      expect(out, contains('H2:章节@0'));
      expect(out, contains('  L1:一级@'));
      expect(out, contains('    L2:二级@'));
      expect(out, contains('      L3:三级@'));
      expect(out, contains('  L1:一级2@'));
    });

    test('列表之后的同级标题会回到正确层级(不会挂错)', () {
      final md = '# A\n- x\n# B\n';
      final nodes = parseOutline(md);
      expect(nodes.length, 2, reason: '两个一级标题都应在根层');
      expect(nodes[0].children.length, 1, reason: '列表项是 A 的子节点');
      expect(nodes[1].text, 'B');
      expect(nodes[1].children, isEmpty);
    });

    test('代码块里的 # 和 - 必须被忽略', () {
      final md = '# 真标题\n```\n# 这是注释,不是标题\n- 也不是列表\n```\n## 后一个标题\n';
      final nodes = parseOutline(md);
      // ## 比 # 低一级,所以它是「真标题」的子节点;关键是代码块那两行没变成节点
      expect(nodes.length, 1);
      expect(nodes[0].text, '真标题');
      expect(nodes[0].children.length, 1);
      expect(nodes[0].children[0].text, '后一个标题');
    });

    test('波浪线围栏同样忽略', () {
      final md = '# A\n~~~\n# 注释\n~~~\n';
      final nodes = parseOutline(md);
      expect(nodes.length, 1);
      expect(nodes[0].children, isEmpty);
    });

    test('任务框语法只留文字', () {
      final md = '- [ ] 待办事项\n- [x] 已完成\n';
      final nodes = parseOutline(md);
      expect(nodes[0].text, '待办事项');
      expect(nodes[1].text, '已完成');
    });

    test('行内标记被清理,标题收尾的 # 被去掉', () {
      final md = '## **粗**与`码` ##\n';
      expect(parseOutline(md)[0].text, '粗与码');
    });

    test('空标题占位;裸 ## 不算标题(CommonMark 要求 # 后有空格)', () {
      expect(parseOutline('## \n')[0].text, '(空标题)');
      expect(parseOutline('##\n'), isEmpty);
    });

    test('charOffset 是行首在正文里的字符偏移(编辑态定位要用)', () {
      final md = 'abc\ndef\n## 目标\n';
      final nodes = parseOutline(md);
      // 'abc\n' = 4, 'def\n' = 4 -> 目标行从 8 开始
      expect(nodes[0].charOffset, 8);
    });

    test('有序列表也算列表项', () {
      final md = '1. 第一\n2. 第二\n';
      final nodes = parseOutline(md);
      expect(nodes.length, 2);
      expect(nodes[0].text, '第一');
      expect(nodes[1].text, '第二');
    });

    test('空内容返回空列表', () {
      expect(parseOutline(''), isEmpty);
      expect(parseOutline('\n\n'), isEmpty);
    });
  });

  group('flattenOutline', () {
    test('折叠父节点后子节点不再出现', () {
      final nodes = parseOutline('# A\n## B\n## C\n');
      final all = flattenOutline(nodes, {});
      expect(all.length, 3);

      final collapsed = flattenOutline(nodes, {nodes[0].lineIndex});
      expect(collapsed.length, 1, reason: 'A 折叠后只剩 A 自己');
      expect(collapsed[0].node.text, 'A');
    });

    test('折叠只影响被折叠的子树', () {
      final nodes = parseOutline('# A\n## B\n### C\n## D\n');
      final b = nodes[0].children[0];
      final rows = flattenOutline(nodes, {b.lineIndex});
      // A, B(折叠), D
      expect(rows.map((r) => r.node.text).toList(), ['A', 'B', 'D']);
    });
  });
}
