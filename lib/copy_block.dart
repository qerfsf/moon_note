import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// 可复制块的语法模板:```copy 标题 ... ```
///
/// 为什么复用围栏代码块而不是自己造语法:围栏是标准 Markdown,
/// 在别的编辑器里会退化成普通代码块显示(内容照样可读),不会出现一堆怪符号;
/// 而且 flutter_markdown 会把 info string 放进 `class=language-...`,
/// 正好能用一个 builder 精准接管、其它代码块照旧走默认渲染。
const String kCopyBlockFence = 'copy';

/// 工具栏插入用的模板。
const String kCopyBlockTemplate = '```$kCopyBlockFence 标题\n内容\n```\n';

/// 模板第一行(```copy 标题\n)的长度 —— 把光标放这里就落在内容行开头,
/// 插入后可以直接敲内容,不用手动往下挪。
///
/// 故意从模板本身量出来而不是手写数字:手算曾写错过(多算了一个 1,光标
/// 会跑到内容首字之后),而且改 fence 名字或标题占位符时也不会失效。
final int kCopyBlockCaretOffset = kCopyBlockTemplate.indexOf('内容');

/// 给 flutter_markdown 用的 builder:只接管 ```copy 围栏,其余返回 null 走默认渲染。
class CopyBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final cls = element.attributes['class'] ?? '';
    // 必须精确匹配,或后面紧跟空格再跟标题 ——
    // 否则 `language-copycat` 这类语言名会被 startsWith 误判成可复制块。
    const prefix = 'language-$kCopyBlockFence';
    if (cls != prefix && !cls.startsWith('$prefix ')) return null;

    final rest = cls.substring(prefix.length).trim();
    final content = element.textContent.replaceAll(RegExp(r'\n$'), '');

    return CopyBlock(title: rest, content: content, textStyle: preferredStyle);
  }
}

/// 渲染成「像代码块那样的框」,右上角一键复制。
class CopyBlock extends StatefulWidget {
  const CopyBlock({
    super.key,
    required this.title,
    required this.content,
    this.textStyle,
  });

  final String title;
  final String content;
  final TextStyle? textStyle;

  @override
  State<CopyBlock> createState() => _CopyBlockState();
}

class _CopyBlockState extends State<CopyBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.content));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final codeStyle = widget.textStyle ??
        TextStyle(fontSize: 14, color: cs.onSurface, height: 1.5);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(90),
        border: Border.all(color: cs.outlineVariant, width: 0.8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题栏:左侧标题(没有就显示「可复制块」),右侧一键复制
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(Icons.copy_all_outlined, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.title.isEmpty ? '可复制块' : widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check : Icons.content_copy,
                    size: 14,
                  ),
                  label: Text(
                    _copied ? '已复制' : '复制',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: _copied ? cs.primary : cs.onSurfaceVariant,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: cs.outlineVariant),
          // 内容:原样保留(可横向滚动,不自动换行破坏内容)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.content,
                style: codeStyle.copyWith(
                  fontFamily: 'monospace',
                  fontSize: (codeStyle.fontSize ?? 14) - 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
