import 'package:flutter/material.dart';
import 'database.dart';
import 'note_page.dart';
import 'recycle_bin_page.dart';

class _NoteSearchDelegate extends SearchDelegate<String> {
  @override
  String get searchFieldLabel => '搜索笔记...';

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        hintStyle: TextStyle(color: Color(0xFF9B9A97), fontSize: 17),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(
            color: Color(0xFF37352F), fontSize: 17, fontWeight: FontWeight.normal),
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear, size: 20, color: Color(0xFF6B6B67)),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back, size: 20, color: Color(0xFF37352F)),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) => _buildSearchResults();

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchResults();

  Widget _buildSearchResults() {
    if (query.isEmpty) {
      return const Center(
        child: Text('输入关键词搜索笔记',
            style: TextStyle(color: Color(0xFF9B9A97), fontSize: 14)),
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _search(query),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snapshot.data!;
        if (results.isEmpty) {
          return const Center(
            child: Text('没有找到相关笔记',
                style: TextStyle(color: Color(0xFF9B9A97), fontSize: 14)),
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
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: Color(0xFFEDEDEB), width: 0.5)),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['title'] as String? ?? '未命名',
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF37352F),
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
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B6B67),
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
      ORDER BY n.modified_at DESC
      LIMIT 50
    ''', [like, like]);
  }
}

const _textPrimary = Color(0xFF37352F);
const _textSecondary = Color(0xFF6B6B67);
const _textTertiary = Color(0xFF9B9A97);
const _borderLight = Color(0xFFEDEDEB);
const _bgHover = Color(0xFFF1F1EF);
const _red = Color(0xFFE03E3E);
const _accent = Color(0xFF37352F);

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
  String _sortField = 'modified_at';
  String _sortDir = 'DESC';
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _loadNodes() async {
    final db = await DatabaseHelper.instance.database;
    final nodes = await db.query(
      'nodes',
      where: 'parent_id IS ? AND is_deleted = 0',
      whereArgs: [_currentFolderId],
      orderBy: 'is_pinned DESC, pin_order ASC, $_sortField $_sortDir',
    );
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
              title: const Text('系统文件夹缺失',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary)),
              content: Text(
                '根目录缺少${missing.join('、')}文件夹，是否重建？',
                style: const TextStyle(fontSize: 15, color: _textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消',
                      style: TextStyle(color: _textTertiary, fontSize: 14)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _rebuildSystemFolders(missing);
                  },
                  child: const Text('重建',
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
    } catch (e) {
      print('创建笔记错误: $e');
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
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'nodes',
      {'is_deleted': 1, 'deleted_at': now},
      where: 'id = ?',
      whereArgs: [node['id']],
    );
  }

  Future<void> _batchDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
        content: Text('确定删除选中的 ${_selectedIds.length} 项吗？',
            style: const TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除',
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
        {'is_deleted': 1, 'deleted_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    _exitSelection();
    await _loadNodes();
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
        title: const Text('移动到',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
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
                          style: const TextStyle(
                              fontSize: 15, color: _textPrimary)),
                      onTap: () => Navigator.pop(context, item['id']),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
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
      },
      where: 'id = ?',
      whereArgs: [node['id']],
    );
    await _loadNodes();
  }

  Future<void> _renameNode(Map<String, dynamic> node) async {
    if ((node['is_system'] as int) == 1) return;
    final controller = TextEditingController(text: node['title']);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          node['type'] == 'folder' ? '重命名文件夹' : '重命名笔记',
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: _textPrimary, fontSize: 15),
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: _borderLight),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: _borderLight),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: _textSecondary, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定',
                style: TextStyle(color: _textPrimary, fontSize: 14)),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'nodes',
        {'title': result},
        where: 'id = ?',
        whereArgs: [node['id']],
      );
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
        title: const Text(
          '移动到',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
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
                        style: const TextStyle(
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
            child: const Text('取消',
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
      backgroundColor: Colors.white,
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
                color: _borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(
                (node['is_pinned'] as int) == 1
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                size: 20,
                color: _textSecondary,
              ),
              title: Text(
                (node['is_pinned'] as int) == 1 ? '取消置顶' : '置顶',
                style: const TextStyle(fontSize: 15, color: _textPrimary),
              ),
              onTap: () {
                Navigator.pop(context);
                _togglePin(node);
              },
            ),
            if ((node['is_system'] as int) != 1)
              ListTile(
                leading: const Icon(Icons.edit_outlined,
                    size: 20, color: _textSecondary),
                title: const Text('重命名',
                    style: TextStyle(fontSize: 15, color: _textPrimary)),
                onTap: () {
                  Navigator.pop(context);
                  _renameNode(node);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined,
                  size: 20, color: _textSecondary),
              title: const Text('移动到',
                  style: TextStyle(fontSize: 15, color: _textPrimary)),
              onTap: () {
                Navigator.pop(context);
                _moveNode(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined,
                  size: 20, color: _textSecondary),
              title: const Text('复制',
                  style: TextStyle(fontSize: 15, color: _textPrimary)),
              onTap: () {
                Navigator.pop(context);
                _copyNode(node);
              },
            ),
            if (node['type'] == 'note')
              ListTile(
                leading: Icon(
                  _reminderNoteIds.contains(node['id'])
                      ? Icons.notifications_active
                      : Icons.notifications_outlined,
                  size: 20,
                  color: _reminderNoteIds.contains(node['id'])
                      ? _accent
                      : _textSecondary,
                ),
                title: Text(
                  _reminderNoteIds.contains(node['id']) ? '修改提醒' : '设置提醒',
                  style:
                      const TextStyle(fontSize: 15, color: _textPrimary),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showReminderDialog(node);
                },
              ),
            ListTile(
              leading: const Icon(Icons.checklist_outlined,
                  size: 20, color: _textSecondary),
              title: const Text('多选',
                  style: TextStyle(fontSize: 15, color: _textPrimary)),
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
                leading: const Icon(Icons.delete_outline, size: 20, color: _red),
                title: const Text('删除',
                    style: TextStyle(fontSize: 15, color: _red)),
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

  void _showSortPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
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
                color: _borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('排序方式',
                    style: TextStyle(
                        fontSize: 13,
                        color: _textTertiary,
                        fontWeight: FontWeight.w500)),
              ),
            ),
            _sortOption(context, '修改时间', 'modified_at', 'DESC'),
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
    return ListTile(
      dense: true,
      leading: Icon(
        isActive ? Icons.check : null,
        size: 18,
        color: _textPrimary,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: isActive ? _textPrimary : _textSecondary,
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
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: _isSelecting
              ? IconButton(
                  icon: const Icon(Icons.close, color: _textPrimary, size: 20),
                  onPressed: _exitSelection,
                )
              : _currentFolderId != null
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: _textPrimary, size: 20),
                      onPressed: _goBack,
                    )
                  : null,
          title: _isSelecting
              ? Text(
                  '已选 ${_selectedIds.length} 项',
                  style: const TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w500,
                    fontSize: 17,
                  ),
                )
              : Text(
                  _currentFolderTitle,
                  style: const TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 17,
                  ),
                ),
          actions: _isSelecting
              ? null
              : [
                  if (_currentFolderId == null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: _textSecondary),
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
                    icon: const Icon(Icons.search,
                        size: 20, color: _textSecondary),
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
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.swap_vert,
                        size: 20, color: _textSecondary),
                    tooltip: '排序',
                    onPressed: _showSortPicker,
                  ),
                ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(0.5),
            child: Divider(height: 0.5, thickness: 0.5, color: _borderLight),
          ),
        ),
        body: _nodes.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_note, size: 40, color: _borderLight),
                    const SizedBox(height: 10),
                    const Text(
                      '点击 + 开始记录',
                      style: TextStyle(color: _textTertiary, fontSize: 14),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _nodes.length,
                itemBuilder: (context, index) {
                  final node = _nodes[index];
                  final isFolder = node['type'] == 'folder';
                  final nodeId = node['id'] as String;
                  final isSelected = _selectedIds.contains(nodeId);

                  final isSystem = (node['is_system'] as int) == 1;
                  return Dismissible(
                    key: Key(nodeId),
                    direction: _isSelecting
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    movementDuration: Duration.zero,
                    confirmDismiss: (direction) async {
                      if (isSystem) return false;
                      _deleteNode(node);
                      return true;
                    },
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
                      onHorizontalDragEnd: (details) {
                        if (_isSelecting) return;
                        final v = details.primaryVelocity;
                        if (v != null && v > 0) {
                          setState(() {
                            _isSelecting = true;
                            _selectedIds.add(nodeId);
                          });
                        }
                      },
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
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
                                child: const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(Icons.push_pin,
                                      size: 17, color: _textSecondary),
                                ),
                              ),
                            if (!_isSelecting &&
                                !isFolder &&
                                _reminderNoteIds.contains(nodeId))
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.notifications_active,
                                    size: 14, color: _textSecondary),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    node['title'],
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: _textPrimary,
                                      height: 1.4,
                                    ),
                                  ),
                                  Text(
                                    _formatDate(
                                        node['modified_at'] as int),
                                    style: const TextStyle(
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
                  );
                },
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
      title: const Text('设置提醒',
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Color(0xFF37352F))),
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
              const SizedBox(
                width: 60,
                child: Text('重复',
                    style:
                        TextStyle(fontSize: 14, color: Color(0xFF37352F))),
              ),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _repeatType,
                    isExpanded: true,
                    isDense: true,
                    items: List.generate(_repeatOptions.length, (i) {
                      return DropdownMenuItem(
                        value: _repeatOptions[i],
                        child: Text(_repeatLabels[i],
                            style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF37352F))),
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
            child: const Text('删除提醒',
                style:
                    TextStyle(color: Color(0xFFE03E3E), fontSize: 14)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消',
              style: TextStyle(color: Color(0xFF9B9A97), fontSize: 14)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, {
                'remind_at': _date.millisecondsSinceEpoch,
                'repeat_type': _repeatType,
                'repeat_day': 0,
              }),
          child: const Text('确定',
              style:
                  TextStyle(color: Color(0xFF37352F), fontSize: 14)),
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
              style: const TextStyle(
                  fontSize: 14, color: Color(0xFF37352F))),
        ),
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFEDEDEB)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 14, color: Color(0xFF37352F))),
            ),
          ),
        ),
      ],
    );
  }
}
