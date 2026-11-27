import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart' as dd;
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../models/usb_device_models.dart';
import '../services/bluetooth_transfer_service.dart';
import '../services/usb_device_manager.dart';

class _InstantTargetSelection {
  const _InstantTargetSelection.usb(this.usbDevice) : btDevice = null;
  const _InstantTargetSelection.bluetooth(this.btDevice) : usbDevice = null;

  final UsbPhoneDevice? usbDevice;
  final BluetoothDeviceInfo? btDevice;

  bool get isUsb => usbDevice != null;
  String get id =>
      usbDevice != null ? 'usb:${usbDevice!.id}' : 'bt:${btDevice!.address}';
  String get displayName => usbDevice?.name ?? btDevice!.name;
}

class _InstantSendLogEntry {
  const _InstantSendLogEntry({
    required this.title,
    required this.subtitle,
    required this.succeeded,
  });

  final String title;
  final String subtitle;
  final bool succeeded;
}

/// Zero-Wi-Fi Instant Send workspace combining USB Cable & Bluetooth OBEX Push.
/// Pick any paired Bluetooth or plugged USB device and drop files to send immediately.
class InstantSendPanel extends StatefulWidget {
  const InstantSendPanel({
    super.key,
    required this.usbManager,
    required this.bluetoothService,
    required this.onSwitchToUsbExplorer,
    this.enableNativeServices = true,
  });

  final UsbDeviceManager usbManager;
  final BluetoothTransferService bluetoothService;
  final VoidCallback onSwitchToUsbExplorer;
  final bool enableNativeServices;

  @override
  State<InstantSendPanel> createState() => _InstantSendPanelState();
}

class _InstantSendPanelState extends State<InstantSendPanel> {
  StreamSubscription<List<UsbPhoneDevice>>? _usbSub;
  StreamSubscription<BatchTransferProgress>? _usbProgressSub;
  StreamSubscription<BluetoothSendProgress>? _btProgressSub;

  List<UsbPhoneDevice> _usbDevices = const [];
  List<BluetoothDeviceInfo> _btDevices = const [];
  String? _selectedTargetId;

  bool _scanningBt = false;
  bool _showAudioBt = false;
  bool _dropHovering = false;
  bool _sending = false;
  String _statusText =
      'Select a USB or Bluetooth device above, then drop files to send immediately — no Wi-Fi required.';

  BatchTransferProgress _usbProgress = const BatchTransferProgress.idle();
  BluetoothSendProgress? _btProgress;
  final List<_InstantSendLogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    _usbDevices = widget.usbManager.currentDevices;
    _usbSub = widget.usbManager.devicesStream.listen((list) {
      if (!mounted) return;
      setState(() {
        _usbDevices = list;
        _ensureSelection();
      });
    });
    _usbProgressSub = widget.usbManager.batchProgressStream.listen((p) {
      if (mounted) setState(() => _usbProgress = p);
    });
    _btProgressSub = widget.bluetoothService.progressStream.listen((p) {
      if (mounted) setState(() => _btProgress = p);
    });

