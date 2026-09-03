import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'sync_change.dart';

enum DiffKind { same, added, removed }

class DiffLine {
  final DiffKind kind;
  final String text;
  const DiffLine(this.kind, this.text);
}

/// 行级 LCS diff。
List<DiffLine> _diffLines(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  final n = a.length;
  final m = b.length;

  // 规模过大时退化为"整段删除 + 整段新增",避免 O(n*m) 内存爆炸
  if (n * m > 4_000_000) {
    return [
      ...a.map((l) => DiffLine(DiffKind.removed, l)),
      ...b.map((l) => DiffLine(DiffKind.added, l)),
    ];
  }

  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.same, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine(DiffKind.removed, a[i]));
      i++;
    } else {
      out.add(DiffLine(DiffKind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffKind.removed, a[i]));
    i++;
  }
  while (j < m) {
    out.add(DiffLine(DiffKind.added, b[j]));
    j++;
  }
  return out;
}

String _shortTime(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 变更内容对比页:行级 diff,并标注新旧版本时间(较新的操作优先保留)。
class SyncChangeComparePage extends StatelessWidget {
  final SyncChangeItem item;

  const SyncChangeComparePage({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final oldText = item.oldContent ?? '';
    final newText = item.newContent ?? '';
    final lines = _diffLines(oldText, newText);

    final oldLabel = item.type == 'conflict' ? '本机版本' : '同步前';
    final newLabel = item.type == 'conflict' ? '对端版本' : '同步后';
    final newerIsNew = item.newTime >= item.oldTime;

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
        title: Text(item.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
      ),
      body: Column(
        children: [
          // 版本与时间头部
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                    child: _versionBox(
                  context,
                  cs,
                  oldLabel,
                  item.oldTime,
                  isNewer: !newerIsNew && item.oldTime > 0,
                  removed: true,
                  content: item.oldContent,
                )),
                const SizedBox(width: 8),
                Expanded(
                    child: _versionBox(
                  context,
                  cs,
                  newLabel,
                  item.newTime,
                  isNewer: newerIsNew,
                  removed: false,
                  content: item.newContent,
                )),
              ],
            ),
          ),
          if (item.type == 'conflict')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 13, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '两端同时修改,保留较新的操作。红色为被替换的旧内容,绿色为新内容。',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    ),
                  ),
                ],
              ),
            ),
          Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final l = lines[i];
                return _diffRow(context, l);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _versionBox(BuildContext context, ColorScheme cs, String label,
      int time,
      {required bool isNewer,
      required bool removed,
      String? content}) {
    final accent =
        removed ? const Color(0xFFC62828) : const Color(0xFF2E7D32);
    final timeText = _shortTime(time);
    final hasContent = content != null && content.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accent)),
              const Spacer(),
              if (isNewer && time > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('较新 · 优先',
                      style: TextStyle(fontSize: 10, color: accent)),
                ),
              if (hasContent)
                InkWell(
                  onTap: () => _copyVersion(context, label, content),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded,
                            size: 13, color: cs.onSurfaceVariant),
                        const SizedBox(width: 2),
                        Text('复制',
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (time > 0) ...[
            const SizedBox(height: 2),
            Text(timeText,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  /// 复制某一版本的全部内容到剪贴板(只读页不提供版本回滚,避免混乱)。
  Future<void> _copyVersion(
      BuildContext context, String label, String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已复制「$label」的全部内容'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Widget _diffRow(BuildContext context, DiffLine l) {
    final cs = Theme.of(context).colorScheme;
    final (prefix, fg, bg) = switch (l.kind) {
      DiffKind.added => ('+', const Color(0xFF2E7D32), const Color(0x142E7D32)),
      DiffKind.removed =>
        ('-', const Color(0xFFC62828), const Color(0x14C62828)),
      _ => (' ', cs.outline, Colors.transparent),
    };
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
              text: prefix,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
          const TextSpan(text: ' '),
          TextSpan(
              text: l.text.isEmpty ? ' ' : l.text,
              style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurface)),
        ]),
      ),
    );
  }
}
