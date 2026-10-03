import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/editor_chunks.dart';
import 'package:moon_note/outline.dart';

/// 编辑态分段的核心不变量:**各块必须是全文的一个精确划分**。
///
/// 只要这个不变量成立,「折叠 = 收起某些块的输入框」就不可能改动正文 ——
/// 拼接永远还原出原文。所以这里花的力气最多。

List<EditorChunk> chunksOf(String md) {
  final nodes = parseOutlineAuto(md);
  return buildEditorChunks(md, nodes, outlineIdentities(nodes));
}

/// 用原文切片拼回去,必须逐字符等于原文。
void expectExactPartition(String md) {
  final chunks = chunksOf(md);
  final texts = [for (final c in chunks) md.substring(c.start, c.end)];
  expect(joinChunkTexts(chunks, texts), md, reason: '拼接结果与原文不一致');
}

const _docs = <String, String>{
  '空': '',
  '只有空白': '\n\n   \n',
  '纯段落': '第一段\n第二行\n\n第二段\n',
  '标准标题': '# 甲\n甲正文\n\n## 乙\n乙正文\n\n# 丙\n丙正文\n',
  '三级嵌套': '# 甲\n甲正文\n\n## 乙\n乙正文\n\n### 丙\n丙正文\n\n## 丁\n丁正文\n',
  '列表': '- 一\n- 二\n  - 二点一\n  - 二点二\n- 三\n',
  '标题加列表': '# 甲\n前言\n- 一\n- 二\n  - 二点一\n\n# 乙\n- 三\n',
  '前言加标题': '开头一段\n\n# 甲\n正文\n',
  '代码块': '# 甲\n```\n# 不是标题\n- 不是列表\n```\n## 乙\n正文\n',
  '中间有正文': '# 甲\n前言\n## 乙\n乙正文\n甲中间的话\n## 丙\n丙正文\n',
  '无收尾换行': '# 甲\n正文\n# 乙\n乙正文',
  '尾部有空行': '# 甲\n正文\n\n\n',
  '只有标题': '# 甲\n# 乙\n',
  '长散文': '第一段\n\n第二段第一行\n第二段第二行\n\n第三段\n',
};

