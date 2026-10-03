import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// 大纲节点:标题(#/##/###)或列表项(- / * / 1.)。
///
/// [charOffset] 是这一行在正文里的字符偏移 —— 编辑态用它把光标定位过去;
/// [lineIndex] 作为稳定 id,用来记住折叠状态。
class OutlineNode {
  OutlineNode({
    required this.lineIndex,
    required this.charOffset,
    required this.level,
    required this.text,
    required this.isHeading,
  });

  final int lineIndex;
  final int charOffset;

  /// 标题为 1..6(对应 # 的个数);列表项为缩进深度(1 起)。
  final int level;
  final String text;
  final bool isHeading;
  final List<OutlineNode> children = [];

  bool get hasChildren => children.isNotEmpty;
}

/// 去掉行内标记,让大纲显示纯文字(`**粗**` -> `粗`)。
/// 标题和列表项都要用 —— 否则大纲里会出现一堆星号和反引号。
///
/// 注意:Dart 的 replaceAll **不支持** `$1` 反向引用(那是 JS/Java 的写法),
/// 必须用 replaceAllMapped,否则替换结果会原样留下 `$1`。
String _cleanInline(String s) => s
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'~~(.+?)~~'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'`(.+?)`'), (m) => m.group(1)!)
    .trim();

/// 把 Markdown 正文解析成层级大纲。
///
/// 层级规则:
///   - `#`..`######` 按 # 个数分层
///   - 列表项(`-` / `*` / `+` / `1.`)按**缩进**分层(2 空格算一级),
///     并挂在最近的标题下面 —— 于是 `## 章节` 里的列表自然成为它的子节点
///   - **围栏代码块(``` / ~~~)内的内容一律忽略**:代码里的 `# xxx` 是注释,
///     不忽略的话会被误判成标题
List<OutlineNode> parseOutline(String markdown) {
  final roots = <OutlineNode>[];
  final stack = <OutlineNode>[]; // 当前祖先链
  final keys = <int>[]; // 与 stack 一一对应的排序键

  /// 排序键:标题用 level(1..6);列表项用 100+depth,
  /// 恒大于任何标题层级,因此一定挂在最近的标题下,彼此再按缩进分父子。
  void attach(OutlineNode node, int key) {
    while (keys.isNotEmpty && keys.last >= key) {
      stack.removeLast();
      keys.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.children.add(node);
    }
    stack.add(node);
    keys.add(key);
  }

  final headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
  final listRe = RegExp(r'^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$');
  final fenceRe = RegExp(r'^(```|~~~)');
  final lines = markdown.split('\n');

  var offset = 0;
  var inFence = false;
  var fenceMarker = '';

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final left = line.trimLeft();

    final fence = fenceRe.firstMatch(left);
    if (fence != null) {
      final marker = fence.group(1)!;
      if (!inFence) {
        inFence = true;
        fenceMarker = marker;
      } else if (marker == fenceMarker) {
        inFence = false;
        fenceMarker = '';
      }
      offset += line.length + 1;
      continue;
    }

    if (!inFence) {
      final h = headingRe.firstMatch(left);
      if (h != null) {
        var text = h.group(2)!.trim();
        text = text.replaceAll(RegExp(r'\s*#+\s*$'), '').trim(); // 收尾的 ###
        text = _cleanInline(text);
        final level = h.group(1)!.length;
        attach(
          OutlineNode(
            lineIndex: i,
            charOffset: offset,
            level: level,
            text: text.isEmpty ? '(空标题)' : text,
            isHeading: true,
          ),
          level,
        );
        offset += line.length + 1;
        continue;
      }

      final li = listRe.firstMatch(line);
      if (li != null) {
        var text = li.group(2)!.trim();
        text = text.replaceAll(RegExp(r'^\[[ xX]\]\s*'), '').trim(); // 任务框
        text = _cleanInline(text);
        if (text.isNotEmpty) {
          final depth = 1 + li.group(1)!.length ~/ 2;
          attach(
            OutlineNode(
              lineIndex: i,
              charOffset: offset,
              level: depth,
              text: text,
              isHeading: false,
            ),
            100 + depth,
          );
          offset += line.length + 1;
          continue;
        }
      }
    }

    offset += line.length + 1;
  }
  return roots;
}

/// 折叠后真正要显示的一行(深度用于缩进)。
class OutlineRow {
  OutlineRow(this.node, this.depth);
  final OutlineNode node;
  final int depth;
}

List<OutlineRow> flattenOutline(List<OutlineNode> nodes, Set<int> collapsed) {
  final rows = <OutlineRow>[];
  void walk(List<OutlineNode> list, int depth) {
    for (final n in list) {
      rows.add(OutlineRow(n, depth));
      if (n.hasChildren && !collapsed.contains(n.lineIndex)) {
        walk(n.children, depth + 1);
      }
    }
  }

  walk(nodes, 0);
  return rows;
}

/// 计算「只显示到第 [level] 级」需要折叠哪些节点。
///
/// 折叠所有 **层级 >= level 且有子节点** 的节点:
/// level=1 时根标题自身被折叠,于是只剩 H1;level=2 时根保持展开、
/// H2 收起,于是看到 H1+H2。
///
/// 注意列表项的 level 是**缩进深度**(1 起,2 空格算一级),不是 100+深度 ——
/// 后者只是 parseOutline 内部的排序键。所以顶层列表项的 level 就是 1,
/// 与 H1 同级;它之所以在「显示到 H1」时看不见,是因为父标题被折叠了。
Set<int> collapseForLevel(List<OutlineNode> nodes, int level) {
  final out = <int>{};
  void walk(List<OutlineNode> list) {
    for (final n in list) {
      if (n.hasChildren && n.level >= level) out.add(n.lineIndex);
      walk(n.children);
    }
  }

  walk(nodes);
  return out;
}

