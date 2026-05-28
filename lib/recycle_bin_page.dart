import 'package:flutter/material.dart';
import 'database.dart';
import 'sync_service.dart';

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key});

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<Map<String, dynamic>> _items = [];
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  int _totalDeletedCount = 0;

  Color get _textPrimary => Theme.of(context).colorScheme.onSurface;
  Color get _textSecondary => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _textTertiary => Theme.of(context).colorScheme.outline;
  Color get _borderLight => Theme.of(context).colorScheme.outlineVariant;
  Color get _red => Theme.of(context).colorScheme.error;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final db = await DatabaseHelper.instance.database;
    final items = await db.rawQuery('''
      SELECT n.* FROM nodes n
      WHERE n.is_deleted = 1
      AND NOT (
        n.type = 'note'
        AND n.title = '未命名'
        AND (SELECT COALESCE(content, '') FROM note_content WHERE note_id = n.id) = ''
      )
      AND NOT (
        n.type = 'folder'
        AND (SELECT COUNT(*) FROM nodes WHERE parent_id = n.id) = 0
      )
      ORDER BY n.deleted_at DESC
    ''');
    final total = await db.rawQuery(
      'SELECT COUNT(*) as c FROM nodes WHERE is_deleted = 1',
    );
    if (mounted) {
      setState(() {
        _items = items;
        _totalDeletedCount = (total.first['c'] as int?) ?? 0;
      });
    }
  }

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _restore(String id) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'nodes',
      {'is_deleted': 0, 'deleted_at': null, 'modified_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _loadItems();
    SyncService.instance.dataVersionNotifier.value++;
  }

  Future<void> _permanentDelete(String id) async {
    SyncService.instance.addPendingDelete(id);
    final db = await DatabaseHelper.instance.database;
    await db.delete('note_content', where: 'note_id = ?', whereArgs: [id]);
    await db.delete('fts_content', where: 'note_id = ?', whereArgs: [id]);
    await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
    await _loadItems();
    SyncService.instance.dataVersionNotifier.value++;
  }

  Future<void> _batchRestore() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in _selectedIds) {
      await db.update(
        'nodes',
        {'is_deleted': 0, 'deleted_at': null, 'modified_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    setState(() {
      _selectedIds.clear();
      _isSelecting = false;
    });
    await _loadItems();
    SyncService.instance.dataVersionNotifier.value++;
  }

  Future<void> _batchDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('永久删除',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: Text('确定永久删除选中的 ${_selectedIds.length} 项吗？此操作不可撤销。',
            style: TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消',
                style:
                    TextStyle(color: _textTertiary, fontSize: 14)),
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
    SyncService.instance.addPendingDeletes(_selectedIds.toList());
    final db = await DatabaseHelper.instance.database;
    for (final id in _selectedIds) {
      await db.delete('note_content',
          where: 'note_id = ?', whereArgs: [id]);
      await db.delete('fts_content',
          where: 'note_id = ?', whereArgs: [id]);
      await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
    }
    setState(() {
      _selectedIds.clear();
      _isSelecting = false;
    });
    await _loadItems();
    SyncService.instance.dataVersionNotifier.value++;
  }

  Future<void> _emptyAll() async {
    final db = await DatabaseHelper.instance.database;
    // Count ALL deleted nodes, including filtered-out empty ones
    final allDeleted = await db.rawQuery(
      'SELECT COUNT(*) as c FROM nodes WHERE is_deleted = 1',
    );
    final totalCount = (allDeleted.first['c'] as int?) ?? 0;
    if (totalCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清空回收站',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: Text('确定永久删除回收站中的 $totalCount 项吗？此操作不可撤销。',
            style: TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消',
                style:
                    TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('清空',
                style: TextStyle(color: _red, fontSize: 14)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Get ALL deleted IDs (not just visible ones)
    final allRows = await db.query('nodes',
        columns: ['id', 'type'],
        where: 'is_deleted = 1');
    final ids = allRows.map((r) => r['id'] as String).toList();
    SyncService.instance.addPendingDeletes(ids);

    // Delete all note_content and fts_content for deleted notes
    await db.rawDelete(
      'DELETE FROM note_content WHERE note_id IN (SELECT id FROM nodes WHERE is_deleted = 1)');
    await db.rawDelete(
      'DELETE FROM fts_content WHERE note_id IN (SELECT id FROM nodes WHERE is_deleted = 1)');
    await db.delete('nodes', where: 'is_deleted = 1');
    await _loadItems();
    SyncService.instance.dataVersionNotifier.value++;
    print('[BIN] 清空回收站: 删除了 $totalCount 个节点 (含隐藏的空笔记/空文件夹)');
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSelecting) _exitSelection();
      },
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
                      color: _textPrimary, size: 20),
                  onPressed: _exitSelection,
                )
              : IconButton(
                  icon: Icon(Icons.arrow_back,
                      color: _textPrimary, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
          title: _isSelecting
              ? Text('已选 ${_selectedIds.length} 项',
                  style: TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 17))
              : Text('回收站',
                  style: TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 17)),
          actions: _isSelecting
              ? [
                  if (_selectedIds.isNotEmpty) ...[
                    IconButton(
                      icon: Icon(Icons.restore,
                          size: 20, color: _textPrimary),
                      tooltip: '恢复',
                      onPressed: _batchRestore,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_forever,
                          size: 20, color: _red),
                      tooltip: '删除',
                      onPressed: _batchDelete,
                    ),
                  ],
                ]
              : [
                  if (_totalDeletedCount > 0)
                    IconButton(
                      icon: Icon(Icons.delete_sweep_outlined,
                          size: 20, color: _textSecondary),
                      tooltip: '清空',
                      onPressed: _emptyAll,
                    ),
                ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.5),
            child:
                Divider(height: 0.5, thickness: 0.5, color: _borderLight),
          ),
        ),
        body: _items.isEmpty
            ? Center(
                child: Text(_totalDeletedCount > 0
                    ? '回收站中有 $_totalDeletedCount 项可清理'
                    : '回收站为空',
                    style: TextStyle(
                        color: _textTertiary, fontSize: 14)),
              )
            : ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final itemId = item['id'] as String;
                  final isSelected = _selectedIds.contains(itemId);
                  final isFolder = item['type'] == 'folder';

                  return InkWell(
                    onTap: _isSelecting
                        ? () {
                            setState(() {
                              if (isSelected) {
                                _selectedIds.remove(itemId);
                                if (_selectedIds.isEmpty) {
                                  _isSelecting = false;
                                }
                              } else {
                                _selectedIds.add(itemId);
                              }
                            });
                          }
                        : null,
                    onLongPress: () {
                      if (!_isSelecting) {
                        setState(() {
                          _isSelecting = true;
                          _selectedIds.add(itemId);
                        });
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                            bottom: BorderSide(
                                color: _borderLight, width: 0.5)),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          if (_isSelecting)
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: 10),
                              child: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 20,
                                color: isSelected
                                    ? _red
                                    : _borderLight,
                              ),
                            )
                          else ...[
                            Icon(
                              isFolder
                                  ? Icons.folder_outlined
                                  : Icons.article_outlined,
                              size: 18,
                              color: _textTertiary,
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title'] as String,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: _textPrimary,
                                    height: 1.4,
                                  ),
                                ),
                                if (item['deleted_at'] != null)
                                  Text(
                                    '删除于 ${_formatDate(item['deleted_at'] as int)}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _textTertiary,
                                      height: 1.3,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!_isSelecting)
                            PopupMenuButton<String>(
                              icon: Icon(Icons.more_horiz,
                                  size: 18, color: _textTertiary),
                              color: Theme.of(context).colorScheme.surface,
                              elevation: 1,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8)),
                              onSelected: (value) {
                                if (value == 'restore') {
                                  _restore(itemId);
                                } else if (value == 'delete')
                                  _permanentDelete(itemId);
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'restore',
                                  child: Text('恢复',
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: _textPrimary)),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('永久删除',
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: _red)),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
