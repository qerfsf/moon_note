import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'database.dart';
import 'image_service.dart';

class NotePage extends StatefulWidget {
  final String noteId;
  final String initialTitle;
  final bool embedded;
  final void Function(String newTitle)? onTitleChanged;

  const NotePage({
    super.key,
    required this.noteId,
    required this.initialTitle,
    this.embedded = false,
    this.onTitleChanged,
  });

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Color get _textPrimary => Theme.of(context).colorScheme.onSurface;
  Color get _textTertiary => Theme.of(context).colorScheme.outline;
  Color get _borderLight => Theme.of(context).colorScheme.outlineVariant;

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
  int _lastPreviewHash = 0;
  double _lastPreviewFontSize = 0;
  Widget? _cachedPreview;

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
          _titleFocusNode.requestFocus();
          _titleController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _titleController.text.length,
          );
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

  void _scheduleSave({bool immediateTitle = false}) {
    _saveDebounce?.cancel();
    // Update title in sidebar immediately, debounce DB write
    if (immediateTitle) {
      final t = _titleController.text.trim();
      final title = t.isEmpty ? '未命名' : t;
      widget.onTitleChanged?.call(title);
    }
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
    final updateMap = <String, dynamic>{
      'title': title,
      'modified_at': now,
    };
    if (contentChanged) {
      updateMap['content_modified_at'] = now;
    }
    await db.update(
      'nodes',
      updateMap,
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
    widget.onTitleChanged?.call(title);
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

  PopupMenuItem<String> _popupItem(IconData icon, String label, String value) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 18, color: _textTertiary),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 14, color: _textPrimary)),
        ],
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
      orderBy: 'content_modified_at DESC',
      limit: 100,
    );
    if (!mounted) return;
    final target = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择笔记',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: notes.isEmpty
              ? Text('没有其他笔记',
                  style: TextStyle(color: _textTertiary, fontSize: 14))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return ListTile(
                      dense: true,
                      title: Text(note['title'] as String,
                          style: TextStyle(
                              fontSize: 15, color: _textPrimary)),
                      onTap: () => Navigator.pop(context, note),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
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

  Future<void> _insertImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;

      final imageId = await ImageService.instance.saveImage(
        widget.noteId,
        filePath,
      );

      final filename = result.files.first.name;
      _undoStack.add(_contentController.text);
      _redoStack.clear();
      final text = _contentController.text;
      final sel = _contentController.selection;
      final pos = sel.isValid ? sel.start : text.length;
      final imgMarkdown = '![$filename](moonimage:$imageId)';
      final newText =
          text.replaceRange(pos, sel.isValid ? sel.end : pos, imgMarkdown);
      final cursorPos = pos + imgMarkdown.length;
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursorPos),
      );
      _doSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('插入图片失败: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
      decoration: BoxDecoration(
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
                    decoration: InputDecoration(
                      hintText: '查找',
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      isDense: true,
                      hintStyle:
                          TextStyle(fontSize: 14, color: _textTertiary),
                    ),
                    style: TextStyle(fontSize: 14, color: _textPrimary),
                    cursorColor: _textPrimary,
                  ),
                ),
              ),
              if (_matchPositions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '${_currentMatchIndex + 1}/${_matchPositions.length}',
                    style: TextStyle(
                        fontSize: 11, color: _textTertiary),
                  ),
                ),
              _findNavBtn(Icons.keyboard_arrow_up, _findPrev),
              _findNavBtn(Icons.keyboard_arrow_down, _findNext),
              SizedBox(
                height: 32,
                width: 32,
                child: IconButton(
                  icon: Icon(Icons.expand_more,
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
                  icon: Icon(Icons.close,
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
                        decoration: InputDecoration(
                          hintText: '替换为',
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          isDense: true,
                          hintStyle: TextStyle(
                              fontSize: 14, color: _textTertiary),
                        ),
                        style: TextStyle(
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
    return Column(
      children: [
        Expanded(
          child: Padding(
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
                  onChanged: (_) => _scheduleSave(immediateTitle: true),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Expanded(
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _toolbarBtn(Icons.undo, '', '', onTap: _undoStack.length > 1 ? _undo : null),
                            _toolbarBtn(Icons.redo, '', '', onTap: _redoStack.isNotEmpty ? _redo : null),
                            const SizedBox(width: 8),
                            _toolbarBtn(Icons.format_bold, '**', '**'),
                            _toolbarBtn(Icons.format_italic, '*', '*'),
                            const SizedBox(width: 8),
                            _toolbarBtn(Icons.format_list_bulleted, '- ', ''),
                            const SizedBox(width: 8),
                            _toolbarBtn(Icons.image_outlined, '', '', onTap: _insertImage),
                            _toolbarBtn(Icons.link, '', '', onTap: _showLinkPicker),
                            const SizedBox(width: 8),
                            _toolbarBtn(Icons.text_decrease, '', '',
                                onTap: _decreaseFont),
                            _toolbarBtn(Icons.text_increase, '', '',
                                onTap: _increaseFont),
                            const SizedBox(width: 8),
                            _toolbarBtn(
                              _isPreviewing
                                  ? Icons.edit_outlined
                                  : Icons.visibility_outlined,
                              '', '',
                              onTap: () {
                                if (!_isPreviewing) _doSave();
                                setState(() => _isPreviewing = !_isPreviewing);
                                _saveViewMode();
                              },
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.add_circle_outline, size: 20, color: _textTertiary),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        offset: const Offset(0, 40),
                        color: Theme.of(context).colorScheme.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        onSelected: (v) {
                          switch (v) {
                            case 'h1': _insertMarkdown('# ', ''); break;
                            case 'h2': _insertMarkdown('## ', ''); break;
                            case 'strike': _insertMarkdown('~~', '~~'); break;
                            case 'checklist': _insertMarkdown('- [ ] ', ''); break;
                            case 'search': _openFind(); break;
                            case 'copylink': _copyLink(); break;
                          }
                        },
                        itemBuilder: (ctx) => [
                          _popupItem(Icons.title, '一级标题', 'h1'),
                          _popupItem(Icons.format_size, '二级标题', 'h2'),
                          _popupItem(Icons.strikethrough_s, '删除线', 'strike'),
                          _popupItem(Icons.checklist, '待办清单', 'checklist'),
                          _popupItem(Icons.search, '查找替换', 'search'),
                          if (widget.embedded)
                            _popupItem(Icons.content_copy, '复制链接', 'copylink'),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, thickness: 0.5, color: _borderLight),
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
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _contentController,
                  builder: (context, value, _) => Text(
                    '${value.text.length} 字',
                    style: TextStyle(fontSize: 12, color: _textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final content = _contentController.text;
    final chars = content.length;
    final hash = content.hashCode;
    if (hash == _lastPreviewHash &&
        _fontSize == _lastPreviewFontSize &&
        _cachedPreview != null) {
      return _cachedPreview!;
    }
    _lastPreviewHash = hash;
    _lastPreviewFontSize = _fontSize;
    _cachedPreview = Column(
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
                    imageBuilder: (uri, title, alt) {
                      if (uri.scheme == 'moonimage') {
                        final imageId = uri.path;
                        return FutureBuilder<String?>(
                          future: ImageService.instance.getImagePath(imageId),
                          builder: (context, snapshot) {
                            if (snapshot.hasData && snapshot.data != null) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    File(snapshot.data!),
                                    fit: BoxFit.contain,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Container(
                                        height: 120,
                                        color: _borderLight.withAlpha(80),
                                        child: Center(
                                          child: Icon(Icons.broken_image_outlined,
                                              size: 32, color: _textTertiary),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              );
                            }
                            return Container(
                              height: 80,
                              color: _borderLight.withAlpha(60),
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          },
                        );
                      }
                      // Default: try loading as network image
                      return Image.network(
                        uri.toString(),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 80,
                            color: _borderLight.withAlpha(60),
                            child: Center(
                              child: Icon(Icons.broken_image_outlined,
                                  size: 24, color: _textTertiary),
                            ),
                          );
                        },
                      );
                    },
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
                      blockquoteDecoration: BoxDecoration(
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
                  style: TextStyle(
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
    return _cachedPreview!;
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

  Widget _buildBody() {
    return Column(
      children: [
        if (_showFind && !_isPreviewing) _buildFindBar(),
        Expanded(
          child: IndexedStack(
            index: _isPreviewing ? 1 : 0,
            children: [
              _buildEditor(),
              _buildPreview(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();

    if (widget.embedded) {
      return Material(
        type: MaterialType.transparency,
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          child: body,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _textPrimary, size: 20),
          onPressed: () async {
            await _doSave();
            await _saveViewMode();
            if (context.mounted) Navigator.pop(context);
          },
        ),
        actions: [
          if (!_isPreviewing)
            IconButton(
              icon: Icon(Icons.content_copy, color: _textPrimary, size: 20),
              tooltip: '复制链接',
              onPressed: _copyLink,
            ),
          if (!_isPreviewing)
            IconButton(
              icon: Icon(Icons.search, color: _textPrimary, size: 20),
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, thickness: 0.5, color: _borderLight),
        ),
      ),
      body: _isDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: body,
              ),
            )
          : body,
    );
  }
}
