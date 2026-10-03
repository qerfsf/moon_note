import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.initialCollapsed,
    this.onStateChanged,
    this.initialLevel,
    this.onLevelChanged,
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

  /// 上次记住的折叠状态(见 outlineIdentities)。
  final Set<String>? initialCollapsed;

  /// 折叠状态变化时回调,调用方负责持久化。
  final void Function(Set<String> collapsed)? onStateChanged;

  /// 上次记住的「显示到第几级」。null = 全部。
  final int? initialLevel;
  final void Function(int? level)? onLevelChanged;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  final Set<int> _collapsed = {};

  /// 「只显示到第 N 级」;null 表示不限制。
  int? _levelLimit;

  /// 过滤关键字(大小写不敏感)。
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  /// 附加在当前章节那一行上,用来把它滚进视野。
  final GlobalKey _activeRowKey = GlobalKey();

  /// 「复制全部标题」成功后的短暂提示文字。
  String _copyLabel = '';

  @override
  void initState() {
    super.initState();
    _levelLimit = widget.initialLevel;
    _restoreCollapsed();
    if (_levelLimit != null) {
      _collapsed
        ..clear()
        ..addAll(collapseForLevel(widget.nodes, _levelLimit!));
    }
    _scheduleRevealActive();
  }

  /// 把持久化的稳定标识还原成 lineIndex 集合。
  /// 找不到的标识直接忽略(标题被删或被改名了)。
  void _restoreCollapsed() {
    final saved = widget.initialCollapsed;
    if (saved == null || saved.isEmpty) return;
    final ids = outlineIdentities(widget.nodes);
    for (final entry in ids.entries) {
      if (saved.contains(entry.value)) _collapsed.add(entry.key);
    }
  }

  /// 把当前折叠状态交给调用方持久化。
  void _notifyState() {
    final cb = widget.onStateChanged;
    if (cb == null) return;
    final ids = outlineIdentities(widget.nodes);
    cb({
      for (final line in _collapsed)
        if (ids[line] != null) ids[line]!,
    });
  }

  @override
  void didUpdateWidget(OutlinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeLineIndex != oldWidget.activeLineIndex) {
      if (widget.activeLineIndex != null && widget.autoExpand) {
        // 当前章节若被折叠在某个收起的父节点里,先把祖先链展开,
        // 否则高亮的那一行根本不可见 —— 这正是 Quiet Outline 的 auto expand。
        final anc = _ancestorsOf(widget.activeLineIndex!);
        if (anc.any(_collapsed.contains)) _collapsed.removeAll(anc);
      }
      _scheduleRevealActive();
    }
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

  /// 求某个节点的祖先 lineIndex 链(不含自己)。
  List<int> _ancestorsOf(int lineIndex) {
    final path = <int>[];
    bool walk(List<OutlineNode> nodes, List<int> acc) {
      for (final n in nodes) {
        if (n.lineIndex == lineIndex) {
          path.addAll(acc);
          return true;
        }
        if (walk(n.children, [...acc, n.lineIndex])) return true;
      }
      return false;
    }

    walk(widget.nodes, const []);
    return path;
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _collectParents(List<OutlineNode> nodes, Set<int> into) {
    for (final n in nodes) {
      if (n.hasChildren) {
        into.add(n.lineIndex);
        _collectParents(n.children, into);
      }
    }
  }

  void _toggleAll() {
    final all = <int>{};
    _collectParents(widget.nodes, all);
    setState(() {
      // 已经全折叠 -> 全部展开;否则全部折叠
      if (all.isNotEmpty && _collapsed.length >= all.length) {
        _collapsed.clear();
      } else {
        _collapsed
          ..clear()
          ..addAll(all);
      }
      _levelLimit = null;
    });
    widget.onLevelChanged?.call(null);
    _notifyState();
  }

  /// 按层级收起:选 H2 就只剩 H1+H2 展开可见。null 为「全部展开」。
  void _applyLevel(int? level) {
    setState(() {
      _levelLimit = level;
      _collapsed
        ..clear()
        ..addAll(level == null
            ? const <int>{}
            : collapseForLevel(widget.nodes, level));
    });
    widget.onLevelChanged?.call(level);
    _notifyState();
  }

  void _toggleNode(int lineIndex) {
    setState(() {
      if (!_collapsed.remove(lineIndex)) _collapsed.add(lineIndex);
    });
    _notifyState();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtering = _filter.trim().isNotEmpty;
    final tree = filtering ? filterOutline(widget.nodes, _filter) : widget.nodes;
    // 过滤时强制展开,否则命中的节点可能被折叠状态藏起来,看着像没搜到
    final rows = flattenOutline(tree, filtering ? const <int>{} : _collapsed);
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
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _buildRow(cs, rows[i]),
                ),
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

  Widget _buildRow(ColorScheme cs, OutlineRow row) {
    final node = row.node;
    final collapsed = _collapsed.contains(node.lineIndex);
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

    // 悬停预览该章节正文(Quiet Outline 的 Hover preview)。
    // 列表项没有章节概念,不挂。
    final src = widget.sourceText;
    if (src == null || !isHeading) return rowWidget;
    final excerpt = sectionExcerptFor(src, widget.nodes, node);
    if (excerpt.isEmpty) return rowWidget;

    return SectionPreviewTooltip(excerpt: excerpt, child: rowWidget);
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
