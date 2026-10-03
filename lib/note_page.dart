import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:file_picker/file_picker.dart';
import 'database.dart';
import 'image_service.dart';
import 'outline.dart';
import 'copy_block.dart';

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
  bool _showImages = true;
  int _previewTodoNdx = 0;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  Timer? _snapshotDebounce;
  Timer? _saveDebounce;
  bool _isUndoRedo = false;
  int _contentVersion = 0;
  int _lastPreviewVersion = -1;
  double _lastPreviewFontSize = 0;
  Widget? _cachedPreview;

  // Find/replace state
  bool _showFind = false;
  bool _showReplaceRow = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final FocusNode _findFocusNode = FocusNode();

  // Todo state — parsed from content on save via syncTodosFromMarkdown
  List<int> _matchPositions = [];
  int _currentMatchIndex = -1;

  double _fontSize = 17;
  static const double _fontSizeMin = 12;
  static const double _fontSizeMax = 24;
  static const double _fontSizeStep = 1;

  // ── 目录大纲 ──
  /// 电脑端是否展开右侧目录面板。
  bool _showOutline = false;

  /// 已解析的大纲;内容变化时按版本号重算,避免每帧都解析。
  List<OutlineNode> _outline = const [];
  int _outlineVersion = -1;

  /// 宽屏阈值:宽于它就用右侧固定面板,窄屏(手机)改用底部弹层。
  /// 760 = 面板 220 + 正文约 540,比这更窄就放不下了。
  static const double _outlineWideWidth = 760;
  static const double _outlinePanelWidth = 220;

  /// 笔记页实际分到的宽度。
  ///
  /// 不能用 MediaQuery 的窗口宽度:笔记页也会被嵌进首页的右侧分栏
  /// (home_page 的 embedded:true),那时窗口 1280 但这一栏可能只有五六百,
  /// 按窗口宽度判断会在窄栏里硬塞一个侧栏。
  double _bodyWidth = 0;

  /// 记住的目录状态(Quiet Outline 的 Remember state)。
  /// 折叠状态用稳定标识而不是行号,见 outlineIdentities。
  Set<String> _outlineCollapsed = {};
  int? _outlineLevel;
  bool _outlineStateLoaded = false;

  /// 预览区滚动控制器(跳转要用),以及每个标题的锚点 key。
  final ScrollController _previewScroll = ScrollController();
  List<GlobalKey> _previewHeadingKeys = [];

  /// 正文里当前读到的章节(标题在全文里的序号)。预览态滚动时更新,
  /// 目录据此高亮那一行并自动展开它的祖先链。
  ///
  /// 编辑态不跟随 —— 这正是 Quiet Outline 的「No auto-expand when editing」:
  /// 打字时目录跟着乱跳比不跳更烦人。
  int _activeHeadingOrdinal = -1;

  /// 取当前正文对应的大纲(带缓存)。
  List<OutlineNode> _currentOutline() {
    if (_outlineVersion != _contentVersion) {
      _outline = parseOutline(_contentController.text);
      _outlineVersion = _contentVersion;
    }
    return _outline;
  }

  /// 文档顺序下所有标题在整篇里的序号 —— 预览渲染时按同样顺序生成锚点,
  /// 所以这个序号能对上(围栏代码块内的 # 两边都被忽略,顺序一致)。
  int _headingOrdinalOf(OutlineNode target) {
    var i = 0;
    int? found;
    void walk(List<OutlineNode> nodes) {
      for (final n in nodes) {
        if (found != null) return;
        if (n.isHeading) {
          if (identical(n, target) || n.lineIndex == target.lineIndex) {
            found = i;
            return;
          }
          i++;
        }
        walk(n.children);
      }
    }

    walk(_currentOutline());
    return found ?? -1;
  }

  /// 点击大纲:预览态滚动到对应标题;编辑态把光标移到那一行。
  Future<void> _jumpToOutlineNode(OutlineNode node) async {
    if (_isPreviewing) {
      final ordinal = _headingOrdinalOf(node);
      if (ordinal >= 0 && ordinal < _previewHeadingKeys.length) {
        final ctx = _previewHeadingKeys[ordinal].currentContext;
        if (ctx != null) {
          await Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 220),
            alignment: 0.06,
          );
          return;
        }
      }
      // 锚点还没建好(例如刚切到预览):退回编辑态定位
    }
    final text = _contentController.text;
    final offset = node.charOffset.clamp(0, text.length);
    setState(() {
      _isPreviewing = false;
      _contentController.selection =
          TextSelection.collapsed(offset: offset);
    });
    _saveViewMode();
    _contentFocusNode.requestFocus();
  }

  /// 宽屏(电脑端)才用常驻侧栏。优先用实测到的本页宽度。
  bool _isWideLayout(BuildContext context) {
    final w = _bodyWidth > 0 ? _bodyWidth : MediaQuery.of(context).size.width;
    return w >= _outlineWideWidth;
  }

  Widget _buildOutlinePanel() {
    return Container(
      width: _outlinePanelWidth,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: _borderLight, width: 0.5),
        ),
      ),
      child: OutlinePanel(
        nodes: _currentOutline(),
        onTapNode: _jumpToOutlineNode,
        onClose: () => setState(() => _showOutline = false),
        activeLineIndex: _headingLineIndexByOrdinal(_activeHeadingOrdinal),
        sourceText: _contentController.text,
        initialCollapsed:
            _outlineStateLoaded ? _outlineCollapsed : null,
        onStateChanged: (c) {
          _outlineCollapsed = c;
          _saveOutlineCollapsed(c);
        },
        initialLevel: _outlineLevel,
        onLevelChanged: (lv) {
          _outlineLevel = lv;
          _saveOutlineLevel(lv);
        },
      ),
    );
  }

  /// 目录入口:宽屏切换侧栏,窄屏(手机)弹出底部目录。
  Future<void> _toggleOutline() async {
    if (_isWideLayout(context)) {
      setState(() => _showOutline = !_showOutline);
      _saveOutlineOpen();
      if (_showOutline) _syncActiveHeading();
      return;
    }
    await showOutlineSheet(
      context,
      nodes: _currentOutline(),
      onTapNode: _jumpToOutlineNode,
    );
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController();
    _loadContent();
    _loadViewMode();
    _loadOutlineState();
    _previewScroll.addListener(_onPreviewScroll);
    _loadFontSize();
    _loadImageSetting();
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

  /// 宽屏下目录默认就是常驻的一栏(像 Obsidian 的右侧栏那样),
  /// 而不是每次打开笔记都要点一下;用户关掉后记住选择。
  ///
  /// 同时恢复「显示到第几级」和折叠状态 —— Quiet Outline 的 Remember state。
  /// 折叠状态按**稳定标识**存(见 outlineIdentities),不是行号:
  /// 正文里插删一行会让行号整体漂移,存行号下次就全错位了。
  Future<void> _loadOutlineState() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('app_settings');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String?,
    };
    final savedOpen = map['outline_open'];
    final savedLevel = map['outline_level'];
    final savedCollapsed = map['outline_collapsed_${widget.noteId}'];
    if (!mounted) return;
    setState(() {
      _showOutline = savedOpen == null ? true : savedOpen == '1';
      _outlineLevel = (savedLevel == null || savedLevel == 'all')
          ? null
          : int.tryParse(savedLevel);
      _outlineCollapsed = (savedCollapsed == null || savedCollapsed.isEmpty)
          ? <String>{}
          : savedCollapsed.split('\n').where((s) => s.isNotEmpty).toSet();
      _outlineStateLoaded = true;
    });
  }

  Future<void> _saveOutlineOpen() async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['outline_open', _showOutline ? '1' : '0'],
    );
  }

  Future<void> _saveOutlineLevel(int? level) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['outline_level', level == null ? 'all' : '$level'],
    );
  }

  Future<void> _saveOutlineCollapsed(Set<String> collapsed) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['outline_collapsed_${widget.noteId}', collapsed.join('\n')],
    );
  }

  /// 预览区滚动 -> 判断当前读到哪个标题。
  ///
  /// 用 RenderAbstractViewport.getOffsetToReveal 求「把该标题顶到视口顶部
  /// 所需的目标滚动量」,取最后一个不超过当前滚动量的标题 —— 比逐帧比较
  /// 全局坐标稳,也不受嵌套滚动影响。
  void _onPreviewScroll() {
    if (!_isPreviewing || _previewHeadingKeys.isEmpty) return;
    final scroll = _previewScroll.hasClients ? _previewScroll.offset : 0.0;
    var active = -1;
    for (var i = 0; i < _previewHeadingKeys.length; i++) {
      final ctx = _previewHeadingKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      if (viewport.getOffsetToReveal(box, 0.0).offset <= scroll + 8) {
        active = i;
      } else {
        break; // 标题按文档顺序取出,一旦超过就可以停了
      }
    }
    if (active == _activeHeadingOrdinal) return;
    setState(() => _activeHeadingOrdinal = active);
  }

  /// 由标题序号反查它在大纲里的 lineIndex(用于高亮)。
  int? _headingLineIndexByOrdinal(int ordinal) {
    if (ordinal < 0) return null;
    var i = 0;
    int? found;
    void walk(List<OutlineNode> nodes) {
      for (final n in nodes) {
        if (found != null) return;
        if (n.isHeading) {
          if (i == ordinal) {
            found = n.lineIndex;
            return;
          }
          i++;
        }
        walk(n.children);
      }
    }

    walk(_currentOutline());
    return found;
  }

  /// 切换预览/编辑时同步跟随状态:进预览立刻定位当前章节,退出则清掉高亮。
  void _syncActiveHeading() {
    if (!_isPreviewing) {
      if (_activeHeadingOrdinal != -1) {
        setState(() => _activeHeadingOrdinal = -1);
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onPreviewScroll();
    });
  }

  Future<void> _saveViewMode() async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['last_view_mode', _isPreviewing ? 'preview' : 'edit'],
    );
  }

  Future<void> _loadImageSetting() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['show_images'],
    );
    if (result.isNotEmpty) {
      setState(() => _showImages = result.first['value'] == '1');
    }
  }

  Future<void> _saveImageSetting() async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['show_images', _showImages ? '1' : '0'],
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
    _contentVersion++;
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
    if (_undoStack.length > 30) _undoStack.removeAt(0);
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
    if (contentChanged) {
      await DatabaseHelper.instance.syncTodosFromMarkdown(
          widget.noteId, _contentController.text);
    }
    widget.onTitleChanged?.call(title);
    _isSaving = false;
  }

  void _toggleTodoFromPreviewSimple(int start, int end, bool currentChecked) {
    final content = _contentController.text;
    final matched = content.substring(start, end);
    final toggled = currentChecked
        ? matched.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]')
        : matched.replaceFirst(RegExp(r'\[\s\]'), '[x]');

    final newContent =
        '${content.substring(0, start)}$toggled${content.substring(end)}';

    _contentController.text = newContent;
    setState(() {});
    _onContentChanged();
    _doSave();
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

    String replacement;
    if (before == '- [ ] ' && selected.contains('\n')) {
      // Multi-line todo conversion: split by \n, one todo per non-empty line
      final lines = selected.split('\n');
      final buffer = StringBuffer();
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trimRight();
        if (line.isEmpty && buffer.isEmpty) continue; // skip leading empty lines
        if (buffer.isNotEmpty) buffer.write('\n');
        if (line.isNotEmpty) {
          buffer.write('- [ ] $line');
        }
      }
      replacement = buffer.toString();
    } else {
      replacement = '$before$selected$after';
    }

    final newText = text.replaceRange(start, end, replacement);
    final cursorPos = start + replacement.length;

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorPos),
    );
    _doSave();
  }

  /// 插入一个「可复制块」(```copy 标题 ... ```)。
  /// 光标落在内容行开头,插入后可直接输入;有选中文字时用它当内容。
  void _insertCopyBlock() {
    _undoStack.add(_contentController.text);
    _redoStack.clear();
    final text = _contentController.text;
    final selection = _contentController.selection;

    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid && selection.end > start ? selection.end : start;
    final selected = text.substring(start, end);

    final header = '```$kCopyBlockFence 标题\n';
    final body = selected.isEmpty ? '内容' : selected;
    final replacement = '$header$body\n```\n';

    final newText = text.replaceRange(start, end, replacement);
    final caret = start + kCopyBlockCaretOffset; // 内容行开头

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
    setState(() => _contentVersion++);
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

  Widget _buildToolbar() {
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
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
                  _toolbarBtn(Icons.checklist, '- [ ] ', '', onTap: () => _insertMarkdown('- [ ] ', '')),
                  _toolbarBtn(Icons.link, '', '', onTap: _showLinkPicker),
                  const SizedBox(width: 8),
                  _toolbarBtn(Icons.text_decrease, '', '',
                      onTap: _decreaseFont),
                  _toolbarBtn(Icons.text_increase, '', '',
                      onTap: _increaseFont),
                ],
              ),
            ),
            _toolbarBtn(Icons.image_outlined, '', '', onTap: _insertImage),
            _toolbarBtn(
              _isPreviewing ? Icons.edit_outlined : Icons.visibility_outlined,
              '', '',
              onTap: () {
                if (!_isPreviewing) _doSave();
                setState(() => _isPreviewing = !_isPreviewing);
                _saveViewMode();
                _syncActiveHeading();
              },
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
                  case 'copyblock': _insertCopyBlock(); break;
                  case 'search': _openFind(); break;
                  case 'copylink': _copyLink(); break;
                  case 'export_md': _exportMarkdownWithImages(); break;
                  case 'toggle_images':
                    setState(() => _showImages = !_showImages);
                    _saveImageSetting();
                    _contentVersion++;
                    break;
                }
              },
              itemBuilder: (ctx) => [
                _popupItem(Icons.title, '一级标题', 'h1'),
                _popupItem(Icons.format_size, '二级标题', 'h2'),
                _popupItem(Icons.strikethrough_s, '删除线', 'strike'),
                _popupItem(Icons.checklist, '待办清单', 'checklist'),
                _popupItem(Icons.copy_all_outlined, '可复制块', 'copyblock'),
                _popupItem(Icons.search, '查找替换', 'search'),
                _popupItem(Icons.ios_share, '导出 Markdown(含图片)', 'export_md'),
                const PopupMenuDivider(height: 1),
                _popupItem(
                  _showImages ? Icons.visibility_off_outlined : Icons.image_outlined,
                  _showImages ? '隐藏图片' : '显示图片',
                  'toggle_images',
                ),
                if (widget.embedded)
                  _popupItem(Icons.content_copy, '复制链接', 'copylink'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ));
  }

  bool _looksLikeLocalPath(String p) {
    if (p.isEmpty) return false;
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) || p.startsWith('/');
  }

  /// 紧凑占位(隐藏图片模式 / 图片文件缺失)
  Widget _imageChip(String? alt, bool exists, String? imageId, String? path) {
    final chip = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: _borderLight),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(exists ? Icons.image_outlined : Icons.broken_image_outlined,
              size: 16, color: _textTertiary),
          const SizedBox(width: 6),
          Text(
            (alt != null && alt.isNotEmpty) ? alt : '图片',
            style: TextStyle(fontSize: 13, color: _textTertiary),
          ),
        ],
      ),
    );
    if (path == null) return chip;
    return GestureDetector(
      onTap: () => _showImageMenu(imageId: imageId, path: path),
      child: chip,
    );
  }

  /// 可点击的图片(点击弹出操作菜单);透明区域显示棋盘格底纹,便于看出透明通道
  Widget _tappableImage(
      {String? imageId, required String path, String? alt}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _showImageMenu(imageId: imageId, path: path),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CheckerPainter(
                      cs.surfaceContainerHighest,
                      cs.surface,
                    ),
                  ),
                ),
                Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 80,
                    color: _borderLight.withAlpha(80),
                    child: Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 24, color: _textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 图片操作菜单:格式信息 + 打开文件夹 / 系统程序打开 / 另存为 / 复制路径
  Future<void> _showImageMenu({String? imageId, required String path}) async {
    final cs = Theme.of(context).colorScheme;
    final info = await ImageService.probeImage(path);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, size: 16, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      ImageService.describeImage(info),
                      style: TextStyle(fontSize: 12, color: cs.outline),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
            ListTile(
              dense: true,
              leading: Icon(Icons.folder_open_outlined,
                  size: 20, color: cs.onSurfaceVariant),
              title: Text('打开所在文件夹',
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _revealInFileManager(path);
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.open_in_new,
                  size: 20, color: cs.onSurfaceVariant),
              title: Text('用系统程序打开',
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _openWithSystem(path);
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.save_alt,
                  size: 20, color: cs.onSurfaceVariant),
              title: Text('另存为…',
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _saveImageAs(imageId, path);
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.content_copy,
                  size: 20, color: cs.onSurfaceVariant),
              title: Text('复制文件路径',
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: path));
                _toast('已复制路径');
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run(
            'explorer.exe', ['/select,${path.replaceAll('/', '\\')}']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (e) {
      _toast('打开文件夹失败: $e');
    }
  }

  Future<void> _openWithSystem(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _toast('打开失败: $e');
    }
  }

  Future<void> _saveImageAs(String? imageId, String path) async {
    try {
      final suggested = path.split(Platform.pathSeparator).last;
      final dest = await FilePicker.platform.saveFile(
        dialogTitle: '保存图片',
        fileName: suggested,
      );
      if (dest == null) return;
      if (imageId != null) {
        final ok = await ImageService.instance.copyImageTo(imageId, dest);
        if (!ok) {
          _toast('图片文件不存在');
          return;
        }
      } else {
        await File(path).copy(dest);
      }
      _toast('已保存到 $dest');
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  /// 导出笔记为 Markdown 文件 + images 目录(图片链接改为标准相对路径,
  /// 便于用 Typora / VSCode / Obsidian 等电脑软件直接查看图片)。
  Future<void> _exportMarkdownWithImages() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出文件夹',
      );
      if (dir == null) return;

      final rawTitle = _titleController.text.trim();
      final title = rawTitle.isEmpty ? '未命名' : rawTitle;
      final safeTitle = ImageService.sanitizeFileName(title);
      final outDir = Directory('$dir${Platform.pathSeparator}$safeTitle');
      final imgDir = Directory('${outDir.path}${Platform.pathSeparator}images');
      await imgDir.create(recursive: true);

      var content = _contentController.text;
      final images = await ImageService.instance.getImagesForNote(widget.noteId);
      var copied = 0;
      for (final img in images) {
        final id = img['id'] as String;
        final filename = img['filename'] as String;
        if (!content.contains('moonimage:$id')) continue;
        final src = await ImageService.instance.getImagePath(id);
        if (src != null) {
          await File(src)
              .copy('${imgDir.path}${Platform.pathSeparator}$filename');
          copied++;
        }
        // 应用内引用 -> 标准相对路径
        content = content.replaceAll('moonimage:$id', 'images/$filename');
      }

      final mdPath = '${outDir.path}${Platform.pathSeparator}$safeTitle.md';
      await File(mdPath).writeAsString('# $title\n\n$content\n', flush: true);
      _toast('已导出到 $outDir(含 $copied 张图片)');
    } catch (e) {
      _toast('导出失败: $e');
    }
  }

  Widget _buildEditorBody() {
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
                const SizedBox(height: 12),
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

  Widget _buildEditor() {
    // Legacy wrapper for compatibility
    return _buildEditorBody();
  }

  Widget _buildPreview() {
    final content = _contentController.text;
    final chars = content.length;
    if (_contentVersion == _lastPreviewVersion &&
        _fontSize == _lastPreviewFontSize &&
        _cachedPreview != null) {
      return _cachedPreview!;
    }
    _lastPreviewVersion = _contentVersion;
    _lastPreviewFontSize = _fontSize;
    // 预览重建时一并重建标题锚点(目录跳转要靠它们定位)
    _previewHeadingKeys = [];
    var headingOrdinal = 0;

    // Parse todo items manually (more reliable than MarkdownBody checkboxBuilder)
    final taskRegex = RegExp(r'^[-*]\s*\[([ xX])\]\s+(.+)$', multiLine: true);
    final taskMatches = taskRegex.allMatches(content).toList();
    final hasTodos = taskMatches.isNotEmpty;

    // Build clean content with todo lines replaced (keep structure)
    final cleanContent = content.replaceAll(taskRegex, '');

    final cs = Theme.of(context).colorScheme;
    _cachedPreview = Column(
      children: [
        // Exit preview bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: _borderLight, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.visibility_outlined, size: 16, color: _textTertiary),
              const SizedBox(width: 8),
              Text(
                hasTodos ? '预览模式 | ${taskMatches.length} 待办' : '预览模式',
                style: TextStyle(fontSize: 13, color: _textTertiary),
              ),
              const Spacer(),
              SizedBox(
                height: 30,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _isPreviewing = false);
                    _saveViewMode();
                  },
                  icon: Icon(Icons.edit_outlined, size: 16),
                  label: Text('编辑', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    foregroundColor: _textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(color: _borderLight),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: SingleChildScrollView(
              controller: _previewScroll,
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
                  // ── Custom todo checkboxes ──
                  if (hasTodos) ...[
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: _borderLight),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: List.generate(taskMatches.length, (i) {
                          final m = taskMatches[i];
                          final checked = m.group(1) != ' ';
                          final title = m.group(2)!.trim();
                          return Container(
                            decoration: BoxDecoration(
                              border: i < taskMatches.length - 1
                                  ? Border(bottom: BorderSide(
                                      color: _borderLight, width: 0.5))
                                  : null,
                            ),
                            child: ListTile(
                              dense: true,
                              leading: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    _toggleTodoFromPreviewSimple(
                                        m.start, m.end, checked),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(
                                    checked
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                    size: 24,
                                    color: checked
                                        ? cs.onSurface
                                        : cs.outline,
                                  ),
                                ),
                              ),
                              title: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: checked
                                      ? _textTertiary
                                      : _textPrimary,
                                  decoration: checked
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 0),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  MarkdownBody(
                    data: cleanContent.isEmpty ? '暂无内容' : cleanContent,
                    selectable: true,
                    softLineBreak: true,
                    builders: {
                      // ```copy 围栏渲染成带一键复制的框;其它代码块返回 null 走默认渲染
                      'code': CopyBlockBuilder(),
                      for (final tag in const ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
                        tag: _HeadingAnchorBuilder(
                            _previewHeadingKeys, () => headingOrdinal++),
                    },
                    imageBuilder: (uri, title, alt) {
                      // 1) 应用内图片引用(跨设备同步使用): moonimage:<id>
                      if (uri.scheme == 'moonimage') {
                        final imageId = uri.path;
                        return FutureBuilder<String?>(
                          future: ImageService.instance.getImagePath(imageId),
                          builder: (context, snapshot) {
                            final path = snapshot.data;
                            final exists = path != null;
                            if (!_showImages || !exists) {
                              return _imageChip(alt, exists, imageId, path);
                            }
                            return _tappableImage(
                                imageId: imageId, path: path, alt: alt);
                          },
                        );
                      }
                      // 2) 标准本地路径(file:// 或绝对路径)——方便用其它 Markdown 软件查看
                      final localPath = uri.scheme == 'file'
                          ? uri.toFilePath()
                          : (uri.scheme.isEmpty && _looksLikeLocalPath(uri.path)
                              ? Uri.decodeComponent(uri.path)
                              : null);
                      if (localPath != null) {
                        return _tappableImage(
                            imageId: null, path: localPath, alt: alt);
                      }
                      // 3) 网络图片
                      return Image.network(
                        uri.toString(),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 60,
                            color: _borderLight.withAlpha(60),
                            child: Center(
                              child: Icon(Icons.broken_image_outlined,
                                  size: 20, color: _textTertiary),
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
    _previewScroll.removeListener(_onPreviewScroll);
    _previewScroll.dispose();
    _contentFocusNode.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _findFocusNode.dispose();
    super.dispose();
  }

  Widget _buildBody() {
    final content = Column(
      children: [
        if (_showFind && !_isPreviewing) _buildFindBar(),
        _buildToolbar(),
        Divider(height: 0.5, thickness: 0.5, color: _borderLight),
        Expanded(
          child: IndexedStack(
            index: _isPreviewing ? 1 : 0,
            children: [
              _buildEditorBody(),
              _buildPreview(),
            ],
          ),
        ),
      ],
    );
    // 电脑端:目录常驻右侧;窄屏不占位,改用 AppBar 的目录按钮弹层
    // 电脑端:目录常驻右侧;窄屏不占位,改用 AppBar 的目录按钮弹层。
    // 用 LayoutBuilder 量本页真实宽度,而不是窗口宽度 —— 嵌入分栏时两者不同。
    return LayoutBuilder(
      builder: (context, constraints) {
        _bodyWidth = constraints.maxWidth;
        if (_showOutline && constraints.maxWidth >= _outlineWideWidth) {
          return Row(
            children: [
              Expanded(child: content),
              _buildOutlinePanel(),
            ],
          );
        }
        return content;
      },
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
          IconButton(
            icon: Icon(Icons.list_alt_outlined, color: _textPrimary, size: 20),
            tooltip: '目录',
            onPressed: _toggleOutline,
          ),
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
              _syncActiveHeading();
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

/// 透明区域底纹:棋盘格,用于直观看出图片的透明通道。
class _CheckerPainter extends CustomPainter {
  final Color light;
  final Color dark;
  final double cell;

  const _CheckerPainter(this.light, this.dark, [this.cell = 8]);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        paint.color = ((r + c) % 2 == 0) ? light : dark;
        canvas.drawRect(
          Rect.fromLTWH(c * cell, r * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter oldDelegate) =>
      oldDelegate.light != light ||
      oldDelegate.dark != dark ||
      oldDelegate.cell != cell;
}

/// 给预览里的标题挂锚点,让目录点击时能精确滚动过去。
///
/// flutter_markdown 不暴露标题对应的源码行号,所以按「文档顺序的第 N 个标题」对齐:
/// 解析大纲时用同样顺序数标题,两边就能对上(围栏代码块里的 # 双方都忽略,
/// 顺序不会错位)。样式沿用 preferredStyle,观感和默认渲染一致。
class _HeadingAnchorBuilder extends MarkdownElementBuilder {
  _HeadingAnchorBuilder(this.keys, this.nextOrdinal);

  final List<GlobalKey> keys;
  final int Function() nextOrdinal;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final ordinal = nextOrdinal();
    while (keys.length <= ordinal) {
      keys.add(GlobalKey());
    }
    return Container(
      key: keys[ordinal],
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(element.textContent, style: preferredStyle),
    );
  }
}
