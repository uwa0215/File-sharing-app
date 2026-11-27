import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' as dd;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../models/usb_device_models.dart';
import '../services/bluetooth_transfer_service.dart';
import '../services/qr_transfer_server.dart';
import '../services/usb_device_manager.dart';

enum _SendTargetKind { qrSession, usbDevice, bluetoothDevice }

class _SendTarget {
  const _SendTarget.qr()
      : kind = _SendTargetKind.qrSession,
        usbDevice = null,
        btDevice = null;
  const _SendTarget.usb(this.usbDevice)
      : kind = _SendTargetKind.usbDevice,
        btDevice = null;
  const _SendTarget.bluetooth(this.btDevice)
      : kind = _SendTargetKind.bluetoothDevice,
        usbDevice = null;

  final _SendTargetKind kind;
  final UsbPhoneDevice? usbDevice;
  final BluetoothDeviceInfo? btDevice;

  String get id => switch (kind) {
        _SendTargetKind.qrSession => 'qr',
        _SendTargetKind.usbDevice => 'usb:${usbDevice!.id}',
        _SendTargetKind.bluetoothDevice => 'bt:${btDevice!.address}',
      };

  String get label => switch (kind) {
        _SendTargetKind.qrSession => 'QR Code Session',
        _SendTargetKind.usbDevice => usbDevice!.name,
        _SendTargetKind.bluetoothDevice => btDevice!.name,
      };
}

class _DirectActivityEntry {
  const _DirectActivityEntry({
    required this.title,
    required this.subtitle,
    required this.succeeded,
  });

  final String title;
  final String subtitle;
  final bool succeeded;
}

/// Unified Easy Transfer dashboard combining:
/// 1. Live scannable QR code + auto-opening Transfer Window
/// 2. Zero-Wi-Fi Bluetooth direct OBEX send
/// 3. Zero-Wi-Fi USB cable instant send
class EasyTransferPanel extends StatefulWidget {
  const EasyTransferPanel({
    super.key,
    required this.qrServer,
    required this.usbManager,
    required this.bluetoothService,
    required this.onSwitchToUsbExplorer,
    this.enableNativeServices = true,
  });

  final QrTransferServer qrServer;
  final UsbDeviceManager usbManager;
  final BluetoothTransferService bluetoothService;
  final VoidCallback onSwitchToUsbExplorer;
  final bool enableNativeServices;

  @override
  State<EasyTransferPanel> createState() => _EasyTransferPanelState();
}

class _EasyTransferPanelState extends State<EasyTransferPanel> {
  StreamSubscription<void>? _qrStateSub;
  StreamSubscription<QrConnectedClient>? _qrScanSub;
  StreamSubscription<List<UsbPhoneDevice>>? _usbSub;
  StreamSubscription<BatchTransferProgress>? _usbProgressSub;
  StreamSubscription<BluetoothSendProgress>? _btProgressSub;

  List<LanInterfaceInfo> _interfaces = const [];
  String? _selectedIp;

  List<UsbPhoneDevice> _usbDevices = const [];
  List<BluetoothDeviceInfo> _btDevices = const [];
  String _selectedTargetId = 'qr';

  bool _dropHovering = false;
  bool _transferWindowOpen = false;
  bool _hasFirewallRule = true;
  bool _isPublicNetwork = false;
  String _networkProfileLabel = '';
  bool _checkingFirewall = false;
  bool _scanningBt = false;
  bool _directSending = false;

  String? _lastScannedBanner;
  String _directStatus =
      'Drop files or folders to share via QR code — or pick a USB / Bluetooth phone to send without Wi-Fi.';

  BatchTransferProgress _usbProgress = const BatchTransferProgress.idle();
  BluetoothSendProgress? _btProgress;
  final List<_DirectActivityEntry> _directLogs = [];

