import 'package:flutter/material.dart';
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
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController();
    _loadContent();
  }

  Future<void> _loadContent() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'note_content',
      where: 'note_id = ?',
      whereArgs: [widget.noteId],
    );
    if (result.isNotEmpty) {
      _contentController.text = result.first['content'] as String;
    }
  }

  Future<void> _save() async {
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
    await db.update(
      'nodes',
      {'title': title, 'modified_at': now},
      where: 'id = ?',
      whereArgs: [widget.noteId],
    );
    await db.update(
      'note_content',
      {'content': _contentController.text, 'modified_at': now},
      where: 'note_id = ?',
      whereArgs: [widget.noteId],
    );
    _isSaving = false;
  }

  @override
  void dispose() {
    _save();
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
            await _save();
            if (context.mounted) Navigator.pop(context);
          },
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(0.5),
          child: Divider(height: 0.5, thickness: 0.5, color: _borderLight),
        ),
      ),
      body: Padding(
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
              onChanged: (_) => _save(),
            ),
            const SizedBox(height: 8),
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
                onChanged: (_) => _save(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