    if (widget.enableNativeServices) {
      unawaited(_refreshBluetooth(inquiry: false));
    }
    _ensureSelection();
  }

  @override
  void dispose() {
    _usbSub?.cancel();
    _usbProgressSub?.cancel();
    _btProgressSub?.cancel();
    super.dispose();
  }

  List<_InstantTargetSelection> get _allTargets {
    return [
      for (final u in _usbDevices) _InstantTargetSelection.usb(u),
      for (final b in _btDevices) _InstantTargetSelection.bluetooth(b),
    ];
  }

  _InstantTargetSelection? get _selectedTarget {
    final targets = _allTargets;
    if (targets.isEmpty) return null;
    if (_selectedTargetId != null) {
      for (final t in targets) {
        if (t.id == _selectedTargetId) return t;
      }
    }
    return targets.first;
  }

  void _ensureSelection() {
    final targets = _allTargets;
    if (targets.isEmpty) {
      _selectedTargetId = null;
      return;
    }
    if (_selectedTargetId == null ||
        !targets.any((t) => t.id == _selectedTargetId)) {
      _selectedTargetId = targets.first.id;
    }
  }

  Future<void> _refreshBluetooth({required bool inquiry}) async {
    setState(() {
      _scanningBt = true;
      if (inquiry) {
        _statusText = 'Scanning nearby Bluetooth devices...';
      }
    });
    try {
      final list = await widget.bluetoothService.listDevices(
        includeAudio: _showAudioBt,
        inquiry: inquiry,
      );
      if (!mounted) return;
      setState(() {
        _btDevices = list;
        _ensureSelection();
        if (inquiry) {
          _statusText =
              'Found ${list.length} Bluetooth device(s). Select one and drop files to send!';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = 'Bluetooth scan error: $e');
      }
    } finally {
      if (mounted) setState(() => _scanningBt = false);
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
      await _sendPathsImmediately(paths);
    }
  }

  Future<void> _pickFilesAndSend() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    final paths = res.paths.whereType<String>().toList();
    if (paths.isNotEmpty) {
      await _sendPathsImmediately(paths);
    }
  }

  Future<void> _pickFolderAndSend() async {
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder to send immediately (No Wi-Fi)',
    );
    if (folder != null) {
      await _sendPathsImmediately([folder]);
    }
  }

  Future<void> _sendPathsImmediately(List<String> paths) async {
    final target = _selectedTarget;
    if (target == null) {
      setState(() {
        _statusText =
            'Plug in a phone via USB or select a paired Bluetooth phone first.';
      });
      return;
    }
    if (_sending) return;

    setState(() {
      _sending = true;
      _btProgress = null;
      _statusText =
          'Sending ${paths.length} item(s) immediately to ${target.displayName}...';
    });

    try {
      if (target.isUsb) {
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
          _statusText = msg;
          _logs.insert(
            0,
            _InstantSendLogEntry(
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
            ? 'Cancelled Bluetooth send.'
            : res.succeededCount > 0
                ? 'Sent ${res.succeededCount} file(s) (${formatByteCount(res.bytesTransferred)}) via Bluetooth to ${bt.name}.'
                : (res.firstError ?? 'Bluetooth send failed.');
        setState(() {
          _statusText = msg;
          _logs.insert(
            0,
            _InstantSendLogEntry(
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
        _statusText = 'Send failed: $e';
        _logs.insert(
          0,
          _InstantSendLogEntry(
            title: target.displayName,
            subtitle: e.toString(),
            succeeded: false,
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _btProgress = null;
        });
      }
    }
  }

  Future<void> _cancelSend() async {
    final target = _selectedTarget;
    if (target?.isUsb == true) {
      await widget.usbManager.cancelActiveBatch();
    } else {
      await widget.bluetoothService.cancelSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _selectedTarget;
    final btAppleSelected = target?.btDevice?.isLikelyApple == true;
    final usbReadOnlySelected =
        target?.usbDevice != null && !target!.usbDevice!.canWriteFiles;

    return Column(
      children: [
        // Top Target Device Bar (USB + Bluetooth — Zero Wi-Fi)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    'Send Target (No Wi-Fi):',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                  for (final u in _usbDevices)
                    ChoiceChip(
                      selected: target?.id == 'usb:${u.id}',
                      avatar: Icon(
                        u.os == MobileOs.ios
                            ? Icons.phone_iphone
                            : Icons.phone_android,
                        size: 17,
                        color: const Color(0xFF38BDF8),
                      ),
                      label: Text('${u.name} • USB (${u.backendBadge})'),
                      onSelected: (_) =>
                          setState(() => _selectedTargetId = 'usb:${u.id}'),
                    ),
                  for (final bt in _btDevices)
                    ChoiceChip(
                      selected: target?.id == 'bt:${bt.address}',
                      avatar: Icon(
                        bt.deviceKind == 'phone'
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth,
                        size: 17,
                        color: bt.isLikelyApple
                            ? Colors.amberAccent
                            : Colors.tealAccent,
                      ),
                      label: Text(
                        '${bt.name} • Bluetooth${bt.isLikelyApple ? " (iOS blocks BT)" : ""}',
                      ),
                      onSelected: (_) =>
                          setState(() => _selectedTargetId = 'bt:${bt.address}'),
                    ),
                  if (_usbDevices.isEmpty && _btDevices.isEmpty)
                    const Text(
                      'No USB or Bluetooth phone detected yet.',
                      style: TextStyle(fontSize: 12.5, color: Colors.amberAccent),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _scanningBt
                        ? null
                        : () => _refreshBluetooth(inquiry: true),
                    icon: const Icon(Icons.bluetooth_searching, size: 17),
                    label: Text(
                      _scanningBt
                          ? 'Scanning Bluetooth...'
                          : 'Scan Nearby Bluetooth',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.bluetoothService.openBluetoothSettings,
                    icon: const Icon(Icons.settings_bluetooth, size: 17),
                    label: const Text('Pair New Device'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: widget.bluetoothService.openReceiveWizard,
                    icon: const Icon(Icons.download, size: 17),
                    label: const Text('Receive from Phone (Bluetooth)'),
                  ),
                  TextButton.icon(
                    onPressed: widget.onSwitchToUsbExplorer,
                    icon: const Icon(Icons.folder_open, size: 17),
                    label: const Text('Browse Phone Files (USB)'),
                  ),
                  FilterChip(
                    selected: _showAudioBt,
                    label: const Text('Show Audio/Other BT'),
                    onSelected: (v) {
                      _showAudioBt = v;
                      unawaited(_refreshBluetooth(inquiry: false));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),

        // Main Instant Drop Zone + Activity Feed
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _wrapDropTarget(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _dropHovering
                            ? const Color(0xFF0EA5E9).withValues(alpha: 0.16)
                            : const Color(0xFF0B1120),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _dropHovering
                              ? const Color(0xFF38BDF8)
                              : target != null
                                  ? const Color(0xFF14B8A6)
                                      .withValues(alpha: 0.6)
                                  : Colors.white24,
                          width: _dropHovering ? 3 : 2,
                        ),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _dropHovering
                                  ? Icons.file_download_outlined
                                  : target == null
                                      ? Icons.bolt
                                      : target.isUsb
                                          ? Icons.usb
                                          : Icons.bluetooth_audio,
                              size: 58,
                              color: (btAppleSelected || usbReadOnlySelected)
                                  ? Colors.amberAccent
                                  : const Color(0xFF38BDF8),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              target == null
                                  ? 'Plug Phone via USB or Pair Bluetooth Above'
                                  : _dropHovering
                                      ? 'Release to Send Immediately to ${target.displayName}!'
                                      : 'Drop Files or Folders Here to Send Immediately to ${target.displayName}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              btAppleSelected
                                  ? 'Note: Apple blocks Bluetooth file transfers to iPhone. Plug in your USB Cable to copy iPhone photos/videos to PC (no Wi-Fi needed).'
                                  : usbReadOnlySelected
                                      ? 'iPhone USB (PTP) only allows copying photos/videos FROM iPhone to Windows. Click "Browse Phone Files (USB)" above.'
                                      : _statusText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: (_sending || target == null)
                                      ? null
                                      : _pickFilesAndSend,
                                  icon: const Icon(Icons.bolt, size: 18),
                                  label: const Text('Select Files & Send Now'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: (_sending || target == null)
                                      ? null
                                      : _pickFolderAndSend,
                                  icon: const Icon(
                                    Icons.create_new_folder_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Send Folder Now'),
                                ),
                              ],
                            ),
                            if (_sending) ...[
                              const SizedBox(height: 20),
                              SizedBox(
                                width: 420,
                                child: Column(
                                  children: [
                                    LinearProgressIndicator(
                                      value: _usbProgress.active
                                          ? _usbProgress.fraction
                                          : _btProgress?.fraction,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _usbProgress.active
                                                ? '${_usbProgress.completedFiles}/${_usbProgress.totalFiles} • ${_usbProgress.formattedSpeed} • ${_usbProgress.currentFileName}'
                                                : _btProgress != null
                                                    ? 'Bluetooth: ${_btProgress!.completedFiles}/${_btProgress!.totalFiles} • ${formatByteCount(_btProgress!.bytesTransferred)} / ${formatByteCount(_btProgress!.totalBytes)} • ${_btProgress!.currentFile}'
                                                    : 'Connecting to ${target?.displayName ?? "device"}...',
                                            style:
                                                const TextStyle(fontSize: 12),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        TextButton.icon(
                                          onPressed: _cancelSend,
                                          icon:
                                              const Icon(Icons.close, size: 16),
                                          label: const Text('Cancel'),
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
              const VerticalDivider(width: 1),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.history,
                              size: 19, color: Colors.tealAccent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Instant Send Activity (${_logs.length})',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (_logs.isNotEmpty)
                            TextButton(
                              onPressed: () => setState(_logs.clear),
                              child: const Text('Clear'),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _logs.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(20),
                                child: Text(
                                  'How No-Wi-Fi Transfer Works:\n\n'
                                  '• Android via Bluetooth: Pair your phone once, select it above, and drop files — sends straight to your phone (just tap Accept on Android).\n\n'
                                  '• Android via USB: Plug USB cable -> instant two-way bulk transfer at USB speed.\n\n'
                                  '• iPhone via USB: Plug USB cable + tap Trust -> click "Browse Phone Files (USB)" to copy photos/videos to Windows.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.white60,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _logs.length,
                              separatorBuilder: (c, i) => Divider(
                                height: 1,
                                color: Colors.white.withValues(alpha: 0.06),
                              ),
                              itemBuilder: (ctx, i) {
                                final item = _logs[i];
                                return ListTile(
                                  leading: Icon(
                                    item.succeeded
                                        ? Icons.check_circle
                                        : Icons.error_outline,
                                    color: item.succeeded
                                        ? Colors.tealAccent
                                        : Colors.redAccent,
                                  ),
                                  title: Text(item.title),
                                  subtitle: Text(item.subtitle),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _wrapDropTarget({required Widget child}) {
    if (!widget.enableNativeServices) return child;
    return dd.DropTarget(
      onEnter: (_) => setState(() => _dropHovering = true),
      onLeave: () => setState(() => _dropHovering = false),
      onDrop: _handleDrop,
      child: child,
    );
  }
}
