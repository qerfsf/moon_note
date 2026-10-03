import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// ① Remember state / ② 上下标题 + 复制标题 / ③ 悬停预览 的纯函数测试。

const _doc = '''
# 第一章
开头的话。

## 一节
一节的正文。
第二行。

### 小节
小节的正文。

## 二节
二节的正文。

# 第二章
第二章的正文。
- 条目 A
''';

void main() {
  group('outlineIdentities 稳定标识', () {
    test('每个节点都有标识,格式是 类型+层级|文字', () {
      final ids = outlineIdentities(parseOutline(_doc));
      final flat = flattenNodes(parseOutline(_doc));
      expect(ids.length, flat.length);
      expect(ids.values, contains('h1|第一章'));
      expect(ids.values, contains('h2|一节'));
      expect(ids.values, contains('h3|小节'));
    });

    test('同名同层级的标题靠 #2 #3 后缀区分', () {
      final ids = outlineIdentities(parseOutline('# 甲\n## 同名\n## 同名\n# 甲\n'));
      final values = ids.values.toList();
      expect(values, contains('h2|同名'));
      expect(values, contains('h2|同名#1'));
      expect(values, contains('h1|甲'));
      expect(values, contains('h1|甲#1'));
    });

    test('标题和同层级的列表项不能撞成同一个标识', () {
      // 列表项的 level 是缩进深度,顶层列表项 level 就是 1,和 H1 相同
      final ids = outlineIdentities(parseOutline('# 甲\n- 甲\n'));
      final values = ids.values.toList();
      expect(values.toSet().length, values.length, reason: '不应有重复标识');
      expect(values, contains('h1|甲'));
      expect(values, contains('l1|甲'));
    });

    test('在别处插一个标题,原有标识不变(所以记忆不会错位)', () {
      final before = outlineIdentities(parseOutline(_doc)).values.toSet();
      // 在最前面插一个完全不同的标题
      final after =
          outlineIdentities(parseOutline('# 前言\n$_doc')).values.toSet();
      // 原有节点的标识都还在
      for (final id in before) {
        expect(after.contains(id), isTrue, reason: '$id 应该保持不变');
      }
    });

    test('列表项也有标识', () {
      final ids = outlineIdentities(parseOutline(_doc));
      expect(ids.values.any((v) => v.startsWith('l1|条目 A')), isTrue);
    });
  });

  group('headingsInOrder', () {
    test('按文档顺序只返回标题', () {
      final heads = headingsInOrder(parseOutline(_doc));
      expect(heads.map((n) => n.text),
          ['第一章', '一节', '小节', '二节', '第二章']);
      expect(heads.every((n) => n.isHeading), isTrue);
    });

    test('没有标题时返回空', () {
      expect(headingsInOrder(parseOutline('- 只有列表\n- 第二条\n')), isEmpty);
    });
  });

  group('outlineToMarkdown 复制标题', () {
    test('默认只导出标题,层级用 # 还原', () {
      final md = outlineToMarkdown(parseOutline(_doc));
      expect(md, contains('# 第一章'));
      expect(md, contains('## 一节'));
      expect(md, contains('### 小节'));
      expect(md, contains('# 第二章'));
      expect(md, isNot(contains('条目 A')));
      expect(md, isNot(contains('开头的话')));
    });

    test('可选把列表项也带上,用缩进体现层级', () {
      final md = outlineToMarkdown(parseOutline(_doc), includeListItems: true);
      expect(md, contains('- 条目 A'));
    });

    test('行尾不留空行', () {
      final md = outlineToMarkdown(parseOutline('# A\n# B\n'));
      expect(md, '# A\n# B');
      expect(md.endsWith('\n'), isFalse);
    });
  });

  group('sectionExcerptFor 悬停预览', () {
    test('取标题到下一个同级标题之前的正文,且不含标题那一行', () {
      final nodes = parseOutline(_doc);
      final heads = headingsInOrder(nodes);
      final jie1 = heads.firstWhere((n) => n.text == '一节');
      final ex = sectionExcerptFor(_doc, nodes, jie1);
      expect(ex, contains('一节的正文。'));
      expect(ex, contains('第二行。'));
      expect(ex, isNot(contains('## 一节'))); // 标题行要去掉
      // ### 小节 层级更深,属于「一节」这一节的内容,所以会带出来
      expect(ex, contains('小节的正文。'));
      // 但到下一个同级标题 ## 二节 就停
      expect(ex, isNot(contains('二节的正文')));
    });

    test('遇到更高级标题也会停(### 小节 被 ## 一节 截住)', () {
      final nodes = parseOutline(_doc);
      final heads = headingsInOrder(nodes);
      final xiao = heads.firstWhere((n) => n.text == '小节');
      final ex = sectionExcerptFor(_doc, nodes, xiao);
      expect(ex, contains('小节的正文。'));
      expect(ex, isNot(contains('二节的正文')));
    });

    test('最后一个标题一直取到文末', () {
      final nodes = parseOutline(_doc);
      final heads = headingsInOrder(nodes);
      final last = heads.firstWhere((n) => n.text == '第二章');
      final ex = sectionExcerptFor(_doc, nodes, last);
      expect(ex, contains('第二章的正文。'));
      expect(ex, contains('条目 A'));
    });

    test('空章节返回空串(调用方据此不显示预览)', () {
      final md = '# 甲\n# 乙\n';
      final nodes = parseOutline(md);
      final ex = sectionExcerptFor(md, nodes, headingsInOrder(nodes).first);
      expect(ex, '');
    });

    test('超长正文被截断并带省略号', () {
      final md = '# 甲\n${'字' * 500}\n';
      final nodes = parseOutline(md);
      final ex =
          sectionExcerptFor(md, nodes, headingsInOrder(nodes).first, maxChars: 50);
      expect(ex.length, 51); // 50 + '…'
      expect(ex.endsWith('…'), isTrue);
    });

    test('列表项没有章节概念,返回空串', () {
      final nodes = parseOutline(_doc);
      final item = flattenNodes(nodes).firstWhere((n) => !n.isHeading);
      expect(sectionExcerptFor(_doc, nodes, item), '');
    });
  });
}
