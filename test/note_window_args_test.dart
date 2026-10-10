// 「一个笔记一个窗口」靠命令行参数启动独立进程实现:
//   moon_note.exe --note <笔记id>
// 这里只校验参数解析这一层(真正的多窗口行为要在发布版上手动/脚本验证,
// 因为集成测试的可执行文件入口是测试本身,不能自己再起一个进程)。
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_note/main.dart' show standaloneNoteIdFromArgs;

void main() {
  group('独立窗口参数解析', () {
    test('--note <id> 能取到 id', () {
      expect(standaloneNoteIdFromArgs(['--note', '1759490000000']),
          '1759490000000');
    });

    test('没有 --note 时是普通主窗口', () {
      expect(standaloneNoteIdFromArgs([]), isNull);
      expect(standaloneNoteIdFromArgs(['--foo', 'bar']), isNull);
    });

    test('--note 后面没有值 -> 当成主窗口,不能崩', () {
      expect(standaloneNoteIdFromArgs(['--note']), isNull);
    });

    test('--note 后面是空白 -> 当成主窗口', () {
      expect(standaloneNoteIdFromArgs(['--note', '   ']), isNull);
    });

    test('前后多余空白会被去掉', () {
      expect(standaloneNoteIdFromArgs(['--note', ' 123 ']), '123');
    });

    test('跟其它参数混在一起也能取到', () {
      expect(
        standaloneNoteIdFromArgs(['--debug', '--note', 'abc', '--x']),
        'abc',
      );
    });
  });
}
