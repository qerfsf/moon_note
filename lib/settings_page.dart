import 'package:flutter/material.dart';
import 'main.dart';
import 'database.dart';
import 'recycle_bin_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _themeMode = 'system';
  double _fontSize = 17;

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
          _sectionHeader(cs, '其他'),
          _tile(cs, Icons.delete_outline, '回收站',
              subtitle: '查看已删除的项目',
              onTap: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const RecycleBinPage()));
              }),
          _tile(cs, Icons.info_outline, '关于 Moon Note',
              subtitle: '版本 1.0.0',
              onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'Moon Note',
                  applicationVersion: '1.0.0',
                  applicationIcon: const Icon(Icons.edit_note, size: 40),
                  children: [
                    const Text('一款简洁的 Notion 风格笔记应用。'),
                  ],
                );
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
      trailing: Icon(Icons.chevron_right, size: 16, color: cs.outlineVariant),
      onTap: onTap,
    );
  }
}