/// 按关键字过滤大纲:保留文字命中的节点**及其所有祖先**(否则层级会断掉),
/// 其余丢弃。关键字为空时原样返回。
///
/// 返回的是新建的节点副本 —— 直接改原节点的 children 会污染调用方的树。
List<OutlineNode> filterOutline(List<OutlineNode> nodes, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return nodes;

  List<OutlineNode> walk(List<OutlineNode> list) {
    final kept = <OutlineNode>[];
    for (final n in list) {
      final kids = walk(n.children);
      if (n.text.toLowerCase().contains(q) || kids.isNotEmpty) {
        final copy = OutlineNode(
          lineIndex: n.lineIndex,
          charOffset: n.charOffset,
          level: n.level,
          text: n.text,
          isHeading: n.isHeading,
        )..children.addAll(kids);
        kept.add(copy);
      }
    }
    return kept;
  }

  return walk(nodes);
}

/// 按文档顺序把整棵树展平(用于求「下一个标题」「复制全部标题」这类顺序操作)。
List<OutlineNode> flattenNodes(List<OutlineNode> nodes) {
  final out = <OutlineNode>[];
  void walk(List<OutlineNode> list) {
    for (final n in list) {
      out.add(n);
      walk(n.children);
    }
  }

  walk(nodes);
  return out;
}

/// 只取标题,按文档顺序。
List<OutlineNode> headingsInOrder(List<OutlineNode> nodes) =>
    flattenNodes(nodes).where((n) => n.isHeading).toList();

/// 给每个节点算一个**稳定标识**,用来持久化折叠状态。
///
/// 不能用 lineIndex:正文里插删一行,后面所有行号都会漂。也不能只用文字:
/// 同名标题会互相干扰。所以用「类型+层级|文字」,同名的按出现次序加 #2 #3
/// 后缀 —— 在别处插删标题不会打乱其它标题的记忆。
///
/// 标识里带类型前缀(h/l)是必须的:列表项的 level 是缩进深度,顶层列表项
/// 的 level 就是 1,和 H1 相同,不区分类型的话「# 甲」和「- 甲」会撞成同一个。
Map<int, String> outlineIdentities(List<OutlineNode> nodes) {
  final seen = <String, int>{};
  final out = <int, String>{};
  for (final n in flattenNodes(nodes)) {
    final base = '${n.isHeading ? 'h' : 'l'}${n.level}|${n.text}';
    final dup = seen[base] ?? 0;
    seen[base] = dup + 1;
    out[n.lineIndex] = dup == 0 ? base : '$base#$dup';
  }
  return out;
}

