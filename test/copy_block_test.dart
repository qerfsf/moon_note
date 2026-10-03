import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:moon_note/copy_block.dart';

/// 造一个 flutter_markdown 会交给 builder 的那种 fenced code 元素。
/// 注意:markdown 7.x 的 Element 不接受 attributes 具名参数,要往 map 里写。
md.Element codeElement(String? className, String content) {
  final el = md.Element('code', [md.Text(content)]);
  if (className != null) el.attributes['class'] = className;
  return el;
}

void main() {
  group('CopyBlockBuilder', () {
    test('```copy 标题 -> 渲染成可复制块,标题和内容都对', () {
      final w = CopyBlockBuilder()
          .visitElementAfter(codeElement('language-copy 我的提示词', 'hello\nworld\n'), null);
      expect(w, isA<CopyBlock>());
      final block = w! as CopyBlock;
      expect(block.title, '我的提示词');
      expect(block.content, 'hello\nworld', reason: '结尾换行应被去掉');
    });

    test('```copy(不带标题)也能渲染,标题为空', () {
      final w = CopyBlockBuilder()
          .visitElementAfter(codeElement('language-copy', '内容'), null);
      expect(w, isA<CopyBlock>());
      expect((w! as CopyBlock).title, '');
    });

    test('普通代码块不接管(返回 null,走默认渲染)', () {
      final w = CopyBlockBuilder()
          .visitElementAfter(codeElement('language-dart', 'void main() {}'), null);
      expect(w, isNull);
    });

    test('没有 class 的代码块不接管', () {
      final w = CopyBlockBuilder()
          .visitElementAfter(codeElement(null, 'plain'), null);
      expect(w, isNull);
    });

    test('只认语言名本身,不误伤 copySomething', () {
      final w = CopyBlockBuilder()
          .visitElementAfter(codeElement('language-copycat', 'x'), null);
      expect(w, isNull);
    });
  });
}
