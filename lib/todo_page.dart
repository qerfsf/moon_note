import 'dart:async';
import 'package:flutter/material.dart';
import 'database.dart';
import 'note_page.dart';
import 'sync_service.dart';

class TodoPage extends StatefulWidget {
  final bool embedded;

  const TodoPage({super.key, this.embedded = false});

  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  List<Map<String, dynamic>> _pendingTodos = [];
  List<Map<String, dynamic>> _doneTodos = [];
  final Map<String, String> _noteTitles = {};
  bool _loading = true;

  Color get _textPrimary => Theme.of(context).colorScheme.onSurface;
  Color get _textSecondary => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _textTertiary => Theme.of(context).colorScheme.outline;
  Color get _borderLight => Theme.of(context).colorScheme.outlineVariant;
  Color get _bgHover => Theme.of(context).colorScheme.surfaceContainerHighest;

  bool get _isEmbedded => widget.embedded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DatabaseHelper.instance.database;
    final todos = await db.query('todos', orderBy: 'sort_order ASC');
    final pending = <Map<String, dynamic>>[];
    final done = <Map<String, dynamic>>[];

    final noteIds = <String>{};
    for (final t in todos) {
      if ((t['is_done'] as int) == 1) {
        done.add(t);
      } else {
        pending.add(t);
      }
      noteIds.add(t['note_id'] as String);
    }

    // Load note titles
    if (noteIds.isNotEmpty) {
      final placeholders = noteIds.map((_) => '?').join(',');
      final notes = await db.rawQuery(
        'SELECT id, title FROM nodes WHERE id IN ($placeholders) AND is_deleted = 0',
        noteIds.toList(),
      );
      for (final n in notes) {
        _noteTitles[n['id'] as String] = n['title'] as String;
      }
    }

    if (mounted) {
      setState(() {
        _pendingTodos = pending;
        _doneTodos = done;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(Map<String, dynamic> todo) async {
    await DatabaseHelper.instance.toggleTodo(todo['id'] as String);
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> todo) async {
    await DatabaseHelper.instance.deleteTodo(todo['id'] as String);
    await _load();
  }

  void _openNote(Map<String, dynamic> todo) {
    final noteId = todo['note_id'] as String;
    final title = _noteTitles[noteId] ?? '';
    if (_isEmbedded) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: Icon(Icons.arrow_back,
                    size: 20, color: _textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(title,
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
              backgroundColor: Theme.of(context).colorScheme.surface,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
            ),
            body: NotePage(noteId: noteId, initialTitle: title),
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NotePage(noteId: noteId, initialTitle: title),
        ),
      );
    }
  }

  Widget _buildSection(String title, List<Map<String, dynamic>> items,
      {required bool isDone}) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '$title (${items.length})',
            style: TextStyle(fontSize: 12, color: _textTertiary, fontWeight: FontWeight.w500),
          ),
        ),
        ...items.map((todo) {
          final noteTitle =
              _noteTitles[todo['note_id']] ?? '未知笔记';
          return Dismissible(
            key: Key(todo['id'] as String),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              color: cs.error,
              child: const Icon(Icons.delete_outline,
                  size: 22, color: Colors.white),
            ),
            confirmDismiss: (_) async {
              await _delete(todo);
              return false;
            },
            child: Container(
              decoration: BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: _borderLight, width: 0.5)),
              ),
              child: ListTile(
                leading: GestureDetector(
                  onTap: () => _toggle(todo),
                  child: Icon(
                    isDone ? Icons.check_circle : Icons.circle_outlined,
                    size: 20,
                    color: isDone ? _textPrimary : _borderLight,
                  ),
                ),
                title: Text(
                  todo['title'] as String,
                  style: TextStyle(
                    fontSize: 15,
                    color: isDone ? _textTertiary : _textPrimary,
                    decoration:
                        isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                subtitle: Text(
                  noteTitle,
                  style: TextStyle(fontSize: 12, color: _textTertiary),
                ),
                onTap: () => _openNote(todo),
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isEmpty = _pendingTodos.isEmpty && _doneTodos.isEmpty;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: _isEmbedded
          ? null
          : AppBar(
              backgroundColor: Theme.of(context).colorScheme.surface,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              title: Text('待办事项',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary)),
            ),
      body: isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.checklist_outlined,
                      size: 40, color: _borderLight),
                  const SizedBox(height: 10),
                  Text(
                    '暂无待办事项',
                    style: TextStyle(fontSize: 14, color: _textTertiary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '在笔记中使用 - [ ] 创建待办',
                    style: TextStyle(fontSize: 12, color: _textTertiary),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  _buildSection('待完成', _pendingTodos, isDone: false),
                  _buildSection('已完成', _doneTodos, isDone: true),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}
