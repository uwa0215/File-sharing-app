import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' as dd;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import 'models/usb_device_models.dart';
import 'services/adb_usb_service.dart';
import 'services/bluetooth_transfer_service.dart';
import 'services/mirror_process_manager.dart';
import 'services/native_tools_locator.dart';
import 'services/qr_transfer_server.dart';
import 'services/usb_device_manager.dart';
import 'services/wpd_usb_service.dart';
import 'widgets/easy_transfer_panel.dart';

enum AppWorkspaceMode { easyTransfer, usbExplorer }

void main() {
  runApp(const DeviceBridgeWindowsApp());
}

class DeviceBridgeWindowsApp extends StatelessWidget {
  const DeviceBridgeWindowsApp({
    super.key,
    this.enableNativeServices = true,
  });

  final bool enableNativeServices;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeviceBridge USB',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0EA5E9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: DashboardScreen(enableNativeServices: enableNativeServices),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.enableNativeServices = true,
  });

  final bool enableNativeServices;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final NativeToolsLocator _toolsLocator = NativeToolsLocator();
  late final WpdUsbService _wpdService;
  late final AdbUsbService _adbService;
  late final UsbDeviceManager _usbManager;
  late final MirrorProcessManager _mirrorManager;
  late final QrTransferServer _qrServer;
  late final BluetoothTransferService _bluetoothService;

  final GlobalKey _viewportKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();

  StreamSubscription<List<UsbPhoneDevice>>? _devicesSub;
  StreamSubscription<List<UsbTransferItem>>? _transfersSub;
  StreamSubscription<BatchTransferProgress>? _batchProgressSub;
  StreamSubscription<MirrorStatus>? _mirrorSub;
  StreamSubscription<QrConnectedClient>? _qrScanSub;

  AppWorkspaceMode _mode = AppWorkspaceMode.easyTransfer;
  List<UsbPhoneDevice> _devices = const [];
  UsbPhoneDevice? _selectedDevice;
  List<UsbPathSegment> _breadcrumbs = const [];
  List<UsbFileEntry> _entries = const [];
  List<UsbFileEntry> _filteredEntriesCache = const [];
  final Set<String> _selectedFileIds = <String>{};
  List<UsbTransferItem> _transfers = const [];
  BatchTransferProgress _batchProgress = const BatchTransferProgress.idle();
  MirrorStatus _mirrorStatus = const MirrorStatus(state: MirrorState.idle);

  bool _loadingFolder = false;
  bool _dropHovering = false;
  bool _transferDrawerExpanded = false;
  String _searchQuery = '';
  String _statusBanner =
      'Plug any Android or iPhone into USB — reads automatically.';

  @override
  void initState() {
    super.initState();
    _wpdService = WpdUsbService();
    _adbService = AdbUsbService(locator: _toolsLocator);
    _usbManager = UsbDeviceManager(
      wpdService: _wpdService,
      adbService: _adbService,
    );
    _mirrorManager = MirrorProcessManager(locator: _toolsLocator);
    _bluetoothService = BluetoothTransferService();
    _qrServer = QrTransferServer(
      receiveDir: Directory(p.join(Directory.systemTemp.path, 'DeviceBridge')),
    );

    _devicesSub = _usbManager.devicesStream.listen(_onDevicesUpdated);
    _transfersSub = _usbManager.transfersStream.listen((items) {
      if (mounted) {
        setState(() => _transfers = items);
      }
    });
    _batchProgressSub = _usbManager.batchProgressStream.listen((progress) {
      if (mounted) {
        setState(() => _batchProgress = progress);
      }
    });
    _mirrorSub = _mirrorManager.statusStream.listen((status) {
      if (mounted) {
        setState(() => _mirrorStatus = status);
      }
    });
    _qrScanSub = _qrServer.deviceScannedStream.listen((client) {
      if (mounted) {
        setState(() {
          _statusBanner =
              'QR scanned & connected: ${client.deviceLabel} (${client.remoteAddress})';
        });
      }
    });

    if (widget.enableNativeServices) {
      _usbManager.startMonitoring();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _devicesSub?.cancel();
    _transfersSub?.cancel();
    _batchProgressSub?.cancel();
    _mirrorSub?.cancel();
    _qrScanSub?.cancel();
    _mirrorManager.dispose();
    _usbManager.dispose();
    _qrServer.dispose();
    super.dispose();
  }

  void _recomputeFilteredEntries() {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _filteredEntriesCache = _entries;
    } else {
      _filteredEntriesCache = _entries
          .where((e) => e.name.toLowerCase().contains(q))
          .toList(growable: false);
    }
  }

  void _onDevicesUpdated(List<UsbPhoneDevice> devices) {
    if (!mounted) return;
    final previousId = _selectedDevice?.id;
    UsbPhoneDevice? nextSelected;

    if (previousId != null) {
      for (final d in devices) {
        if (d.id == previousId) {
          nextSelected = d;
          break;
        }
      }
    }
    nextSelected ??= devices.isNotEmpty ? devices.first : null;

    final deviceChanged = nextSelected?.id != previousId ||
        (nextSelected != null &&
            _selectedDevice != null &&
            nextSelected.authorized != _selectedDevice!.authorized);

    setState(() {
      _devices = devices;
      _selectedDevice = nextSelected;
      if (devices.isEmpty) {
        _breadcrumbs = const [];
        _entries = const [];
        _filteredEntriesCache = const [];
        _selectedFileIds.clear();
        _statusBanner =
            'Plug any Android or iPhone into USB — reads automatically.';
      }
    });

    if (devices.isEmpty && _mirrorManager.isRunning) {
      unawaited(_mirrorManager.stopMirror());
    }

    if (nextSelected != null && deviceChanged) {
      unawaited(_selectAndLoadDevice(nextSelected));
    }
  }

  Future<void> _selectAndLoadDevice(UsbPhoneDevice device) async {
    setState(() {
      _selectedDevice = device;
      _loadingFolder = true;
      _selectedFileIds.clear();
      _searchQuery = '';
      _searchController.clear();
      _statusBanner = 'Reading ${device.name} over USB...';
    });

    try {
      final result = await _usbManager.openInitialDirectory(device);
      if (!mounted) return;
      setState(() {
        _breadcrumbs = result.breadcrumbs;
        _entries = result.entries;
        _recomputeFilteredEntries();
        _loadingFolder = false;
        if (!device.authorized) {
          _statusBanner =
              'Tap "Allow USB debugging" on ${device.name}, or switch USB mode to File Transfer (MTP).';
        } else if (device.os == MobileOs.ios) {
          _statusBanner =
              'Connected to ${device.name}. Open DCIM to select & drag photos in bulk to your PC.';
        } else {
          _statusBanner =
              'Connected to ${device.name} (${device.backendBadge}).';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFolder = false;
        _statusBanner = 'Could not read ${device.name}: $e';
      });
    }
  }

  Future<void> _openFolder(UsbFileEntry folder) async {
    final device = _selectedDevice;
    if (device == null || !folder.isDirectory) return;

    setState(() {
      _loadingFolder = true;
      _selectedFileIds.clear();
    });

    try {
      final children = await _usbManager.listFolder(
        device: device,
        folderId: folder.id,
        displayPath: folder.displayPath,
      );
      if (!mounted) return;
      setState(() {
        _breadcrumbs = [
          ..._breadcrumbs,
          UsbPathSegment(id: folder.id, label: folder.name),
        ];
        _entries = children;
        _recomputeFilteredEntries();
        _loadingFolder = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFolder = false;
        _statusBanner = 'Failed to open ${folder.name}: $e';
      });
    }
  }

  Future<void> _navigateToBreadcrumb(int index) async {
    final device = _selectedDevice;
    if (device == null || index < 0 || index >= _breadcrumbs.length) return;

    final target = _breadcrumbs[index];
    setState(() {
      _loadingFolder = true;
      _selectedFileIds.clear();
    });

    try {
      final children = await _usbManager.listFolder(
        device: device,
        folderId: target.id,
        displayPath: target.label,
      );
      if (!mounted) return;
      setState(() {
        _breadcrumbs = _breadcrumbs.sublist(0, index + 1);
        _entries = children;
        _recomputeFilteredEntries();
        _loadingFolder = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFolder = false;
        _statusBanner = 'Refresh failed: $e';
      });
    }
  }

  Future<void> _jumpToAndroidPath(String posixPath, String label) async {
    final device = _selectedDevice;
    if (device == null || device.backend != UsbBackendMode.adb) return;

    setState(() {
      _loadingFolder = true;
      _selectedFileIds.clear();
    });

    try {
      final children = await _usbManager.listFolder(
        device: device,
        folderId: posixPath,
        displayPath: posixPath,
      );
      if (!mounted) return;
      setState(() {
        _breadcrumbs = [
          const UsbPathSegment(
            id: AdbUsbService.defaultRootPath,
            label: 'Internal Storage',
          ),
          if (posixPath != AdbUsbService.defaultRootPath)
            UsbPathSegment(id: posixPath, label: label),
        ];
        _entries = children;
        _recomputeFilteredEntries();
        _loadingFolder = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFolder = false;
        _statusBanner = 'Folder $posixPath not found: $e';
      });
    }
  }

  Future<void> _refreshCurrentFolder() async {
    if (_breadcrumbs.isEmpty) {
      await _usbManager.scanDevices(force: true);
      if (_selectedDevice != null) {
        await _selectAndLoadDevice(_selectedDevice!);
      }
      return;
    }
    await _navigateToBreadcrumb(_breadcrumbs.length - 1);
  }

  void _selectAllVisibleFiles() {
    setState(() {
      for (final entry in _filteredEntriesCache) {
        if (!entry.isDirectory) {
          _selectedFileIds.add(entry.id);
        }
      }
    });
  }

  void _selectMediaFiles() {
    const mediaExts = {
      '.jpg',
      '.jpeg',
      '.png',
      '.heic',
      '.webp',
      '.gif',
      '.mp4',
      '.mov',
      '.mkv',
      '.avi',
    };
    setState(() {
      for (final entry in _filteredEntriesCache) {
        if (!entry.isDirectory &&
            mediaExts.contains(p.extension(entry.name).toLowerCase())) {
          _selectedFileIds.add(entry.id);
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedFileIds.clear());
  }

  Future<void> _handleDropToPhone(dd.DropDetails details) async {
    setState(() => _dropHovering = false);
    final device = _selectedDevice;
    if (device == null) {
      setState(() => _statusBanner = 'Plug in a phone via USB first.');
      return;
    }

    final paths = <String>[];
    for (final item in details.items) {
      if (item is dd.DropFileItem) {
        final path = item.localPath;
        if (path != null && path.isNotEmpty) {
          paths.add(path);
        }
      } else if (item is dd.DropDirectoryItem) {
        final path = item.localPath;
        if (path != null && path.isNotEmpty) {
          paths.add(path);
        }
      }
    }
    if (paths.isEmpty) return;

    await _sendPathsToPhone(paths);
  }

  Future<void> _pickFilesAndSend() async {
    final device = _selectedDevice;
    if (device == null) {
      setState(() => _statusBanner = 'Plug in a phone via USB first.');
      return;
    }
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final paths = result.paths.whereType<String>().toList();
    if (paths.isEmpty) return;
    await _sendPathsToPhone(paths);
  }

  Future<void> _pickFolderAndSend() async {
    final device = _selectedDevice;
    if (device == null) {
      setState(() => _statusBanner = 'Plug in a phone via USB first.');
      return;
    }
    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select a folder from Windows to copy to ${device.name}',
    );
    if (folderPath == null) return;
    await _sendPathsToPhone([folderPath]);
  }

  Future<void> _sendPathsToPhone(List<String> paths) async {
    final device = _selectedDevice;
    if (device == null) return;

    final currentFolderId = _breadcrumbs.isNotEmpty ? _breadcrumbs.last.id : '';

    setState(() {
      _statusBanner = 'Sending ${paths.length} item(s) to ${device.name}...';
    });

    try {
      final summary = await _usbManager.pushLocalPaths(
        device: device,
        localPaths: paths,
        targetFolderId: currentFolderId,
      );
      if (mounted) {
        setState(() {
          if (summary.cancelled) {
            _statusBanner = 'Bulk upload cancelled.';
          } else {
            _statusBanner =
                'Sent ${summary.succeededCount} file(s) (${formatByteCount(summary.bytesTransferred)}) to ${device.name}.';
          }
        });
        await _refreshCurrentFolder();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Send failed: $e');
      }
    }
  }

  Future<void> _saveSingleFileToPc(UsbFileEntry entry) async {
    final device = _selectedDevice;
    if (device == null) return;

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${entry.name}',
      fileName: entry.name,
    );
    if (savePath == null) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final staged = await _usbManager.pullFile(
        device: device,
        entry: entry,
        targetDir: Directory(p.join(tempDir.path, 'DeviceBridgePull')),
      );
      await staged.copy(savePath);
      if (mounted) {
        setState(() => _statusBanner = 'Saved ${entry.name} to $savePath');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Download failed: $e');
      }
    }
  }

  Future<void> _exportSelectedFilesToPc() async {
    final device = _selectedDevice;
    if (device == null || _selectedFileIds.isEmpty) return;

    final chosen = _entries
        .where((e) => !e.isDirectory && _selectedFileIds.contains(e.id))
        .toList(growable: false);
    if (chosen.isEmpty) return;

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle:
          'Choose Windows folder to export ${chosen.length} file(s)',
    );
    if (folderPath == null) return;

    setState(() {
      _statusBanner = 'Exporting ${chosen.length} file(s) to $folderPath...';
    });

    try {
      final summary = await _usbManager.pullBatch(
        device: device,
        entries: chosen,
        targetDir: Directory(folderPath),
      );
      if (mounted) {
        setState(() {
          if (!summary.cancelled) {
            _selectedFileIds.clear();
          }
          _statusBanner = summary.cancelled
              ? 'Export cancelled (${summary.files.length} of ${chosen.length} saved).'
              : 'Exported ${summary.files.length} file(s) (${formatByteCount(summary.bytesTransferred)}) to $folderPath';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Bulk export failed: $e');
      }
    }
  }

  Future<Map<String, File>> _pullEntriesForDragOut(
    List<UsbFileEntry> entries,
  ) async {
    final device = _selectedDevice;
    if (device == null) {
      throw StateError('No USB phone connected');
    }
    final tempDir = await getTemporaryDirectory();
    final dragCache = Directory(p.join(tempDir.path, 'DeviceBridgeDragOut'));
    final summary = await _usbManager.pullBatch(
      device: device,
      entries: entries,
      targetDir: dragCache,
    );
    final byName = <String, File>{
      for (final file in summary.files) p.basename(file.path): file,
    };
    final result = <String, File>{};
    for (final entry in entries) {
      final match = byName[entry.name];
      if (match != null) {
        result[entry.id] = match;
      }
    }
    return result;
  }

  Rect? _measureMirrorViewportRect() {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  Future<void> _toggleMirror() async {
    if (_mirrorManager.isRunning) {
      await _mirrorManager.stopMirror();
      return;
    }
    final device = _selectedDevice;
    if (device == null) {
      setState(() => _statusBanner = 'Plug in a phone via USB before mirroring.');
      return;
    }
    await _mirrorManager.startMirror(
      platform: device.os == MobileOs.ios ? MobileOs.ios : MobileOs.android,
      androidSerial: device.adbSerial,
      viewportRect: _measureMirrorViewportRect(),
    );
  }

  void _showToolsDiagnosticsDialog() {
    final tools = _toolsLocator.resolveAll();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bundled USB & Mirroring Tools'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'DeviceBridge uses a persistent Win32 WPD COM engine (2 MB streaming) plus concurrent ADB USB pipelines for fast bulk transfers:',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              for (final tool in tools)
                ListTile(
                  dense: true,
                  leading: Icon(
                    tool.isAvailable ? Icons.check_circle : Icons.info_outline,
                    color: tool.isAvailable ? Colors.tealAccent : Colors.amber,
                  ),
                  title: Text(tool.executableName),
                  subtitle: Text(
                    tool.resolvedPath ?? 'Optional (${tool.source.name})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  int get _selectedTotalBytes {
    var total = 0;
    for (final entry in _entries) {
      if (!entry.isDirectory && _selectedFileIds.contains(entry.id)) {
        total += entry.sizeBytes;
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final mirrorRunning = _mirrorManager.isRunning;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            _selectAllVisibleFiles,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: Row(
              children: [
                Icon(
                  _mode == AppWorkspaceMode.easyTransfer
                      ? Icons.qr_code_2
                      : Icons.usb,
                  color: const Color(0xFF38BDF8),
                ),
                const SizedBox(width: 8),
                const Flexible(
                  flex: 0,
                  child: Text(
                    'DeviceBridge',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _mode == AppWorkspaceMode.easyTransfer
                        ? 'Scan QR code or send via USB / Bluetooth'
                        : _statusBanner,
                    style:
                        const TextStyle(fontSize: 12.5, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: [
              SegmentedButton<AppWorkspaceMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: AppWorkspaceMode.easyTransfer,
                    icon: Icon(Icons.qr_code_2, size: 18),
                    label: Text('Easy Transfer'),
                  ),
                  ButtonSegment(
                    value: AppWorkspaceMode.usbExplorer,
                    icon: Icon(Icons.usb, size: 18),
                    label: Text('USB Explorer'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (next) {
                  final target = next.first;
                  if (target != AppWorkspaceMode.usbExplorer &&
                      _mirrorManager.isRunning) {
                    unawaited(_mirrorManager.stopMirror());
                  }
                  setState(() => _mode = target);
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _usbManager.scanDevices(force: true),
                icon: const Icon(Icons.refresh),
                tooltip: 'Rescan USB Devices',
              ),
              IconButton(
                onPressed: _showToolsDiagnosticsDialog,
                icon: const Icon(Icons.build_outlined),
                tooltip: 'USB & Mirroring Tools Status',
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: _mode == AppWorkspaceMode.easyTransfer
              ? EasyTransferPanel(
                  qrServer: _qrServer,
                  usbManager: _usbManager,
                  bluetoothService: _bluetoothService,
                  enableNativeServices: widget.enableNativeServices,
                  onSwitchToUsbExplorer: () =>
                      setState(() => _mode = AppWorkspaceMode.usbExplorer),
                )
              : Column(
                  children: [
                    _buildConnectedDevicesStrip(),
                    Expanded(
                      child: Row(
                        children: [
                          SizedBox(
                            width: 370,
                            child: _buildMirrorAndDropPanel(mirrorRunning),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Column(
                              children: [
                                Expanded(child: _buildPhoneExplorerPanel()),
                                if (_batchProgress.active)
                                  _buildBulkProgressBanner(),
                                if (_transfers.isNotEmpty)
                                  _buildTransferActivityDrawer(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildConnectedDevicesStrip() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: _devices.isEmpty
          ? const Row(
              children: [
                Icon(Icons.cable, size: 18, color: Colors.amberAccent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Waiting for USB mobile device... Plug in your Android (File Transfer / USB Debugging) or iPhone (tap Trust) via USB cable.',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
              ],
            )
          : Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'USB Connected:',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white60,
                  ),
                ),
                for (final device in _devices)
                  ChoiceChip(
                    selected: _selectedDevice?.id == device.id,
                    avatar: Icon(
                      device.os == MobileOs.ios
                          ? Icons.phone_iphone
                          : Icons.phone_android,
                      size: 18,
                      color: device.authorized
                          ? const Color(0xFF38BDF8)
                          : Colors.amberAccent,
                    ),
                    label: Text('${device.name} • ${device.backendBadge}'),
                    onSelected: (_) => _selectAndLoadDevice(device),
                  ),
              ],
            ),
    );
  }

  Widget _buildMirrorAndDropPanel(bool mirrorRunning) {
    final device = _selectedDevice;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Mirror & Send to Phone',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: device == null || !device.canMirrorScreen
                    ? null
                    : _toggleMirror,
                icon: Icon(
                  mirrorRunning ? Icons.stop : Icons.screen_share,
                  size: 18,
                ),
                label: Text(mirrorRunning ? 'Stop' : 'Mirror'),
              ),
              if (mirrorRunning && device?.os == MobileOs.android) ...[
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () =>
                      _mirrorManager.setDocked(!_mirrorManager.isDocked),
                  icon: Icon(
                    _mirrorManager.isDocked
                        ? Icons.open_in_new
                        : Icons.picture_in_picture_alt,
                    size: 18,
                  ),
                  tooltip: _mirrorManager.isDocked
                      ? 'Pop out mirror window'
                      : 'Dock mirror inside frame',
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _wrapDropTarget(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 9 / 18.5,
                  child: Container(
                    key: _viewportKey,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B1120),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: _dropHovering
                            ? const Color(0xFF38BDF8)
                            : device != null
                                ? const Color(0xFF14B8A6).withValues(alpha: 0.65)
                                : Colors.white24,
                        width: _dropHovering ? 3 : 2,
                      ),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (mirrorRunning && _mirrorStatus.docked)
                          const Spacer()
                        else ...[
                          Icon(
                            _dropHovering
                                ? Icons.file_download_outlined
                                : device == null
                                    ? Icons.usb_off
                                    : device.canWriteFiles
                                        ? Icons.upload_file
                                        : Icons.photo_library_outlined,
                            size: 46,
                            color: const Color(0xFF38BDF8),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _dropHovering
                                ? 'Release to bulk send to ${device?.name ?? "phone"}'
                                : device == null
                                    ? 'Plug Phone via USB'
                                    : device.canWriteFiles
                                        ? 'Drop Files or Folders Here\nto Bulk Send to ${device.name}'
                                        : '${device.name} (Read-Only PTP)\nBrowse Photos on the Right',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            device == null
                                ? 'No mobile app installation needed.'
                                : device.canWriteFiles
                                    ? 'Supports 100s of files or whole folders at full USB speed.'
                                    : 'Apple blocks writing back over USB PTP. Select & drag photos from Phone Explorer onto your Desktop!',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white60,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (device != null && device.canWriteFiles) ...[
                            FilledButton.icon(
                              onPressed: _pickFilesAndSend,
                              icon: const Icon(Icons.file_present, size: 18),
                              label: const Text('Select PC Files to Send'),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _pickFolderAndSend,
                              icon: const Icon(Icons.create_new_folder_outlined,
                                  size: 18),
                              label: const Text('Send Entire Folder...'),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              mirrorRunning
                  ? 'Mirror active: check & drag files in Phone Explorer on the right to copy FROM your phone to Windows.'
                  : (_mirrorStatus.message ??
                      (device?.os == MobileOs.android &&
                              device?.adbSerial == null
                          ? 'Tip: Enable USB Debugging on Android for faster ADB bulk transfers & Live Mirror.'
                          : 'Zero phone app required — 100% Windows USB.')),
              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneExplorerPanel() {
    final device = _selectedDevice;
    final filtered = _filteredEntriesCache;
    final fileCount = filtered.where((e) => !e.isDirectory).length;
    final currentBreadcrumbLabel = _breadcrumbs.isEmpty
        ? 'Phone Storage'
        : _breadcrumbs.map((b) => b.label).join(' / ');

    return _wrapDropTarget(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header + Breadcrumbs + Search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: _breadcrumbs.length <= 1 || _loadingFolder
                      ? null
                      : () => _navigateToBreadcrumb(_breadcrumbs.length - 2),
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Up one folder',
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < _breadcrumbs.length; i++) ...[
                          if (i > 0)
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 2),
                              child: Icon(Icons.chevron_right,
                                  size: 18, color: Colors.white54),
                            ),
                          TextButton(
                            onPressed: _loadingFolder
                                ? null
                                : () => _navigateToBreadcrumb(i),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              _breadcrumbs[i].label,
                              style: TextStyle(
                                fontWeight: i == _breadcrumbs.length - 1
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                        if (_breadcrumbs.isEmpty)
                          Text(
                            currentBreadcrumbLabel,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() {
                      _searchQuery = v;
                      _recomputeFilteredEntries();
                    }),
                    decoration: InputDecoration(
                      hintText: 'Filter current folder...',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _recomputeFilteredEntries();
                                });
                              },
                            )
                          : null,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _loadingFolder ? null : _refreshCurrentFolder,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh folder',
                ),
              ],
            ),
          ),

          // Quick jump shortcuts + Bulk selection controls + Drag-out hint
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (device?.backend == UsbBackendMode.adb &&
                    device!.authorized) ...[
                  ActionChip(
                    avatar: const Icon(Icons.photo_camera, size: 16),
                    label: const Text('DCIM'),
                    onPressed: () =>
                        _jumpToAndroidPath('/sdcard/DCIM', 'DCIM'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.download, size: 16),
                    label: const Text('Download'),
                    onPressed: () =>
                        _jumpToAndroidPath('/sdcard/Download', 'Download'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.image, size: 16),
                    label: const Text('Pictures'),
                    onPressed: () =>
                        _jumpToAndroidPath('/sdcard/Pictures', 'Pictures'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.description, size: 16),
                    label: const Text('Documents'),
                    onPressed: () =>
                        _jumpToAndroidPath('/sdcard/Documents', 'Documents'),
                  ),
                ],
                if (fileCount > 0) ...[
                  ActionChip(
                    avatar: const Icon(Icons.select_all, size: 16),
                    label: Text('Select All ($fileCount)'),
                    onPressed: _selectAllVisibleFiles,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.perm_media_outlined, size: 16),
                    label: const Text('Select Photos/Videos'),
                    onPressed: _selectMediaFiles,
                  ),
                ],
                if (_selectedFileIds.isNotEmpty) ...[
                  ActionChip(
                    avatar: const Icon(Icons.clear, size: 16),
                    label: Text(
                        'Clear (${_selectedFileIds.length} • ${formatByteCount(_selectedTotalBytes)})'),
                    onPressed: _clearSelection,
                  ),
                  FilledButton.icon(
                    onPressed: _batchProgress.active
                        ? null
                        : _exportSelectedFilesToPc,
                    icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                    label: Text(
                        'Export ${_selectedFileIds.length} to PC (${formatByteCount(_selectedTotalBytes)})'),
                  ),
                ],
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.drag_indicator,
                          size: 16, color: Color(0xFF38BDF8)),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Drag any file (or drag one checked item to drag all selected files!) straight to Desktop or Explorer',
                          style: TextStyle(fontSize: 12, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // High-FPS Fixed-Extent Explorer List
          Expanded(
            child: device == null
                ? const Center(
                    child: Text(
                      'Plug in your Android or iPhone via USB to browse & drag files.',
                      style: TextStyle(color: Colors.white60),
                    ),
                  )
                : _loadingFolder
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                        ? Center(
                            child: Text(
                              device.authorized
                                  ? 'No files in this folder.'
                                  : 'Waiting for permission on ${device.name}...',
                              style: const TextStyle(color: Colors.white60),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemExtent: 64,
                            itemBuilder: (context, index) {
                              return _buildExplorerRow(filtered[index]);
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplorerRow(UsbFileEntry entry) {
    final isChecked = _selectedFileIds.contains(entry.id);

    final row = DecoratedBox(
      decoration: BoxDecoration(
        color: isChecked
            ? const Color(0xFF0EA5E9).withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!entry.isDirectory)
              Checkbox(
                value: isChecked,
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedFileIds.add(entry.id);
                    } else {
                      _selectedFileIds.remove(entry.id);
                    }
                  });
                },
              )
            else
              const SizedBox(width: 40),
            Icon(
              _iconForEntry(entry),
              color: entry.isDirectory
                  ? const Color(0xFFFBBF24)
                  : const Color(0xFF38BDF8),
            ),
          ],
        ),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          entry.isDirectory
              ? 'Folder • Click to open'
              : '${entry.formattedSize}${entry.modifiedLabel.isNotEmpty ? " • ${entry.modifiedLabel}" : ""} • Drag to Desktop',
          style: const TextStyle(fontSize: 12, color: Colors.white60),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: entry.isDirectory ? () => _openFolder(entry) : null,
        trailing: entry.isDirectory
            ? const Icon(Icons.chevron_right, color: Colors.white54)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Tooltip(
                    message: 'Drag onto Desktop or Windows Explorer',
                    child: Icon(Icons.drag_indicator, color: Colors.white54),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.download_rounded),
                    tooltip: 'Save to PC',
                    onPressed: () => _saveSingleFileToPc(entry),
                  ),
                ],
              ),
      ),
    );

    if (entry.isDirectory || !widget.enableNativeServices) {
      return row;
    }

    return DragItemWidget(
      dragItemProvider: (request) async {
        final item = DragItem(suggestedName: entry.name);
        item.add(
          Formats.fileUri.lazy(() async {
            final map = await _pullEntriesForDragOut([entry]);
            final file = map[entry.id];
            if (file == null) {
              throw StateError('Failed pulling ${entry.name}');
            }
            return file.uri;
          }),
        );
        return item;
      },
      allowedOperations: () => const [DropOperation.copy],
      child: DraggableWidget(
        onDragConfiguration: (configuration, session) {
          // If dragging one checked file while multiple are selected, package ALL checked files into one fast batch drag!
          if (!isChecked || _selectedFileIds.length <= 1) {
            return configuration;
          }
          final chosen = _entries
              .where((e) => !e.isDirectory && _selectedFileIds.contains(e.id))
              .toList(growable: false);
          if (chosen.length <= 1 || configuration.items.isEmpty) {
            return configuration;
          }

          final baseSnapshot = configuration.items.first.image;
          late final Future<Map<String, File>> sharedBatchFuture =
              _pullEntriesForDragOut(chosen);

          final multiItems = chosen.map((fileEntry) {
            final dragItem = DragItem(suggestedName: fileEntry.name);
            dragItem.add(
              Formats.fileUri.lazy(() async {
                final filesMap = await sharedBatchFuture;
                final f = filesMap[fileEntry.id];
                if (f == null) {
                  throw StateError('Failed pulling ${fileEntry.name}');
                }
                return f.uri;
              }),
            );
            return DragConfigurationItem(
              item: dragItem,
              image: baseSnapshot,
            );
          }).toList(growable: false);

          return DragConfiguration(
            items: multiItems,
            allowedOperations: configuration.allowedOperations,
            options: configuration.options,
          );
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: row,
        ),
      ),
    );
  }

  Widget _buildBulkProgressBanner() {
    final pState = _batchProgress;
    final dirLabel = pState.direction == UsbTransferDirection.pcToPhone
        ? 'Sending to phone'
        : 'Copying from phone';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0C4A6E).withValues(alpha: 0.45),
        border: Border(
          top: BorderSide(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$dirLabel: ${pState.completedFiles}/${pState.totalFiles} files • '
                  '${formatByteCount(pState.transferredBytes)}'
                  '${pState.totalBytes > 0 ? " / ${formatByteCount(pState.totalBytes)}" : ""} • '
                  '${pState.formattedSpeed} • ${pState.currentFileName}',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _usbManager.cancelActiveBatch,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: pState.fraction),
        ],
      ),
    );
  }

  Widget _buildTransferActivityDrawer() {
    final activeCount =
        _transfers.where((t) => t.status == UsbTransferStatus.running).length;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(
                () => _transferDrawerExpanded = !_transferDrawerExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    activeCount > 0
                        ? Icons.sync
                        : Icons.swap_vert_circle_outlined,
                    size: 18,
                    color: activeCount > 0
                        ? const Color(0xFF38BDF8)
                        : Colors.tealAccent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    activeCount > 0
                        ? 'USB Transfers ($activeCount running)'
                        : 'USB Transfer History (${_transfers.length})',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Icon(_transferDrawerExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up),
                ],
              ),
            ),
          ),
          if (_transferDrawerExpanded)
            SizedBox(
              height: 140,
              child: ListView.builder(
                itemCount: _transfers.length,
                itemBuilder: (ctx, i) {
                  final tx = _transfers[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      tx.direction == UsbTransferDirection.pcToPhone
                          ? Icons.upload
                          : Icons.download,
                      color: switch (tx.status) {
                        UsbTransferStatus.running => const Color(0xFF38BDF8),
                        UsbTransferStatus.completed => Colors.tealAccent,
                        UsbTransferStatus.failed => Colors.redAccent,
                        UsbTransferStatus.cancelled => Colors.amberAccent,
                      },
                    ),
                    title: Text(tx.fileName),
                    subtitle: Text(tx.detail ?? ''),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrapDropTarget({required Widget child}) {
    if (!widget.enableNativeServices) return child;
    return dd.DropTarget(
      onEnter: (_) => setState(() => _dropHovering = true),
      onLeave: () => setState(() => _dropHovering = false),
      onDrop: _handleDropToPhone,
      child: child,
    );
  }

  IconData _iconForEntry(UsbFileEntry entry) {
    if (entry.isDirectory) return Icons.folder;
    final ext = p.extension(entry.name).toLowerCase();
    if (const {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic'}
        .contains(ext)) {
      return Icons.image_outlined;
    }
    if (const {'.mp4', '.mov', '.mkv', '.avi', '.webm'}.contains(ext)) {
      return Icons.movie_outlined;
    }
    if (const {'.mp3', '.wav', '.aac', '.flac', '.m4a'}.contains(ext)) {
      return Icons.audiotrack_outlined;
    }
    if (const {'.pdf', '.doc', '.docx', '.txt', '.csv', '.xlsx'}
        .contains(ext)) {
      return Icons.description_outlined;
    }
    if (const {'.zip', '.rar', '.7z', '.apk'}.contains(ext)) {
      return Icons.archive_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
