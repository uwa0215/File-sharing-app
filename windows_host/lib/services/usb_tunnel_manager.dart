import 'dart:async';
import 'dart:io';

import 'package:shared_protocol/shared_protocol.dart';

import 'lan_discovery_service.dart';
import 'native_tools_locator.dart';

/// Watches USB-attached Android (`adb.exe`) and iOS (`iproxy.exe`) devices
/// and maintains `localhost` port forwarding so transfers work without Wi-Fi.
class UsbTunnelManager {
  UsbTunnelManager({
    required this._locator,
    this.localPort = kDefaultTransferPort,
    this.remotePort = kDefaultTransferPort,
  });

  final NativeToolsLocator _locator;
  final int localPort;
  final int remotePort;

  Timer? _pollTimer;
  Process? _iproxyProcess;
  bool _polling = false;
  final Set<String> _reversedAndroidSerials = <String>{};
  final List<DiscoveredDevice> _usbDevices = <DiscoveredDevice>[];
  final StreamController<List<DiscoveredDevice>> _controller =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devicesStream => _controller.stream;
  List<DiscoveredDevice> get currentDevices =>
      List.unmodifiable(_usbDevices);

  void startPolling({Duration interval = const Duration(seconds: 3)}) {
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) => refreshNow());
    unawaited(refreshNow());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Scans connected Android ADB devices and starts iOS `iproxy` tunnel.
  Future<void> refreshNow() async {
    if (_polling) return;
    _polling = true;
    try {
      final found = <DiscoveredDevice>[];
      await _pollAndroidAdb(found);
      await _ensureIosIproxy(found);
      _usbDevices
        ..clear()
        ..addAll(found);
      if (!_controller.isClosed) {
        _controller.add(currentDevices);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollAndroidAdb(List<DiscoveredDevice> found) async {
    final adb = _locator.resolve(NativeToolKind.adb);
    if (!adb.isAvailable) return;

    try {
      final res = await Process.run(adb.resolvedPath!, ['devices', '-l']);
      if (res.exitCode != 0) return;

      final lines = res.stdout.toString().split(RegExp(r'\r?\n'));
      final onlineSerials = <String>{};

      for (final line in lines.skip(1)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 2 || parts[1] != 'device') continue;

        final serial = parts[0];
        onlineSerials.add(serial);

        if (!_reversedAndroidSerials.contains(serial)) {
          final fwd = await Process.run(
            adb.resolvedPath!,
            ['-s', serial, 'forward', 'tcp:$localPort', 'tcp:$remotePort'],
          );
          if (fwd.exitCode == 0) {
            _reversedAndroidSerials.add(serial);
          }
        }

        final modelMatch = RegExp(r'model:(\S+)').firstMatch(trimmed);
        final displayName = modelMatch?.group(1)?.replaceAll('_', ' ') ?? serial;

        found.add(
          DiscoveredDevice(
            id: 'adb-$serial',
            name: '$displayName (USB)',
            platform: DevicePlatform.android,
            transport: DeviceTransport.usbAndroid,
            host: '127.0.0.1',
            port: localPort,
            serial: serial,
          ),
        );
      }

      _reversedAndroidSerials.removeWhere((s) => !onlineSerials.contains(s));
    } catch (_) {
      // Ignore transient ADB startup errors.
    }
  }

  Future<void> _ensureIosIproxy(List<DiscoveredDevice> found) async {
    final iproxy = _locator.resolve(NativeToolKind.iproxy);
    if (!iproxy.isAvailable) return;

    if (_iproxyProcess == null) {
      try {
        _iproxyProcess = await Process.start(
          iproxy.resolvedPath!,
          ['$localPort:$remotePort'],
        );
        unawaited(
          _iproxyProcess!.exitCode.then((_) {
            _iproxyProcess = null;
          }),
        );
      } catch (_) {
        _iproxyProcess = null;
      }
    }

    if (_iproxyProcess != null) {
      found.add(
        DiscoveredDevice(
          id: 'ios-usbmuxd',
          name: 'iPhone / iPad (USB Tunnel)',
          platform: DevicePlatform.ios,
          transport: DeviceTransport.usbIos,
          host: '127.0.0.1',
          port: localPort,
        ),
      );
    }
  }

  Future<void> dispose() async {
    stopPolling();
    _iproxyProcess?.kill();
    _iproxyProcess = null;
    await _controller.close();
  }
}
