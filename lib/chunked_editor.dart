import 'package:flutter/material.dart';

import 'editor_chunks.dart';
import 'outline.dart';

/// 编辑态的分块编辑器:每块一个输入框,折叠就是把对应块的输入框收起来。
///
/// 只在笔记**当前有折叠**时启用(没折叠时仍用原来的单个输入框),所以日常
/// 编辑路径完全不变。内容安全由 [buildEditorChunks] 的划分不变量保证:
/// 全文 = 各块按顺序拼接,折叠只决定渲染哪些块。
class ChunkedEditor extends StatefulWidget {
  const ChunkedEditor({
    super.key,
    required this.markdown,
    required this.nodes,
    required this.foldedIds,
    required this.onFoldedChanged,
    required this.onTextChanged,
    required this.textStyle,
    this.onCursorMoved,
    this.hintText = '',
  });

  /// 当前正文(全文)。外部改动(撤销、查找替换、拖拽等)会通过它传进来。
  final String markdown;

  final List<OutlineNode> nodes;

  /// 已折叠的节点标识(与目录、阅读态共用同一份)。
  final Set<String> foldedIds;
  final void Function(Set<String> foldedIds) onFoldedChanged;

  /// 每次编辑后回传拼好的全文。
  final void Function(String fullText) onTextChanged;

  /// 用户把光标放进某一块时,回传**绝对偏移**(块起点 + 块内位置)。
  ///
  /// 工具栏那些「在光标处插入」的功能都读整篇控制器的 selection,不给它回传的话
  /// 插入会跑到全文开头去。
  final void Function(int offset)? onCursorMoved;

  final TextStyle textStyle;
  final String hintText;

  @override
  State<ChunkedEditor> createState() => _ChunkedEditorState();
}

class _ChunkedEditorState extends State<ChunkedEditor> {
  List<EditorChunk> _chunks = const [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};
  Map<int, String> _ids = const {};

  /// 我们上一次交出去的全文。用来区分「外部改动」和「用户在这里打字」。
  String _lastEmitted = '';

  bool get _anyFocused => _focusNodes.values.any((f) => f.hasFocus);

  @override
  void initState() {
    super.initState();
    _lastEmitted = widget.markdown;
    _syncChunks();
  }

  @override
  void didUpdateWidget(ChunkedEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改动了正文(撤销/查找替换/拖拽/阅读态里的折叠…):必须重新切块并把
    // 新内容灌进输入框。
    final external = widget.markdown != _lastEmitted;
    // 用户正在这里打字时**不要重新切块**:结构变了会重建输入框、焦点会丢。
    // 等焦点离开再切(打字过程中大纲和阅读态仍然实时更新,只是分块滞后)。
    if (external || (!_anyFocused && _needsResegment())) {
      _syncChunks();
    }
  }

  bool _needsResegment() {
    if (_chunks.isEmpty) return true;
    final rebuilt = _build();
    if (rebuilt.length != _chunks.length) return true;
    for (var i = 0; i < rebuilt.length; i++) {
      if (rebuilt[i].id != _chunks[i].id ||
          rebuilt[i].start != _chunks[i].start ||
          rebuilt[i].end != _chunks[i].end) {
        return true;
      }
    }
    return false;
  }

  List<EditorChunk> _build() {
    _ids = outlineIdentities(widget.nodes);
    return buildEditorChunks(widget.markdown, widget.nodes, _ids);
  }