void main() {
  group('不变量:块是全文的精确划分', () {
    for (final entry in _docs.entries) {
      test('${entry.key}:拼接逐字符等于原文', () {
        expectExactPartition(entry.value);
      });

      test('${entry.key}:块之间不重叠、不留缝', () {
        final chunks = chunksOf(entry.value);
        var cursor = 0;
        for (final c in chunks.isEmpty ? <EditorChunk>[] : chunks) {
          expect(c.start, cursor, reason: '${c.id} 的起点应接上一块的终点');
          expect(c.end, greaterThanOrEqualTo(c.start));
          cursor = c.end;
        }
        expect(cursor, entry.value.length, reason: '最后一块应到全文末尾');
      });
    }
  });

  group('切块的形状', () {
    test('标题的头块只含它那一行(否则折它收不起下面的正文)', () {
      const md = '# 甲\n甲正文\n甲正文二\n\n# 乙\n乙正文\n';
      final chunks = chunksOf(md);
      final head = chunks.firstWhere((c) => c.node?.text == '甲');
      expect(md.substring(head.start, head.end), '# 甲');
    });

    test('列表项的头块含它那一行和续行,到第一个子项为止', () {
      const md = '- 父项\n  续行\n  - 子项\n- 第二项\n';
      final chunks = chunksOf(md);
      final head = chunks.firstWhere((c) => c.node?.text == '父项');
      expect(md.substring(head.start, head.end), '- 父项\n  续行\n');
    });

    test('开头到第一个条目之间是前言块', () {
      const md = '开头一段\n\n# 甲\n正文\n';
      final chunks = chunksOf(md);
      expect(chunks.first.id, 'preamble');
      expect(md.substring(chunks.first.start, chunks.first.end), '开头一段\n\n');
    });

    test('没有前言时不出前言块', () {
      expect(chunksOf('# 甲\n正文\n').first.id, isNot('preamble'));
    });

    test('标题自己的正文单独成块(受该标题的折叠控制)', () {
      const md = '# 甲\n甲正文\n## 乙\n乙正文\n';
      final chunks = chunksOf(md);
      final body = chunks.firstWhere(
          (c) => !c.isHead && md.substring(c.start, c.end).contains('甲正文'));
      expect(body.hiddenIfFolded, contains('h1|甲'));
    });

    test('子条目之间的空隙归属父条目的折叠', () {
      const md = '# 甲\n## 乙\n乙正文\n甲中间的话\n## 丙\n丙正文\n';
      final chunks = chunksOf(md);
      final mid = chunks.firstWhere(
          (c) => !c.isHead && md.substring(c.start, c.end).contains('甲中间的话'));
      // 折父条目一定收得起来
      expect(mid.hiddenIfFolded, contains('h1|甲'));
      // 也受「乙」的折叠影响:按 Markdown 的节定义,这段文字在乙这一节里
      // (从乙到下一个同级标题为止),阅读态折叠也是这么切的。
      expect(mid.hiddenIfFolded, contains('h2|乙'));
    });

    test('折叠范围与阅读态一致(两处不能各收各的)', () {
      // 这是关键的一致性约束:同一份折叠状态,编辑态收起来的内容必须和
      // 阅读态(foldSectionsForPreview)收起来的一样,否则用户会看到
      // 「目录里折了、正文里没收」这种矛盾。
      const md = '# 甲\n甲正文\n\n## 乙\n乙正文\n甲中间的话\n\n## 丙\n丙正文\n';
      final nodes = parseOutlineAuto(md);
      final ids = outlineIdentities(nodes);
      final chunks = buildEditorChunks(md, nodes, ids);

      Set<String> linesOf(String text) => text
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .map((l) => l.trim())
          .toSet();

      for (final foldId in ['h1|甲', 'h2|乙', 'h2|丙']) {
        final preview = linesOf(foldSectionsForPreview(md, nodes, {foldId}).text);
        // 可见块之间用换行连接再比:编辑器里每块是独立的输入框、纵向排列,
        // 视觉上本来就分行。直接拼接的话,被隐藏的正文块会把换行也带走,
        // 相邻两个标题行会「粘」成一个字符串 —— 那只是拼接方式的问题,
        // 实际界面不会这样(踩过这个坑,所以这里显式说明)。
        final edit = linesOf([
          for (final c in visibleChunks(chunks, {foldId}))
            md.substring(c.start, c.end)
        ].join('\n'));
        expect(edit, preview, reason: '折 $foldId 时两边可见内容应一致');
      }
    });

    test('块 id 唯一(要拿去当输入框的 key)', () {
      for (final md in _docs.values) {
        final ids = chunksOf(md).map((c) => c.id).toList();
        expect(ids.toSet().length, ids.length, reason: '文档「$md」出现重复块 id');
      }
    });
  });

  group('折叠与可见性', () {
    test('折一个 H1:它的头还在,正文和子标题全不见', () {
      const md = '# 甲\n甲正文\n\n## 乙\n乙正文\n\n# 丙\n丙正文\n';
      final chunks = chunksOf(md);
      final folded = {'h1|甲'};
      final vis = visibleChunks(chunks, folded);
      final texts = [for (final c in vis) md.substring(c.start, c.end)].join();
      expect(texts, contains('# 甲'));
      expect(texts, isNot(contains('甲正文')));
      expect(texts, isNot(contains('乙正文')));
      expect(texts, contains('# 丙'));
      expect(texts, contains('丙正文'));
    });

    test('折一个列表项:它的头还在,嵌套子项不见', () {
      const md = '- 父项\n  - 子项一\n  - 子项二\n- 另一个\n';
      final chunks = chunksOf(md);
      final parent = chunks.firstWhere((c) => c.node?.text == '父项');
      final id = outlineIdentities(parseOutlineAuto(md))[parent.node!.lineIndex]!;
      final vis = visibleChunks(chunks, {id});
      final texts = [for (final c in vis) md.substring(c.start, c.end)].join();
      expect(texts, contains('- 父项'));
      expect(texts, isNot(contains('子项一')));
      expect(texts, contains('- 另一个'));
    });

    test('折起来的块仍然参与拼接(内容不会丢)', () {
      const md = '# 甲\n甲正文\n\n## 乙\n乙正文\n';
      final chunks = chunksOf(md);
      // 就算全部折起来,用**全部**块拼回来仍然是原文
      final folded = {'h1|甲', 'h2|乙'};
      expect(visibleChunks(chunks, folded).length, lessThan(chunks.length));
      final all = [for (final c in chunks) md.substring(c.start, c.end)];
      expect(joinChunkTexts(chunks, all), md);
    });

    test('hiddenAmount 统计折起来藏了多少行', () {
      const md = '# 甲\n甲正文\n甲正文二\n\n# 乙\n乙正文\n';
      final chunks = chunksOf(md);
      final amt = hiddenAmount(md, chunks, {'h1|甲'});
      expect(amt.lines, greaterThanOrEqualTo(2));
      expect(amt.chars, greaterThan(0));
    });

    test('什么都没折时全部可见', () {
      const md = '# 甲\n甲正文\n\n## 乙\n乙正文\n';
      final chunks = chunksOf(md);
      expect(visibleChunks(chunks, const <String>{}).length, chunks.length);
    });
  });
}
