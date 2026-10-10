import 'dart:io';

import 'package:flutter/material.dart';

import 'database.dart';
import 'main.dart' show appTheme, lightScheme, darkScheme, themeNotifier;
import 'note_page.dart';

/// 把一篇笔记「拉」成一个独立窗口。
///
/// 实现方式是再起一个自己的进程: `moon_note.exe --note <id>`。
/// 独立进程的好处是窗口之间完全隔离(互不影响输入/滚动/主题切换),
/// 而且能同时开任意多篇。调用方负责先保存当前编辑内容。
Future<void> openNoteInNewWindow(String noteId) async {
  final exe = Platform.resolvedExecutable;
  await Process.start(
    exe,
    <String>['--note', noteId],
    mode: ProcessStartMode.detached,
    workingDirectory: File(exe).parent.path,
  );
}

/// 独立笔记窗口。
///
/// 桌面端「一个笔记一个窗口」是用**独立进程**实现的(见 main() 里对 `--note`
/// 的处理):每个窗口是一个进程,互不干扰,也能同时开多篇。
///
/// 这个窗口**只负责显示一篇笔记**,不起同步服务、不发通知 —— 那些是主窗口的事。
class NoteWindowApp extends StatelessWidget {
  const NoteWindowApp({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Moon Note',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: appTheme(lightScheme()),
          darkTheme: appTheme(darkScheme()),
          home: _NoteWindowBody(noteId: noteId),
        );
      },
    );
  }
}

class _NoteWindowBody extends StatefulWidget {
  const _NoteWindowBody({required this.noteId});

  final String noteId;

  @override
  State<_NoteWindowBody> createState() => _NoteWindowBodyState();
}

class _NoteWindowBodyState extends State<_NoteWindowBody> {
  String? _title;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'nodes',
      where: 'id = ?',
      whereArgs: [widget.noteId],
      limit: 1,
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      setState(() => _missing = true);
      return;
    }
    setState(() {
      _title = (rows.first['title'] as String?) ?? '未命名';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_missing) {
      return Scaffold(
        backgroundColor: cs.surface,
        body: Center(
          child: Text(
            '这篇笔记已不存在(可能被删除了)',
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    if (_title == null) {
      return Scaffold(
        backgroundColor: cs.surface,
        body: const Center(child: SizedBox.shrink()),
      );
    }
    return NotePage(
      noteId: widget.noteId,
      initialTitle: _title!,
      // 独立窗口:AppBar 左边的返回箭头变成「关闭窗口」
      standalone: true,
    );
  }
}
