import 'dart:async';
import 'package:flutter/material.dart';
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
  final FocusNode _contentFocusNode = FocusNode();
  String _loadedContent = '';
  bool _isSaving = false;
  bool _isPreviewing = false;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  Timer? _snapshotDebounce;
  Timer? _saveDebounce;
  bool _isUndoRedo = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController();
    _loadContent();
    _loadViewMode();
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
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 18, color: _textTertiary),
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

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _contentFocusNode.requestFocus(),
            decoration: const InputDecoration(
              hintText: '无标题',
              border: InputBorder.none,
              hintStyle: TextStyle(
                color: _textTertiary,
                fontWeight: FontWeight.w600,
                fontSize: 22,
                height: 1.3,
              ),
            ),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: _textPrimary,
              height: 1.3,
            ),
            cursorColor: _textPrimary,
            onChanged: (_) => _scheduleSave(),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 36,
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
              decoration: const InputDecoration(
                hintText: '开始写点什么...',
                border: InputBorder.none,
                hintStyle: TextStyle(
                  color: _textTertiary,
                  fontSize: 17,
                  height: 1.7,
                ),
              ),
              style: const TextStyle(
                fontSize: 17,
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
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MarkdownBody(
                    data: content.isEmpty ? '暂无内容' : content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      h1: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: _textPrimary,
                        height: 1.5,
                      ),
                      h2: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                        height: 1.5,
                      ),
                      p: const TextStyle(
                        fontSize: 17,
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
    _contentFocusNode.dispose();
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
      body: _isPreviewing
          ? _buildPreview()
          : _buildEditor(),
    );
  }
}