/// 把大纲导出成 Markdown 文本(缩进体现层级),用于「复制标题」。
/// [includeListItems] 为 false 时只导出 `#` 标题。
String outlineToMarkdown(List<OutlineNode> nodes,
    {bool includeListItems = false}) {
  final sb = StringBuffer();
  void walk(List<OutlineNode> list, int depth) {
    for (final n in list) {
      if (n.isHeading) {
        sb.writeln('${'#' * n.level} ${n.text}');
      } else if (includeListItems) {
        sb.writeln('${'  ' * depth}- ${n.text}');
      }
      walk(n.children, n.isHeading ? 0 : depth + 1);
    }
  }

  walk(nodes, 0);
  return sb.toString().trimRight();
}

/// 取某个标题所在章节的正文摘要 —— 从它自己到**下一个同级或更高级标题**
/// 之前,去掉标题那一行,超长截断。悬停预览用。
///
/// 列表项没有「章节」概念,返回空串(调用方据此不显示预览)。
String sectionExcerptFor(
  String markdown,
  List<OutlineNode> nodes,
  OutlineNode target, {
  int maxChars = 200,
}) {
  if (!target.isHeading) return '';
  final flat = flattenNodes(nodes);
  final idx = flat.indexWhere((n) => n.lineIndex == target.lineIndex);
  if (idx < 0) return '';

  var end = markdown.length;
  for (var i = idx + 1; i < flat.length; i++) {
    final n = flat[i];
    if (n.isHeading && n.level <= target.level) {
      end = n.charOffset;
      break;
    }
  }
  final start = target.charOffset.clamp(0, markdown.length);
  final stop = end.clamp(start, markdown.length);
  final lines = markdown.substring(start, stop).split('\n');
  // 第一行是标题本身,预览要的是正文
  var body = lines.skip(1).join('\n').trim();
  if (body.length > maxChars) {
    body = '${body.substring(0, maxChars)}…';
  }
  return body;
}

/// 求某个标题「整节」在原文里的字符范围 [start, end)。
///
/// 一节 = 该标题那一行起,到**下一个同级或更高级标题**之前(含中间的空行),
/// 所以搬动一节会把它下面的子标题和正文一起带走。
/// 标题以外的节点(列表项)没有节的概念,返回 null。
({int start, int end})? sectionRange(
  String markdown,
  List<OutlineNode> nodes,
  OutlineNode node,
) {
  if (!node.isHeading) return null;
  final flat = flattenNodes(nodes);
  final idx = flat.indexWhere((n) => n.lineIndex == node.lineIndex);
  if (idx < 0) return null;

  final start = node.charOffset.clamp(0, markdown.length);
  var end = markdown.length;
  for (var i = idx + 1; i < flat.length; i++) {
    final n = flat[i];
    if (n.isHeading && n.level <= node.level) {
      end = n.charOffset.clamp(start, markdown.length);
      break;
    }
  }
  return (start: start, end: end);
}

/// 把 [node] 所在整节搬到 [target] 所在节的**前面或后面**。
///
/// 返回搬完之后的正文;如果这次搬动没有意义就返回 null,调用方据此
/// **什么都不做** —— 而不是写回一份内容相同的新文本(那会平白多一条撤销记录,
/// 也会把光标位置和未保存状态搅乱)。返回 null 的情形:
///   - 拖到自己身上
///   - 落点在自己这一节内部(等于拖进自己的子树,会形成环)
///   - 本来就已经在那个位置
///   - 任一方不是标题(列表项没有节的概念,界不了范围)
///
/// 只做「换位置」,不改标题层级 —— 层级变了会连带改变别的节的归属,
/// 那种改动不适合靠拖一下来完成。
///
/// 搬完会在**这一节的两处接缝**上补齐空行,保证节与节之间空一行。
/// 只碰这两处,文档其余部分原样保留。
String? moveSectionInMarkdown(
  String markdown,
  List<OutlineNode> nodes,
  OutlineNode node,
  OutlineNode target, {
  bool after = false,
}) {
  if (identical(node, target) || node.lineIndex == target.lineIndex) return null;
  final src = sectionRange(markdown, nodes, node);
  final dst = sectionRange(markdown, nodes, target);
  if (src == null || dst == null) return null;

  final ins = after ? dst.end : dst.start;
  // 落点落在自己这一节内(含首尾)= 拖进自己子树或拖回原位,拒绝
  if (ins >= src.start && ins <= src.end) return null;

  final slice = markdown.substring(src.start, src.end);
  final remainder =
      markdown.substring(0, src.start) + markdown.substring(src.end);
  // 从前面搬走会让后面的偏移整体前移,落点要跟着修正
  final at = (ins > src.start ? ins - (src.end - src.start) : ins)
      .clamp(0, remainder.length);

  final before = remainder.substring(0, at);
  final tail = remainder.substring(at);

  // 块只保留内容本身(剥掉尾部空行),前后分隔统一由下面拼接时补 ——
  // 否则每搬一次都会在接缝上多留一个空行,来回拖几次文档就被空行撑肥了。
  final block = slice.replaceFirst(RegExp(r'\n+$'), '');

  // 前半段必须收在整行边界上,否则会把两行粘起来:把一节搬到文末时曾生成
  // `乙的正文# 甲`,「甲」直接不再是标题,从目录里消失。
  var head = before;
  if (head.trim().isNotEmpty) {
    if (!head.endsWith('\n')) head = '$head\n'; // 落在行中间:先断行
    head = head.replaceFirst(RegExp(r'\n+$'), '\n\n'); // 再保证空一行
  }

  final segments = <String>[
    if (head.isNotEmpty) head,
    '$block\n',
    if (tail.isNotEmpty) '\n${tail.replaceFirst(RegExp(r'^\n+'), '')}',
  ];
  var out = segments.join();
  // 原文没有收尾换行就不要凭空添一个
  if (!markdown.endsWith('\n')) out = out.replaceFirst(RegExp(r'\n+$'), '');
  return out;
}

/// 某个节点的祖先链标识(不含自己),按从上到下排列。
Set<String> ancestorIdentities(List<OutlineNode> nodes, OutlineNode node) {
  final ids = outlineIdentities(nodes);
  final path = <int>[];
  bool walk(List<OutlineNode> list, List<int> acc) {
    for (final n in list) {
      if (n.lineIndex == node.lineIndex) {
        path.addAll(acc);
        return true;
      }
      if (walk(n.children, [...acc, n.lineIndex])) return true;
    }
    return false;
  }

  walk(nodes, const []);
  return {
    for (final line in path)
      if (ids[line] != null) ids[line]!,
  };
}

/// 这个标题有没有可折叠的内容(正文或子标题都算)。
///
/// 判据不能只看「有没有子节点」:一个只有正文、没有子标题的标题同样是能折的
/// (Obsidian 里就是如此),只看子节点会让折它变成「点了没反应」。
/// 只有空行的也不算内容。
bool hasFoldableContent(
  String markdown,
  List<OutlineNode> nodes,
  OutlineNode node,
) {
  final r = sectionRange(markdown, nodes, node);
  if (r == null) return false;
  final nl = markdown.indexOf('\n', r.start);
  final bodyStart = nl < 0 ? r.end : nl + 1;
  if (bodyStart >= r.end) return false;
  return markdown.substring(bodyStart, r.end).trim().isNotEmpty;
}

/// 正文按折叠状态切一刀,得到「预览真正要渲染的文本」和「其中还看得见的标题」。
///
/// 只影响渲染,**不改笔记内容**。折叠某个标题 = 把它标题行之后的整节删掉,
/// 包括它下面的子标题 —— 所以被外层折叠包住的内层折叠不必重复切
/// (展开外层时内层仍然是折叠的,因为它的标识还在 foldedIds 里)。
///
/// 返回的 headings 与折叠后文本里标题出现的顺序一一对应,渲染器靠这个顺序
/// 把每个标题认回原来的节点(行号已经变了,不能再用)。foldable 是可以折叠的
/// 那些节点的标识,界面靠它决定要不要画折叠箭头。
({String text, List<OutlineNode> headings, Set<String> foldable})
    foldSectionsForPreview(
  String markdown,
  List<OutlineNode> nodes,
  Set<String> foldedIds,
) {
  final all = headingsInOrder(nodes);
  final ids = outlineIdentities(nodes);
  final anyNode = flattenNodes(nodes);
  final foldable = <String>{
    for (final n in anyNode)
      if (ids[n.lineIndex] != null &&
          hasFoldableContent(markdown, nodes, n))
        ids[n.lineIndex]!,
  };

  if (foldedIds.isEmpty) {
    return (text: markdown, headings: all, foldable: foldable);
  }

  final raw = <({int start, int end})>[];
  for (final n in anyNode) {
    final id = ids[n.lineIndex];
    if (id == null || !foldedIds.contains(id)) continue;
    if (!foldable.contains(id)) continue; // 没内容可折,别白切一刀
    final r = sectionRange(markdown, nodes, n);
    if (r != null) raw.add(r);
  }
  if (raw.isEmpty) return (text: markdown, headings: all, foldable: foldable);
  raw.sort((a, b) => a.start.compareTo(b.start));

  // 被外层范围包住的内层直接丢掉(切一次就够了),并把切点从「标题行开头」
  // 挪到「标题行之后」—— 标题本身要留着。
  final cuts = <({int start, int end})>[];
  for (final r in raw) {
    if (cuts.any((k) => r.start >= k.start && r.end <= k.end)) continue;
    final nl = markdown.indexOf('\n', r.start);
    cuts.add((start: nl < 0 ? r.end : nl + 1, end: r.end));
  }

  final sb = StringBuffer();
  var at = 0;
  for (final c in cuts) {
    if (c.start >= c.end) continue;
    sb.write(markdown.substring(at, c.start));
    at = c.end;
  }
  sb.write(markdown.substring(at));

  final visible = <OutlineNode>[];
  for (final h in all) {
    final cut = cuts.any((c) => h.charOffset >= c.start && h.charOffset < c.end);
    if (!cut) visible.add(h);
  }
  return (text: sb.toString(), headings: visible, foldable: foldable);
}

/// 给预览里的标题挂锚点 + 折叠箭头,让正文自己也能展开收起(参考 Obsidian)。
///
/// 锚点 key 按**可见标题**的顺序分配;行号在折叠后已经变了,所以要靠调用方
/// 传进来的 visibleHeadings 顺序把每个标题认回原节点。
class FoldableHeadingBuilder extends MarkdownElementBuilder {
  FoldableHeadingBuilder({
    required this.keys,
    required this.visibleHeadings,
    required this.isFolded,
    required this.onToggleFold,
    required this.isFoldable,
  });

  /// 渲染时按顺序填进去的锚点 key,跳转要用。
  final List<GlobalKey> keys;

  /// 折叠之后仍然可见的标题,按文档顺序。
  final List<OutlineNode> visibleHeadings;

  final bool Function(OutlineNode node) isFolded;
  final void Function(OutlineNode node) onToggleFold;

  /// 这个标题有没有内容可折(正文也算,见 hasFoldableContent)。
  /// 没有就不画箭头 —— 点了没反应的箭头比没有箭头更让人困惑。
  final bool Function(OutlineNode node) isFoldable;

  int _next = 0;

  /// 已经渲染了几个标题(测试与跳转逻辑用得上)。
  int get rendered => _next;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // 自愈:万一这一帧被重建了第二遍(主题/尺寸变化会重新走一遍 Markdown AST),
    // 计数器已经用到底,就从头开始,否则会认不到节点、箭头全丢。
    if (_next >= visibleHeadings.length) _next = 0;
    final index = _next++;
    final node =
        index < visibleHeadings.length ? visibleHeadings[index] : null;
    while (keys.length <= index) {
      keys.add(GlobalKey());
    }

    return Container(
      key: keys[index],
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (node != null && isFoldable(node))
            InkWell(
              onTap: () => onToggleFold(node),
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.only(right: 2, top: 2),
                child: Icon(
                  isFolded(node)
                      ? Icons.chevron_right
                      : Icons.keyboard_arrow_down,
                  size: 18,
                ),
              ),
            )
          else
            // 没有子节点也占位,保证所有标题文字左缘对齐
            const SizedBox(width: 20),
          Expanded(
            child: Text(element.textContent, style: preferredStyle),
          ),
        ],
      ),
    );
  }
}

