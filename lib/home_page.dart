import 'package:flutter/material.dart';
import 'database.dart';
import 'note_page.dart';

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
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(
          node['type'] == 'folder' ? '重命名文件夹' : '重命名笔记',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
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
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '移动到',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('没有可用的目标文件夹',
                      style: TextStyle(color: Colors.grey)),
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
                        left: 16.0 + (item['depth'] as int) * 20.0,
                      ),
                      leading: Icon(
                        isRoot ? Icons.home_outlined : Icons.folder_outlined,
                        size: 20,
                        color: const Color(0xFFFFC107),
                      ),
                      title: Text(
                        item['title'],
                        style: const TextStyle(fontSize: 15),
                      ),
                      onTap: () => Navigator.pop(context, item['id']),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.black54),
              title: const Text('重命名', style: TextStyle(color: Colors.black87)),
              onTap: () {
                Navigator.pop(context);
                _renameNode(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined, color: Colors.black54),
              title: const Text('移动到', style: TextStyle(color: Colors.black87)),
              onTap: () {
                Navigator.pop(context);
                _moveNode(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteNode(node);
              },
            ),
            const SizedBox(height: 8),
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
          leading: _currentFolderId != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black87),
                  onPressed: _goBack,
                )
              : null,
          title: Text(
            _currentFolderTitle,
            style: const TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
              fontSize: 18,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(color: Colors.grey[200], height: 1),
          ),
        ),
        body: _nodes.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.note_outlined, size: 48, color: Colors.grey[300]),
                    const SizedBox(height: 12),
                    Text(
                      '点击右下角开始创建',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(top: 8),
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            isFolder ? Icons.folder : Icons.article_outlined,
                            size: 20,
                            color: isFolder
                                ? const Color(0xFFFFC107)
                                : Colors.grey[500],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              node['title'],
                              style: const TextStyle(
                                fontSize: 15,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          if (isFolder)
                            Icon(Icons.chevron_right,
                                size: 18, color: Colors.grey[400]),
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
              backgroundColor: Colors.grey[100],
              foregroundColor: Colors.black54,
              elevation: 1,
              child: const Icon(Icons.folder_outlined),
            ),
            const SizedBox(height: 8),
            FloatingActionButton(
              heroTag: 'note',
              onPressed: _createNote,
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              elevation: 2,
              child: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}