  /// 重新切块,并把每块的文本灌进对应输入框。**不调用 setState** ——
  /// 它会在 didUpdateWidget(build 期间)被调用,那里 setState 会撞断言。
  void _syncChunks() {
    final chunks = _build();
    final alive = <String>{};
    for (final c in chunks) {
      alive.add(c.id);
      final text = widget.markdown.substring(c.start, c.end);
      final ctrl = _controllers.putIfAbsent(c.id, () {
        final n = TextEditingController(text: text);
        _focusNodes[c.id] = FocusNode()..addListener(_onFocusChanged);
        // 光标动了就把绝对偏移报出去(工具栏插入要用)
        n.addListener(() {
          final focused = _focusNodes[c.id]?.hasFocus ?? false;
          if (!focused) return;
          final i = _chunks.indexWhere((x) => x.id == c.id);
          if (i < 0) return;
          widget.onCursorMoved
              ?.call(_chunks[i].start + n.selection.baseOffset);
        });
        return n;
      });
      if (ctrl.text != text) {
        // 只在内容真的不同时才写,避免把光标顶回开头
        final sel = ctrl.selection;
        ctrl.text = text;
        if (sel.isValid && sel.end <= text.length) ctrl.selection = sel;
      }
    }
    for (final id in _controllers.keys.toList()) {
      if (alive.contains(id)) continue;
      _controllers.remove(id)!.dispose();
      _focusNodes.remove(id)?.dispose();
    }
    _chunks = chunks;
    _lastEmitted = widget.markdown;
  }

  void _onFocusChanged() {
    // 焦点离开后可以把打字期间欠下的重新切块补上
    if (mounted && !_anyFocused && _needsResegment()) {
      setState(_syncChunks);
    } else if (mounted) {
      setState(() {});
    }
  }

  /// 用户在某一块里打字:拼出全文交出去(全文 = 各块按顺序拼接)。
  void _emit() {
    final texts = [for (final c in _chunks) _controllers[c.id]?.text ?? ''];
    final full = joinChunkTexts(_chunks, texts);
    if (full == _lastEmitted) return;
    _lastEmitted = full;
    widget.onTextChanged(full);
  }

  void _toggleFold(String nodeId) {
    final next = {...widget.foldedIds};
    if (!next.remove(nodeId)) next.add(nodeId);
    widget.onFoldedChanged(next);
  }

  @override
  void dispose() {
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = visibleChunks(_chunks, widget.foldedIds);
    final hidden =
        hiddenAmount(widget.markdown, _chunks, widget.foldedIds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.foldedIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Icon(Icons.unfold_more, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Text(
                  '已折叠 ${hidden.lines} 行',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                ),
              ],
            ),
          ),
        for (final c in visible) _buildChunk(cs, c),
      ],
    );
  }

  Widget _buildChunk(ColorScheme cs, EditorChunk chunk) {
    final node = chunk.node;
    final nodeId = node == null ? null : _ids[node.lineIndex];
    final canFold = nodeId != null && node != null && _canFold(node);

    final field = TextField(
      controller: _controllers[chunk.id],
      focusNode: _focusNodes[chunk.id],
      maxLines: null,
      keyboardType: TextInputType.multiline,
      style: widget.textStyle,
      cursorColor: cs.onSurface,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText:
            chunk.start == 0 && chunk.end == widget.markdown.length
                ? widget.hintText
                : null,
        hintStyle: TextStyle(color: cs.outline, fontSize: widget.textStyle.fontSize),
      ),
      onChanged: (_) => _emit(),
    );

    if (!canFold) {
      // 正文块:左边留出和三角同宽的槽,保证文字左缘对齐
      return Padding(
        padding: const EdgeInsets.only(left: 20),
        child: field,
      );
    }

    final folded = widget.foldedIds.contains(nodeId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 20,
          height: 24,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 20, minHeight: 24),
            iconSize: 16,
            icon: Icon(
              folded ? Icons.chevron_right : Icons.keyboard_arrow_down,
              color: cs.outline,
            ),
            tooltip: folded ? '展开' : '折叠',
            onPressed: () => _toggleFold(nodeId),
          ),
        ),
        Expanded(child: field),
      ],
    );
  }

  /// 折起来有东西可收才给三角:有子条目,或者头块之后还有正文。
  bool _canFold(OutlineNode node) {
    if (node.hasChildren) return true;
    // 标题:头块只有一行,行后还有内容就说明折得动
    final i = _chunks.indexWhere((c) => c.node?.lineIndex == node.lineIndex);
    if (i < 0) return false;
    return _chunks.skip(i + 1).any((c) => c.hiddenIfFolded.contains(
        _ids[node.lineIndex]));
  }
}
