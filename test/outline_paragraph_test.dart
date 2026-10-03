import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 段落兜底:整篇没有标题也没有列表项时,把空行分隔的段落当目录条目。
///
/// 针对的是一篇纯散文(比如 7192 字的「竖屏人海」):它既没有 # 也没有 -,
/// 目录按原逻辑是空的、也没有任何可折的东西。

const _prose = '''
今天想聊聊这个功能的设计。

第一段有
两行内容,中间没有空行。

第二段只有一行。

```dart
// 代码块里的空行不该把段落切开

final x = 1;
```

最后一段,
也是两行。
''';

void main() {
  group('parseOutlineAuto 何时启用兜底', () {
    test('有标题时不启用(照常按标题解析)', () {
      final nodes = parseOutlineAuto('# 甲\n正文\n# 乙\n');
      expect(nodes.every((n) => !n.isParagraph), isTrue);
      expect(nodes.map((n) => n.text), ['甲', '乙']);
    });

    test('只有列表项时不启用(列表已经是目录内容了)', () {
      final nodes = parseOutlineAuto('- 一\n- 二\n- 三\n');
      expect(nodes.every((n) => !n.isParagraph), isTrue);
      expect(nodes.length, 3);
    });

    test('纯散文时启用兜底', () {
      final nodes = parseOutlineAuto(_prose);
      expect(nodes, isNotEmpty);
      expect(nodes.every((n) => n.isParagraph), isTrue);
    });

    test('空内容两边都返回空', () {
      expect(parseOutlineAuto(''), isEmpty);
      expect(parseOutlineAuto('\n\n   \n'), isEmpty);
    });
  });

  group('parseParagraphOutline 分段', () {
    test('按空行分段,条目文字取每段第一行', () {
      final nodes = parseParagraphOutline(_prose);
      expect(nodes.map((n) => n.text), [
        '今天想聊聊这个功能的设计。',
        '第一段有',
        '第二段只有一行。',
        '最后一段,',
      ]);
    });

    test('条目是伪标题(这样折叠/摘要机制能复用)', () {
      final nodes = parseParagraphOutline(_prose);
      for (final n in nodes) {
        expect(n.isHeading, isTrue);
        expect(n.isParagraph, isTrue);
        expect(n.level, 1);
      }
    });

    test('代码块整块跳过,内部的空行不切段', () {
      final nodes = parseParagraphOutline(_prose);
      final texts = nodes.map((n) => n.text).join('|');
      expect(texts, isNot(contains('final x')));
      expect(texts, isNot(contains('```')));
      // 代码块前后的段落各自完整
      expect(nodes.length, 4);
    });

    test('偏移能定位到该段开头', () {
      final nodes = parseParagraphOutline(_prose);
      for (final n in nodes) {
        expect(_prose.substring(n.charOffset).startsWith(n.text.substring(0, 4)),
            isTrue,
            reason: '「${n.text}」的偏移对不上');
      }
    });

    test('单行段落没有可折内容;多行段落有', () {
      // 用一份干净的样本:第二段是最后一段且只有一行,它后面没有任何内容
      const small = '第一段\n只有一行\n\n第二段只有一行。\n';
      final nodes = parseParagraphOutline(small);
      final one = nodes.firstWhere((n) => n.text == '第二段只有一行。');
      final many = nodes.firstWhere((n) => n.text == '第一段');
      expect(hasFoldableContent(small, nodes, one), isFalse);
      expect(hasFoldableContent(small, nodes, many), isTrue);
    });

    test('段落后面跟着代码块时算「有内容可折」(代码块属于这一段)', () {
      // _prose 里「第二段只有一行。」后面紧跟代码块,折它会把代码块一起收起来。
      // 这是想要的:否则折起来之后代码块会孤零零留在外面。
      final nodes = parseParagraphOutline(_prose);
      final two = nodes.firstWhere((n) => n.text == '第二段只有一行。');
      expect(hasFoldableContent(_prose, nodes, two), isTrue);
      final r = foldSectionsForPreview(
          _prose, nodes, {outlineIdentities(nodes)[two.lineIndex]!});
      expect(r.text, contains('第二段只有一行。'));
      expect(r.text, isNot(contains('final x'))); // 代码块跟着收起
    });

    test('超长首行被截断到 60 字加省略号', () {
      final md = '${'字' * 200}\n第二行\n\n另一段\n';
      final nodes = parseParagraphOutline(md);
      expect(nodes.first.text.length, 61);
      expect(nodes.first.text.endsWith('…'), isTrue);
    });

    test('行内标记被清掉(目录里不该出现星号反引号)', () {
      final nodes = parseParagraphOutline('**加粗** 和 `代码`\n\n下一段\n');
      expect(nodes.first.text, '加粗 和 代码');
    });

    test('没有空行的整篇算一段', () {
      final nodes = parseParagraphOutline('第一行\n第二行\n第三行\n');
      expect(nodes.length, 1);
      expect(nodes.first.text, '第一行');
    });
  });

  group('段落条目的折叠', () {
    test('折一段 = 只留它的第一行,后面的行都不渲染', () {
      final nodes = parseParagraphOutline(_prose);
      final ids = outlineIdentities(nodes);
      final many = nodes.firstWhere((n) => n.text == '第一段有');
      final folded = {ids[many.lineIndex]!};

      final r = foldSectionsForPreview(_prose, nodes, folded);
      expect(r.text, contains('第一段有')); // 首行还在
      expect(r.text, isNot(contains('两行内容'))); // 正文收起来了
      // 其它段落不受影响
      expect(r.text, contains('第二段只有一行。'));
      expect(r.text, contains('今天想聊聊这个功能的设计。'));
    });

    test('折一个段落不会连带折掉后面的段落', () {
      final nodes = parseParagraphOutline(_prose);
      final ids = outlineIdentities(nodes);
      final first = nodes.first;
      final r = foldSectionsForPreview(_prose, nodes, {ids[first.lineIndex]!});
      expect(r.text, contains('第一段有'));
      expect(r.text, contains('第二段只有一行。'));
      expect(r.text, contains('最后一段,'));
    });

    test('foldable 集合给出的是「有内容可折」的那些标识', () {
      const small = '第一段\n只有一行\n\n第二段只有一行。\n';
      final nodes = parseParagraphOutline(small);
      final r = foldSectionsForPreview(small, nodes, const <String>{});
      final ids = outlineIdentities(nodes);
      final oneLine = nodes.firstWhere((n) => n.text == '第二段只有一行。');
      final twoLine = nodes.firstWhere((n) => n.text == '第一段');
      expect(r.foldable.contains(ids[oneLine.lineIndex]), isFalse);
      expect(r.foldable.contains(ids[twoLine.lineIndex]), isTrue);
    });
  });

  group('段落条目与既有机制相处', () {
    test('复制全部标题时把段落条目排除掉', () {
      final nodes = parseParagraphOutline(_prose);
      final md = outlineToMarkdown(nodes);
      expect(md, isEmpty); // 段落不是标题,不该导出成 # 段落第一行
      expect(md, isNot(contains('#')));
    });

    test('往上一个/下一个标题跳时,段落条目也算条目', () {
      final nodes = parseParagraphOutline(_prose);
      final heads = headingsInOrder(nodes);
      expect(heads.length, nodes.length); // 伪标题所以进列表
      expect(heads.map((n) => n.text).first, '今天想聊聊这个功能的设计。');
    });

    test('过滤之后段落条目仍是段落(不能变成真标题)', () {
      final nodes = parseParagraphOutline(_prose);
      final hits = filterOutline(nodes, '第二段');
      expect(hits.length, 1);
      expect(hits.first.isParagraph, isTrue);
      expect(outlineToMarkdown(hits), isEmpty);
    });
  });
}
