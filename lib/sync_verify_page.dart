import 'package:flutter/material.dart';

import 'sync_service.dart';

/// 一致性检查页:
/// 先用「计数 + 指纹」一次性比对两端数据(笔记/文件夹/回收站/正文/图片),
/// 指纹一致即认为完全一致;不一致时才拉取差异清单定位到具体条目,
/// 避免每次都逐文件比较。
class SyncVerifyPage extends StatefulWidget {
  const SyncVerifyPage({super.key});

  @override
  State<SyncVerifyPage> createState() => _SyncVerifyPageState();
}

class _SyncVerifyPageState extends State<SyncVerifyPage> {
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _local;
  Map<String, dynamic>? _remote;
  Map<String, dynamic>? _localManifest;
  Map<String, dynamic>? _remoteManifest;
  bool _showDiff = false;

  Color _ok(ColorScheme cs) => const Color(0xFF2E7D32);
  Color _bad(ColorScheme cs) => cs.error;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final s = await SyncService.instance.buildLocalSummary();
    if (mounted) setState(() => _local = s);
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _remote = null;
      _remoteManifest = null;
      _localManifest = null;
      _showDiff = false;
    });
    final local = await SyncService.instance.buildLocalSummary();
    final remote = await SyncService.instance.fetchRemoteSummary();
    if (!mounted) return;
    setState(() {
      _local = local;
      _remote = remote;
      _busy = false;
      if (remote == null) {
        _error = '无法获取对端数据摘要。请确认:另一端应用已打开(USB 已连接或同一 WiFi),'
            '且版本为 v3.2.0 及以上(旧版本没有一致性检查接口)。';
      }
    });
  }

  Future<void> _loadDiff() async {
    setState(() => _busy = true);
    final local = await SyncService.instance.buildLocalManifest();
    final remote = await SyncService.instance.fetchRemoteManifest();
    if (!mounted) return;
    setState(() {
      _localManifest = local;
      _remoteManifest = remote;
      _showDiff = true;
      _busy = false;
      if (remote == null) _error = '无法获取对端差异清单。';
    });
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final ok = await SyncService.instance.syncWithRemote();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已执行一次完整同步,可重新检查' : '同步失败(无连接或对端未运行)'),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
    if (ok) await _check();
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
        title: Text('一致性检查',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child:
              Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '先比对"计数 + 指纹",一致即说明两端的笔记、文件夹、回收站、正文、图片完全一致;'
            '不一致时再查看具体差异条目。',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('开始检查'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _syncNow,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('立即同步'),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12, color: cs.onSurface)),
            ),
          ],
          if (_remote != null) ...[
            const SizedBox(height: 16),
            _verdictCard(cs),
            const SizedBox(height: 16),
            _compareTable(cs),
            const SizedBox(height: 16),
            _fingerprintCard(cs),
            const SizedBox(height: 16),
            _recentCard(cs),
            if (!_sameFingerprint) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _loadDiff,
                      icon: const Icon(Icons.difference_outlined, size: 18),
                      label: const Text('查看差异条目'),
                    ),
                  ),
                ],
              ),
            ],
            if (_showDiff) ...[
              const SizedBox(height: 16),
              _diffCard(cs),
            ],
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  bool get _sameFingerprint {
    final l = _local;
    final r = _remote;
    if (l == null || r == null) return false;
    return l['fp_nodes'] == r['fp_nodes'] &&
        l['fp_content'] == r['fp_content'] &&
        l['fp_images'] == r['fp_images'];
  }

  Widget _card(ColorScheme cs, {required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );

  Widget _verdictCard(ColorScheme cs) {
    final same = _sameFingerprint;
    final c = same ? _ok(cs) : _bad(cs);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(same ? Icons.verified_outlined : Icons.report_problem_outlined,
              size: 22, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              same
                  ? '两端数据完全一致 ✅'
                  : '两端数据存在差异,建议先「立即同步」再重新检查',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compareTable(ColorScheme cs) {
    final lc = (_local?['counts'] as Map?) ?? {};
    final rc = (_remote?['counts'] as Map?) ?? {};
    const labels = {
      'notes': '笔记(在用)',
      'folders': '文件夹',
      'recycle_bin': '回收站条目',
      'content': '正文记录',
      'images': '图片记录',
      'nodes': '节点总计',
    };
    return _card(
      cs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('条目计数',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  flex: 4,
                  child: Text('项目',
                      style: TextStyle(fontSize: 12, color: cs.outline))),
              Expanded(
                  flex: 3,
                  child: Text('本机',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: cs.outline))),
              Expanded(
                  flex: 3,
                  child: Text('对端',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: cs.outline))),
            ],
          ),
          const SizedBox(height: 4),
          ...labels.entries.map((e) {
            final lv = lc[e.key];
            final rv = rc[e.key];
            final same = lv == rv;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                      flex: 4,
                      child: Text(e.value,
                          style: TextStyle(
                              fontSize: 13, color: cs.onSurface))),
                  Expanded(
                      flex: 3,
                      child: Text('$lv',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              color: same ? cs.onSurface : _bad(cs),
                              fontWeight:
                                  same ? FontWeight.normal : FontWeight.w700))),
                  Expanded(
                      flex: 3,
                      child: Text('$rv',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              color: same ? cs.onSurface : _bad(cs),
                              fontWeight:
                                  same ? FontWeight.normal : FontWeight.w700))),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _fingerprintCard(ColorScheme cs) {
    Widget row(String label, String key) {
      final lv = '${_local?[key] ?? '-'}';
      final rv = '${_remote?[key] ?? '-'}';
      final same = lv == rv;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(same ? Icons.check_circle_outline : Icons.cancel_outlined,
                size: 16, color: same ? _ok(cs) : _bad(cs)),
            const SizedBox(width: 8),
            SizedBox(
                width: 74,
                child: Text(label,
                    style: TextStyle(fontSize: 13, color: cs.onSurface))),
            Expanded(
              child: Text(
                same ? '一致 ($lv)' : '本机 $lv / 对端 $rv',
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: same ? cs.outline : _bad(cs)),
              ),
            ),
          ],
        ),
      );
    }

    return _card(
      cs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('数据指纹(一致即完全相同)',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 6),
          row('笔记结构', 'fp_nodes'),
          row('正文内容', 'fp_content'),
          row('图片记录', 'fp_images'),
        ],
      ),
    );
  }

  Widget _recentCard(ColorScheme cs) {
    List<dynamic> listOf(Map<String, dynamic>? s) =>
        (s?['recent_changes'] as List?) ?? const [];

    Widget side(String title, List<dynamic> changes) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const SizedBox(height: 4),
              if (changes.isEmpty)
                Text('暂无记录',
                    style: TextStyle(fontSize: 11, color: cs.outline))
              else
                ...changes.take(3).map((c) {
                  final m = c as Map;
                  final ts = DateTime.fromMillisecondsSinceEpoch(
                          (m['timestamp'] as num).toInt())
                      .toLocal();
                  String two(int v) => v.toString().padLeft(2, '0');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '${two(ts.month)}-${two(ts.day)} ${two(ts.hour)}:${two(ts.minute)} · ${m['total']} 项',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    ),
                  );
                }),
            ],
          ),
        );

    return _card(
      cs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最近修改记录对照',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              side('本机最近同步', listOf(_local)),
              const SizedBox(width: 12),
              side('对端最近同步', listOf(_remote)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diffCard(ColorScheme cs) {
    final lm = _localManifest;
    final rm = _remoteManifest;
    if (lm == null || rm == null) {
      return _card(cs, child: const Text('无法获取差异清单'));
    }

    List<String> diff(String key, String label) {
      final lset = ((lm[key] as List?) ?? const []).cast<String>().toList();
      final rset = ((rm[key] as List?) ?? const []).cast<String>().toList();
      String idOf(String line) => line.split('|').first;
      final lmap = {for (final l in lset) idOf(l): l};
      final rmap = {for (final l in rset) idOf(l): l};
      final out = <String>[];
      for (final e in lmap.entries) {
        if (!rmap.containsKey(e.key)) {
          out.add('仅本机有:$label ${_tail(e.value)}');
        } else if (rmap[e.key] != e.value) {
          out.add('内容/时间不同:$label ${_tail(e.value)} ↔ ${_tail(rmap[e.key]!)}');
        }
      }
      for (final e in rmap.entries) {
        if (!lmap.containsKey(e.key)) {
          out.add('仅对端有:$label ${_tail(e.value)}');
        }
      }
      return out;
    }

    final diffs = <String>[
      ...diff('nodes', '笔记'),
      ...diff('content', '正文'),
      ...diff('images', '图片'),
    ];

    return _card(
      cs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('差异条目(${diffs.length})',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 6),
          if (diffs.isEmpty)
            Text('清单比对未发现差异(指纹差异可能来自排序等细节)',
                style: TextStyle(fontSize: 12, color: cs.outline))
          else
            ...diffs.take(60).map((d) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(d,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface,
                          fontFamily: 'monospace')),
                )),
          if (diffs.length > 60)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('(仅显示前 60 条,共 ${diffs.length} 条)',
                  style: TextStyle(fontSize: 11, color: cs.outline)),
            ),
        ],
      ),
    );
  }

  static String _tail(String line) {
    final parts = line.split('|');
    if (parts.length < 2) return line;
    final ts = int.tryParse(parts[1]) ?? 0;
    final t = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final rest = parts.length > 3 ? ' ${parts[3]}' : '';
    return '${parts.first} @${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}$rest';
  }
}
