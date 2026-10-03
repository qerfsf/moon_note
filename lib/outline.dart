import 'package:flutter/material.dart';

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
/// H2 收起,于是看到 H1+H2。列表项的 level 是 100+缩进,恒 >= 任何标题层级,
/// 所以选 H2 时列表也会一并收起,不会被漏掉。
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
  });

  final List<OutlineNode> nodes;
  final void Function(OutlineNode node) onTapNode;
  final VoidCallback? onClose;
  final String title;

  /// 正文里当前所在章节的标题(对应 OutlineNode.lineIndex),用来高亮。
  final int? activeLineIndex;

  /// 当前章节变化时自动展开它的祖先链(Quiet Outline 的 auto expand)。
  final bool autoExpand;

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

  @override
  void initState() {
    super.initState();
    _scheduleRevealActive();
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
  }

  void _toggleNode(int lineIndex) {
    setState(() {
      if (!_collapsed.remove(lineIndex)) _collapsed.add(lineIndex);
    });
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
      ],
    );
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

    return InkWell(
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
