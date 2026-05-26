import 'package:flutter/material.dart';
import 'sync_service.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final SyncService _sync = SyncService.instance;
  bool _isSyncing = false;
  List<String> _ips = [];
  List<String> _adbDevices = [];
  bool _adbReversed = false;
  final ValueNotifier<String> _adbDevicesText =
      ValueNotifier('未检测');

  Color get _onSurface => Theme.of(context).colorScheme.onSurface;
  Color get _onSurfaceVariant =>
      Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _outline => Theme.of(context).colorScheme.outline;
  Color get _outlineVariant => Theme.of(context).colorScheme.outlineVariant;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _error => Theme.of(context).colorScheme.error;

  @override
  void initState() {
    super.initState();
    _sync.statusNotifier.addListener(_onStatusChange);
    _sync.messageNotifier.addListener(_onMessageChange);
    _portController.text = '9090';
    _loadIps();
    _loadLastConnection();
  }

  Future<void> _loadLastConnection() async {
    final info = await _sync.getLastConnection();
    if (mounted && info['host'] != null) {
      _hostController.text = info['host']!;
      if (info['port'] != null) _portController.text = info['port']!;
    }
  }

  Future<void> _loadIps() async {
    final ips = await _sync.getLocalIps();
    if (mounted) setState(() => _ips = ips);
  }

  @override
  void dispose() {
    _sync.statusNotifier.removeListener(_onStatusChange);
    _sync.messageNotifier.removeListener(_onMessageChange);
    _hostController.dispose();
    _portController.dispose();
    _adbDevicesText.dispose();
    super.dispose();
  }

  void _onStatusChange() {
    if (mounted) setState(() {});
  }

  void _onMessageChange() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleServer() async {
    if (_sync.isServerRunning) {
      await _sync.stopServer();
    } else {
      final port = int.tryParse(_portController.text) ?? 9090;
      try {
        await _sync.startServer(port: port);
        await _loadIps();
      } catch (_) {
        // Error already set in service messageNotifier
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _doSync([String? host]) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      final h = host ?? _hostController.text.trim();
      final port = int.tryParse(_portController.text) ?? 9090;
      await _sync.fullSync(h, port);
    } catch (_) {
      // Error already handled in service
    }
    if (mounted) setState(() => _isSyncing = false);
  }

  Future<void> _detectAdbDevices() async {
    final devices = await _sync.getAdbDevices();
    _adbDevices = devices;
    if (devices.isEmpty) {
      _adbDevicesText.value = '未检测到设备（请确保手机已 USB 连接并开启调试）';
    } else {
      _adbDevicesText.value = devices.join('\n');
    }
  }

  Future<void> _setupAdbReverse() async {
    final port = int.tryParse(_portController.text) ?? 9090;
    final ok = await _sync.setupAdbReverse(port: port);
    if (mounted) {
      setState(() => _adbReversed = ok);
      _adbDevicesText.value = ok
          ? '端口映射成功：localhost:$port → PC:$port'
          : '映射失败，请确认 ADB 已连接';
    }
  }

  Future<void> _removeAdbReverse() async {
    final port = int.tryParse(_portController.text) ?? 9090;
    await _sync.removeAdbReverse(port: port);
    if (mounted) {
      setState(() => _adbReversed = false);
      _adbDevicesText.value =
          _adbDevices.isNotEmpty ? _adbDevices.join('\n') : '未检测';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _onSurface, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('局域网同步',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _onSurface)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child:
              Divider(height: 0.5, thickness: 0.5, color: _outlineVariant),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Server section
          _sectionHeader('本机服务'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _sync.isServerRunning
                          ? Icons.cloud_done
                          : Icons.cloud_off,
                      size: 20,
                      color: _sync.isServerRunning
                          ? _onSurface
                          : _outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _sync.isServerRunning ? '服务运行中' : '服务已停止',
                      style: TextStyle(
                        fontSize: 15,
                        color: _onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    Text('端口',
                        style: TextStyle(
                            fontSize: 12, color: _outline)),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 60,
                      height: 32,
                      child: TextField(
                        controller: _portController,
                        keyboardType: TextInputType.number,
                        enabled: !_sync.isServerRunning,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 14, color: _onSurface),
                        decoration: InputDecoration(
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(6),
                            borderSide: BorderSide(
                                color: _outlineVariant),
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _smallBtn(
                      _sync.isServerRunning ? '停止' : '启动',
                      _toggleServer,
                      isPrimary: !_sync.isServerRunning,
                    ),
                  ],
                ),
                if (_ips.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('本机 IP 地址：',
                      style: TextStyle(
                          fontSize: 12, color: _outline)),
                  const SizedBox(height: 4),
                  ..._ips.map((ip) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(ip,
                            style: TextStyle(
                                fontSize: 14,
                                color: _onSurfaceVariant,
                                fontFamily: 'monospace')),
                      )),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('IP 地址获取中...',
                        style: TextStyle(
                            fontSize: 13, color: _outline)),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // USB sync section
          _sectionHeader('USB 数据线同步'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('ADB 设备',
                        style: TextStyle(
                            fontSize: 14,
                            color: _onSurface,
                            fontWeight: FontWeight.w500)),
                    const Spacer(),
                    _smallBtn('检测', _detectAdbDevices),
                  ],
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: _adbDevicesText,
                  builder: (context, val, _) => Text(val,
                      style: TextStyle(
                          fontSize: 13,
                          color: _adbDevices.isNotEmpty
                              ? _onSurfaceVariant
                              : _outline)),
                ),
                if (_adbDevices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _smallBtn(
                        _adbReversed
                            ? '已映射'
                            : '设置端口映射',
                        _adbReversed ? null : _setupAdbReverse,
                      ),
                      const SizedBox(width: 8),
                      if (_adbReversed)
                        _smallBtn('取消映射', _removeAdbReverse),
                      const SizedBox(width: 8),
                      if (_adbReversed)
                        _smallBtn('同步',
                            () => _doSync('127.0.0.1'),
                            isPrimary: true),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Client section
          _sectionHeader('连接设备'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _hostController,
                        decoration: InputDecoration(
                          hintText: 'IP 地址',
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(6),
                            borderSide: BorderSide(
                                color: _outlineVariant),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                          isDense: true,
                          hintStyle: TextStyle(
                              fontSize: 14, color: _outline),
                        ),
                        style: TextStyle(
                            fontSize: 14, color: _onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: _portController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          hintText: '端口',
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(6),
                            borderSide: BorderSide(
                                color: _outlineVariant),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                          isDense: true,
                          hintStyle: TextStyle(
                              fontSize: 14, color: _outline),
                        ),
                        style: TextStyle(
                            fontSize: 14, color: _onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _smallBtn(
                      '连接',
                      _isSyncing ? null : _doSync,
                      isPrimary: true,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Status
          Center(
            child: ValueListenableBuilder<String>(
              valueListenable: _sync.messageNotifier,
              builder: (context, msg, _) {
                final isError =
                    _sync.statusNotifier.value == SyncStatus.error;
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    msg.isEmpty ? '准备就绪' : msg,
                    style: TextStyle(
                      fontSize: 13,
                      color: isError ? _error : _outline,
                    ),
                  ),
                );
              },
            ),
          ),

          if (_isSyncing) ...[
            const SizedBox(height: 12),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(title,
        style: TextStyle(
            fontSize: 12,
            color: _outline,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5));
  }

  Widget _smallBtn(String label, VoidCallback? onTap,
      {bool isPrimary = false}) {
    return SizedBox(
      height: 32,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              isPrimary ? _onSurface : Colors.transparent,
          foregroundColor:
              isPrimary ? _surface : _onSurfaceVariant,
          elevation: 0,
          padding:
              const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: isPrimary
                ? BorderSide.none
                : BorderSide(color: _outlineVariant),
          ),
          minimumSize: Size.zero,
        ),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}
