import 'package:flutter/material.dart';
import 'database.dart';

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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () async {
            await _save();
            if (context.mounted) Navigator.pop(context);
          },
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: Colors.grey[200], height: 1),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                hintText: '标题',
                border: InputBorder.none,
                hintStyle: TextStyle(
                  color: Colors.black26,
                  fontWeight: FontWeight.w600,
                  fontSize: 24,
                ),
              ),
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
              onChanged: (_) => _save(),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: TextField(
                controller: _contentController,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                ),
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.black87,
                  height: 1.7,
                ),
                onChanged: (_) => _save(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}