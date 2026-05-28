import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'main.dart';
import 'database.dart';
import 'backup_service.dart';
import 'recycle_bin_page.dart';
import 'about_page.dart';
import 'sync_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _themeMode = 'system';
  double _fontSize = 17;
  String _syncKey = '';
  String _deviceId = '';
  String _deviceName = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query('app_settings');
    for (final row in result) {
      final k = row['key'] as String;
      final v = row['value'] as String;
      if (k == 'theme') setState(() => _themeMode = v);
      if (k == 'font_size') {
        final f = double.tryParse(v);
        if (f != null) setState(() => _fontSize = f);
      }
      if (k == 'sync_key') setState(() => _syncKey = v);
      if (k == 'device_id') setState(() => _deviceId = v);
      if (k == 'device_name') setState(() => _deviceName = v);
    }
  }

  Future<void> _setTheme(String mode) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['theme', mode],
    );
    setState(() => _themeMode = mode);
    switch (mode) {
      case 'light':
        themeNotifier.value = ThemeMode.light;
      case 'dark':
        themeNotifier.value = ThemeMode.dark;
      default:
        themeNotifier.value = ThemeMode.system;
    }
  }

  Future<void> _setFontSize(double size) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      ['font_size', size.toStringAsFixed(0)],
    );
    setState(() => _fontSize = size);
  }

  Future<void> _setSetting(String key, String value) async {
    final db = await DatabaseHelper.instance.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
      [key, value],
    );
  }

  Future<void> _migrateSyncKey() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('迁移设备身份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入旧设备的 sync_key，数据将从旧设备同步到此设备。',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                hintText: '例如: moon-a3f8k2',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认迁移'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await _setSetting('sync_key', ctrl.text.trim());
      setState(() => _syncKey = ctrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('sync_key 已更新，请手动同步数据')),
        );
      }
    }
  }

  Future<void> _editDeviceName() async {
    final ctrl = TextEditingController(text: _deviceName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备名称'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: '输入设备名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await _setSetting('device_name', ctrl.text.trim());
      setState(() => _deviceName = ctrl.text.trim());
    }
  }

  Future<void> _exportData() async {
    try {
      final path = await BackupService.instance.exportToFile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导出到:\n$path'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  Future<void> _importData() async {
    // List backup files in Downloads
    final downloadDir = Platform.isAndroid
        ? Directory('/storage/emulated/0/Download')
        : Directory('${Platform.environment['USERPROFILE']}\\Downloads');

    List<FileSystemEntity> files = [];
    if (await downloadDir.exists()) {
      files = downloadDir
          .listSync()
          .where((f) => f.path.endsWith('.json') &&
              f.path.contains('moon_note_backup'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
    }

    if (!mounted) return;

    if (files.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入数据'),
          content: const Text('未找到备份文件。\n\n请将备份文件放在下载目录中。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择备份文件'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (_, i) {
              final name = files[i].path.split(Platform.pathSeparator).last;
              return ListTile(
                dense: true,
                title: Text(name, style: const TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(ctx, files[i].path),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );

    if (selected == null || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: const Text('导入将覆盖当前所有数据，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final count = await BackupService.instance.importFromFile(selected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入完成: $count 条记录')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: cs.onSurface, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('设置',
            style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 17)),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _sectionHeader(cs, '外观'),
          _tile(cs, Icons.brightness_6, '主题模式',
              subtitle: _themeLabel, onTap: _showThemePicker),
          _tile(cs, Icons.format_size, '字体大小',
              subtitle: '${_fontSize.toStringAsFixed(0)} px', onTap: _showFontSizePicker),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _sectionHeader(cs, '同步'),
          _tile(cs, Icons.sync, '局域网同步',
              subtitle: '同一 WiFi 下同步笔记',
              onTap: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SyncPage()));
              }),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _sectionHeader(cs, '设备标识'),
          _tile(cs, Icons.badge_outlined, '设备名称',
              subtitle: _deviceName,
              onTap: _editDeviceName),
          InkWell(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: _syncKey));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('sync_key 已复制到剪贴板')),
              );
            },
            child: _tile(cs, Icons.vpn_key_outlined, 'sync_key',
                subtitle: _syncKey,
                onTap: _migrateSyncKey),
          ),
          InkWell(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: _deviceId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('device_id 已复制到剪贴板')),
              );
            },
            child: _tile(cs, Icons.perm_device_information_outlined, 'device_id',
                subtitle: _deviceId,
                onTap: null),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, top: 4),
            child: Text(
              'sync_key 相同的设备之间可以同步数据。换设备时，在新设备上点击 sync_key 并输入旧设备的 key 即可迁移身份。',
              style: TextStyle(fontSize: 12, color: cs.outline),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _sectionHeader(cs, '数据备份'),
          _tile(cs, Icons.upload_file, '导出备份',
              subtitle: '导出全部笔记到 JSON 文件',
              onTap: _exportData),
          _tile(cs, Icons.download, '导入恢复',
              subtitle: '从备份文件恢复数据',
              onTap: _importData),
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, top: 4),
            child: Text(
              '更新前建议先导出备份，避免数据丢失。导入将覆盖当前数据。',
              style: TextStyle(fontSize: 12, color: cs.outline),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _sectionHeader(cs, '其他'),
          _tile(cs, Icons.delete_outline, '回收站',
              subtitle: '查看已删除的项目',
              onTap: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const RecycleBinPage()));
              }),
          _tile(cs, Icons.info_outline, '关于 Moon Note',
              subtitle: '版本 3.0.0',
              onTap: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AboutPage()));
              }),
        ],
      ),
    );
  }

  String get _themeLabel {
    switch (_themeMode) {
      case 'light':
        return '浅色';
      case 'dark':
        return '深色';
      default:
        return '跟随系统';
    }
  }

  void _showThemePicker() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32, height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
            _themeOption(ctx, cs, '浅色', 'light'),
            _themeOption(ctx, cs, '深色', 'dark'),
            _themeOption(ctx, cs, '跟随系统', 'system'),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _themeOption(
      BuildContext sheetCtx, ColorScheme cs, String label, String value) {
    return ListTile(
      dense: true,
      leading: Icon(
        _themeMode == value ? Icons.check : null,
        size: 18,
        color: cs.onSurface,
      ),
      title: Text(label,
          style: TextStyle(
              fontSize: 15,
              color: _themeMode == value ? cs.onSurface : cs.onSurfaceVariant,
              fontWeight:
                  _themeMode == value ? FontWeight.w600 : FontWeight.normal)),
      onTap: () {
        Navigator.pop(sheetCtx);
        _setTheme(value);
      },
    );
  }

  void _showFontSizePicker() {
    final cs = Theme.of(context).colorScheme;
    int current = _fontSize.round();
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32, height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text('字体大小',
                        style: TextStyle(
                            fontSize: 13,
                            color: cs.outline,
                            fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text('$current px',
                        style: TextStyle(
                            fontSize: 14,
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Slider(
                  value: current.toDouble(),
                  min: 12,
                  max: 24,
                  divisions: 12,
                  activeColor: cs.onSurface,
                  inactiveColor: cs.outlineVariant,
                  onChanged: (v) {
                    setSheetState(() => current = v.round());
                  },
                  onChangeEnd: (v) => _setFontSize(v),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(ColorScheme cs, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4, top: 8),
      child: Text(title,
          style: TextStyle(
              fontSize: 12,
              color: cs.outline,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5)),
    );
  }

  Widget _tile(ColorScheme cs, IconData icon, String title,
      {String? subtitle, VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      title: Text(title,
          style: TextStyle(fontSize: 15, color: cs.onSurface)),
      subtitle: subtitle != null
          ? Text(subtitle,
              style: TextStyle(fontSize: 13, color: cs.outline))
          : null,
      trailing: onTap != null
          ? Icon(Icons.chevron_right, size: 16, color: cs.outlineVariant)
          : null,
      onTap: onTap,
    );
  }
}
