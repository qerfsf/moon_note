import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'database.dart';

const _textPrimary = Color(0xFF37352F);
const _textTertiary = Color(0xFF9B9A97);
const _borderLight = Color(0xFFEDEDEB);

class NotePage extends StatefulWidget {
  final String noteId;
  final String initialTitle;

  const NotePage({
    super.key,
    required this.noteId,
    required this.initialTitle,
  });

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  final FocusNode _titleFocusNode = FocusNode();
  final FocusNode _contentFocusNode = FocusNode();
  String _loadedContent = '';
  bool _isSaving = false;
  bool _isPreviewing = false;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  Timer? _snapshotDebounce;
  Timer? _saveDebounce;
  bool _isUndoRedo = false;

  // Find/replace state
  bool _showFind = false;
  bool _showReplaceRow = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final FocusNode _findFocusNode = FocusNode();
  List<int> _matchPositions = [];
  int _currentMatchIndex = -1;

  double _fontSize = 17;
  static const double _fontSizeMin = 12;
  static const double _fontSizeMax = 24;
  static const double _fontSizeStep = 1;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController();
    _loadContent();
    _loadViewMode();
    _loadFontSize();
    if (widget.initialTitle == '未命名') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _titleController.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 3,
          );
          _titleFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _loadViewMode() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['last_view_mode'],
    );
    if (result.isNotEmpty) {
      setState(() => _isPreviewing = result.first['value'] == 'preview');
    }
  }

  Future<void> _saveViewMode() async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['last_view_mode', _isPreviewing ? 'preview' : 'edit'],
    );
  }

  Future<void> _loadFontSize() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['font_size'],
    );
    if (result.isNotEmpty) {
      final val = double.tryParse(result.first['value'] as String);
      if (val != null && val >= _fontSizeMin && val <= _fontSizeMax) {
        setState(() => _fontSize = val);
      }
    }
  }

  Future<void> _saveFontSize() async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['font_size', _fontSize.toStringAsFixed(0)],
    );
  }

  void _increaseFont() {
    if (_fontSize >= _fontSizeMax) return;
    setState(() => _fontSize += _fontSizeStep);
    _saveFontSize();
  }

  void _decreaseFont() {
    if (_fontSize <= _fontSizeMin) return;
    setState(() => _fontSize -= _fontSizeStep);
    _saveFontSize();
  }

  Future<void> _loadContent() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'note_content',
      where: 'note_id = ?',
      whereArgs: [widget.noteId],
    );
    if (result.isNotEmpty) {
      final content = result.first['content'] as String;
      _contentController.text = content;
      _loadedContent = content;
    }
    _undoStack.clear();
    _undoStack.add(_contentController.text);
  }

  void _onContentChanged() {
    if (_isUndoRedo) return;
    _scheduleSnapshot();
    _scheduleSave();
  }

  void _scheduleSnapshot() {
    if (_snapshotDebounce == null) {
      _undoStack.add(_contentController.text);
      _redoStack.clear();
    }
    _snapshotDebounce?.cancel();
    _snapshotDebounce = Timer(const Duration(milliseconds: 400), () {
      _pushSnapshot();
    });
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _doSave();
    });
  }

  void _pushSnapshot() {
    final text = _contentController.text;
    if (_undoStack.isNotEmpty && _undoStack.last == text) return;
    _undoStack.add(text);
    _redoStack.clear();
    if (_undoStack.length > 80) _undoStack.removeAt(0);
  }

  void _undo() {
    _snapshotDebounce?.cancel();
    _snapshotDebounce = null;
    // Push current state to undo if it's different from the last snapshot
    final current = _contentController.text;
    if (_undoStack.isEmpty || _undoStack.last != current) {
      _undoStack.add(current);
    }
    if (_undoStack.length < 2) return; // nothing to undo
    _isUndoRedo = true;
    _redoStack.add(_undoStack.removeLast());
    final previous = _undoStack.last;
    _contentController.text = previous;
    _contentController.selection =
        TextSelection.collapsed(offset: previous.length);
    _isUndoRedo = false;
    _doSave();
  }

  void _redo() {
    _snapshotDebounce?.cancel();
    _snapshotDebounce = null;
    if (_redoStack.isEmpty) return;
    _isUndoRedo = true;
    _undoStack.add(_contentController.text);
    final next = _redoStack.removeLast();
    _contentController.text = next;
    _contentController.selection =
        TextSelection.collapsed(offset: next.length);
    _isUndoRedo = false;
    _doSave();
  }

  Future<void> _doSave() async {
    _saveDebounce?.cancel();
    if (_isSaving) return;
    _isSaving = true;
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    String title = _titleController.text.trim();
    if (title.isEmpty) {
      final content = _contentController.text.trim();
      title = content.isEmpty ? '未命名' : content.split('\n').first;
      if (title.length > 50) title = title.substring(0, 50);
    }
    final contentChanged = _contentController.text != _loadedContent;
    await db.update(
      'nodes',
      contentChanged
          ? {'title': title, 'modified_at': now}
          : {'title': title},
      where: 'id = ?',
      whereArgs: [widget.noteId],
    );
    if (contentChanged) {
      await db.update(
        'note_content',
        {'content': _contentController.text, 'modified_at': now},
        where: 'note_id = ?',
        whereArgs: [widget.noteId],
      );
      _loadedContent = _contentController.text;
    }
    await db.rawInsert(
      'INSERT OR REPLACE INTO fts_content(note_id, title, content) VALUES(?, ?, ?)',
      [widget.noteId, title, _contentController.text],
    );
    _isSaving = false;
  }

  Widget _toolbarBtn(IconData icon, String before, String after, {VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap ?? () => _insertMarkdown(before, after),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, size: 20, color: _textTertiary),
          ),
        ),
      ),
    );
  }

  void _insertMarkdown(String before, String after) {
    _undoStack.add(_contentController.text);
    _redoStack.clear();
    final text = _contentController.text;
    final selection = _contentController.selection;

    int start;
    int end;
    if (selection.isValid && selection.start != selection.end) {
      start = selection.start;
      end = selection.end;
    } else {
      start = selection.isValid ? selection.start : text.length;
      end = start;
    }

    final selected = text.substring(start, end);
    final newText =
        text.replaceRange(start, end, '$before$selected$after');
    final cursorPos = start + before.length + selected.length;

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorPos),
    );
    _doSave();
  }

  Future<void> _showLinkPicker() async {
    final db = await DatabaseHelper.instance.database;
    final notes = await db.query(
      'nodes',
      where: 'type = ? AND is_deleted = 0 AND id != ?',
      whereArgs: ['note', widget.noteId],
      orderBy: 'modified_at DESC',
      limit: 100,
    );
    if (!mounted) return;
    final target = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择笔记',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: notes.isEmpty
              ? const Text('没有其他笔记',
                  style: TextStyle(color: _textTertiary, fontSize: 14))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return ListTile(
                      dense: true,
                      title: Text(note['title'] as String,
                          style: const TextStyle(
                              fontSize: 15, color: _textPrimary)),
                      onTap: () => Navigator.pop(context, note),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style:
                    TextStyle(color: _textTertiary, fontSize: 14)),
          ),
        ],
      ),
    );
    if (target == null) return;
    final title = target['title'] as String;
    final targetId = target['id'] as String;
    _insertLink(title, targetId);
  }

  void _insertLink(String title, String targetId) {
    _undoStack.add(_contentController.text);
    _redoStack.clear();
    final text = _contentController.text;
    final sel = _contentController.selection;
    final pos = sel.isValid ? sel.start : text.length;
    final linkText = sel.isValid && sel.start != sel.end
        ? text.substring(sel.start, sel.end)
        : title;
    final link = '[$linkText](moonnote:$targetId)';
    final newText =
        text.replaceRange(pos, sel.isValid ? sel.end : pos, link);
    final cursorPos = pos + link.length;
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorPos),
    );
    _doSave();
  }

  void _copyLink() {
    final title = _titleController.text.trim().isEmpty
        ? '未命名'
        : _titleController.text.trim();
    final link = '[$title](moonnote:${widget.noteId})';
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('链接已复制'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 120,
      ),
    );
  }

  void _openFind() {
    setState(() {
      _showFind = true;
      _showReplaceRow = false;
      _matchPositions = [];
      _currentMatchIndex = -1;
    });
    _findFocusNode.requestFocus();
  }

  void _closeFind() {
    setState(() {
      _showFind = false;
      _matchPositions = [];
      _currentMatchIndex = -1;
    });
    _findController.clear();
    _replaceController.clear();
  }

  void _performFind() {
    final query = _findController.text;
    if (query.isEmpty) {
      setState(() {
        _matchPositions = [];
        _currentMatchIndex = -1;
      });
      return;
    }
    final text = _contentController.text;
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final positions = <int>[];
    int start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx == -1) break;
      positions.add(idx);
      start = idx + lowerQuery.length;
    }
    setState(() {
      _matchPositions = positions;
      _currentMatchIndex = 0;
    });
    if (positions.isNotEmpty) _selectMatch(0);
  }

  void _selectMatch(int index) {
    if (_matchPositions.isEmpty) return;
    final pos = _matchPositions[index];
    final len = _findController.text.length;
    _contentController.selection = TextSelection(
      baseOffset: pos,
      extentOffset: pos + len,
    );
    _contentFocusNode.unfocus();
  }

  void _findNext() {
    if (_matchPositions.isEmpty) return;
    final next = (_currentMatchIndex + 1) % _matchPositions.length;
    setState(() => _currentMatchIndex = next);
    _selectMatch(next);
  }

  void _findPrev() {
    if (_matchPositions.isEmpty) return;
    final prev = (_currentMatchIndex - 1 + _matchPositions.length) %
        _matchPositions.length;
    setState(() => _currentMatchIndex = prev);
    _selectMatch(prev);
  }

  void _replaceOne() {
    if (_matchPositions.isEmpty || _currentMatchIndex < 0) return;
    final query = _findController.text;
    final replacement = _replaceController.text;
    final pos = _matchPositions[_currentMatchIndex];
    final text = _contentController.text;
    final newText =
        text.replaceRange(pos, pos + query.length, replacement);
    _undoStack.add(text);
    _redoStack.clear();
    _contentController.text = newText;
    _doSave();
    _performFind();
  }

  void _replaceAll() {
    if (_matchPositions.isEmpty) return;
    final query = _findController.text;
    final replacement = _replaceController.text;
    final text = _contentController.text;
    _undoStack.add(text);
    _redoStack.clear();
    final buf = StringBuffer();
    int lastEnd = 0;
    for (final pos in _matchPositions) {
      buf.write(text.substring(lastEnd, pos));
      buf.write(replacement);
      lastEnd = pos + query.length;
    }
    buf.write(text.substring(lastEnd));
    _contentController.text = buf.toString();
    _doSave();
    _performFind();
  }

  Widget _buildFindBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _borderLight, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _findController,
                    focusNode: _findFocusNode,
                    onChanged: (_) => _performFind(),
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      isDense: true,
                      hintStyle:
                          TextStyle(fontSize: 14, color: _textTertiary),
                    ),
                    style: const TextStyle(fontSize: 14, color: _textPrimary),
                    cursorColor: _textPrimary,
                  ),
                ),
              ),
              if (_matchPositions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '${_currentMatchIndex + 1}/${_matchPositions.length}',
                    style: const TextStyle(
                        fontSize: 11, color: _textTertiary),
                  ),
                ),
              _findNavBtn(Icons.keyboard_arrow_up, _findPrev),
              _findNavBtn(Icons.keyboard_arrow_down, _findNext),
              SizedBox(
                height: 32,
                width: 32,
                child: IconButton(
                  icon: const Icon(Icons.expand_more,
                      size: 16, color: _textTertiary),
                  padding: EdgeInsets.zero,
                  onPressed: () =>
                      setState(() => _showReplaceRow = !_showReplaceRow),
                ),
              ),
              SizedBox(
                height: 32,
                width: 32,
                child: IconButton(
                  icon: const Icon(Icons.close,
                      size: 16, color: _textTertiary),
                  padding: EdgeInsets.zero,
                  onPressed: _closeFind,
                ),
              ),
            ],
          ),
          if (_showReplaceRow)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        controller: _replaceController,
                        decoration: const InputDecoration(
                          hintText: '替换为',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          isDense: true,
                          hintStyle: TextStyle(
                              fontSize: 14, color: _textTertiary),
                        ),
                        style: const TextStyle(
                            fontSize: 14, color: _textPrimary),
                        cursorColor: _textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _textBtn('替换', _replaceOne,
                      enabled: _matchPositions.isNotEmpty),
                  const SizedBox(width: 4),
                  _textBtn('全部', _replaceAll,
                      enabled: _matchPositions.isNotEmpty),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _findNavBtn(IconData icon, VoidCallback onTap) {
    return SizedBox(
      height: 32,
      width: 28,
      child: IconButton(
        icon: Icon(icon, size: 16, color: _textTertiary),
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }

  Widget _textBtn(String label, VoidCallback onTap, {bool enabled = true}) {
    return SizedBox(
      height: 28,
      child: TextButton(
        onPressed: enabled ? onTap : null,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: enabled ? _textPrimary : _textTertiary,
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            focusNode: _titleFocusNode,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _contentFocusNode.requestFocus(),
            decoration: InputDecoration(
              hintText: '无标题',
              border: InputBorder.none,
              hintStyle: TextStyle(
                color: _textTertiary,
                fontWeight: FontWeight.w600,
                fontSize: _fontSize + 5,
                height: 1.3,
              ),
            ),
            style: TextStyle(
              fontSize: _fontSize + 5,
              fontWeight: FontWeight.w600,
              color: _textPrimary,
              height: 1.3,
            ),
            cursorColor: _textPrimary,
            onChanged: (_) => _scheduleSave(),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _toolbarBtn(Icons.undo, '', '', onTap: _undoStack.length > 1 ? _undo : null),
                _toolbarBtn(Icons.redo, '', '', onTap: _redoStack.isNotEmpty ? _redo : null),
                const SizedBox(width: 8),
                _toolbarBtn(Icons.format_bold, '**', '**'),
                _toolbarBtn(Icons.format_italic, '*', '*'),
                _toolbarBtn(Icons.strikethrough_s, '~~', '~~'),
                const SizedBox(width: 8),
                _toolbarBtn(Icons.title, '# ', ''),
                _toolbarBtn(Icons.format_size, '## ', ''),
                const SizedBox(width: 8),
                _toolbarBtn(Icons.format_list_bulleted, '- ', ''),
                _toolbarBtn(Icons.checklist, '- [ ] ', ''),
                const SizedBox(width: 8),
                _toolbarBtn(Icons.link, '', '', onTap: _showLinkPicker),
                const SizedBox(width: 8),
                _toolbarBtn(Icons.text_decrease, '', '',
                    onTap: _decreaseFont),
                _toolbarBtn(Icons.text_increase, '', '',
                    onTap: _increaseFont),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.5, color: _borderLight),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: _contentController,
              focusNode: _contentFocusNode,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: '开始写点什么...',
                border: InputBorder.none,
                hintStyle: TextStyle(
                  color: _textTertiary,
                  fontSize: _fontSize,
                  height: 1.7,
                ),
              ),
              style: TextStyle(
                fontSize: _fontSize,
                color: _textPrimary,
                height: 1.7,
              ),
              cursorColor: _textPrimary,
              onChanged: (_) => _onContentChanged(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final content = _contentController.text;
    final chars = content.length;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleController.text.trim().isEmpty
                        ? '无标题'
                        : _titleController.text.trim(),
                    style: TextStyle(
                      fontSize: _fontSize + 5,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MarkdownBody(
                    data: content.isEmpty ? '暂无内容' : content,
                    selectable: true,
                    onTapLink: (text, href, title) {
                      if (href == null) return;
                      if (href.startsWith('moonnote:')) {
                        final targetId = href.substring(9);
                        final targetTitle = text;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => NotePage(
                              noteId: targetId,
                              initialTitle: targetTitle,
                            ),
                          ),
                        );
                      }
                    },
                    styleSheet: MarkdownStyleSheet(
                      h1: TextStyle(
                        fontSize: _fontSize + 5,
                        fontWeight: FontWeight.w700,
                        color: _textPrimary,
                        height: 1.5,
                      ),
                      h2: TextStyle(
                        fontSize: _fontSize + 3,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                        height: 1.5,
                      ),
                      p: TextStyle(
                        fontSize: _fontSize,
                        color: _textPrimary,
                        height: 1.7,
                      ),
                      code: TextStyle(
                        fontSize: 15,
                        color: _textPrimary,
                        backgroundColor: Colors.grey.shade100,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      blockquoteDecoration: const BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: _borderLight,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '$chars 字',
                  style: const TextStyle(
                    fontSize: 12,
                    color: _textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _snapshotDebounce?.cancel();
    _saveDebounce?.cancel();
    _doSave();
    _titleController.dispose();
    _contentController.dispose();
    _titleFocusNode.dispose();
    _contentFocusNode.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _findFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: _textPrimary, size: 20),
          onPressed: () async {
            await _doSave();
            await _saveViewMode();
            if (context.mounted) Navigator.pop(context);
          },
        ),
        actions: [
          if (!_isPreviewing)
            IconButton(
              icon: const Icon(Icons.link, color: _textPrimary, size: 20),
              tooltip: '复制链接',
              onPressed: _copyLink,
            ),
          if (!_isPreviewing)
            IconButton(
              icon: const Icon(Icons.search, color: _textPrimary, size: 20),
              tooltip: '查找替换',
              onPressed: _openFind,
            ),
          IconButton(
            icon: Icon(
              _isPreviewing ? Icons.edit_outlined : Icons.visibility_outlined,
              color: _textPrimary,
              size: 20,
            ),
            tooltip: _isPreviewing ? '编辑' : '预览',
            onPressed: () {
              if (!_isPreviewing) _doSave();
              setState(() => _isPreviewing = !_isPreviewing);
              _saveViewMode();
            },
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(0.5),
          child: Divider(height: 0.5, thickness: 0.5, color: _borderLight),
        ),
      ),
      body: Column(
        children: [
          if (_showFind && !_isPreviewing) _buildFindBar(),
          Expanded(
            child:
                _isPreviewing ? _buildPreview() : _buildEditor(),
          ),
        ],
      ),
    );
  }
}