/// 章节正文的悬停预览气泡。
///
/// 单独抽成一个具名控件,而不是就地写个 Tooltip:面板上那些 IconButton 的
/// tooltip 属性内部也是 Tooltip,混在一起后按类型根本分不出谁是谁
/// (写测试时踩过这个坑)。
class SectionPreviewTooltip extends StatelessWidget {
  const SectionPreviewTooltip({
    super.key,
    required this.excerpt,
    required this.child,
  });

  final String excerpt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: excerpt,
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant),
      ),
      textStyle: TextStyle(fontSize: 12, color: cs.onSurface, height: 1.5),
      constraints: const BoxConstraints(maxWidth: 320),
      child: child,
    );
  }
}

/// 大纲面板:分级折叠 + 点击导航。电脑端放在右侧,手机端放进底部弹层。
class OutlinePanel extends StatefulWidget {
  const OutlinePanel({
    super.key,
    required this.nodes,
    required this.onTapNode,
    this.onClose,
    this.title = '目录',
    this.activeLineIndex,
    this.autoExpand = true,
    this.sourceText,
    this.foldedIds = const <String>{},
    this.onFoldChanged,
    this.initialLevel,
    this.onLevelChanged,
    this.onMoveNode,
  });

  final List<OutlineNode> nodes;
  final void Function(OutlineNode node) onTapNode;
  final VoidCallback? onClose;
  final String title;

