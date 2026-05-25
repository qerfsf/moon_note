import 'package:flutter/material.dart';
import 'database.dart';

const _textPrimary = Color(0xFF37352F);
const _textSecondary = Color(0xFF6B6B67);
const _textTertiary = Color(0xFF9B9A97);
const _borderLight = Color(0xFFEDEDEB);
const _red = Color(0xFFE03E3E);

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key});

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<Map<String, dynamic>> _items = [];
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final db = await DatabaseHelper.instance.database;
    final items = await db.query(
      'nodes',
      where: 'is_deleted = 1',
      orderBy: 'deleted_at DESC',
    );
    setState(() => _items = items);
  }

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _restore(String id) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'nodes',
      {'is_deleted': 0, 'deleted_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _loadItems();
  }

  Future<void> _permanentDelete(String id) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('note_content', where: 'note_id = ?', whereArgs: [id]);
    await db.delete('fts_content', where: 'note_id = ?', whereArgs: [id]);
    await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
    await _loadItems();
  }

  Future<void> _batchRestore() async {
    final db = await DatabaseHelper.instance.database;
    for (final id in _selectedIds) {
      await db.update(
        'nodes',
        {'is_deleted': 0, 'deleted_at': null},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    setState(() {
      _selectedIds.clear();
      _isSelecting = false;
    });
    await _loadItems();
  }

  Future<void> _batchDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: Text('确定永久删除选中的 ${_selectedIds.length} 项吗？此操作不可撤销。',
            style: const TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消',
                style:
                    TextStyle(color: _textTertiary, fontSize: 14)),
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
  }

  Future<void> _emptyAll() async {
    if (_items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空回收站',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _textPrimary)),
        content: Text('确定永久删除回收站中的 ${_items.length} 项吗？此操作不可撤销。',
            style: const TextStyle(fontSize: 15, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消',
                style:
                    TextStyle(color: _textTertiary, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空',
                style: TextStyle(color: _red, fontSize: 14)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final db = await DatabaseHelper.instance.database;
    for (final item in _items) {
      final id = item['id'] as String;
      await db.delete('note_content',
          where: 'note_id = ?', whereArgs: [id]);
      await db.delete('fts_content',
          where: 'note_id = ?', whereArgs: [id]);
      await db.delete('nodes', where: 'id = ?', whereArgs: [id]);
    }
    await _loadItems();
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
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: _isSelecting
              ? IconButton(
                  icon: const Icon(Icons.close,
                      color: _textPrimary, size: 20),
                  onPressed: _exitSelection,
                )
              : IconButton(
                  icon: const Icon(Icons.arrow_back,
                      color: _textPrimary, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
          title: _isSelecting
              ? Text('已选 ${_selectedIds.length} 项',
                  style: const TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 17))
              : const Text('回收站',
                  style: TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 17)),
          actions: _isSelecting
              ? [
                  if (_selectedIds.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.restore,
                          size: 20, color: _textPrimary),
                      tooltip: '恢复',
                      onPressed: _batchRestore,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_forever,
                          size: 20, color: _red),
                      tooltip: '删除',
                      onPressed: _batchDelete,
                    ),
                  ],
                ]
              : [
                  if (_items.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined,
                          size: 20, color: _textSecondary),
                      tooltip: '清空',
                      onPressed: _emptyAll,
                    ),
                ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(0.5),
            child:
                Divider(height: 0.5, thickness: 0.5, color: _borderLight),
          ),
        ),
        body: _items.isEmpty
            ? const Center(
                child: Text('回收站为空',
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
                                if (_selectedIds.isEmpty)
                                  _isSelecting = false;
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
                      decoration: const BoxDecoration(
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
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: _textPrimary,
                                    height: 1.4,
                                  ),
                                ),
                                if (item['deleted_at'] != null)
                                  Text(
                                    '删除于 ${_formatDate(item['deleted_at'] as int)}',
                                    style: const TextStyle(
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
                              icon: const Icon(Icons.more_horiz,
                                  size: 18, color: _textTertiary),
                              color: Colors.white,
                              elevation: 1,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8)),
                              onSelected: (value) {
                                if (value == 'restore')
                                  _restore(itemId);
                                else if (value == 'delete')
                                  _permanentDelete(itemId);
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'restore',
                                  child: Text('恢复',
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: _textPrimary)),
                                ),
                                const PopupMenuItem(
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