  @override
  void initState() {
    super.initState();
    _usbDevices = widget.usbManager.currentDevices;

    _qrStateSub = widget.qrServer.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _qrScanSub = widget.qrServer.deviceScannedStream.listen((client) {
      if (!mounted) return;
      setState(() {
        _lastScannedBanner =
            'Scanned & connected: ${client.deviceLabel} (${client.remoteAddress})';
        _selectedTargetId = 'qr';
      });
      if (!_transferWindowOpen) {
        _openDedicatedTransferWindow();
      }
    });
    _usbSub = widget.usbManager.devicesStream.listen((list) {
      if (!mounted) return;
      setState(() {
        _usbDevices = list;
        _validateSelectedTarget();
      });
    });
    _usbProgressSub = widget.usbManager.batchProgressStream.listen((p) {
      if (mounted) setState(() => _usbProgress = p);
    });
    _btProgressSub = widget.bluetoothService.progressStream.listen((p) {
      if (mounted) setState(() => _btProgress = p);
    });

    if (widget.enableNativeServices) {
      unawaited(_initServices());
    }
  }

  @override
  void dispose() {
    _qrStateSub?.cancel();
    _qrScanSub?.cancel();
    _usbSub?.cancel();
    _usbProgressSub?.cancel();
    _btProgressSub?.cancel();
    super.dispose();
  }