  /// 正文里当前所在章节的标题(对应 OutlineNode.lineIndex),用来高亮。
  final int? activeLineIndex;

  /// 当前章节变化时自动展开它的祖先链(Quiet Outline 的 auto expand)。
  final bool autoExpand;

  /// 正文原文。给了就能在悬停标题时预览该章节内容。
  final String? sourceText;

  /// 已折叠的节(标识集合)。这是**受控属性**:正文折叠和目录折叠共用同一份
  /// 状态,由调用方持有 —— 否则两处各存一份,在正文里折了目录不会跟着变。
  final Set<String> foldedIds;

  /// 用户折叠/展开时回调,调用方负责更新 foldedIds 并持久化。
  final void Function(Set<String> foldedIds)? onFoldChanged;

  /// 上次记住的「显示到第几级」。null = 全部。这只影响目录的显示,
  /// 不写进 foldedIds —— 它是个视图过滤器,不该顺手把正文也折了。
  final int? initialLevel;
  final void Function(int? level)? onLevelChanged;

  /// 在目录里把某一节拖到另一节前/后。给了它才启用拖拽。
  final void Function(OutlineNode node, OutlineNode target, bool after)?
      onMoveNode;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  /// 「只显示到第 N 级」;null 表示不限制。
  int? _levelLimit;

  /// 过滤关键字(大小写不敏感)。
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  /// 附加在当前章节那一行上,用来把它滚进视野。
  final GlobalKey _activeRowKey = GlobalKey();

  /// 每个行一个 key(不限标题),拖拽时要靠它算每行在屏幕上的位置。
  final Map<int, GlobalKey> _rowKeys = {};

  /// 列表区域的 key,用来把插入线换算到列表的局部坐标。
  final GlobalKey _listAreaKey = GlobalKey();

  /// 上一次 build 出来的可见行(拖拽时算落点用)。
  List<OutlineRow> _lastRows = const [];

  /// 正在被拖的节点(非空时显示拖拽相关的界面)。
  OutlineNode? _draggingNode;

  /// 插入线的位置(相对列表区域的 y)。null = 不显示。
  double? _dropLineY;

  /// 松手会落到哪个标题的前/后。null = 没有可落的位置。
  OutlineNode? _dropTarget;
  bool _dropAfter = false;

  /// 落点是否合法(拖进自己子树时为 false,插入线会变红提示)。
  bool _dropLegal = false;

  /// 「复制全部标题」成功后的短暂提示文字。
  String _copyLabel = '';

  Map<int, String> get _ids => outlineIdentities(widget.nodes);

  /// 目录实际要折起来的节 = 用户折的 + 层级过滤挡住的。
  ///
  /// 层级过滤只在这里叠加,不写回 foldedIds —— 否则选一次「显示到 H1」
  /// 会连正文也一起折掉。
  Set<String> get _effectiveFoldedIds {
    final level = _levelLimit;
    if (level == null) return widget.foldedIds;
    return {...widget.foldedIds, ..._idsForLevel(level)};
  }

  /// 当前树下行号形式的折叠集合(渲染用)。
  Set<int> get _collapsedLines {
    final ids = _ids;
    final folded = _effectiveFoldedIds;
    return {
      for (final e in ids.entries)
        if (folded.contains(e.value)) e.key,
    };
  }

  @override
  void initState() {
    super.initState();
    _levelLimit = widget.initialLevel;
    _scheduleRevealActive();
  }

  /// 需要折起来才能「只显示到第 level 级」的那些节点的标识。
  Set<String> _idsForLevel(int level) {
    final ids = _ids;
    return {
      for (final line in collapseForLevel(widget.nodes, level))
        if (ids[line] != null) ids[line]!,
    };
  }

  /// 所有有子节点的节点的标识(「全部折叠」用)。
  Set<String> get _parentIds {
    final ids = _ids;
    final out = <String>{};
    void walk(List<OutlineNode> list) {
      for (final n in list) {
        if (n.hasChildren && ids[n.lineIndex] != null) {
          out.add(ids[n.lineIndex]!);
        }
        walk(n.children);
      }
    }

    walk(widget.nodes);
    return out;
  }

