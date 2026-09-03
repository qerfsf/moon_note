import 'package:flutter/material.dart';

import 'database.dart';
import 'sync_change.dart';

String formatSyncTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

Color _typeColor(ColorScheme cs, String type) {
  switch (type) {
    case 'added':
      return const Color(0xFF2E7D32); // green
    case 'deleted':
      return const Color(0xFFC62828); // red
    default:
      return const Color(0xFFF9A825); // amber
  }
}

/// 模块二:变更详情底部面板。
Future<void> showSyncChangeSheet(
  BuildContext context,
  SyncRoundResult result,
) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部把手
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Row(
              children: [
                Text('同步变更详情',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface)),
                const Spacer(),
                Text('${formatSyncTime(result.timestamp)}  ·  ${result.totalChanges} 项',
                    style: TextStyle(fontSize: 12, color: cs.outline)),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: cs.outline),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: result.items.length,
              itemBuilder: (context, i) =>
                  SyncChangeItemTile(item: result.items[i]),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 变更条目行(详情面板与历史页共用)。点击打开该笔记当前内容的只读查看页。
class SyncChangeItemTile extends StatelessWidget {
  final SyncChangeItem item;

  const SyncChangeItemTile({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _typeColor(cs, item.type);
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SyncChangeViewPage(item: item)),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(item.typeLabel,
                  style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(item.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: cs.onSurface)),
            ),
            if (item.size > 0)
              Text('${item.size} 字',
                  style: TextStyle(fontSize: 11, color: cs.outline)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: cs.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// 点击变更项后打开当前内容的只读查看页。
class SyncChangeViewPage extends StatefulWidget {
  final SyncChangeItem item;

  const SyncChangeViewPage({super.key, required this.item});

  @override
  State<SyncChangeViewPage> createState() => _SyncChangeViewPageState();
}

class _SyncChangeViewPageState extends State<SyncChangeViewPage> {
  Map<String, dynamic>? _node;
  String? _content;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DatabaseHelper.instance.database;
    final nodes = await db
        .query('nodes', where: 'id = ?', whereArgs: [widget.item.id]);
    String? content;
    if (nodes.isNotEmpty) {
      final contents = await db.query('note_content',
          where: 'note_id = ?', whereArgs: [widget.item.id]);
      if (contents.isNotEmpty) {
        content = contents.first['content'] as String?;
      }
    }
    if (mounted) {
      setState(() {
        _node = nodes.isNotEmpty ? nodes.first : null;
        _content = content;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: cs.onSurface, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _node != null ? (_node!['title'] as String? ?? '未命名') : widget.item.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(widget.item.typeLabel,
                  style: TextStyle(
                      fontSize: 12,
                      color: _typeColor(cs, widget.item.type))),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_node == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('该笔记已不存在(可能已被删除)',
              style: TextStyle(fontSize: 13, color: cs.outline)),
        ),
      );
    }
    final isDeleted = (_node!['is_deleted'] as int? ?? 0) == 1;
    final isFolder = _node!['type'] == 'folder';
    final String body;
    if (isFolder) {
      body = '（文件夹，无正文内容）';
    } else if (isDeleted) {
      body = '（该笔记已删除，内容在回收站中）';
    } else if (_content == null || _content!.isEmpty) {
      body = '（空白笔记）';
    } else {
      body = _content!;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        body,
        style: TextStyle(
            fontSize: 16,
            height: 1.7,
            color: isDeleted ? cs.outline : cs.onSurface),
      ),
    );
  }
}
