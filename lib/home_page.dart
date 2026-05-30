import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'database.dart';
import 'note_page.dart';
import 'recycle_bin_page.dart';
import 'settings_page.dart';
import 'notification_service.dart';
import 'sync_service.dart';
import 'image_service.dart';

class _NoteSearchDelegate extends SearchDelegate<String> {
  final Map<String, List<Map<String, dynamic>>> _cache = {};
  static const _maxCacheSize = 20;
  static const _debounceMs = 200;

  @override
  String get searchFieldLabel => '搜索笔记...';

  @override
  ThemeData appBarTheme(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: InputBorder.none,
        hintStyle: TextStyle(color: cs.outline, fontSize: 17),
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(
            color: cs.onSurface, fontSize: 17, fontWeight: FontWeight.normal),
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: Icon(Icons.clear,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: Icon(Icons.arrow_back,
            size: 20, color: Theme.of(context).colorScheme.onSurface),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) =>
      _buildSearchResults(context);

  @override
  Widget buildSuggestions(BuildContext context) =>
      _buildSearchResults(context);

  Widget _buildSearchResults(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (query.isEmpty) {
      return Center(
        child: Text('输入关键词搜索笔记',
            style: TextStyle(color: cs.outline, fontSize: 14)),
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _searchWithDebounce(query),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }
        final results = snapshot.data!;
        if (results.isEmpty) {
          return Center(
            child: Text('没有找到相关笔记',
                style: TextStyle(color: cs.outline, fontSize: 14)),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: results.length,
          itemBuilder: (context, index) {
            final item = results[index];
            return InkWell(
              onTap: () => close(context, item['note_id'] as String),
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                      bottom:
                          BorderSide(color: cs.outlineVariant, width: 0.5)),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['title'] as String? ?? '未命名',
                      style: TextStyle(
                        fontSize: 15,
                        color: cs.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (item['content'] != null &&
                        (item['content'] as String).isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item['content'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _searchWithDebounce(String keyword) async {
    await Future.delayed(const Duration(milliseconds: _debounceMs));
    if (keyword != query) return [];
    if (_cache.containsKey(keyword)) return _cache[keyword]!;

    final results = await _search(keyword);
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[keyword] = results;
    return results;
  }

  Future<List<Map<String, dynamic>>> _search(String keyword) async {
    final db = await DatabaseHelper.instance.database;
    final like = '%$keyword%';
    return await db.rawQuery('''
      SELECT DISTINCT f.note_id, f.title,
        substr(f.content, 1, 100) as content
      FROM fts_content f
      INNER JOIN nodes n ON n.id = f.note_id
      WHERE n.is_deleted = 0
        AND (f.title LIKE ? OR f.content LIKE ?)
      ORDER BY n.content_modified_at DESC
      LIMIT 50
    ''', [like, like]);
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _nodes = [];
  String? _currentFolderId;
  String _currentFolderTitle = 'Moon Note';
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  Set<String> _reminderNoteIds = {};
  String _sortField = 'content_modified_at';
  String _sortDir = 'DESC';
  DateTime? _lastBackPress;
  String? _hoveredId;
  String? _selectedNoteId;
  String _selectedNoteTitle = '';
  bool _isMouseDown = false;
  Offset? _dragStart;
  bool _isEditingTitle = false;
  late final TextEditingController _titleEditController;
  late final FocusNode _titleEditFocusNode;

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Color get _textPrimary => Theme.of(context).colorScheme.onSurface;
  Color get _textSecondary => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _textTertiary => Theme.of(context).colorScheme.outline;
  Color get _borderLight => Theme.of(context).colorScheme.outlineVariant;
  Color get _bgHover => Theme.of(context).colorScheme.surfaceContainerHighest;
  Color get _red => Theme.of(context).colorScheme.error;
  Color get _accent => Theme.of(context).colorScheme.onSurface;

  Future<void> _refresh() async {
    await _loadNodes();
    _trySync();
  }

  @override
  void initState() {
    super.initState();
    _titleEditController = TextEditingController();
    _titleEditFocusNode = FocusNode();
    _titleEditFocusNode.addListener(() {
      if (!_titleEditFocusNode.hasFocus && _isEditingTitle) {
        _finishEditingTitle();
      }
    });
    _refresh();
    NotificationService.instance.onQuickNote = _onQuickNote;
    NotificationService.instance.drainPendingQuickNote();
    if (!_isDesktop) _checkBatteryOptimization();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) => _trySync(showToast: false));
    SyncService.instance.dataVersionNotifier.addListener(_onRemoteDataChanged);
  }

  @override
  void dispose() {
    _titleEditFocusNode.dispose();
    _titleEditController.dispose();
    _syncTimer?.cancel();
    _quickSyncTimer?.cancel();
    SyncService.instance.dataVersionNotifier.removeListener(_onRemoteDataChanged);
    super.dispose();
  }

  void _checkBatteryOptimization() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final ignoring =
            await NotificationService.instance.isIgnoringBatteryOptimizations();
        if (!ignoring && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('保持后台运行',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary)),
              content: Text(
                'Moon Note 需要在后台运行以提供同步和快捷笔记功能。\n\n1. 请关闭电池优化\n2. 请开启「后台弹出界面」权限',
                style: TextStyle(fontSize: 15, color: _textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('稍后',
                      style: TextStyle(color: _textTertiary, fontSize: 14)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    NotificationService.instance
                        .requestBatteryOptimization();
                  },
                  child: Text('电池优化',
                      style: TextStyle(color: _textPrimary, fontSize: 14)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    NotificationService.instance
                        .openBackgroundPopupPermission();
                  },
                  child: Text('后台弹出',
                      style: TextStyle(color: _textPrimary, fontSize: 14)),
                ),
              ],
            ),
          );
        }
      } catch (_) {}
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _loadNodes() async {
    final db = await DatabaseHelper.instance.database;
    final nodes = (await db.query(
      'nodes',
      where: _currentFolderId == null
          ? 'parent_id IS NULL AND is_deleted = 0'
          : 'parent_id = ? AND is_deleted = 0',
      whereArgs: _currentFolderId == null ? null : [_currentFolderId],
      orderBy: 'is_pinned DESC, pin_order ASC, $_sortField $_sortDir',
    )).toList();
    final reminders = await db.query(
      'reminders',
      where: 'is_done = 0',
    );
    setState(() {
      _nodes = nodes;
      _reminderNoteIds =
          reminders.map((r) => r['note_id'] as String).toSet();
    });

    if (_currentFolderId == null) {
      _checkSystemFolders(nodes);
    }
  }

  bool _isSyncing = false;
  Timer? _syncTimer;

  void _onRemoteDataChanged() => _loadNodes();

  Future<void> _trySync({bool showToast = true}) async {
    if (_isSyncing) {
      print('[SYNC] 跳过: 上一次同步仍在进行中');
      return;
    }
    _isSyncing = true;
    print('[SYNC] 开始同步...');
    try {
      bool synced = false;
      if (_isDesktop) {
        try {
          synced = await SyncService.instance.tryUsbSync();
        } catch (e) {
          print('[SYNC] USB 同步异常: $e');
        }
      }
      if (!synced) {
        try {
          final info = await SyncService.instance.getLastConnection();
          final host = info['host'];
          final port = int.tryParse(info['port'] ?? '') ?? 9090;
          if (host != null && !SyncService.instance.isOwnAddress(host)) {
            print('[SYNC] USB 未成功，尝试 WiFi 同步 $host:$port');
            await SyncService.instance.fullSync(host, port);
            synced = true;
          } else {
            print('[SYNC] 无可用 WiFi 连接');
          }
        } catch (e) {
          print('[SYNC] WiFi 同步异常: $e');
        }
      }
      if (synced) {
        await _loadNodes();
        print('[SYNC] 同步完成');
        if (showToast && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('同步完成'),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        print('[SYNC] 本次未执行同步（无设备/无连接）');
      }
    } finally {
      _isSyncing = false;
    }
  }

  void _checkSystemFolders(List<Map<String, dynamic>> nodes) {
    final ids = nodes.map((n) => n['id'] as String).toSet();
    final missing = <String>[];
    if (!ids.contains('system_reminders')) missing.add('提醒');
    if (!ids.contains('system_journal')) missing.add('日志');

    if (missing.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('系统文件夹缺失',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary)),
              content: Text(
                '根目录缺少${missing.join('、')}文件夹，是否重建？',
                style: TextStyle(fontSize: 15, color: _textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('取消',
                      style: TextStyle(color: _textTertiary, fontSize: 14)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _rebuildSystemFolders(missing);
                  },
                  child: Text('重建',
                      style: TextStyle(color: _textPrimary, fontSize: 14)),
                ),
              ],
            ),
          );
        }
      });
    }
  }

  Future<void> _rebuildSystemFolders(List<String> missing) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (missing.contains('提醒')) {
      await db.rawInsert('''
        INSERT OR IGNORE INTO nodes(id, type, parent_id, title, sort_order, is_pinned, pin_order, is_expanded, is_deleted, is_system, created_at, modified_at)
        VALUES('system_reminders', 'folder', NULL, '提醒', -2.0, 1, -2.0, 0, 0, 1, ?, ?)
      ''', [now, now]);
    }
    if (missing.contains('日志')) {
      await db.rawInsert('''
        INSERT OR IGNORE INTO nodes(id, type, parent_id, title, sort_order, is_pinned, pin_order, is_expanded, is_deleted, is_system, created_at, modified_at)
        VALUES('system_journal', 'folder', NULL, '日志', -1.0, 1, -1.0, 0, 0, 1, ?, ?)
      ''', [now, now]);
    }

    await _loadNodes();
  }

  Future<void> _createNote() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = now.toString();
      final isJournal = _currentFolderId == 'system_journal';
      final now2 = DateTime.now();
      final title = isJournal
          ? '${now2.year}/${now2.month.toString().padLeft(2, '0')}/${now2.day.toString().padLeft(2, '0')}'
          : '未命名';
      await db.insert('nodes', {
        'id': id,
        'type': 'note',
        'parent_id': _currentFolderId,
        'title': title,
        'sort_order': now.toDouble(),
        'is_pinned': 0,
        'pin_order': 0,
        'is_expanded': 0,
        'is_deleted': 0,
        'is_system': 0,
        'created_at': now,
        'modified_at': now,
        'content_modified_at': now,
      });
      await db.insert('note_content', {
        'note_id': id,
        'content': '',
        'modified_at': now,
      });
      await db.insert('fts_content', {
        'note_id': id,
        'title': title,
        'content': '',
      });
      await _loadNodes();
      _scheduleQuickSync();
      if (_isDesktop && !isJournal) {
        setState(() {
          _selectedNoteId = id;
          _selectedNoteTitle = title;
        });
      }
    } catch (e) {
      print('创建笔记错误: $e');
    }
  }

  Future<void> _onQuickNote() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = now.toString();
      await db.insert('nodes', {
        'id': id,
        'type': 'note',
        'parent_id': null,
        'title': '未命名',
        'sort_order': now.toDouble(),
        'is_pinned': 0,
        'pin_order': 0,
        'is_expanded': 0,
        'is_deleted': 0,
        'is_system': 0,
        'created_at': now,
        'modified_at': now,
        'content_modified_at': now,
      });
      await db.insert('note_content', {
        'note_id': id,
        'content': '',
        'modified_at': now,
      });
      await db.insert('fts_content', {
        'note_id': id,
        'title': '未命名',
        'content': '',
      });
      if (_currentFolderId == null) {
        await _loadNodes();
      }
      if (!mounted) return;
      if (_isDesktop) {
        setState(() {
          _selectedNoteId = id;
          _selectedNoteTitle = '未命名';
        });
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => NotePage(
              noteId: id,
              initialTitle: '未命名',
            ),
          ),
        );
        if (mounted) await _loadNodes();
      }
    } catch (e) {
      print('快速笔记错误: $e');
    }
  }

  Future<void> _createFolder() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = now.toString();
      await db.insert('nodes', {
        'id': id,
        'type': 'folder',
        'parent_id': _currentFolderId,
        'title': '未命名文件夹',
        'sort_order': now.toDouble(),
        'is_pinned': 0,
        'pin_order': 0,
        'is_expanded': 0,
        'is_deleted': 0,
        'is_system': 0,
        'created_at': now,
        'modified_at': now,
      });
      await _loadNodes();
    } catch (e) {
      print('创建文件夹错误: $e');
    }
  }

  Future<void> _goBack() async {
    if (_currentFolderId == null) return;
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'nodes',
      where: 'id = ?',
      whereArgs: [_currentFolderId],
    );
    if (result.isNotEmpty) {
      setState(() {
        _currentFolderId = result.first['parent_id'] as String?;
        _currentFolderTitle = _currentFolderId == null
            ? 'Moon Note'
            : result.first['title'] as String;
      });
      _loadNodes();
    }
  }

  Future<void> _deleteNode(Map<String, dynamic> node) async {
    if ((node['is_system'] as int) == 1) return;
    if (_selectedNoteId == node['id']) {
      setState(() {
        _selectedNoteId = null;
        _selectedNoteTitle = '';
      });
    }
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'nodes',
      {'is_deleted': 1, 'deleted_at': now, 'modified_at': now},
      where: 'id = ?',
      whereArgs: [node['id']],
    );
    _scheduleQuickSync();
  }

  /// Debounced sync trigger — avoids hammering on rapid operations
  Timer? _quickSyncTimer;
  void _scheduleQuickSync() {
    _quickSyncTimer?.cancel();
    _quickSyncTimer = Timer(const Duration(seconds: 2), () {
      _trySync(showToast: false);
    });
  }

  Future<void> _permanentDelete(Database db, Map<String, dynamic> node) async {
    final id = node['id'];
    if (node['type'] == 'note') {
      await db.delete('note_content', where: 'note_id = ?', whereArgs: [id]);
      await db.delete('fts_content', where: 'note_id = ?', whereArgs: [id]);
      await ImageService.instance.deleteImagesForNote(id);
    }
    await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _batchDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
        content: Text('确定删除选中的 ${_selectedIds.length} 项吗？',
            style: TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('删除',
                style: TextStyle(color: _red, fontSize: 14)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in _selectedIds) {
      await db.update(
        'nodes',
        {'is_deleted': 1, 'deleted_at': now, 'modified_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    _exitSelection();
    await _loadNodes();
    _scheduleQuickSync();
  }

  Future<void> _batchMove() async {
    final db = await DatabaseHelper.instance.database;
    final allFolders = await db.query(
      'nodes',
      where: 'type = ? AND is_deleted = 0',
      whereArgs: ['folder'],
    );

    final selectedNodes =
        _nodes.where((n) => _selectedIds.contains(n['id'])).toList();

    final excludeIds = <String>{};
    for (final node in selectedNodes) {
      if (node['type'] == 'folder') {
        excludeIds.add(node['id'] as String);
        _addDescendantIds(allFolders, node['id'] as String, excludeIds);
      }
    }

    final sameParent = selectedNodes
        .every((n) => n['parent_id'] == selectedNodes.first['parent_id']);
    if (sameParent && selectedNodes.first['parent_id'] != null) {
      excludeIds.add(selectedNodes.first['parent_id'] as String);
    }

    final items = <Map<String, dynamic>>[];
    if (!sameParent || selectedNodes.first['parent_id'] != null) {
      items.add({'id': '__root__', 'title': '根目录', 'depth': 0});
    }
    final rootFolders =
        allFolders.where((f) => f['parent_id'] == null).toList();
    rootFolders.sort((a, b) {
      final ao = (a['sort_order'] as num?) ?? 0;
      final bo = (b['sort_order'] as num?) ?? 0;
      return ao.compareTo(bo);
    });
    for (final f in rootFolders) {
      if (!excludeIds.contains(f['id'])) {
        _addFolderToList(allFolders, f, items, 0, excludeIds);
      }
    }

    final targetId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移动到',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text('没有可用的目标文件夹',
                      style: TextStyle(color: _textTertiary, fontSize: 14)),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isRoot = item['id'] == '__root__';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                          left: 12.0 + (item['depth'] as int) * 20.0),
                      leading: Icon(
                        isRoot ? Icons.home_outlined : Icons.folder_outlined,
                        size: 18,
                        color: _textTertiary,
                      ),
                      title: Text(item['title'],
                          style: TextStyle(
                              fontSize: 15, color: _textPrimary)),
                      onTap: () => Navigator.pop(context, item['id']),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
        ],
      ),
    );

    if (targetId != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final newParentId = targetId == '__root__' ? null : targetId;
      for (final node in selectedNodes) {
        if (node['parent_id'] != newParentId) {
          await db.update(
            'nodes',
            {'parent_id': newParentId, 'modified_at': now},
            where: 'id = ?',
            whereArgs: [node['id']],
          );
        }
      }
      _exitSelection();
      await _loadNodes();
    }
  }

  Future<void> _copyNode(Map<String, dynamic> node) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final newId = now.toString();
    final newTitle = '${node['title']} 副本';

    await db.insert('nodes', {
      'id': newId,
      'type': node['type'],
      'parent_id': node['parent_id'],
      'title': newTitle,
      'sort_order': now.toDouble(),
      'is_pinned': 0,
      'pin_order': 0,
      'is_expanded': 0,
      'is_deleted': 0,
      'is_system': 0,
      'sort_preference': node['sort_preference'],
      'created_at': now,
      'modified_at': now,
      'content_modified_at': node['content_modified_at'] ?? now,
    });

    if (node['type'] == 'note') {
      final contentRows = await db.query(
        'note_content',
        where: 'note_id = ?',
        whereArgs: [node['id']],
      );
      if (contentRows.isNotEmpty) {
        await db.insert('note_content', {
          'note_id': newId,
          'content': contentRows.first['content'],
          'modified_at': now,
        });
      } else {
        await db.insert('note_content', {
          'note_id': newId,
          'content': '',
          'modified_at': now,
        });
      }
    }

    await _loadNodes();
  }

  Future<void> _togglePin(Map<String, dynamic> node) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final isPinned = (node['is_pinned'] as int) == 1;
    await db.update(
      'nodes',
      {
        'is_pinned': isPinned ? 0 : 1,
        'pin_order': isPinned ? 0 : now.toDouble(),
        'modified_at': now,
      },
      where: 'id = ?',
      whereArgs: [node['id']],
    );
    await _loadNodes();
    _scheduleQuickSync();
  }

  Widget _buildAppBarTitle() {
    if (_isEditingTitle) {
      return Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: 200,
          child: TextField(
            controller: _titleEditController,
            focusNode: _titleEditFocusNode,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _finishEditingTitle(),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 17,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            cursorColor: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: _currentFolderId != null ? _startEditingTitle : null,
      child: Text(
        _currentFolderTitle,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 17,
        ),
      ),
    );
  }

  void _startEditingTitle() {
    _titleEditController.text = _currentFolderTitle;
    _titleEditController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _currentFolderTitle.length,
    );
    setState(() => _isEditingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleEditFocusNode.requestFocus();
    });
  }

  Future<void> _finishEditingTitle() async {
    if (!_isEditingTitle) return;
    final newTitle = _titleEditController.text.trim();
    setState(() => _isEditingTitle = false);
    if (newTitle.isNotEmpty &&
        newTitle != _currentFolderTitle &&
        _currentFolderId != null &&
        !_currentFolderId!.startsWith('system_')) {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'nodes',
        {'title': newTitle, 'modified_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [_currentFolderId],
      );
      setState(() => _currentFolderTitle = newTitle);
      await _loadNodes();
    }
  }

  Future<void> _renameNode(Map<String, dynamic> node) async {
    if ((node['is_system'] as int) == 1) return;
    final controller = TextEditingController(text: node['title']);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          node['type'] == 'folder' ? '重命名文件夹' : '重命名笔记',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: _textPrimary, fontSize: 15),
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: _borderLight),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: _borderLight),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: _textSecondary, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('确定',
                style: TextStyle(color: _textPrimary, fontSize: 14)),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'nodes',
        {'title': result, 'modified_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [node['id']],
      );
      if (node['type'] == 'note') {
        await db.rawInsert(
          'INSERT OR REPLACE INTO fts_content(note_id, title, content) SELECT note_id, ?, content FROM fts_content WHERE note_id = ?',
          [result, node['id']],
        );
      }
      if (node['id'] == _currentFolderId) {
        _currentFolderTitle = result;
      }
      await _loadNodes();
    }
  }

  Future<void> _moveNode(Map<String, dynamic> node) async {
    final db = await DatabaseHelper.instance.database;
    final allFolders = await db.query(
      'nodes',
      where: 'type = ? AND is_deleted = 0',
      whereArgs: ['folder'],
    );

    final excludeIds = <String>{};
    if (node['type'] == 'folder') {
      excludeIds.add(node['id'] as String);
      _addDescendantIds(allFolders, node['id'] as String, excludeIds);
    }
    if (node['parent_id'] != null) {
      excludeIds.add(node['parent_id'] as String);
    }

    final targetId = await _showFolderPicker(allFolders, excludeIds, node);
    if (targetId != null && targetId != node['parent_id']) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.update(
        'nodes',
        {
          'parent_id': targetId == '__root__' ? null : targetId,
          'modified_at': now,
        },
        where: 'id = ?',
        whereArgs: [node['id']],
      );
      await _loadNodes();
    }
  }

  Future<void> _showReminderDialog(Map<String, dynamic> node) async {
    final nodeId = node['id'] as String;
    final db = await DatabaseHelper.instance.database;
    final existing = await db.query(
      'reminders',
      where: 'note_id = ? AND is_done = 0',
      whereArgs: [nodeId],
    );

    DateTime date = DateTime.now().add(const Duration(hours: 1));
    String repeatType = 'once';

    if (existing.isNotEmpty) {
      final r = existing.first;
      date = DateTime.fromMillisecondsSinceEpoch(r['remind_at'] as int);
      repeatType = r['repeat_type'] as String;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return _ReminderDialog(
          initialDate: date,
          initialRepeatType: repeatType,
          hasExisting: existing.isNotEmpty,
        );
      },
    );

    if (result == null) return;

    if (result['action'] == 'delete') {
      await db.delete(
        'reminders',
        where: 'note_id = ?',
        whereArgs: [nodeId],
      );
    } else {
      await db.rawInsert(
        'INSERT OR REPLACE INTO reminders(id, note_id, remind_at, repeat_type, repeat_day, is_done, created_at) VALUES(?, ?, ?, ?, ?, 0, ?)',
        [
          existing.isNotEmpty ? existing.first['id'] as String : DateTime.now().millisecondsSinceEpoch.toString(),
          nodeId,
          result['remind_at'],
          result['repeat_type'],
          result['repeat_day'] ?? 0,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }

    await _loadNodes();
  }

  void _addDescendantIds(
    List<Map<String, dynamic>> allFolders,
    String parentId,
    Set<String> result,
  ) {
    for (final f in allFolders) {
      if (f['parent_id'] == parentId) {
        final id = f['id'] as String;
        result.add(id);
        _addDescendantIds(allFolders, id, result);
      }
    }
  }

  Future<String?> _showFolderPicker(
    List<Map<String, dynamic>> allFolders,
    Set<String> excludeIds,
    Map<String, dynamic> node,
  ) async {
    final items = <Map<String, dynamic>>[];
    if (node['parent_id'] != null) {
      items.add({'id': '__root__', 'title': '根目录', 'depth': 0});
    }

    final rootFolders = allFolders
        .where((f) => f['parent_id'] == null)
        .toList();
    rootFolders.sort((a, b) {
      final ao = (a['sort_order'] as num?) ?? 0;
      final bo = (b['sort_order'] as num?) ?? 0;
      return ao.compareTo(bo);
    });

    for (final f in rootFolders) {
      if (!excludeIds.contains(f['id'])) {
        _addFolderToList(allFolders, f, items, 0, excludeIds);
      }
    }

    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '移动到',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text('没有可用的目标文件夹',
                      style: TextStyle(color: _textTertiary, fontSize: 14)),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isRoot = item['id'] == '__root__';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                        left: 12.0 + (item['depth'] as int) * 20.0,
                      ),
                      leading: Icon(
                        isRoot ? Icons.home_outlined : Icons.folder_outlined,
                        size: 18,
                        color: _textTertiary,
                      ),
                      title: Text(
                        item['title'],
                        style: TextStyle(
                            fontSize: 15, color: _textPrimary),
                      ),
                      onTap: () => Navigator.pop(context, item['id']),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
        ],
      ),
    );
  }

  void _addFolderToList(
    List<Map<String, dynamic>> allFolders,
    Map<String, dynamic> folder,
    List<Map<String, dynamic>> items,
    int depth,
    Set<String> excludeIds,
  ) {
    items.add({
      'id': folder['id'],
      'title': folder['title'],
      'depth': depth,
    });
    final children = allFolders
        .where((f) => f['parent_id'] == folder['id'])
        .toList();
    children.sort((a, b) {
      final ao = (a['sort_order'] as num?) ?? 0;
      final bo = (b['sort_order'] as num?) ?? 0;
      return ao.compareTo(bo);
    });
    for (final child in children) {
      if (!excludeIds.contains(child['id'])) {
        _addFolderToList(allFolders, child, items, depth + 1, excludeIds);
      }
    }
  }

  void _showNodeMenu(BuildContext context, Map<String, dynamic> node) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(
                (node['is_pinned'] as int) == 1
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              title: Text(
                (node['is_pinned'] as int) == 1 ? '取消置顶' : '置顶',
                style: TextStyle(
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface),
              ),
              onTap: () {
                Navigator.pop(context);
                _togglePin(node);
              },
            ),
            if ((node['is_system'] as int) != 1)
              ListTile(
                leading: Icon(Icons.edit_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                title: Text('重命名',
                    style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface)),
                onTap: () {
                  Navigator.pop(context);
                  _renameNode(node);
                },
              ),
            ListTile(
              leading: Icon(Icons.drive_file_move_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text('移动到',
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface)),
              onTap: () {
                Navigator.pop(context);
                _moveNode(node);
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text('复制',
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface)),
              onTap: () {
                Navigator.pop(context);
                _copyNode(node);
              },
            ),
            if (node['type'] == 'note') ...[
              ListTile(
                leading: Icon(
                  _reminderNoteIds.contains(node['id'])
                      ? Icons.notifications_active
                      : Icons.notifications_outlined,
                  size: 20,
                  color: _reminderNoteIds.contains(node['id'])
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  _reminderNoteIds.contains(node['id']) ? '修改提醒' : '设置提醒',
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showReminderDialog(node);
                },
              ),
              ListTile(
                leading: Icon(Icons.file_download_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                title: Text('导出为 Markdown',
                    style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface)),
                onTap: () {
                  Navigator.pop(context);
                  _exportNote(node);
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.checklist_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text('多选',
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface)),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _isSelecting = true;
                  _selectedIds.add(node['id'] as String);
                });
              },
            ),
            if ((node['is_system'] as int) != 1)
              ListTile(
                leading: Icon(Icons.delete_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.error),
                title: Text('删除',
                    style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteNode(node);
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _buildPopupMenuItems(Map<String, dynamic> node) {
    final items = <PopupMenuEntry<String>>[];
    final isFolder = node['type'] == 'folder';
    final isSystem = (node['is_system'] as int) == 1;

    items.add(PopupMenuItem<String>(
      value: 'pin',
      child: Row(
        children: [
          Icon(
            (node['is_pinned'] as int) == 1
                ? Icons.push_pin
                : Icons.push_pin_outlined,
            size: 18,
            color: _textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              (node['is_pinned'] as int) == 1 ? '取消置顶' : '置顶',
              style: TextStyle(fontSize: 14, color: _textPrimary),
            ),
          ),
        ],
      ),
      onTap: () => _togglePin(node),
    ));

    if (!isSystem) {
      items.add(PopupMenuItem<String>(
        value: 'rename',
        child: Row(
          children: [
            Icon(Icons.edit_outlined, size: 18, color: _textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text('重命名',
                  style: TextStyle(fontSize: 14, color: _textPrimary)),
            ),
          ],
        ),
        onTap: () => _renameNode(node),
      ));
    }

    items.add(PopupMenuItem<String>(
      value: 'move',
      child: Row(
        children: [
          Icon(Icons.drive_file_move_outlined,
              size: 18, color: _textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('移动到',
                style: TextStyle(fontSize: 14, color: _textPrimary)),
          ),
        ],
      ),
      onTap: () => _moveNode(node),
    ));

    items.add(PopupMenuItem<String>(
      value: 'copy',
      child: Row(
        children: [
          Icon(Icons.copy_outlined, size: 18, color: _textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('复制',
                style: TextStyle(fontSize: 14, color: _textPrimary)),
          ),
        ],
      ),
      onTap: () => _copyNode(node),
    ));

    if (!isFolder) {
      items.add(PopupMenuItem<String>(
        value: 'reminder',
        child: Row(
          children: [
            Icon(
              _reminderNoteIds.contains(node['id'])
                  ? Icons.notifications_active
                  : Icons.notifications_outlined,
              size: 18,
              color: _textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _reminderNoteIds.contains(node['id']) ? '修改提醒' : '设置提醒',
                style: TextStyle(fontSize: 14, color: _textPrimary),
              ),
            ),
          ],
        ),
        onTap: () => _showReminderDialog(node),
      ));
      items.add(PopupMenuItem<String>(
        value: 'export',
        child: Row(
          children: [
            Icon(Icons.file_download_outlined,
                size: 18, color: _textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text('导出为 Markdown',
                  style: TextStyle(fontSize: 14, color: _textPrimary)),
            ),
          ],
        ),
        onTap: () => _exportNote(node),
      ));
    }

    if (_isDesktop) {
      items.add(PopupMenuItem<String>(
        value: 'open_location',
        child: Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 18, color: _textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text('打开文件位置',
                  style: TextStyle(fontSize: 14, color: _textPrimary)),
            ),
          ],
        ),
        onTap: () => _openFileLocation(),
      ));
    }

    items.add(PopupMenuItem<String>(
      value: 'select',
      child: Row(
        children: [
          Icon(Icons.checklist_outlined, size: 18, color: _textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('多选',
                style: TextStyle(fontSize: 14, color: _textPrimary)),
          ),
        ],
      ),
      onTap: () {
        setState(() {
          _isSelecting = true;
          _selectedIds.add(node['id'] as String);
        });
      },
    ));

    if (!isSystem) {
      items.add(PopupMenuItem<String>(
        value: 'delete',
        child: Row(
          children: [
            Icon(Icons.delete_outline, size: 18, color: _red),
            const SizedBox(width: 10),
            Expanded(
              child: Text('删除',
                  style: TextStyle(fontSize: 14, color: _red)),
            ),
          ],
        ),
        onTap: () => _deleteNode(node),
      ));
    }

    return items;
  }

  Future<void> _openFileLocation() async {
    if (!Platform.isWindows) return;
    try {
      final dbPath = await getDatabasesPath();
      final fullPath = '$dbPath${Platform.pathSeparator}moon_note.db';
      await Process.run('explorer', ['/select,', fullPath]);
    } catch (_) {}
  }

  Future<void> _exportNote(Map<String, dynamic> node) async {
    if (node['type'] != 'note') return;
    final nodeId = node['id'] as String;
    final title = node['title'] as String? ?? '未命名';
    try {
      final db = await DatabaseHelper.instance.database;
      final contentRows = await db.query(
        'note_content',
        where: 'note_id = ?',
        whereArgs: [nodeId],
      );
      final content =
          contentRows.isNotEmpty ? contentRows.first['content'] as String : '';

      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${dir.path}${Platform.pathSeparator}exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final safeName = title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ');
      var filePath = '${exportDir.path}${Platform.pathSeparator}$safeName.md';

      // avoid overwriting
      var i = 1;
      while (await File(filePath).exists()) {
        filePath =
            '${exportDir.path}${Platform.pathSeparator}$safeName ($i).md';
        i++;
      }

      await File(filePath).writeAsString(content);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导出: $safeName.md'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            action: Platform.isWindows
                ? SnackBarAction(
                    label: '打开文件夹',
                    onPressed: () async {
                      try {
                        await Process.run(
                            'explorer', ['/select,', filePath]);
                      } catch (_) {}
                    },
                  )
                : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showDesktopContextMenu(
      Map<String, dynamic> node, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: _buildPopupMenuItems(node),
    );
  }

  Widget _buildDesktopRow(Map<String, dynamic> node) {
    final nodeId = node['id'] as String;
    final isFolder = node['type'] == 'folder';
    final isSelected = _selectedIds.contains(nodeId);
    final isSystem = (node['is_system'] as int) == 1;
    final isHovered = _hoveredId == nodeId;

    return MouseRegion(
      onEnter: (_) {
        if (mounted) {
          setState(() => _hoveredId = nodeId);
          if (_isSelecting && _isMouseDown) {
            _toggleSelection(nodeId);
          }
        }
      },
      onExit: (_) {
        if (mounted) setState(() => _hoveredId = null);
      },
      cursor: _isSelecting ? SystemMouseCursors.click : SystemMouseCursors.click,
      child: Listener(
        onPointerDown: (d) => _dragStart = d.localPosition,
        onPointerUp: (d) {
          if (_dragStart == null || _isSelecting) return;
          final dy = (d.localPosition.dy - _dragStart!.dy).abs();
          final dx = (d.localPosition.dx - _dragStart!.dx).abs();
          if (dy > 40 && dx < dy) {
            setState(() {
              _isSelecting = true;
              _selectedIds.add(nodeId);
            });
          }
          _dragStart = null;
        },
        child: Dismissible(
        key: Key(nodeId),
        direction: _isSelecting
            ? DismissDirection.none
            : DismissDirection.endToStart,
        movementDuration: const Duration(milliseconds: 200),
        dismissThresholds:
            const {DismissDirection.endToStart: 0.3},
        confirmDismiss: (direction) async {
          if (isSystem) return false;
          setState(() => _nodes.removeWhere((n) => n['id'] == nodeId));
          _deleteNode(node);
          return true;
        },
        background: const SizedBox.shrink(),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          color: isSystem ? _textTertiary : _red,
          child: Icon(
            isSystem ? Icons.block : Icons.delete_outline,
            size: 22,
            color: Colors.white,
          ),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_isSelecting) {
              _toggleSelection(nodeId);
            } else if (isFolder) {
              setState(() {
                _currentFolderId = node['id'];
                _currentFolderTitle = node['title'];
              });
              _loadNodes();
              if ((node['title'] as String).contains('未命名')) {
                _startEditingTitle();
              }
            } else {
              setState(() {
                _selectedNoteId = node['id'];
                _selectedNoteTitle = node['title'];
              });
            }
          },
          onDoubleTap: () {
            if (!_isSelecting && !isSystem) _renameNode(node);
          },
          onSecondaryTapUp: (d) {
            if (!_isSelecting) {
              _showDesktopContextMenu(node, d.globalPosition);
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: isHovered ? _bgHover : Colors.transparent,
              border: Border(
                  bottom: BorderSide(color: _borderLight, width: 0.5)),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                if (_isSelecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      size: 20,
                      color: isSelected ? _accent : _borderLight,
                    ),
                  )
                else
                  Icon(
                    isFolder ? Icons.folder_outlined : Icons.article_outlined,
                    size: 18,
                    color: _textTertiary,
                  ),
                if (!_isSelecting) const SizedBox(width: 10),
                if (!_isSelecting && (node['is_pinned'] as int) == 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child:
                        Icon(Icons.push_pin, size: 17, color: _textSecondary),
                  ),
                if (!_isSelecting &&
                    !isFolder &&
                    _reminderNoteIds.contains(nodeId))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(Icons.notifications_active,
                        size: 14, color: _textSecondary),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node['title'],
                        style: TextStyle(
                          fontSize: 15,
                          color: _textPrimary,
                          height: 1.4,
                        ),
                      ),
                      Text(
                        _formatDate((node['content_modified_at'] ?? node['modified_at']) as int),
                        style: TextStyle(
                          fontSize: 11,
                          color: _textTertiary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity: isHovered && !_isSelecting ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _desktopActionBtn(
                        (node['is_pinned'] as int) == 1
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        () => _togglePin(node),
                      ),
                      if (!isSystem)
                        _desktopActionBtn(
                          Icons.delete_outline,
                          () {
                            setState(() => _nodes.removeWhere(
                                (n) => n['id'] == node['id']));
                            _deleteNode(node);
                          },
                          color: _red,
                        ),
                      _desktopActionBtn(
                        Icons.more_horiz,
                        () {},
                        onTapDown: (d) =>
                            _showDesktopContextMenu(node, d.globalPosition),
                      ),
                    ],
                  ),
                ),
                if (!_isSelecting && isFolder && !isHovered)
                  Icon(Icons.chevron_right, size: 16, color: _borderLight),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  Widget _desktopActionBtn(IconData icon, VoidCallback? onTap,
      {Color? color, void Function(TapDownDetails)? onTapDown}) {
    return GestureDetector(
      onTap: onTapDown == null ? onTap : null,
      onTapDown: onTapDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(icon, size: 18, color: color ?? _textTertiary),
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Row(
      children: [
        SizedBox(
          width: 320,
          child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.surface,
            appBar: AppBar(
              backgroundColor: Theme.of(context).colorScheme.surface,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              leading: _isSelecting
                  ? IconButton(
                      icon: Icon(Icons.close,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 20),
                      onPressed: _exitSelection,
                    )
                  : _currentFolderId != null
                      ? IconButton(
                          icon: Icon(Icons.arrow_back,
                              color: Theme.of(context).colorScheme.onSurface,
                              size: 20),
                          onPressed: _goBack,
                        )
                      : null,
              title: _isSelecting
                  ? Text(
                      '已选 ${_selectedIds.length} 项',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                        fontSize: 17,
                      ),
                    )
                  : _buildAppBarTitle(),
              actions: _isSelecting || _isEditingTitle
                  ? null
                  : [
                      if (_currentFolderId == null)
                        IconButton(
                          icon: Icon(Icons.settings_outlined,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          tooltip: '设置',
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const SettingsPage()),
                            );
                            _loadNodes();
                          },
                        ),
                      IconButton(
                        icon: Icon(Icons.refresh,
                            size: 20,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                        tooltip: '刷新并同步',
                        onPressed: _refresh,
                      ),
                      if (_currentFolderId == null)
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          tooltip: '回收站',
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const RecycleBinPage()),
                            );
                            _loadNodes();
                          },
                        ),
                      IconButton(
                        icon: Icon(Icons.search,
                            size: 20,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                        tooltip: '搜索',
                        onPressed: () async {
                          final noteId = await showSearch<String>(
                            context: context,
                            delegate: _NoteSearchDelegate(),
                          );
                          if (noteId != null &&
                              noteId.isNotEmpty &&
                              mounted) {
                            final db =
                                await DatabaseHelper.instance.database;
                            final node = await db.query('nodes',
                                where: 'id = ?',
                                whereArgs: [noteId]);
                            if (node.isNotEmpty && mounted) {
                              setState(() {
                                _selectedNoteId = noteId;
                                _selectedNoteTitle =
                                    node.first['title'] as String? ??
                                        '';
                              });
                            }
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.swap_vert,
                            size: 20,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                        tooltip: '排序',
                        onPressed: _showSortPicker,
                      ),
                    ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(0.5),
                child: Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
            body: Listener(
                  onPointerDown: (_) => _isMouseDown = true,
                  onPointerUp: (_) => _isMouseDown = false,
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: _nodes.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: MediaQuery.of(context).size.height * 0.6,
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_note,
                                          size: 40, color: _borderLight),
                                      const SizedBox(height: 10),
                                      Text(
                                        '点击 + 开始记录',
                                        style: TextStyle(
                                            color: _textTertiary, fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: _nodes.length,
                            itemBuilder: (context, index) {
                              final node = _nodes[index];
                              return _buildDesktopRow(node);
                            },
                          ),
                  ),
                ),
            floatingActionButton: _isSelecting
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'batchmove',
                        onPressed:
                            _selectedIds.isNotEmpty ? _batchMove : null,
                        backgroundColor: _bgHover,
                        foregroundColor: _selectedIds.isNotEmpty
                            ? _textSecondary
                            : _textTertiary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.drive_file_move_outlined,
                            size: 20),
                      ),
                      const SizedBox(height: 6),
                      FloatingActionButton(
                        heroTag: 'batchdelete',
                        onPressed:
                            _selectedIds.isNotEmpty ? _batchDelete : null,
                        backgroundColor: _selectedIds.isNotEmpty
                            ? _red
                            : _bgHover,
                        foregroundColor: _selectedIds.isNotEmpty
                            ? Colors.white
                            : _textTertiary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        child: const Icon(Icons.delete_outline, size: 24),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'folder',
                        onPressed: _createFolder,
                        backgroundColor: _bgHover,
                        foregroundColor: _textSecondary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        child:
                            const Icon(Icons.folder_outlined, size: 20),
                      ),
                      const SizedBox(height: 6),
                      FloatingActionButton(
                        heroTag: 'note',
                        onPressed: _createNote,
                        backgroundColor: _textPrimary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        child: const Icon(Icons.add, size: 24),
                      ),
                    ],
                  ),
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(child: _buildRightPanel()),
      ],
      ),
    );
  }

  Widget _buildRightPanel() {
    final cs = Theme.of(context).colorScheme;
    if (_selectedNoteId == null) {
      return Container(
        color: cs.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_note, size: 48, color: _borderLight),
              const SizedBox(height: 12),
              Text(
                '选择一条笔记开始编辑',
                style: TextStyle(fontSize: 15, color: _textTertiary),
              ),
            ],
          ),
        ),
      );
    }
    final editingNoteId = _selectedNoteId!;
    return NotePage(
      key: ValueKey(editingNoteId),
      noteId: editingNoteId,
      initialTitle: _selectedNoteTitle,
      embedded: true,
      onTitleChanged: (newTitle) {
        _selectedNoteTitle = newTitle;
        final idx = _nodes.indexWhere((n) => n['id'] == editingNoteId);
        if (idx != -1) {
          _nodes[idx] = Map<String, dynamic>.from(_nodes[idx])
            ..['title'] = newTitle
            ..['modified_at'] = DateTime.now().millisecondsSinceEpoch;
        }
        setState(() {
          _nodes = List<Map<String, dynamic>>.from(_nodes);
        });
      },
    );
  }

  void _showSortPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('排序方式',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.outline,
                        fontWeight: FontWeight.w500)),
              ),
            ),
            _sortOption(context, '修改时间', 'content_modified_at', 'DESC'),
            _sortOption(context, '创建时间', 'created_at', 'DESC'),
            _sortOption(context, '标题 A-Z', 'title', 'ASC'),
            _sortOption(context, '标题 Z-A', 'title', 'DESC'),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _sortOption(
      BuildContext sheetContext, String label, String field, String dir) {
    final isActive = _sortField == field && _sortDir == dir;
    final cs = Theme.of(sheetContext).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(
        isActive ? Icons.check : null,
        size: 18,
        color: cs.onSurface,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: isActive ? cs.onSurface : cs.onSurfaceVariant,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () {
        Navigator.pop(sheetContext);
        setState(() {
          _sortField = field;
          _sortDir = dir;
        });
        _loadNodes();
      },
    );
  }

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) {
          _isSelecting = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelecting) {
          _exitSelection();
          return;
        }
        if (_currentFolderId != null) {
          _goBack();
          return;
        }
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          Navigator.of(context).pop();
          return;
        }
        _lastBackPress = now;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再按一次退出应用'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 160,
          ),
        );
      },
      child: _isDesktop
          ? _buildDesktopLayout()
          : Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.surface,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: _isSelecting
              ? IconButton(
                  icon: Icon(Icons.close,
                      color: Theme.of(context).colorScheme.onSurface, size: 20),
                  onPressed: _exitSelection,
                )
              : _currentFolderId != null
                  ? IconButton(
                      icon: Icon(Icons.arrow_back,
                          color: Theme.of(context).colorScheme.onSurface, size: 20),
                      onPressed: _goBack,
                    )
                  : null,
          title: _isSelecting
              ? Text(
                  '已选 ${_selectedIds.length} 项',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                    fontSize: 17,
                  ),
                )
              : _buildAppBarTitle(),
          actions: _isSelecting || _isEditingTitle
              ? null
              : [
                  if (_currentFolderId == null)
                    IconButton(
                      icon: Icon(Icons.settings_outlined,
                          size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      tooltip: '设置',
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) =>
                                  const SettingsPage()),
                        );
                        _loadNodes();
                      },
                    ),
                  if (_currentFolderId == null)
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      tooltip: '回收站',
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) =>
                                  const RecycleBinPage()),
                        );
                        _loadNodes();
                      },
                    ),
                  IconButton(
                    icon: Icon(Icons.search,
                        size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    tooltip: '搜索',
                    onPressed: () async {
                      final noteId = await showSearch<String>(
                        context: context,
                        delegate: _NoteSearchDelegate(),
                      );
                      if (noteId != null && noteId.isNotEmpty && mounted) {
                        final db = await DatabaseHelper.instance.database;
                        final node = await db.query('nodes',
                            where: 'id = ?', whereArgs: [noteId]);
                        if (node.isNotEmpty && mounted) {
                          if (_isDesktop) {
                            setState(() {
                              _selectedNoteId = noteId;
                              _selectedNoteTitle =
                                  node.first['title'] as String? ?? '';
                            });
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => NotePage(
                                  noteId: noteId,
                                  initialTitle:
                                      node.first['title'] as String? ?? '',
                                ),
                              ),
                            );
                            _loadNodes();
                          }
                        }
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.swap_vert,
                        size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    tooltip: '排序',
                    onPressed: _showSortPicker,
                  ),
                ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.5),
            child: Divider(
                height: 0.5,
                thickness: 0.5,
                color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: _nodes.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit_note, size: 40, color: _borderLight),
                            const SizedBox(height: 10),
                            Text(
                              '点击 + 开始记录',
                              style: TextStyle(color: _textTertiary, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: _nodes.length,
                  itemBuilder: (context, index) {
                    final node = _nodes[index];
                    if (_isDesktop) {
                      return _buildDesktopRow(node);
                    }
                    final isFolder = node['type'] == 'folder';
                  final nodeId = node['id'] as String;
                  final isSelected = _selectedIds.contains(nodeId);

                  final isSystem = (node['is_system'] as int) == 1;
                  return Listener(
                    onPointerDown: (d) => _dragStart = d.localPosition,
                    onPointerUp: (d) {
                      if (_dragStart == null || _isSelecting) return;
                      final dx = d.localPosition.dx - _dragStart!.dx;
                      final dy = (d.localPosition.dy - _dragStart!.dy).abs();
                      if (dx > 40 && dy < dx) {
                        setState(() {
                          _isSelecting = true;
                          _selectedIds.add(nodeId);
                        });
                      }
                      _dragStart = null;
                    },
                    child: Dismissible(
                    key: Key(nodeId),
                    direction: _isSelecting
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    movementDuration: Duration.zero,
                    dismissThresholds:
                        const {DismissDirection.endToStart: 0.2},
                    confirmDismiss: (direction) async {
                      if (isSystem) return false;
                      setState(() => _nodes.removeWhere(
                          (n) => n['id'] == node['id']));
                      _deleteNode(node);
                      return true;
                    },
                    background: const SizedBox.shrink(),
                    secondaryBackground: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: isSystem ? _textTertiary : _red,
                      child: Icon(
                        isSystem ? Icons.block : Icons.delete_outline,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        if (_isSelecting) {
                          _toggleSelection(nodeId);
                        } else if (isFolder) {
                          setState(() {
                            _currentFolderId = node['id'];
                            _currentFolderTitle = node['title'];
                          });
                          _loadNodes();
                          if ((node['title'] as String).contains('未命名')) {
                            _startEditingTitle();
                          }
                        } else {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => NotePage(
                                noteId: node['id'],
                                initialTitle: node['title'],
                              ),
                            ),
                          );
                          _loadNodes();
                        }
                      },
                      onLongPress: () {
                        if (!_isSelecting) {
                          _showNodeMenu(context, node);
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                              bottom:
                                  BorderSide(color: _borderLight, width: 0.5)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            if (_isSelecting)
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 20,
                                  color:
                                      isSelected ? _accent : _borderLight,
                                ),
                              )
                            else
                              Icon(
                                isFolder
                                    ? Icons.folder_outlined
                                    : Icons.article_outlined,
                                size: 18,
                                color: _textTertiary,
                              ),
                            if (!_isSelecting) const SizedBox(width: 10),
                            if (!_isSelecting &&
                                (node['is_pinned'] as int) == 1)
                              GestureDetector(
                                onTap: () => _togglePin(node),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(Icons.push_pin,
                                      size: 17, color: _textSecondary),
                                ),
                              ),
                            if (!_isSelecting &&
                                !isFolder &&
                                _reminderNoteIds.contains(nodeId))
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(Icons.notifications_active,
                                    size: 14, color: _textSecondary),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    node['title'],
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: _textPrimary,
                                      height: 1.4,
                                    ),
                                  ),
                                  Text(
                                    _formatDate(
                                        node['modified_at'] as int),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _textTertiary,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!_isSelecting && isFolder)
                              Icon(Icons.chevron_right,
                                  size: 16, color: _borderLight),
                          ],
                        ),
                      ),
                    ),
                    ),
                  );
                },
              ),
          ),
        floatingActionButton: _isSelecting
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'batchmove',
                    onPressed:
                        _selectedIds.isNotEmpty ? _batchMove : null,
                    backgroundColor: _bgHover,
                    foregroundColor: _selectedIds.isNotEmpty
                        ? _textSecondary
                        : _textTertiary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.drive_file_move_outlined,
                        size: 20),
                  ),
                  const SizedBox(height: 6),
                  FloatingActionButton(
                    heroTag: 'batchdelete',
                    onPressed:
                        _selectedIds.isNotEmpty ? _batchDelete : null,
                    backgroundColor: _selectedIds.isNotEmpty
                        ? _red
                        : _bgHover,
                    foregroundColor: _selectedIds.isNotEmpty
                        ? Colors.white
                        : _textTertiary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.delete_outline, size: 24),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'folder',
                    onPressed: _createFolder,
                    backgroundColor: _bgHover,
                    foregroundColor: _textSecondary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.folder_outlined, size: 20),
                  ),
                  const SizedBox(height: 6),
                  FloatingActionButton(
                    heroTag: 'note',
                    onPressed: _createNote,
                    backgroundColor: _textPrimary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.add, size: 24),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ReminderDialog extends StatefulWidget {
  final DateTime initialDate;
  final String initialRepeatType;
  final bool hasExisting;

  const _ReminderDialog({
    required this.initialDate,
    required this.initialRepeatType,
    required this.hasExisting,
  });

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  late DateTime _date;
  late String _repeatType;

  Color get _onSurface => Theme.of(context).colorScheme.onSurface;
  Color get _outline => Theme.of(context).colorScheme.outline;
  Color get _outlineVar => Theme.of(context).colorScheme.outlineVariant;
  Color get _error => Theme.of(context).colorScheme.error;

  static const _repeatOptions = ['once', 'daily', 'weekly', 'monthly', 'yearly'];
  static const _repeatLabels = ['不重复', '每天', '每周', '每月', '每年'];

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _repeatType = widget.initialRepeatType;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
    );
    if (picked != null) {
      setState(() => _date = DateTime(
            picked.year,
            picked.month,
            picked.day,
            _date.hour,
            _date.minute,
          ));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _date.hour, minute: _date.minute),
    );
    if (picked != null) {
      setState(() => _date = DateTime(
            _date.year,
            _date.month,
            _date.day,
            picked.hour,
            picked.minute,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('设置提醒',
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _onSurface)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pickerRow(
            '日期',
            '${_date.year}/${_date.month.toString().padLeft(2, '0')}/${_date.day.toString().padLeft(2, '0')}',
            _pickDate,
          ),
          const SizedBox(height: 10),
          _pickerRow(
            '时间',
            '${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}',
            _pickTime,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 60,
                child: Text('重复',
                    style: TextStyle(fontSize: 14, color: _onSurface)),
              ),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _repeatType,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: Theme.of(context).colorScheme.surface,
                    items: List.generate(_repeatOptions.length, (i) {
                      return DropdownMenuItem(
                        value: _repeatOptions[i],
                        child: Text(_repeatLabels[i],
                            style: TextStyle(
                                fontSize: 14, color: _onSurface)),
                      );
                    }),
                    onChanged: (v) {
                      if (v != null) setState(() => _repeatType = v);
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (widget.hasExisting)
          TextButton(
            onPressed: () => Navigator.pop(context, {'action': 'delete'}),
            child: Text('删除提醒',
                style: TextStyle(color: _error, fontSize: 14)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消',
              style: TextStyle(color: _outline, fontSize: 14)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, {
                'remind_at': _date.millisecondsSinceEpoch,
                'repeat_type': _repeatType,
                'repeat_day': 0,
              }),
          child: Text('确定',
              style: TextStyle(color: _onSurface, fontSize: 14)),
        ),
      ],
    );
  }

  Widget _pickerRow(String label, String value, VoidCallback onTap) {
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(label,
              style: TextStyle(fontSize: 14, color: _onSurface)),
        ),
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: _outlineVar),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(value,
                  style: TextStyle(fontSize: 14, color: _onSurface)),
            ),
          ),
        ),
      ],
    );
  }
}