  Future<void> _initServices() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      await widget.qrServer.setReceiveDirectory(
        Directory(p.join(downloads.path, 'DeviceBridge')),
      );
    }
    await widget.qrServer.start();
    await Future.wait([
      _refreshInterfaces(),
      _refreshFirewallStatus(),
      _refreshBluetooth(inquiry: false),
    ]);
  }

  Future<void> _refreshInterfaces() async {
    final list = await widget.qrServer.discoverLanInterfaces();
    if (!mounted) return;
    setState(() {
      _interfaces = list;
      if (list.isNotEmpty &&
          (_selectedIp == null ||
              !list.any((iface) => iface.ipAddress == _selectedIp))) {
        _selectedIp = list.first.ipAddress;
      }
    });
  }

  Future<void> _refreshFirewallStatus() async {
    final status = await widget.qrServer.checkWindowsFirewallStatus();
    if (!mounted) return;
    setState(() {
      _hasFirewallRule = status.hasFirewallRule;
      _isPublicNetwork = status.isPublicNetwork;
      _networkProfileLabel = status.profileLabel;
    });
  }

  Future<void> _allowFirewallPressed() async {
    setState(() => _checkingFirewall = true);
    try {
      await widget.qrServer.requestFirewallAllowRule();
      await _refreshFirewallStatus();
    } finally {
      if (mounted) setState(() => _checkingFirewall = false);
    }
  }

  Future<void> _refreshBluetooth({required bool inquiry}) async {
    setState(() => _scanningBt = true);
    try {
      final list = await widget.bluetoothService.listDevices(
        includeAudio: false,
        inquiry: inquiry,
      );
      if (!mounted) return;
      setState(() {
        _btDevices = list;
        _validateSelectedTarget();
      });
    } finally {
      if (mounted) setState(() => _scanningBt = false);
    }
  }

  List<_SendTarget> get _targets => [
        const _SendTarget.qr(),
        for (final u in _usbDevices) _SendTarget.usb(u),
        for (final bt in _btDevices) _SendTarget.bluetooth(bt),
      ];

  _SendTarget get _activeTarget {
    for (final t in _targets) {
      if (t.id == _selectedTargetId) return t;
    }
    return const _SendTarget.qr();
  }

  void _validateSelectedTarget() {
    if (!_targets.any((t) => t.id == _selectedTargetId)) {
      _selectedTargetId = 'qr';
    }
  }

  Future<void> _handleDrop(dd.DropDetails details) async {
    setState(() => _dropHovering = false);
    final paths = <String>[];
    for (final item in details.items) {
      if (item is dd.DropFileItem && item.localPath != null) {
        paths.add(item.localPath!);
      } else if (item is dd.DropDirectoryItem && item.localPath != null) {
        paths.add(item.localPath!);
      }
    }
    if (paths.isNotEmpty) {
      await _sendPathsToActiveTarget(paths);
    }
  }

  Future<void> _pickFilesAndSend() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    final paths = res.paths.whereType<String>().toList();
    if (paths.isNotEmpty) {
      await _sendPathsToActiveTarget(paths);
    }
  }

  Future<void> _pickFolderAndSend() async {
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder to transfer',
    );
    if (folder != null) {
      await _sendPathsToActiveTarget([folder]);
    }
  }

  Future<void> _sendPathsToActiveTarget(List<String> paths) async {
    final target = _activeTarget;

    if (target.kind == _SendTargetKind.qrSession) {
      final count = await widget.qrServer.addOutboxPaths(paths);
      if (!mounted) return;
      setState(() {
        _directStatus =
            'Added $count file(s) to QR Transfer Window — scan QR on your phone to download.';
      });
      return;
    }

    if (_directSending) return;
    setState(() {
      _directSending = true;
      _btProgress = null;
      _directStatus = 'Sending ${paths.length} item(s) to ${target.label}...';
    });

    try {
      if (target.kind == _SendTargetKind.usbDevice) {
        final usb = target.usbDevice!;
        final summary = await widget.usbManager.pushLocalPaths(
          device: usb,
          localPaths: paths,
          targetFolderId: '',
        );
        if (!mounted) return;
        final msg = summary.cancelled
            ? 'Cancelled USB transfer.'
            : 'Sent ${summary.succeededCount} file(s) (${formatByteCount(summary.bytesTransferred)}) via USB to ${usb.name}.';
        setState(() {
          _directStatus = msg;
          _directLogs.insert(
            0,
            _DirectActivityEntry(
              title: '${usb.name} (USB)',
              subtitle: msg,
              succeeded: !summary.cancelled && summary.failureCount == 0,
            ),
          );
        });
      } else {
        final bt = target.btDevice!;
        final res = await widget.bluetoothService.sendPaths(
          device: bt,
          localPaths: paths,
        );
        if (!mounted) return;
        final msg = res.cancelled
            ? 'Cancelled Bluetooth transfer.'
            : res.succeededCount > 0
                ? 'Sent ${res.succeededCount} file(s) (${formatByteCount(res.bytesTransferred)}) via Bluetooth to ${bt.name}.'
                : (res.firstError ?? 'Bluetooth send failed.');
        setState(() {
          _directStatus = msg;
          _directLogs.insert(
            0,
            _DirectActivityEntry(
              title: '${bt.name} (Bluetooth)',
              subtitle: msg,
              succeeded: res.succeededCount > 0 && res.failureCount == 0,
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _directStatus = 'Transfer failed: $e';
        _directLogs.insert(
          0,
          _DirectActivityEntry(
            title: target.label,
            subtitle: e.toString(),
            succeeded: false,
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _directSending = false;
          _btProgress = null;
        });
      }
    }
  }

  Future<void> _cancelDirectSend() async {
    if (_activeTarget.kind == _SendTargetKind.usbDevice) {
      await widget.usbManager.cancelActiveBatch();
    } else if (_activeTarget.kind == _SendTargetKind.bluetoothDevice) {
      await widget.bluetoothService.cancelSend();
    }
  }

  Future<void> _chooseReceiveFolder() async {
    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Windows folder for incoming files',
    );
    if (dirPath != null) {
      await widget.qrServer.setReceiveDirectory(Directory(dirPath));
    }
  }

  Future<void> _openFolderInExplorer(String path) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', [path]);
  }

  Future<void> _revealFileInExplorer(String filePath) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', ['/select,$filePath']);
  }

  void _openDedicatedTransferWindow() {
    if (_transferWindowOpen) return;
    _transferWindowOpen = true;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 880,
            height: 640,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.qr_code_2, color: Color(0xFF38BDF8)),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'QR File Transfer Window',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Chip(
                        avatar: Icon(
                          widget.qrServer.connectedClients.isNotEmpty
                              ? Icons.verified
                              : Icons.qr_code_scanner,
                          size: 16,
                          color: widget.qrServer.connectedClients.isNotEmpty
                              ? Colors.tealAccent
                              : Colors.amberAccent,
                        ),
                        label: Text(
                          widget.qrServer.connectedClients.isNotEmpty
                              ? '${widget.qrServer.connectedClients.length} device connected'
                              : 'Waiting for QR scan',
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close Transfer Window',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: StreamBuilder<void>(
                    stream: widget.qrServer.stateStream,
                    builder: (context, _) =>
                        _buildTransferWindowContent(inModal: true),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _transferWindowOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeIp = _selectedIp ?? '127.0.0.1';
    final qrUrl = widget.qrServer.buildQrUrl(activeIp);
    final clients = widget.qrServer.connectedClients;

    return Row(
      children: [
        // Left Column: QR Code Scanner + Quick Unblock Tools + Save Folder
        SizedBox(
          width: 380,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Scan QR Code to Connect',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Scan with iPhone/Android Camera to open a live two-way transfer window — no phone app needed.',
                  style: TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.25),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: qrUrl,
                      version: QrVersions.auto,
                      size: 196,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                if (_interfaces.isNotEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedIp,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Hotspot / Wi-Fi IP',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          items: _interfaces
                              .map(
                                (iface) => DropdownMenuItem(
                                  value: iface.ipAddress,
                                  child: Text(
                                    iface.displayLabel,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (ip) {
                            if (ip != null) setState(() => _selectedIp = ip);
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: _refreshInterfaces,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh Network Adapters',
                      ),
                    ],
                  ),
                const SizedBox(height: 8),

                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          qrUrl,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 17),
                        tooltip: 'Copy QR URL',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: qrUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Copied QR URL'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.lock_reset, size: 17),
                        tooltip: 'New QR Code Token',
                        onPressed: widget.qrServer.regenerateToken,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // Connection status + Open Transfer Window
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: clients.isNotEmpty
                        ? const Color(0xFF14B8A6).withValues(alpha: 0.14)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: clients.isNotEmpty
                          ? const Color(0xFF14B8A6).withValues(alpha: 0.5)
                          : Colors.white12,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            clients.isNotEmpty
                                ? Icons.verified
                                : Icons.qr_code_scanner,
                            size: 18,
                            color: clients.isNotEmpty
                                ? Colors.tealAccent
                                : Colors.amberAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              clients.isNotEmpty
                                  ? '${clients.length} Device(s) Connected via QR'
                                  : (_lastScannedBanner ??
                                      'Waiting for phone scan...'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (clients.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final c in clients)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(Icons.devices, size: 14),
                                label: Text(
                                    '${c.deviceLabel} (${c.remoteAddress})'),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          FilledButton.icon(
                            onPressed: _openDedicatedTransferWindow,
                            icon: const Icon(Icons.open_in_new, size: 17),
                            label: const Text('Open Transfer Window'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                widget.qrServer.openMobileHotspotSettings,
                            icon: const Icon(Icons.wifi_tethering, size: 17),
                            label: const Text('Hotspot'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                if (widget.enableNativeServices && !_hasFirewallRule) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.amberAccent.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isPublicNetwork
                              ? 'Firewall ($_networkProfileLabel) may block QR scans'
                              : 'Allow Windows Firewall for QR scans',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            color: Colors.amberAccent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Click below to allow incoming phone scans — or turn on Windows Hotspot (no router needed).',
                          style: TextStyle(fontSize: 11.5, color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            onPressed: _checkingFirewall
                                ? null
                                : _allowFirewallPressed,
                            icon: const Icon(Icons.shield_outlined, size: 17),
                            label: Text(
                              _checkingFirewall
                                  ? 'Waiting for UAC...'
                                  : 'Allow Windows Firewall Access',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // Incoming Save Folder Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Windows Save Folder (Incoming Files)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.qrServer.receiveDir.path,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.white70,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _chooseReceiveFolder,
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: const Text('Change'),
                          ),
                          TextButton.icon(
                            onPressed: () => _openFolderInExplorer(
                              widget.qrServer.receiveDir.path,
                            ),
                            icon: const Icon(Icons.launch, size: 16),
                            label: const Text('Open Folder'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),

        // Right Column: Unified Transfer Window
        Expanded(
          child: _buildTransferWindowContent(inModal: false),
        ),
      ],
    );
  }

  Widget _buildTransferWindowContent({required bool inModal}) {
    final target = _activeTarget;
    final shared = widget.qrServer.sharedFiles;
    final qrRecords = widget.qrServer.transferRecords;

    final btAppleSelected =
        target.kind == _SendTargetKind.bluetoothDevice &&
        target.btDevice!.isLikelyApple;
    final usbReadOnlySelected =
        target.kind == _SendTargetKind.usbDevice &&
        !target.usbDevice!.canWriteFiles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top Target Bar (QR Session + USB Phones + Paired Bluetooth Phones)
        if (!inModal)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Transfer Target:',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                      ),
                    ),
                    ChoiceChip(
                      selected: _selectedTargetId == 'qr',
                      avatar: const Icon(Icons.qr_code_2,
                          size: 17, color: Color(0xFF38BDF8)),
                      label: Text(
                        widget.qrServer.connectedClients.isNotEmpty
                            ? 'QR Session (${widget.qrServer.connectedClients.length} connected)'
                            : 'QR Code Session',
                      ),
                      onSelected: (_) =>
                          setState(() => _selectedTargetId = 'qr'),
                    ),
                    for (final u in _usbDevices)
                      ChoiceChip(
                        selected: _selectedTargetId == 'usb:${u.id}',
                        avatar: Icon(
                          u.os == MobileOs.ios
                              ? Icons.phone_iphone
                              : Icons.phone_android,
                          size: 17,
                          color: Colors.tealAccent,
                        ),
                        label: Text('${u.name} • USB'),
                        onSelected: (_) =>
                            setState(() => _selectedTargetId = 'usb:${u.id}'),
                      ),
                    for (final bt in _btDevices)
                      ChoiceChip(
                        selected: _selectedTargetId == 'bt:${bt.address}',
                        avatar: Icon(
                          Icons.bluetooth,
                          size: 17,
                          color: bt.isLikelyApple
                              ? Colors.amberAccent
                              : Colors.tealAccent,
                        ),
                        label: Text(
                          '${bt.name} • Bluetooth${bt.isLikelyApple ? " (No iOS BT)" : ""}',
                        ),
                        onSelected: (_) => setState(
                            () => _selectedTargetId = 'bt:${bt.address}'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _scanningBt
                          ? null
                          : () => _refreshBluetooth(inquiry: true),
                      icon: const Icon(Icons.bluetooth_searching, size: 16),
                      label:
                          Text(_scanningBt ? 'Scanning...' : 'Scan Bluetooth'),
                    ),
                    OutlinedButton.icon(
                      onPressed: widget.bluetoothService.openBluetoothSettings,
                      icon: const Icon(Icons.settings_bluetooth, size: 16),
                      label: const Text('Pair Device'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: widget.bluetoothService.openReceiveWizard,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Receive Bluetooth'),
                    ),
                    if (_usbDevices.isNotEmpty)
                      TextButton.icon(
                        onPressed: widget.onSwitchToUsbExplorer,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Browse USB Phone'),
                      ),
                  ],
                ),
              ],
            ),
          ),

        // Middle Area: Drop & Send Window + Shared QR Outbox
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.upload_file,
                        color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        target.kind == _SendTargetKind.qrSession
                            ? 'Transfer Window — Shared to QR Devices (${shared.length})'
                            : 'Instant Send to ${target.label} (No Wi-Fi)',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _directSending ? null : _pickFilesAndSend,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(target.kind == _SendTargetKind.qrSession
                          ? 'Add Files'
                          : 'Send Files Now'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _directSending ? null : _pickFolderAndSend,
                      icon: const Icon(Icons.create_new_folder_outlined,
                          size: 18),
                      label: const Text('Add Folder'),
                    ),
                    if (target.kind == _SendTargetKind.qrSession &&
                        shared.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: widget.qrServer.clearOutbox,
                        child: const Text('Clear'),
                      ),
                    ],
                    if (!inModal) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: _openDedicatedTransferWindow,
                        icon: const Icon(Icons.open_in_full, size: 18),
                        tooltip: 'Expand Transfer Window',
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _wrapDropZone(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _dropHovering
                            ? const Color(0xFF0EA5E9).withValues(alpha: 0.14)
                            : const Color(0xFF0B1120),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _dropHovering
                              ? const Color(0xFF38BDF8)
                              : Colors.white.withValues(alpha: 0.12),
                          width: _dropHovering ? 2 : 1,
                        ),
                      ),
                      child: (target.kind == _SendTargetKind.qrSession &&
                              shared.isNotEmpty)
                          ? ListView.builder(
                              itemCount: shared.length,
                              itemExtent: 58,
                              itemBuilder: (ctx, i) {
                                final item = shared[i];
                                return ListTile(
                                  leading: const Icon(
                                    Icons.insert_drive_file_outlined,
                                    color: Color(0xFF38BDF8),
                                  ),
                                  title: Text(
                                    item.relativePath,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${formatByteCount(item.sizeBytes)} • Ready on scanned device',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white60,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () =>
                                        widget.qrServer.removeOutboxFile(
                                      item.id,
                                    ),
                                  ),
                                );
                              },
                            )
                          : Center(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _dropHovering
                                          ? Icons.file_download_outlined
                                          : target.kind ==
                                                  _SendTargetKind.qrSession
                                              ? Icons.cloud_upload_outlined
                                              : target.kind ==
                                                      _SendTargetKind.usbDevice
                                                  ? Icons.usb
                                                  : Icons.bluetooth_connected,
                                      size: 44,
                                      color: (btAppleSelected ||
                                              usbReadOnlySelected)
                                          ? Colors.amberAccent
                                          : const Color(0xFF38BDF8),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _dropHovering
                                          ? 'Release to send to ${target.label}'
                                          : 'Drag & Drop Files or Folders Here',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      btAppleSelected
                                          ? 'Apple iOS blocks Bluetooth file transfer. Use QR Code Session or USB Cable instead.'
                                          : usbReadOnlySelected
                                              ? 'iPhone USB (PTP) only reads photos/videos to Windows. Click "Browse USB Phone" above or use QR Code Session.'
                                              : _directStatus,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        color: Colors.white60,
                                      ),
                                    ),
                                    if (_directSending) ...[
                                      const SizedBox(height: 16),
                                      SizedBox(
                                        width: 380,
                                        child: Column(
                                          children: [
                                            LinearProgressIndicator(
                                              value: _usbProgress.active
                                                  ? _usbProgress.fraction
                                                  : _btProgress?.fraction,
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _usbProgress.active
                                                        ? '${_usbProgress.completedFiles}/${_usbProgress.totalFiles} • ${_usbProgress.formattedSpeed} • ${_usbProgress.currentFileName}'
                                                        : _btProgress != null
                                                            ? 'Bluetooth: ${_btProgress!.completedFiles}/${_btProgress!.totalFiles} • ${formatByteCount(_btProgress!.bytesTransferred)} / ${formatByteCount(_btProgress!.totalBytes)}'
                                                            : 'Sending...',
                                                    style: const TextStyle(
                                                        fontSize: 12),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: _cancelDirectSend,
                                                  child: const Text('Cancel'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const Divider(height: 1),

        // Bottom Area: Unified Live Activity (QR Incoming/Outgoing + Bluetooth/USB Logs)
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Row(
                  children: [
                    const Icon(Icons.swap_vert,
                        color: Colors.tealAccent, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Live Transfer Activity (${qrRecords.length + _directLogs.length})',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (qrRecords.isNotEmpty || _directLogs.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          widget.qrServer.clearCompletedRecords();
                          setState(_directLogs.clear);
                        },
                        child: const Text('Clear Finished'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: (qrRecords.isEmpty && _directLogs.isEmpty)
                    ? const Center(
                        child: Text(
                          'Incoming QR files from phones, QR downloads, and Bluetooth/USB transfers will appear live here.',
                          style: TextStyle(fontSize: 12.5, color: Colors.white60),
                        ),
                      )
                    : ListView.builder(
                        itemCount: qrRecords.length + _directLogs.length,
                        itemBuilder: (ctx, idx) {
                          if (idx < qrRecords.length) {
                            final rec = qrRecords[idx];
                            final fromPhone =
                                rec.direction == QrTransferDirection.fromDevice;
                            final savedPath = rec.savedPath;

                            Widget tile = ListTile(
                              dense: true,
                              leading: Icon(
                                fromPhone ? Icons.download : Icons.upload,
                                color: switch (rec.state) {
                                  QrTransferState.transferring =>
                                    const Color(0xFF38BDF8),
                                  QrTransferState.completed => Colors.tealAccent,
                                  QrTransferState.failed => Colors.redAccent,
                                },
                              ),
                              title: Text(
                                rec.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    rec.state == QrTransferState.failed
                                        ? (rec.error ?? 'Failed')
                                        : 'QR • ${fromPhone ? "From device" : "To device"} • '
                                            '${formatByteCount(rec.transferredBytes)}'
                                            '${rec.totalBytes > 0 ? " / ${formatByteCount(rec.totalBytes)}" : ""}',
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                  if (rec.state == QrTransferState.transferring)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: LinearProgressIndicator(
                                        value: rec.totalBytes > 0
                                            ? rec.fraction
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                              trailing: (savedPath != null &&
                                      rec.state == QrTransferState.completed)
                                  ? IconButton(
                                      icon: const Icon(Icons.folder_open,
                                          size: 18),
                                      tooltip: 'Show in File Explorer',
                                      onPressed: () =>
                                          _revealFileInExplorer(savedPath),
                                    )
                                  : null,
                            );

                            if (widget.enableNativeServices &&
                                savedPath != null &&
                                rec.state == QrTransferState.completed) {
                              tile = DragItemWidget(
                                dragItemProvider: (_) async {
                                  final item =
                                      DragItem(suggestedName: rec.fileName);
                                  item.add(
                                      Formats.fileUri(File(savedPath).uri));
                                  return item;
                                },
                                allowedOperations: () =>
                                    const [DropOperation.copy],
                                child: DraggableWidget(child: tile),
                              );
                            }
                            return tile;
                          }

                          final log = _directLogs[idx - qrRecords.length];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              log.succeeded
                                  ? Icons.check_circle
                                  : Icons.error_outline,
                              color: log.succeeded
                                  ? Colors.tealAccent
                                  : Colors.redAccent,
                            ),
                            title: Text(log.title),
                            subtitle: Text(log.subtitle),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _wrapDropZone({required Widget child}) {
    if (!widget.enableNativeServices) return child;
    return dd.DropTarget(
      onEnter: (_) => setState(() => _dropHovering = true),
      onLeave: () => setState(() => _dropHovering = false),
      onDrop: _handleDrop,
      child: child,
    );
  }
}
