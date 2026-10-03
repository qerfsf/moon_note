import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:moon_note/copy_block.dart';

Future<void> pumpBlock(
  WidgetTester tester, {
  required String title,
  required String content,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: CopyBlock(title: title, content: content),
        ),
      ),
    ),
  );
}

/// 拦下 Clipboard.setData,把写进剪贴板的内容记下来。
/// 不这样做的话测试环境里没有真实剪贴板,拿不到断言依据。
List<String> captureClipboard(WidgetTester tester) {
  final written = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        written.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  return written;
}

/// 造一个 flutter_markdown 传给 builder 的 <code class="language-..."> 元素。
md.Element codeElement(String className, String text) {
  final el = md.Element('code', [md.Text(text)]);
  el.attributes['class'] = className;
  return el;
}

void main() {
  // 每个用例结束后把剪贴板 mock 摘掉,免得串到别的测试里。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('CopyBlock 渲染', () {
    testWidgets('标题和内容都显示出来', (tester) async {
      await pumpBlock(tester, title: '安装命令', content: 'pnpm install');
      expect(find.text('安装命令'), findsOneWidget);
      expect(find.text('pnpm install'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets('没写标题时显示「可复制块」而不是空白', (tester) async {
      await pumpBlock(tester, title: '', content: 'x');
      expect(find.text('可复制块'), findsOneWidget);
    });

    testWidgets('内容可选中(方便手动复制一部分)', (tester) async {
      await pumpBlock(tester, title: 't', content: 'abc');
      expect(find.byType(SelectableText), findsOneWidget);
    });
  });

  group('CopyBlock 一键复制', () {
    testWidgets('点复制把内容写进剪贴板,按钮变成「已复制」', (tester) async {
      final written = captureClipboard(tester);
      await pumpBlock(tester, title: 't', content: '要复制的内容 123');

      expect(find.text('复制'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pump(); // 让 Clipboard 的 Future 完成

      expect(written, ['要复制的内容 123']);
      expect(find.text('已复制'), findsOneWidget);
      expect(find.text('复制'), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // 让「已复制」的 1200ms 复位计时器跑完,否则测试结束时会报 Timer 未清理
      await tester.pump(const Duration(milliseconds: 1300));
    });

    testWidgets('约 1.2 秒后按钮自己变回「复制」', (tester) async {
      final written = captureClipboard(tester);
      await pumpBlock(tester, title: 't', content: 'abc');

      await tester.tap(find.text('复制'));
      await tester.pump();
      expect(find.text('已复制'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('已复制'), findsNothing);
      expect(written, ['abc']);
    });

    testWidgets('复制的是原文,首尾换行不额外混进去', (tester) async {
      final written = captureClipboard(tester);
      await pumpBlock(tester, title: 't', content: 'line1\nline2');

      await tester.tap(find.text('复制'));
      await tester.pump();

      expect(written.single, 'line1\nline2');
      expect(written.single.contains('\r'), isFalse);

      await tester.pump(const Duration(milliseconds: 1300)); // 清掉复位计时器
    });
  });

  group('CopyBlockBuilder 只接管 ```copy 围栏', () {
    test('language-copy 生成可复制块', () {
      final w = CopyBlockBuilder().visitElementAfter(
        codeElement('language-copy 安装命令', 'pnpm install\n'),
        null,
      );
      expect(w, isA<CopyBlock>());
      expect((w as CopyBlock).title, '安装命令');
      // 结尾那个换行要去掉,否则复制出来多一行空行
      expect(w.content, 'pnpm install');
    });

    test('language-copy 没跟标题时标题为空(渲染兜底成「可复制块」)', () {
      final w = CopyBlockBuilder().visitElementAfter(
        codeElement('language-copy', 'body'),
        null,
      );
      expect(w, isA<CopyBlock>());
      expect((w as CopyBlock).title, '');
    });

    test('普通代码块交回默认渲染(返回 null)', () {
      for (final cls in ['language-dart', 'language-python', 'language-']) {
        final w = CopyBlockBuilder().visitElementAfter(
          codeElement(cls, 'void main() {}'),
          null,
        );
        expect(w, isNull, reason: '$cls 不该被接管');
      }
    });

    test('前缀相似的语言名不能被误判(copycat 回归)', () {
      // 早期用 startsWith('language-copy') 判断,把 copycat 也吞了
      for (final cls in ['language-copycat', 'language-copy2', 'language-copied']) {
        final w = CopyBlockBuilder().visitElementAfter(
          codeElement(cls, 'x'),
          null,
        );
        expect(w, isNull, reason: '$cls 不该被接管');
      }
    });

    test('没有 class 属性的代码块交回默认渲染', () {
      final el = md.Element('code', [md.Text('x')]);
      final w = CopyBlockBuilder().visitElementAfter(el, null);
      expect(w, isNull);
    });
  });

  group('插入模板', () {
    test('模板本身就是一段能被解析回可复制块的 ```copy 围栏', () {
      final body = '```$kCopyBlockFence 标题\n内容\n```\n';
      expect(kCopyBlockTemplate, body);
      expect(kCopyBlockTemplate.startsWith('```copy '), isTrue);
      expect(kCopyBlockTemplate.endsWith('```\n'), isTrue);
    });

    test('光标偏移正好落在内容行开头(点标题就能直接敲内容)', () {
      // 模板第一行是 "```copy 标题\n" —— 3 + 4 + 1 + 2 + 1 = 11 个字符。
      // 这里写死 11 是为了不让断言跟着常量一起漂:常量算错时能被抓到。
      expect(kCopyBlockCaretOffset, 11);
      expect(
        kCopyBlockTemplate.substring(0, kCopyBlockCaretOffset),
        '```copy 标题\n',
      );
      expect(kCopyBlockTemplate[kCopyBlockCaretOffset], '内');
    });
  });
}
