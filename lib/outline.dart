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

/// 大纲面板:分级折叠 + 点击导航。电脑端放在右侧,手机端放进底部弹层。
class OutlinePanel extends StatefulWidget {
  const OutlinePanel({
    super.key,
    required this.nodes,
    required this.onTapNode,
    this.onClose,
    this.title = '目录',
  });

  final List<OutlineNode> nodes;
  final void Function(OutlineNode node) onTapNode;
  final VoidCallback? onClose;
  final String title;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  final Set<int> _collapsed = {};

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
    final rows = flattenOutline(widget.nodes, _collapsed);
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
        Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
        Expanded(
          child: widget.nodes.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '这篇笔记还没有目录\n\n用 # 标题或 - 列表来建立结构',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.6),
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
    final fontSize = isHeading
        ? (node.level == 1 ? 13.5 : (node.level == 2 ? 13.0 : 12.5))
        : 12.5;
    final color = isHeading ? cs.onSurface : cs.onSurfaceVariant;

    return InkWell(
      onTap: () => widget.onTapNode(node),
      child: Padding(
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
                  color: cs.primary.withAlpha(110),
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
                  fontWeight: isHeading ? FontWeight.w600 : FontWeight.w400,
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
