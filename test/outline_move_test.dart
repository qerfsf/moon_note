import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/outline.dart';

/// 拖拽改结构的纯函数测试。
///
/// 这是全项目唯一会**改写用户笔记正文**的功能,所以除了逐例断言,还专门加了
/// 一条不变量测试:任意两个标题、任意方向的搬动,只要返回了结果,正文的行
/// 多重集就必须和原文完全一致 —— 不丢行、不重复行。这比手写几十个用例更能
/// 兜住 off-by-one。

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

List<String> _lines(String s) =>
    s.split('\n').where((l) => l.trim().isNotEmpty).toList()..sort();

OutlineNode _head(List<OutlineNode> nodes, String text) =>
    headingsInOrder(nodes).firstWhere((n) => n.text == text);

final _headingRe = RegExp(r'^#{1,6}\s');

/// 除正文最开头那个标题外,每个标题前面都应该是一个空行 ——
/// 搬动只允许在这一节的两处接缝上补空行,不该把标题挤到别人正文屁股后面。
void expectSectionsSeparated(String md) {
  final lines = md.split('\n');
  var seenContent = false;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trim();
    if (l.isEmpty) continue;
    if (_headingRe.hasMatch(l) && seenContent) {
      expect(i > 0 && lines[i - 1].trim().isEmpty, isTrue,
          reason: '标题「$l」前面没有空行:\n---\n$md\n---');
    }
    seenContent = true;
  }
}

