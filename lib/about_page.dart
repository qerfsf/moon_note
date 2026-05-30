import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
        title: Text('关于',
            style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 17)),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 40),
          Icon(Icons.edit_note, size: 64, color: cs.onSurface),
          const SizedBox(height: 14),
          Text(
            'Moon Note',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '版本 1.0.0 (build 1)',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: cs.outline),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '一款简洁的 Notion 风格笔记应用，支持无限嵌套文件夹、Markdown 编辑、提醒、日志等功能。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, height: 1.6),
            ),
          ),
          const SizedBox(height: 32),
          _section(cs, '技术栈', [
            _infoRow(cs, '框架', 'Flutter 3.32'),
            _infoRow(cs, '语言', 'Dart'),
            _infoRow(cs, '数据库', 'SQLite (sqflite)'),
            _infoRow(cs, '平台', 'Android / Windows'),
          ]),
          const SizedBox(height: 8),
          _section(cs, '链接', [
            _linkRow(context, cs, 'GitHub', 'https://github.com/qerfsf/moon_note'),
          ]),
          const SizedBox(height: 8),
          _section(cs, '贡献者', [
            _contributorRow(cs, 'qerfsf', '设计与开发'),
            _contributorRow(cs, 'Claude Code', '代码审查与安全审计'),
          ]),
          const SizedBox(height: 8),
          _section(cs, '法律', [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text('开源许可',
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
              trailing: Icon(Icons.chevron_right, size: 16, color: cs.outlineVariant),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Moon Note',
                applicationVersion: '1.0.0',
                applicationIcon: const Icon(Icons.edit_note, size: 40),
              ),
            ),
          ]),
          const SizedBox(height: 40),
          Text(
            'Made with ❤️ by qerfsf',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(height: 8),
          Text(
            '2025 Moon Note',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _section(ColorScheme cs, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 4, top: 8),
          child: Text(title,
              style: TextStyle(
                  fontSize: 12,
                  color: cs.outline,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5)),
        ),
        ...children,
      ],
    );
  }

  Widget _infoRow(ColorScheme cs, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant)),
          const Spacer(),
          Text(value, style: TextStyle(fontSize: 15, color: cs.onSurface)),
        ],
      ),
    );
  }

  Widget _contributorRow(ColorScheme cs, String name, String role) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(name,
              style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 8),
          Text(role,
              style: TextStyle(fontSize: 13, color: cs.outline)),
        ],
      ),
    );
  }

  Widget _linkRow(BuildContext context, ColorScheme cs, String label, String url) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(label,
          style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant)),
      subtitle: Text(url,
          style: TextStyle(fontSize: 12, color: cs.outline)),
      trailing: IconButton(
        icon: Icon(Icons.copy_outlined, size: 18, color: cs.outline),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: url));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('链接已复制'),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              width: 120,
            ),
          );
        },
      ),
      onTap: () {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('链接已复制'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 120,
          ),
        );
      },
    );
  }
}
