import 'outline.dart';

/// 编辑态分段:把正文切成「块」,每块一个可编辑区域。
///
/// **核心不变量:全文 = 各块按顺序拼接,块之间既不重叠也不留缝。**
///
/// 为什么要有这个不变量:编辑态折叠只能靠「收起某些块的输入框」来实现
/// (Flutter 的 TextField 没有隐藏文本范围的能力,Obsidian 用的是 CodeMirror)。
/// 只要切块是全文的一个**划分**,折叠就只影响「渲染哪些块」,拼接结果永远不变 ——
/// 也就是说折叠本身**在结构上不可能改坏正文**。
class EditorChunk {
  EditorChunk({
    required this.id,
    required this.start,
    required this.end,
    required this.depth,
    required this.hiddenIfFolded,
    this.node,
  });

  /// 稳定标识:跨重建复用输入框控制器(否则一打字焦点就丢)。
  final String id;

  /// 在全文里的字符范围 [start, end)。
  final int start;
  final int end;

  /// 缩进层级(渲染用)。
  final int depth;

  /// 这些标识对应的条目被折叠时,本块就该隐藏。
  ///
  /// 条目的**头块**(标题行 / 列表项那一行)不含它自己的标识 —— 折它自己要留下
  /// 头;而它下面的正文块和子条目块都含它,所以会跟着收起来。
  final Set<String> hiddenIfFolded;

  /// 非空表示这一块是某个条目的「头」:标题的行,或列表项那一行(含其续行)。
  /// 只有头块能挂折叠三角。
  final OutlineNode? node;

  int get length => end - start;

  bool get isHead => node != null;

  bool visibleWhen(Set<String> folded) =>
      !hiddenIfFolded.any(folded.contains);

  @override
  String toString() =>
      'Chunk($id, $start..$end, depth=$depth, node=${node?.text})';
}

/// 取 [offset] 所在行的结尾(不含换行符)。没有换行就是全文末尾。
int _lineEndAfter(String markdown, int offset) {
  final nl = markdown.indexOf('\n', offset);
  return nl < 0 ? markdown.length : nl;
}

/// 把正文切成编辑用的块。
///
/// 划分规则:
///   - 开头到第一个条目之间是「前言块」;
///   - 每个条目先出一个**头块**:标题只含它那一行(这样折它才能把下面的正文也
///     收起来),列表项含它那一行及其续行(嵌套子列表算它的内容,折它收起来);
///   - 头块之后是它的子条目,子条目之间以及末尾的空隙各成一块(这些属于父条目
///     的正文,折父条目时一并收起)。
List<EditorChunk> buildEditorChunks(
  String markdown,
  List<OutlineNode> nodes,
  Map<int, String> ids,
) {
  final chunks = <EditorChunk>[];
  if (markdown.isEmpty) return chunks;

  final flat = flattenNodes(nodes);
  final order = {for (var i = 0; i < flat.length; i++) flat[i].lineIndex: i};

  /// 某个条目子树在全文里的结束位置 = 文档顺序里它子树之后第一个节点的起点。
  int subtreeEnd(OutlineNode node) {
    final i = order[node.lineIndex];
    if (i == null) return markdown.length;
    final inside = <int>{};
    void collect(OutlineNode n) {
      inside.add(n.lineIndex);
      n.children.forEach(collect);
    }

    collect(node);
    for (var k = i + 1; k < flat.length; k++) {
      if (!inside.contains(flat[k].lineIndex)) return flat[k].charOffset;
    }
    return markdown.length;
  }

  void emit(OutlineNode node, Set<String> ancestorIds) {
    final id = ids[node.lineIndex];
    if (id == null) return;
    final selfId = id;
    final foldSet = {...ancestorIds, selfId};
    final end = subtreeEnd(node).clamp(0, markdown.length);
    final start = node.charOffset.clamp(0, markdown.length);
    if (end <= start) return;

    // 头块:标题只要它那一行;列表项要它那一行 + 续行(到第一个子条目为止)
    final headEnd = node.isHeading
        ? _lineEndAfter(markdown, start)
        : (node.children.isEmpty
            ? end
            : node.children.first.charOffset.clamp(start, end));

    chunks.add(EditorChunk(
      id: '$selfId#h',
      start: start,
      end: headEnd,
      depth: node.isHeading ? 0 : 1,
      // 头块不含自己:折它自己要留下这一行
      hiddenIfFolded: ancestorIds,
      node: node,
    ));

    var cursor = headEnd;
    for (final child in node.children) {
      final childStart = child.charOffset.clamp(cursor, end);
      if (childStart > cursor) {
        chunks.add(EditorChunk(
          id: '$selfId#g$cursor',
          start: cursor,
          end: childStart,
          depth: 0,
          hiddenIfFolded: foldSet,
        ));
      }
      emit(child, foldSet);
      cursor = subtreeEnd(child).clamp(cursor, end);
    }
    if (end > cursor) {
      chunks.add(EditorChunk(
        id: '$selfId#g$cursor',
        start: cursor,
        end: end,
        depth: 0,
        hiddenIfFolded: foldSet,
      ));
    }
  }

  final first = flat.isEmpty ? markdown.length : flat.first.charOffset;
  if (first > 0) {
    chunks.add(EditorChunk(
      id: 'preamble',
      start: 0,
      end: first,
      depth: 0,
      // 前言不属于任何条目,永远可见
      hiddenIfFolded: const <String>{},
    ));
  }
  for (final root in nodes) {
    emit(root, const <String>{});
  }

  chunks.sort((a, b) => a.start.compareTo(b.start));
  return chunks;
}

/// 按顺序拼接各块的文本 —— 必须逐字符等于原文(测试会验这个不变量)。
String joinChunkTexts(List<EditorChunk> chunks, List<String> texts) {
  assert(chunks.length == texts.length, '块数与文本数必须一致');
  final sb = StringBuffer();
  for (var i = 0; i < chunks.length; i++) {
    sb.write(texts[i]);
  }
  return sb.toString();
}

/// 当前折叠状态下要渲染的块。
List<EditorChunk> visibleChunks(List<EditorChunk> chunks, Set<String> folded) =>
    chunks.where((c) => c.visibleWhen(folded)).toList();

/// 折叠后隐藏了多少行、多少个字符(收起时显示「已折叠 N 行」用)。
({int lines, int chars}) hiddenAmount(
  String markdown,
  List<EditorChunk> chunks,
  Set<String> folded,
) {
  var lines = 0;
  var chars = 0;
  for (final c in chunks) {
    if (c.visibleWhen(folded)) continue;
    chars += c.length;
    final text = markdown.substring(c.start, c.end);
    lines += '\n'.allMatches(text).length;
    if (!text.endsWith('\n')) lines += 1;
  }
  return (lines: lines, chars: chars);
}
