import 'package:flutter/material.dart';
import 'database.dart';
import 'note_page.dart';

const _textPrimary = Color(0xFF37352F);
const _textSecondary = Color(0xFF6B6B67);
const _textTertiary = Color(0xFF9B9A97);
const _borderLight = Color(0xFFEDEDEB);
const _bgHover = Color(0xFFF1F1EF);
const _red = Color(0xFFE03E3E);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _nodes = [];
  String? _currentFolderId;
  String _currentFolderTitle = 'Moon Note';

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  Future<void> _loadNodes() async {
    final db = await DatabaseHelper.instance.database;
    final nodes = await db.query(
      'nodes',
      where: 'parent_id IS ? AND is_deleted = 0',
      whereArgs: [_currentFolderId],
      orderBy: 'is_pinned DESC, pin_order ASC, sort_order ASC',
    );
    setState(() {
      _nodes = nodes;
    });
  }

  Future<void> _createNote() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = now.toString();
      await db.insert('nodes', {
        'id': id,
        'type': 'note',
        'parent_id': _currentFolderId,
        'title': '未命名',
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
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'nodes',
      {'is_deleted': 1, 'deleted_at': now},
      where: 'id = ?',
      whereArgs: [node['id']],
    );
    await _loadNodes();
  }

  Future<void> _renameNode(Map<String, dynamic> node) async {
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
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.update(
        'nodes',
        {'title': result, 'modified_at': now},
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
    rootFolders
        .sort((a, b) => (a['sort_order'] as num).compareTo(b['sort_order']));

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
    children
        .sort((a, b) => (a['sort_order'] as num).compareTo(b['sort_order']));
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentFolderId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _currentFolderId != null) {
          _goBack();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: _currentFolderId != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back, color: _textPrimary,
                      size: 20),
                  onPressed: _goBack,
                )
              : null,
          title: Text(
            _currentFolderTitle,
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 17,
            ),
          ),
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
                  return InkWell(
                    onTap: () async {
                      if (isFolder) {
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
                    onLongPress: () => _showNodeMenu(context, node),
                    child: Container(
                      decoration: const BoxDecoration(
                        border: Border(
                            bottom:
                                BorderSide(color: _borderLight, width: 0.5)),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            isFolder
                                ? Icons.folder_outlined
                                : Icons.article_outlined,
                            size: 18,
                            color: _textTertiary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              node['title'],
                              style: const TextStyle(
                                fontSize: 15,
                                color: _textPrimary,
                                height: 1.4,
                              ),
                            ),
                          ),
                          if (isFolder)
                            Icon(Icons.chevron_right,
                                size: 16, color: _borderLight),
                        ],
                      ),
                    ),
                  );
                },
              ),
        floatingActionButton: Column(
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
