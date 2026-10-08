// 真的去点同步页那个「同步」按钮 —— 不是调函数、不是发指令。
//
// 为什么要这个测试:之前我一直用「启动时的自动同步」验证,那条路
// (tryUsbSync)每次都会把 adb 转发删掉重建,所以即使转发已经失效也照样成功;
// 而同步页的「同步」按钮走的是 ensureAdbForward,旧实现只要转发**存在**就信它,
// 于是「自动同步能成功、点按钮却失败」。两条路不一样,必须分开验。
//
// 跑法(要先停掉正在运行的电脑端,否则 9090 端口和数据库会打架):
//   flutter test integration_test/sync_button_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:moon_note/database.dart';
import 'package:moon_note/sync_page.dart';
import 'package:moon_note/sync_service.dart';

const _adb = r'C:\Users\mi\AppData\Local\Android\Sdk\platform-tools\adb.exe';

Future<List<String>> _adbForwardList() async {
  final r = await Process.run(_adb, ['forward', '--list']);
  return (r.stdout as String)
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
}

/// 页面上的按钮是 ElevatedButton(_smallBtn),按文案定位。
Finder get _syncButton => find.widgetWithText(ElevatedButton, '同步');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 和 main() 一样的初始化,但不起通知服务(测试里不需要)
    await DatabaseHelper.instance.database;
    await SyncService.instance.startServer();
  });

  tearDownAll(() async {
    await SyncService.instance.stopServer();
  });

  Future<void> pumpSyncPage(WidgetTester tester) async {
    // 先直接问一次 adb,确认探测本身是通的(与 UI 无关)
    final devices = await SyncService.instance.getAdbDevices();
    // ignore: avoid_print
    print('[测试] getAdbDevices 直接返回: $devices');

    await tester.pumpWidget(const MaterialApp(home: SyncPage()));
    await tester.pumpAndSettle();

    final detect = find.widgetWithText(ElevatedButton, '检测');
    // ignore: avoid_print
    print('[测试] 页面上「检测」按钮个数: ${detect.evaluate().length}');
    if (detect.evaluate().isNotEmpty) {
      await tester.tap(detect, warnIfMissed: false);
      await tester.pumpAndSettle();
    }

    // 等 USB 那一行出现(adb devices 是真实进程调用,要给它时间)
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_syncButton.evaluate().isNotEmpty) return;
    }
    // 没等到就把页面文字打出来,便于定位
    final texts = <String>[];
    for (final w in tester.allWidgets) {
      if (w is Text && w.data != null) texts.add(w.data!);
    }
    // ignore: avoid_print
    print('[测试] 页面上的文字: $texts');
    // ignore: avoid_print
    print('[测试] 再次 getAdbDevices: ${await SyncService.instance.getAdbDevices()}');
  }

  testWidgets('点「同步」按钮能成功(转发已失效时会自动重建)', (tester) async {
    // 先把转发删掉,制造「同步页以为映射还在、实际早就没了」的现场
    await Process.run(_adb, ['forward', '--remove', 'tcp:9091']);
    expect(await _adbForwardList(), isEmpty, reason: '前置条件:转发应为空');

    await pumpSyncPage(tester);
    expect(_syncButton, findsOneWidget, reason: 'USB 那一行应该显示「同步」按钮');

    SyncService.instance.messageNotifier.value = '';
    await tester.tap(_syncButton);

    // 给 adb + HTTP 一点时间(按钮逻辑是异步的)
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (SyncService.instance.statusNotifier.value == SyncStatus.idle &&
          SyncService.instance.messageNotifier.value.isNotEmpty) {
        break;
      }
    }

    final msg = SyncService.instance.messageNotifier.value;
    final forwards = await _adbForwardList();
    // ignore: avoid_print
    print('[测试] 提示文字: $msg');
    // ignore: avoid_print
    print('[测试] 转发状态: $forwards');

    // 1) 转发被重建出来了
    expect(forwards, isNotEmpty, reason: '点同步后应该把转发重建出来');
    expect(forwards.first, contains('tcp:9091'));

    // 2) 转发确实通到手机(这一条最关键:旧实现会拿着失效转发直接失败)
    expect(await SyncService.instance.adbForwardReachable(),
        isTrue,
        reason: '重建后的转发应当真的能连上手机');

    // 3) 没留下错误状态
    expect(SyncService.instance.statusNotifier.value, isNot(SyncStatus.error),
        reason: '不该停在错误状态,提示:$msg');
    expect(msg, isNot(contains('失败')));
    expect(msg, isNot(contains('无法')));
  });

  testWidgets('转发「存在但已失效」时,点同步也必须能自愈', (tester) async {
    await pumpSyncPage(tester);

    // 先点一次同步,确保现在的转发是好的
    await tester.tap(_syncButton);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (SyncService.instance.statusNotifier.value == SyncStatus.idle) break;
    }

    // 关键场景:让转发**存在但连不通** —— 手动建一个指向不存在端口的映射。
    // 旧实现看到「转发存在」就返回 true,于是同步必然失败;
    // 新实现会探测,连不通就删掉重建。
    await Process.run(_adb, ['forward', '--remove', 'tcp:9091']);
    final bogus = await Process.run(
        _adb, ['forward', 'tcp:9091', 'tcp:1']); // 手机上的 1 端口没人听
    expect(bogus.exitCode, 0, reason: '前置条件:要能建出这个坏映射');
    expect(await SyncService.instance.adbForwardReachable(), isFalse,
        reason: '前置条件:这个映射应当连不通');

    SyncService.instance.messageNotifier.value = '';
    await tester.tap(_syncButton);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (SyncService.instance.statusNotifier.value == SyncStatus.idle &&
          SyncService.instance.messageNotifier.value.isNotEmpty) {
        break;
      }
    }

    final msg = SyncService.instance.messageNotifier.value;
    final forwards = await _adbForwardList();
    // ignore: avoid_print
    print('[测试] 坏映射场景 · 提示: $msg');
    // ignore: avoid_print
    print('[测试] 坏映射场景 · 转发: $forwards');

    // 坏映射必须被换掉,并且换成了能连通的
    expect(forwards.any((l) => l.contains('tcp:9091')), isTrue);
    expect(forwards.any((l) => l.endsWith('tcp:1')), isFalse,
        reason: '指向 tcp:1 的坏映射应该已经被替换掉');
    expect(await SyncService.instance.adbForwardReachable(), isTrue,
        reason: '点同步后应当自愈成一条能连通的转发');
    expect(SyncService.instance.statusNotifier.value, isNot(SyncStatus.error));
  });
}
