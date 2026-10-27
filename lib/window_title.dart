/// 把 Windows 窗口标题改成笔记名。
///
/// 为什么要自己调 user32:独立笔记窗口(一个笔记一个窗口)如果标题都叫
/// `moon_note`,任务栏里根本分不清哪个窗口是哪篇。而 Flutter 在 Windows 上
/// **不处理** `MaterialApp.title`(实测窗口标题一直是 runner 里写死的项目名),
/// 所以只能直接调 SetWindowTextW。
///
/// 关键细节:笔记窗口是**多个进程**,必须按「本进程的进程 id」挑窗口。
/// 用 FindWindow 会随便命中一个,可能把别的窗口的标题改掉。
/// 所以走 EnumWindows → GetWindowThreadProcessId 比对 → IsWindowVisible,
/// 只改属于自己、且可见的那一个顶层窗口。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hWnd, IntPtr lParam);
typedef _EnumWindowsNative = Int32 Function(
    Pointer<NativeFunction<_EnumWindowsProcNative>> lpEnumFunc, IntPtr lParam);
typedef _EnumWindowsDart = int Function(
    Pointer<NativeFunction<_EnumWindowsProcNative>> lpEnumFunc, int lParam);
typedef _GetWindowThreadProcessIdNative = Uint32 Function(
    IntPtr hWnd, Pointer<Uint32> lpdwProcessId);
typedef _GetWindowThreadProcessIdDart = int Function(
    int hWnd, Pointer<Uint32> lpdwProcessId);
typedef _IsWindowVisibleNative = Int32 Function(IntPtr hWnd);
typedef _IsWindowVisibleDart = int Function(int hWnd);
typedef _SetWindowTextWNative = Int32 Function(
    IntPtr hWnd, Pointer<Utf16> lpString);
typedef _SetWindowTextWDart = int Function(int hWnd, Pointer<Utf16> lpString);
typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

// 顶层 final 是惰性初始化的,非 Windows 平台不会去打开 user32.dll
final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _EnumWindowsDart _enumWindows =
    _user32.lookupFunction<_EnumWindowsNative, _EnumWindowsDart>(
        'EnumWindows');
final _GetWindowThreadProcessIdDart _getWindowThreadProcessId =
    _user32.lookupFunction<_GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
final _IsWindowVisibleDart _isWindowVisible =
    _user32.lookupFunction<_IsWindowVisibleNative, _IsWindowVisibleDart>(
        'IsWindowVisible');
final _SetWindowTextWDart _setWindowTextW =
    _user32.lookupFunction<_SetWindowTextWNative, _SetWindowTextWDart>(
        'SetWindowTextW');
final _GetCurrentProcessIdDart _getCurrentProcessId =
    _kernel32.lookupFunction<_GetCurrentProcessIdNative,
        _GetCurrentProcessIdDart>('GetCurrentProcessId');

int _targetPid = 0;
int _foundWindow = 0;

/// EnumWindows 的回调。**绝对不能抛异常**:FFI 回调里抛异常会直接把进程打崩,
/// 所以整个函数体包在 try/catch 里,出错就当没找到。
int _enumWindowsCallback(int hWnd, int lParam) {
  try {
    if (_foundWindow != 0) return 0;
    final pidPtr = calloc<Uint32>();
    // 注意:GetWindowThreadProcessId 的**返回值是线程 id**,进程 id 是写进
    // pidPtr 的。这里必须读指针,不能读返回值(踩过:读返回值时永远匹配不上,
    // 表现为窗口标题一直不变)。
    _getWindowThreadProcessId(hWnd, pidPtr);
    final pid = pidPtr.value;
    calloc.free(pidPtr);
    if (pid == _targetPid && _isWindowVisible(hWnd) != 0) {
      _foundWindow = hWnd;
      return 0; // 找到了,停止枚举
    }
  } catch (_) {
    // 忽略,继续枚举
  }
  return 1; // 继续枚举
}

/// 找本进程的顶层可见窗口句柄,找不到返回 0。
int _findOwnWindow() {
  _targetPid = _getCurrentProcessId();
  _foundWindow = 0;
  final callback =
      Pointer.fromFunction<_EnumWindowsProcNative>(_enumWindowsCallback, 1);
  _enumWindows(callback, 0);
  return _foundWindow;
}

/// 把当前进程的窗口标题设为 [title]。非 Windows 平台直接返回。
///
/// [retries] 用来处理「窗口还没创建好」:独立窗口刚启动时 Dart 已经跑起来了,
/// 但原生窗口可能还没 ShowWindow(实测第一次枚举扫到 300 多个窗口也找不到自己),
/// 过 250ms 再试就找到了。
Future<void> applyWindowTitle(
  String title, {
  int retries = 8,
  Duration interval = const Duration(milliseconds: 250),
}) async {
  if (!Platform.isWindows) return;
  final text = title.trim().isEmpty ? 'Moon Note' : title.trim();
  for (var i = 0; i < retries; i++) {
    try {
      final hwnd = _findOwnWindow();
      if (hwnd != 0) {
        final native = text.toNativeUtf16();
        try {
          _setWindowTextW(hwnd, native);
        } finally {
          malloc.free(native);
        }
        return;
      }
    } catch (_) {
      return; // 改标题失败不影响笔记功能,安静放弃
    }
    await Future<void>.delayed(interval);
  }
}