void main() {
  group('sectionRange 求一节的字符范围', () {
    test('到下一个同级或更高级标题为止', () {
      final nodes = parseOutline(_doc);
      final r = sectionRange(_doc, nodes, _head(nodes, '一节'))!;
      final text = _doc.substring(r.start, r.end);
      expect(text.startsWith('## 一节'), isTrue);
      expect(text, contains('一节的正文。'));
      expect(text, contains('### 小节')); // 子章节算在本节内
      expect(text, isNot(contains('## 二节'))); // 到同级标题就停
    });

    test('更高级标题也会截断它', () {
      final nodes = parseOutline(_doc);
      final r = sectionRange(_doc, nodes, _head(nodes, '二节'))!;
      expect(_doc.substring(r.start, r.end), isNot(contains('# 第二章')));
    });

    test('最后一节一直取到文末', () {
      final nodes = parseOutline(_doc);
      final r = sectionRange(_doc, nodes, _head(nodes, '第二章'))!;
      expect(r.end, _doc.length);
      expect(_doc.substring(r.start, r.end), contains('第二章的正文。'));
    });

    test('根标题的范围覆盖到下一个根标题', () {
      final nodes = parseOutline(_doc);
      final r = sectionRange(_doc, nodes, _head(nodes, '第一章'))!;
      final text = _doc.substring(r.start, r.end);
      expect(text, contains('### 小节'));
      expect(text, isNot(contains('# 第二章')));
    });

    test('列表项没有节,返回 null', () {
      final md = '# 甲\n- 条目\n';
      final nodes = parseOutline(md);
      final item = flattenNodes(nodes).firstWhere((n) => !n.isHeading);
      expect(sectionRange(md, nodes, item), isNull);
    });
  });

  group('moveSectionInMarkdown 搬动整节', () {
    test('把第一节搬到第二节后面', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '第一章'),
          _head(nodes, '第二章'), after: true);
      expect(out, isNotNull);
      final texts = headingsInOrder(parseOutline(out!)).map((n) => n.text);
      expect(texts, ['第二章', '第一章', '一节', '小节', '二节']);
      // 子章节和正文都跟着走了
      expect(out, contains('小节的正文。'));
    });

    test('把后面的节搬到第一节前面', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '第二章'),
          _head(nodes, '第一章'));
      expect(out, isNotNull);
      final texts = headingsInOrder(parseOutline(out!)).map((n) => n.text);
      expect(texts, ['第二章', '第一章', '一节', '小节', '二节']);
      expect(out.startsWith('# 第二章'), isTrue);
    });

    test('把中间的子节搬到另一节后面', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '一节'),
          _head(nodes, '二节'), after: true);
      expect(out, isNotNull);
      final texts = headingsInOrder(parseOutline(out!)).map((n) => n.text);
      expect(texts, ['第一章', '二节', '一节', '小节', '第二章']);
    });

    test('搬到自己身上返回 null', () {
      final nodes = parseOutline(_doc);
      final a = _head(nodes, '一节');
      expect(moveSectionInMarkdown(_doc, nodes, a, a), isNull);
      expect(moveSectionInMarkdown(_doc, nodes, a, a, after: true), isNull);
    });

    test('搬进自己的子树返回 null(否则会形成环)', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '第一章'),
          _head(nodes, '小节'), after: true);
      expect(out, isNull);
    });

    test('本来就在那个位置返回 null(不写回内容相同的新文本)', () {
      final nodes = parseOutline(_doc);
      // 第一章 后面紧跟着 一节 所在的节? 不是。用相邻的两个子节来试:
      // 一节 的后面紧跟着 二节 前面的位置 = 一节 的末尾
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '一节'),
          _head(nodes, '一节'), after: true);
      expect(out, isNull);
    });

    test('把第二节搬到第一节前面是「本来就在前面」以外的合法移动', () {
      final nodes = parseOutline(_doc);
      // 二节 本来在一节 后面,搬到一节 前面应该成功
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '二节'),
          _head(nodes, '一节'));
      expect(out, isNotNull);
      final texts = headingsInOrder(parseOutline(out!)).map((n) => n.text);
      expect(texts, ['第一章', '二节', '一节', '小节', '第二章']);
    });

    test('列表项当源或当目标都返回 null', () {
      final md = '# 甲\n- 条目\n# 乙\n';
      final nodes = parseOutline(md);
      final item = flattenNodes(nodes).firstWhere((n) => !n.isHeading);
      expect(
          moveSectionInMarkdown(md, nodes, item, _head(nodes, '乙')), isNull);
      expect(
          moveSectionInMarkdown(md, nodes, _head(nodes, '乙'), item), isNull);
    });

    test('节之间的空行跟着节一起走,不会挤成一坨', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '第一章'),
          _head(nodes, '第二章'), after: true)!;
      expectSectionsSeparated(out);
      expect(out, contains('\n\n# 第一章'));
    });

    test('原文没有收尾换行时插到末尾不会把标题和正文粘成一行', () {
      // 这是真踩到过的坑:曾生成 `乙的正文# 甲`,「甲」直接不再是标题,
      // 从目录里消失。修法是让落点落在整行边界上。
      const md = '# 甲\n甲的正文\n# 乙\n乙的正文';
      final nodes = parseOutline(md);
      final out = moveSectionInMarkdown(
          md, nodes, _head(nodes, '甲'), _head(nodes, '乙'),
          after: true)!;

      expect(out.split('\n').contains('乙的正文# 甲'), isFalse);
      expect(out.split('\n').contains('# 甲'), isTrue);
      final texts = headingsInOrder(parseOutline(out)).map((n) => n.text);
      expect(texts, ['乙', '甲']);
      expect(_lines(out), _lines(md)); // 没丢内容
      expectSectionsSeparated(out);
    });

    test('搬过去再搬回来能回到原文', () {
      final nodes = parseOutline(_doc);
      final a = _head(nodes, '一节');
      final b = _head(nodes, '二节');
      final moved = moveSectionInMarkdown(_doc, nodes, a, b, after: true)!;
      // 在搬动后的结构上,把 一节 搬回 二节 前面
      final n2 = parseOutline(moved);
      final back = moveSectionInMarkdown(
          moved, n2, _head(n2, '一节'), _head(n2, '二节'))!;
      expect(back, _doc);
    });
  });

  group('不变量:搬动不许丢行或重复行', () {
    test('任意两个标题、任意方向,行多重集都和原文一致', () {
      final nodes = parseOutline(_doc);
      final heads = headingsInOrder(nodes);
      final before = _lines(_doc);
      var checked = 0;

      for (final a in heads) {
        for (final b in heads) {
          for (final after in [false, true]) {
            final out = moveSectionInMarkdown(_doc, nodes, a, b, after: after);
            if (out == null) continue;
            checked++;
            expect(_lines(out), before,
                reason: '把「${a.text}」搬到「${b.text}」'
                    '${after ? '后' : '前'}之后行集合变了');
            // 标题数量也不能变
            expect(headingsInOrder(parseOutline(out)).length, heads.length,
                reason: '搬「${a.text}」-> 「${b.text}」后标题数变了');
            // 而且每个标题都还得是标题(没被粘到上一行的屁股后面)
            expectSectionsSeparated(out);
          }
        }
      }
      // 确认这个测试真的跑到了一些合法组合,而不是全被拒了
      expect(checked, greaterThan(5));
    });

    test('搬完之后每个标题的正文都还跟着自己', () {
      final nodes = parseOutline(_doc);
      final out = moveSectionInMarkdown(_doc, nodes, _head(nodes, '一节'),
          _head(nodes, '第二章'), after: true)!;
      // 「一节」的正文和小节必须仍然在它后面
      final idx1 = out.indexOf('## 一节');
      expect(out.indexOf('一节的正文。'), greaterThan(idx1));
      expect(out.indexOf('### 小节'), greaterThan(idx1));
      // 而「二节」的正文不该被卷进「一节」
      expect(out.indexOf('二节的正文。'), greaterThan(out.indexOf('## 二节')));
    });
  });
}