  @override
  void didUpdateWidget(OutlinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeLineIndex != oldWidget.activeLineIndex) {
      final active = widget.activeLineIndex;
      final node = active == null ? null : _currentOutlineOf(active);
      if (node != null && widget.autoExpand) {
        // 当前章节若被折叠在某个收起的父节点里,先把祖先链展开,
        // 否则高亮的那一行根本不可见 —— 这正是 Quiet Outline 的 auto expand。
        final unfold = ancestorIdentities(widget.nodes, node)
            .where(widget.foldedIds.contains)
            .toSet();
        if (unfold.isNotEmpty) {
          final next = {...widget.foldedIds}..removeAll(unfold);
          // 必须延后一帧:didUpdateWidget 是在**父组件 build 期间**跑的,
          // 这时候同步回调父组件的 setState 会撞上
          // 「'!_dirty': is not true」断言(折叠状态改成受控后才踩到)。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onFoldChanged?.call(next);
          });
        }
      }
      _scheduleRevealActive();
    }
  }

  /// 按行号找节点(自动展开时要用)。
  OutlineNode? _currentOutlineOf(int lineIndex) {
    for (final n in flattenNodes(widget.nodes)) {
      if (n.lineIndex == lineIndex) return n;
    }
    return null;
  }

  /// 把当前章节那行滚进视野。要等这一帧布局完成才知道位置。
  void _scheduleRevealActive() {
    if (widget.activeLineIndex == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeRowKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
        alignment: 0.4,
      );
    });
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _toggleAll() {
    final all = _parentIds;
    final folded = widget.foldedIds;
    // 已经全折叠 -> 全部展开;否则全部折叠
    final next = (all.isNotEmpty && folded.length >= all.length)
        ? <String>{}
        : {...all};
    setState(() => _levelLimit = null);
    widget.onLevelChanged?.call(null);
    widget.onFoldChanged?.call(next);
  }

  /// 按层级收起:选 H2 就只剩 H1+H2 展开可见。null 为「全部展开」。
  ///
  /// 只动层级这个视图过滤器,不碰 foldedIds —— 选一次「显示到 H1」不该
  /// 把正文也一起折了。
  void _applyLevel(int? level) {
    setState(() => _levelLimit = level);
    widget.onLevelChanged?.call(level);
  }

  void _toggleNode(int lineIndex) {
    final id = _ids[lineIndex];
    if (id == null) return;
    // 手动折/开就把层级过滤器撤掉:否则「显示到 H1」还压着,
    // 用户点了三角却看不出任何变化,像坏了。
    setState(() => _levelLimit = null);
    widget.onLevelChanged?.call(null);
    final next = {...widget.foldedIds};
    if (!next.remove(id)) next.add(id);
    widget.onFoldChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtering = _filter.trim().isNotEmpty;
    final tree = filtering ? filterOutline(widget.nodes, _filter) : widget.nodes;
    // 折叠集合按标识算出当前树对应的行号 —— 拖动改结构后行号会变,
    // 直接存行号的话记忆会错位到别的标题上。
    final collapsedLines = _collapsedLines;
    // 过滤时强制展开,否则命中的节点可能被折叠状态藏起来,看着像没搜到
    final rows =
        flattenOutline(tree, filtering ? const <int>{} : collapsedLines);
    final hasAnyChild = _collectCount(widget.nodes) > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(
            children: [
              Icon(Icons.list_alt_outlined, size: 16, color: cs.outline),
              const SizedBox(width: 6),
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Text('${rows.length}',
                  style: TextStyle(fontSize: 11, color: cs.outline)),
              const Spacer(),
              if (hasAnyChild)
                IconButton(
                  icon: Icon(Icons.unfold_more, size: 16, color: cs.outline),
                  tooltip: '全部折叠 / 展开',
                  visualDensity: VisualDensity.compact,
                  onPressed: _toggleAll,
                ),
              if (widget.onClose != null)
                IconButton(
                  icon: Icon(Icons.close, size: 16, color: cs.outline),
                  tooltip: '关闭目录',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ),
        // 第二行:层级收起 + 过滤
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: TextField(
                    controller: _filterController,
                    onChanged: (v) => setState(() => _filter = v),
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: cs.surfaceContainerHighest.withAlpha(90),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      hintText: '过滤…',
                      hintStyle: TextStyle(fontSize: 12, color: cs.outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: cs.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: cs.outlineVariant),
                      ),
                      suffixIcon: filtering
                          ? InkWell(
                              onTap: () {
                                _filterController.clear();
                                setState(() => _filter = '');
                              },
                              child: Icon(Icons.close,
                                  size: 14, color: cs.outline),
                            )
                          : null,
                      suffixIconConstraints:
                          const BoxConstraints(minWidth: 24, minHeight: 24),
                    ),
                  ),
                ),
              ),
              if (hasAnyChild) ...[
                const SizedBox(width: 4),
                PopupMenuButton<int>(
                  tooltip: '只显示到第几级',
                  initialValue: _levelLimit ?? 0,
                  // 用 0 当「全部」的哨兵:PopupMenuButton 会把 value=null 视作
                  // 取消菜单,直接不回调 onSelected,那样「全部展开」会点不动。
                  onSelected: (v) => _applyLevel(v == 0 ? null : v),
                  itemBuilder: (ctx) => [
                    for (var i = 1; i <= 6; i++)
                      PopupMenuItem<int>(value: i, child: Text('显示到 H$i')),
                    const PopupMenuItem<int>(value: 0, child: Text('全部展开')),
                  ],
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _levelLimit == null ? '全部' : 'H$_levelLimit',
                          style: TextStyle(fontSize: 11.5, color: cs.onSurface),
                        ),
                        Icon(Icons.arrow_drop_down, size: 14, color: cs.outline),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
        Expanded(
          child: tree.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      filtering
                          ? '没有匹配「$_filter」的条目'
                          : '这篇笔记还没有目录\n\n用 # 标题或 - 列表来建立结构',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 12, color: cs.outline, height: 1.6),
                    ),
                  ),
                )
              : _buildDropArea(cs, rows, collapsedLines),
        ),
        // 底部:上一个/下一个标题 + 复制全部标题
        if (hasAnyChild) ...[
          Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Row(
              children: [
                // 刻意不用 keyboard_arrow_down/up:那是折叠三角的图标,
                // 同一个面板里两套控件用同一个图标,既混淆用户也会让
                // 按图标定位的测试分不清谁是谁。
                _footerBtn(cs, Icons.arrow_upward, '上一个标题', _goPrev),
                _footerBtn(cs, Icons.arrow_downward, '下一个标题', _goNext),
                const Spacer(),
                _copyLabel.isEmpty
                    ? _footerBtn(cs, Icons.copy_all_outlined, '复制全部标题', _copyAll)
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          _copyLabel,
                          style: TextStyle(fontSize: 11, color: cs.primary),
                        ),
                      ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _footerBtn(
    ColorScheme cs,
    IconData icon,
    String tip,
    VoidCallback onTap,
  ) {
    return IconButton(
      icon: Icon(icon, size: 16, color: cs.outline),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 26),
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
  }

  /// 跳到相邻标题。没有当前章节时,「下一个」从第一个标题开始。
  void _goStep(int delta) {
    final heads = headingsInOrder(widget.nodes);
    if (heads.isEmpty) return;
    final curIdx = _activeHeadingIndex(heads);
    var next = curIdx < 0 ? (delta > 0 ? 0 : heads.length - 1) : curIdx + delta;
    if (next < 0) next = heads.length - 1; // 到头了绕回,省得点了没反应
    if (next >= heads.length) next = 0;
    widget.onTapNode(heads[next]);
  }

  int _activeHeadingIndex(List<OutlineNode> heads) {
    if (widget.activeLineIndex == null) return -1;
    return heads.indexWhere((n) => n.lineIndex == widget.activeLineIndex);
  }

  void _goPrev() => _goStep(-1);
  void _goNext() => _goStep(1);

  Future<void> _copyAll() async {
    final text = outlineToMarkdown(widget.nodes);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final n = headingsInOrder(widget.nodes).length;
    setState(() => _copyLabel = '已复制 $n 个标题');
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copyLabel = '');
  }

  int _collectCount(List<OutlineNode> nodes) {
    var n = 0;
    for (final node in nodes) {
      if (node.hasChildren) n += 1 + _collectCount(node.children);
    }
    return n;
  }

  Widget _buildRow(ColorScheme cs, OutlineRow row, Set<int> collapsedLines) {
    final node = row.node;
    final collapsed = collapsedLines.contains(node.lineIndex);
    final isHeading = node.isHeading;
    final isActive = widget.activeLineIndex != null &&
        node.lineIndex == widget.activeLineIndex;
    final fontSize = isHeading
        ? (node.level == 1 ? 13.5 : (node.level == 2 ? 13.0 : 12.5))
        : 12.5;
    final color = isActive
        ? cs.primary
        : (isHeading ? cs.onSurface : cs.onSurfaceVariant);

    final rowWidget = InkWell(
      key: isActive ? _activeRowKey : null,
      onTap: () => widget.onTapNode(node),
      child: Container(
        // 当前章节整行加淡底,让人一眼看到读到哪了
        color: isActive ? cs.primary.withAlpha(26) : null,
        padding: EdgeInsets.only(
          left: 4.0 + row.depth * 12.0,
          right: 8,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          children: [
            // 折叠三角;无子节点时占位,保证文字左缘对齐
            SizedBox(
              width: 18,
              height: 18,
              child: node.hasChildren
                  ? InkWell(
                      onTap: () => _toggleNode(node.lineIndex),
                      child: Icon(
                        collapsed
                            ? Icons.chevron_right
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: cs.outline,
                      ),
                    )
                  : null,
            ),
            // 标题左侧加一道短色条,便于和列表项区分
            if (isHeading)
              Container(
                width: 3,
                height: 12,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: (isActive ? cs.primary : cs.primary.withAlpha(110)),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            Expanded(
              child: Text(
                node.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: isHeading || isActive
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 每行都挂 key:拖拽时靠它量出每行在屏幕上的位置,才能把插入线画准
    final rowKey = _rowKeys.putIfAbsent(node.lineIndex, () => GlobalKey());
    Widget result = KeyedSubtree(key: rowKey, child: rowWidget);

    // 悬停预览该章节正文(Quiet Outline 的 Hover preview)。
    // 列表项没有章节概念,不挂。
    final src = widget.sourceText;
    if (src != null && isHeading) {
      final excerpt = sectionExcerptFor(src, widget.nodes, node);
      if (excerpt.isNotEmpty) {
        result = SectionPreviewTooltip(excerpt: excerpt, child: result);
      }
    }

    // 拖动改结构:只在给了回调和原文、且是标题时启用
    if (widget.onMoveNode != null && src != null && isHeading) {
      result = _wrapDraggable(result, cs, node);
    }
    return result;
  }

  /// 根据指针位置算落点:吸附到**最近的一条缝隙**。
  ///
  /// 缝隙 = 每个可见标题行的上边缘(插到它前面)+ 最后一个可见行的下边缘
  /// (插到末尾)。这就是 Godot 里拖节点时那条插入线的模型 —— 指针不必精确
  /// 压在某一行的上半/下半,线会自己吸到最近的位置,松手必定有结果。
  void _computeDrop(OutlineNode dragged, Offset globalPointer) {
    final rows = _lastRows;
    final heads = headingsInOrder(widget.nodes);
    final src = widget.sourceText;
    if (rows.isEmpty || heads.isEmpty || src == null) return;

    ({double top, double bottom})? rowBox(int lineIndex) {
      final box = _rowKeys[lineIndex]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return null;
      final top = box.localToGlobal(Offset.zero).dy;
      return (top: top, bottom: top + box.size.height);
    }

    final slots = <({double y, int slot})>[];
    for (var i = 0; i < heads.length; i++) {
      final rb = rowBox(heads[i].lineIndex);
      if (rb != null) slots.add((y: rb.top, slot: i));
    }
    final lastBox = rowBox(rows.last.node.lineIndex);
    if (lastBox != null) slots.add((y: lastBox.bottom, slot: heads.length));
    if (slots.isEmpty) return;

    var best = slots.first;
    for (final s in slots) {
      if ((s.y - globalPointer.dy).abs() < (best.y - globalPointer.dy).abs()) {
        best = s;
      }
    }

    final after = best.slot >= heads.length;
    final target = after ? heads.last : heads[best.slot];
    // 落点落在被拖这一节内部 = 拖回原位或拖进自己子树,不合法。
    // 这时线会用警示色画出来 —— 总比松手后什么都没发生要好懂。
    final range = sectionRange(src, widget.nodes, dragged);
    final offset = after ? src.length : target.charOffset;
    final legal =
        range != null && !(offset >= range.start && offset <= range.end);

    final stack = _listAreaKey.currentContext?.findRenderObject();
    final localY = stack is RenderBox && stack.hasSize
        ? stack.globalToLocal(Offset(0, best.y)).dy
        : null;

    if (localY == _dropLineY &&
        target.lineIndex == _dropTarget?.lineIndex &&
        after == _dropAfter &&
        legal == _dropLegal) {
      return; // 位置没变就别 setState,免得拖动时每帧重建整棵树
    }
    setState(() {
      _dropLineY = localY;
      _dropTarget = target;
      _dropAfter = after;
      _dropLegal = legal;
    });
  }

  void _clearDrop() {
    if (_dropLineY == null && _draggingNode == null) return;
    setState(() {
      _dropLineY = null;
      _dropTarget = null;
      _dropLegal = false;
      _draggingNode = null;
    });
  }

  /// 目录列表 + 整个列表范围都是拖放区。
  ///
  /// 为什么要**一整块** DragTarget 而不是每行一个:按行做的话,松手时指针
  /// 稍微偏到行外(行间、列表上下留白、末尾空白)就没有目标接住,拖了半天
  /// 什么都没发生 —— 这正是「拖拽有点问题」的主要来源。
  Widget _buildDropArea(
    ColorScheme cs,
    List<OutlineRow> rows,
    Set<int> collapsedLines,
  ) {
    // 供 _computeDrop 使用:拖拽回调发生在两帧之间,那时拿不到当次的 rows
    _lastRows = rows;

    final canDrag = widget.onMoveNode != null && widget.sourceText != null;
    final list = ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: rows.length,
      itemBuilder: (context, i) => _buildRow(cs, rows[i], collapsedLines),
    );

    if (!canDrag) return list;

    return DragTarget<OutlineNode>(
      onMove: (d) => _computeDrop(d.data, d.offset),
      onLeave: (_) {
        if (_dropLineY != null) setState(() => _dropLineY = null);
      },
      onWillAcceptWithDetails: (d) => d.data.isHeading,
      onAcceptWithDetails: (d) {
        final target = _dropTarget;
        final legal = _dropLegal;
        final after = _dropAfter;
        _clearDrop();
        // 不合法就别调回调 —— 界面上那条警示色的线已经说明了原因
        if (target == null || !legal) return;
        widget.onMoveNode!(d.data, target, after);
      },
      builder: (ctx, candidate, rejected) {
        return Stack(
          key: _listAreaKey,
          children: [
            list,
            // 插入线:Godot 式的一条横线,明确告诉你松手会落到哪
            if (_dropLineY != null)
              Positioned(
                left: 2,
                right: 2,
                top: _dropLineY! < 0 ? 0 : _dropLineY!,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('outline-drop-line'),
                    height: 2,
                    decoration: BoxDecoration(
                      color: _dropLegal ? cs.primary : cs.error,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _wrapDraggable(Widget row, ColorScheme cs, OutlineNode node) {
    return Draggable<OutlineNode>(
      data: node,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => setState(() => _draggingNode = node),
      onDragEnd: (_) => _clearDrop(),
      onDraggableCanceled: (_, __) => _clearDrop(),
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 200),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: cs.primary),
            ),
            child: Text(
              node.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurface),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: row,
      ),
    );
  }
}

/// 手机端入口:底部弹层打开目录,选中后自动关闭并跳转。
Future<void> showOutlineSheet(
  BuildContext context, {
  required List<OutlineNode> nodes,
  required void Function(OutlineNode node) onTapNode,
  double heightFactor = 0.62,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final h = MediaQuery.of(ctx).size.height * heightFactor;
      return SizedBox(
        height: h,
        child: OutlinePanel(
          nodes: nodes,
          onTapNode: (node) {
            Navigator.of(ctx).pop();
            onTapNode(node);
          },
        ),
      );
    },
  );
}
