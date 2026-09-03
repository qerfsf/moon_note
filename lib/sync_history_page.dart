import 'dart:convert';

import 'package:flutter/material.dart';

import 'sync_change.dart';
import 'sync_change_sheet.dart';

/// 模块四:同步历史查看页(只读)。
class SyncHistoryPage extends StatefulWidget {
  const SyncHistoryPage({super.key});

  @override
  State<SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<SyncHistoryPage> {
  bool _loading = true;
  List<SyncRoundResult> _rounds = [];
  final Set<int> _expanded = {}; // 用 timestamp 标识展开的记录

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await SyncHistoryStore.instance.getRecentRounds();
    final rounds = <SyncRoundResult>[];
    for (final row in rows) {
      final raw = jsonDecode(row['items_json'] as String) as List;
      final items = raw
          .map((e) => SyncChangeItem.fromJson(e as Map<String, dynamic>))
          .toList();
      rounds.add(SyncRoundResult(
        timestamp: row['timestamp'] as int,
        items: items,
      ));
    }
    if (mounted) {
      setState(() {
        _rounds = rounds;
        _loading = false;
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
        title: Text('同步历史',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rounds.isEmpty
              ? _buildEmpty(cs)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: _rounds.length,
                    itemBuilder: (context, i) =>
                        _RoundCard(
                          result: _rounds[i],
                          expanded: _expanded.contains(_rounds[i].timestamp),
                          onToggle: () => setState(() {
                            final ts = _rounds[i].timestamp;
                            if (!_expanded.remove(ts)) _expanded.add(ts);
                          }),
                        ),
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 40, color: cs.outlineVariant),
          const SizedBox(height: 12),
          Text('暂无同步记录',
              style: TextStyle(fontSize: 14, color: cs.outline)),
          const SizedBox(height: 6),
          Text('有变更的同步完成后会出现在这里',
              style: TextStyle(fontSize: 12, color: cs.outline)),
        ],
      ),
    );
  }
}

class _RoundCard extends StatelessWidget {
  final SyncRoundResult result;
  final bool expanded;
  final VoidCallback onToggle;

  const _RoundCard({
    required this.result,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.sync, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(formatSyncTime(result.timestamp),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                        const SizedBox(height: 2),
                        Text('${result.totalChanges} 个文件已更新',
                            style: TextStyle(
                                fontSize: 12, color: cs.outline)),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        showSyncChangeSheet(context, result),
                    child: Text('详情',
                        style: TextStyle(fontSize: 13, color: cs.onSurface)),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(Icons.expand_more,
                        size: 20, color: cs.outline),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
            for (final item in result.items)
              SyncChangeItemTile(item: item),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
