import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' hide DropOperation;
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_protocol/shared_protocol.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import 'services/lan_discovery_service.dart';
import 'services/mirror_process_manager.dart';
import 'services/native_tools_locator.dart';
import 'services/transfer_client.dart';
import 'services/usb_tunnel_manager.dart';

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
      title: 'DeviceBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0EA5E9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: DesktopDashboardPage(enableNativeServices: enableNativeServices),
    );
  }
}

class DesktopDashboardPage extends StatefulWidget {
  const DesktopDashboardPage({
    super.key,
    this.enableNativeServices = true,
  });

  final bool enableNativeServices;

  @override
  State<DesktopDashboardPage> createState() => _DesktopDashboardPageState();
}

class _DesktopDashboardPageState extends State<DesktopDashboardPage> {
  final TransferClient _client = TransferClient();
  final NativeToolsLocator _toolsLocator = NativeToolsLocator();
  late final LanDiscoveryService _lanDiscovery = LanDiscoveryService();
  late final UsbTunnelManager _usbManager = UsbTunnelManager(
    locator: _toolsLocator,
  );
  late final MirrorProcessManager _mirrorManager = MirrorProcessManager(
    locator: _toolsLocator,
  );

  final GlobalKey _mirrorViewportKey = GlobalKey();
  final TextEditingController _hostController = TextEditingController(
    text: '127.0.0.1',
  );
  final TextEditingController _portController = TextEditingController(
    text: '$kDefaultTransferPort',
  );

  StreamSubscription<HandshakeAck?>? _connSub;
  StreamSubscription<List<TransferTask>>? _tasksSub;
  StreamSubscription<List<DiscoveredDevice>>? _lanSub;
  StreamSubscription<List<DiscoveredDevice>>? _usbSub;
  StreamSubscription<MirrorStatus>? _mirrorSub;

  HandshakeAck? _connectedDevice;
  DiscoveredDevice? _selectedDiscoveredDevice;
  List<TransferTask> _tasks = const [];
  List<DiscoveredDevice> _lanDevices = const [];
  List<DiscoveredDevice> _usbDevices = const [];
  List<RemoteFileEntry> _remoteEntries = const [];
  String _remotePath = '';
  bool _loadingRemote = false;

  MirrorStatus _mirrorStatus = const MirrorStatus(state: MirrorState.idle);
  bool _connecting = false;
  bool _dragHovering = false;
  String? _statusBanner;

  List<DiscoveredDevice> get _allDiscovered => [
        ..._usbDevices,
        ..._lanDevices,
      ];

  @override
  void initState() {
    super.initState();
    _connSub = _client.connectionStream.listen((ack) {
      if (mounted) {
        setState(() => _connectedDevice = ack);
        if (ack != null) {
          unawaited(_loadRemoteDirectory(''));
        } else {
          setState(() => _remoteEntries = const []);
        }
      }
    });
    _tasksSub = _client.tasksStream.listen((tasks) {
      if (mounted) {
        setState(() => _tasks = tasks);
      }
    });
    _mirrorSub = _mirrorManager.statusStream.listen((status) {
      if (mounted) {
        setState(() => _mirrorStatus = status);
      }
    });

    if (widget.enableNativeServices) {
      _lanSub = _lanDiscovery.devicesStream.listen((devices) {
        if (mounted) setState(() => _lanDevices = devices);
      });
      _usbSub = _usbManager.devicesStream.listen((devices) {
        if (mounted) setState(() => _usbDevices = devices);
      });
      unawaited(_lanDiscovery.start().catchError((_) {}));
      _usbManager.startPolling();
    }
  }

  Rect? _measureMirrorViewportRect() {
    final renderBox =
        _mirrorViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return null;
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Rect.fromLTWH(
      topLeft.dx * dpr,
      topLeft.dy * dpr,
      renderBox.size.width * dpr,
      renderBox.size.height * dpr,
    );
  }

  void _syncMirrorBounds() {
    if (_mirrorManager.isRunning) {
      final rect = _measureMirrorViewportRect();
      if (rect != null) {
        _mirrorManager.updateViewportBounds(rect);
      }
    }
  }

  Future<void> _connectToDevice(DiscoveredDevice device) async {
    _hostController.text = device.host;
    _portController.text = '${device.port}';
    _selectedDiscoveredDevice = device;
    await _connect();
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final port =
        int.tryParse(_portController.text.trim()) ?? kDefaultTransferPort;
    if (host.isEmpty) return;

    setState(() {
      _connecting = true;
      _statusBanner = null;
    });

    try {
      final ack = await _client.connect(host: host, port: port);
      if (mounted) {
        setState(() {
          _connectedDevice = ack;
          _statusBanner = 'Connected to ${ack.deviceName} (${ack.platform.name})';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Connection failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  Future<void> _disconnect() async {
    await _client.disconnect();
    if (mounted) {
      setState(() => _statusBanner = 'Disconnected');
    }
  }

  Future<void> _toggleMirror() async {
    if (_mirrorManager.isRunning) {
      await _mirrorManager.stopMirror();
      return;
    }

    final platform = _connectedDevice?.platform ??
        _selectedDiscoveredDevice?.platform ??
        DevicePlatform.android;
    final serial = _selectedDiscoveredDevice?.serial;
    final bounds = _measureMirrorViewportRect();

    await _mirrorManager.startMirror(
      platform: platform,
      androidSerial: serial,
      viewportRect: bounds,
    );
  }

  Future<void> _loadRemoteDirectory(String relativePath) async {
    if (!_client.isConnected) return;
    setState(() => _loadingRemote = true);
    try {
      final resp = await _client.listDirectory(relativePath: relativePath);
      if (mounted) {
        setState(() {
          _remotePath = resp.relativePath;
          _remoteEntries = resp.entries;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Browse error: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingRemote = false);
      }
    }
  }

  Future<void> _saveRemoteFileToPc(RemoteFileEntry entry) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${entry.name}',
      fileName: entry.name,
    );
    if (savePath == null) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final staged = await _client.pullFile(
        remoteRelativePath: entry.relativePath,
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

  Future<File> _pullForDragOut(RemoteFileEntry entry) async {
    final tempDir = await getTemporaryDirectory();
    final dragCache = Directory(p.join(tempDir.path, 'DeviceBridgeDragOut'));
    return _client.pullFile(
      remoteRelativePath: entry.relativePath,
      targetDir: dragCache,
    );
  }

  Future<void> _pickAndSendFiles() async {
    if (!_client.isConnected) {
      setState(() => _statusBanner = 'Connect to a phone before sending files.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;

    final paths = result.paths.whereType<String>().toList();
    if (paths.isEmpty) return;

    try {
      await _client.sendPaths(paths);
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Transfer error: $e');
      }
    }
  }

  Future<void> _handleDrop(DropDetails details) async {
    setState(() => _dragHovering = false);
    if (!_client.isConnected) {
      setState(() => _statusBanner = 'Connect to a phone before dropping files.');
      return;
    }

    final paths = <String>[];
    for (final item in details.items) {
      switch (item) {
        case DropFileItem(:final localPath):
          if (localPath != null) paths.add(localPath);
        case DropDirectoryItem(:final localPath):
          if (localPath != null) paths.add(localPath);
        case DropStringItem():
          break;
      }
    }

    if (paths.isEmpty) return;
    try {
      await _client.sendPaths(paths);
    } catch (e) {
      if (mounted) {
        setState(() => _statusBanner = 'Drop transfer failed: $e');
      }
    }
  }

  void _showToolDiagnostics() {
    final tools = _toolsLocator.resolveAll();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Native Sidecar Tools'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tool in tools)
                ListTile(
                  dense: true,
                  leading: Icon(
                    tool.isAvailable ? Icons.check_circle : Icons.warning_amber,
                    color: tool.isAvailable
                        ? Colors.tealAccent
                        : Colors.orangeAccent,
                  ),
                  title: Text(tool.executableName),
                  subtitle: Text(
                    tool.resolvedPath ??
                        'Missing — place in native_tools/ or tools/',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(tool.source.name),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _tasksSub?.cancel();
    _lanSub?.cancel();
    _usbSub?.cancel();
    _mirrorSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _mirrorManager.dispose();
    _usbManager.dispose();
    _lanDiscovery.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _connectedDevice != null;
    final discovered = _allDiscovered;

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMirrorBounds());

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            // Left: Phone-shaped "Mirror & Drop" viewport
            SizedBox(
              width: 350,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Mirror & Drop',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        onPressed: _showToolDiagnostics,
                        icon: const Icon(Icons.build_circle_outlined),
                        tooltip: 'Native Sidecar Tools',
                      ),
                      if (_mirrorManager.isRunning)
                        IconButton(
                          onPressed: () =>
                              _mirrorManager.setDocked(!_mirrorManager.isDocked),
                          icon: Icon(
                            _mirrorManager.isDocked
                                ? Icons.open_in_new
                                : Icons.picture_in_picture_alt,
                          ),
                          tooltip: _mirrorManager.isDocked
                              ? 'Pop out mirror'
                              : 'Dock mirror',
                        ),
                      FilledButton.tonalIcon(
                        onPressed: _toggleMirror,
                        icon: Icon(
                          _mirrorManager.isRunning
                              ? Icons.stop
                              : Icons.screen_share,
                        ),
                        label: Text(
                          _mirrorManager.isRunning ? 'Stop' : 'Mirror',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _buildViewportDropWrapper(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(36),
                          border: Border.all(
                            color: _dragHovering
                                ? theme.colorScheme.primary
                                : Colors.white24,
                            width: _dragHovering ? 3 : 2,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 20,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(14),
                        child: Container(
                          key: _mirrorViewportKey,
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _dragHovering
                                    ? Icons.file_download_outlined
                                    : Icons.smartphone,
                                size: 56,
                                color: _dragHovering
                                    ? theme.colorScheme.primary
                                    : Colors.white54,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _dragHovering
                                    ? 'Release to Send to Phone'
                                    : connected
                                        ? 'Drop Files or Folders Here\n(${_connectedDevice!.deviceName})'
                                        : 'Connect a Phone & Drop Files Here',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                              if (_mirrorStatus.message != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _mirrorStatus.message!,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: _mirrorStatus.state ==
                                            MirrorState.error
                                        ? Colors.orangeAccent
                                        : Colors.tealAccent,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 18),
                              FilledButton.icon(
                                onPressed:
                                    connected ? _pickAndSendFiles : null,
                                icon: const Icon(Icons.upload_file),
                                label: const Text('Select Files'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            // Right: Discovery, Connection, Transfer Queue & Phone File Browser
            Expanded(
              child: DefaultTabController(
                length: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  connected ? Icons.link : Icons.link_off,
                                  color: connected
                                      ? Colors.tealAccent
                                      : Colors.orangeAccent,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    connected
                                        ? 'Connected: ${_connectedDevice!.deviceName} (${_connectedDevice!.platform.name})'
                                        : 'Disconnected — Pick a Discovered Device or Enter IP',
                                    style: theme.textTheme.titleMedium,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            if (discovered.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  for (final d in discovered)
                                    ActionChip(
                                      avatar: Icon(
                                        d.platform == DevicePlatform.ios
                                            ? Icons.phone_iphone
                                            : Icons.phone_android,
                                        size: 16,
                                      ),
                                      label: Text(
                                        '${d.name} • ${d.transportLabel}',
                                      ),
                                      onPressed: () => _connectToDevice(d),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _hostController,
                                    decoration: const InputDecoration(
                                      labelText: 'Host / IP',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: _portController,
                                    decoration: const InputDecoration(
                                      labelText: 'Port',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                FilledButton(
                                  onPressed: _connecting
                                      ? null
                                      : (connected ? _disconnect : _connect),
                                  child: Text(
                                    _connecting
                                        ? 'Connecting...'
                                        : (connected
                                            ? 'Disconnect'
                                            : 'Connect'),
                                  ),
                                ),
                              ],
                            ),
                            if (_statusBanner != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                _statusBanner!,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TabBar(
                      tabs: [
                        Tab(text: 'Transfer Queue (${_tasks.length})'),
                        Tab(text: 'Phone Files (${_remoteEntries.length})'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildTransferQueueTab(),
                          _buildPhoneFilesTab(connected),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferQueueTab() {
    return Card(
      child: _tasks.isEmpty
          ? const Center(
              child: Text(
                'No transfers yet. Drag files onto the phone viewport to begin.',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _tasks.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return ListTile(
                  leading: Icon(_iconForTask(task.status, task.direction)),
                  title: Text(task.relativePath),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (task.status == TransferTaskStatus.sending ||
                          task.status == TransferTaskStatus.receiving ||
                          task.status == TransferTaskStatus.hashing)
                        LinearProgressIndicator(
                          value: task.status == TransferTaskStatus.hashing
                              ? null
                              : task.progress,
                        ),
                      Text(
                        task.errorMessage ??
                            (task.status == TransferTaskStatus.completed
                                ? 'SHA-256 verified • Saved to ${task.savedLocation}'
                                : '${task.sentBytes} / ${task.totalBytes} bytes (${task.status.name})'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildPhoneFilesTab(bool connected) {
    if (!connected) {
      return const Card(
        child: Center(
          child: Text('Connect to a phone to browse and drag files to your PC.'),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: _remotePath.isEmpty
                      ? null
                      : () {
                          final parent = p.posix.dirname(_remotePath);
                          _loadRemoteDirectory(parent == '.' ? '' : parent);
                        },
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Up',
                ),
                Expanded(
                  child: Text(
                    _remotePath.isEmpty ? '/ (Phone Root)' : '/$_remotePath',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: _loadingRemote
                      ? null
                      : () => _loadRemoteDirectory(_remotePath),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loadingRemote
                ? const Center(child: CircularProgressIndicator())
                : _remoteEntries.isEmpty
                    ? const Center(child: Text('Folder is empty.'))
                    : ListView.builder(
                        itemCount: _remoteEntries.length,
                        itemBuilder: (context, index) {
                          final entry = _remoteEntries[index];
                          final row = ListTile(
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder
                                  : Icons.insert_drive_file,
                            ),
                            title: Text(entry.name),
                            subtitle: Text(
                              entry.isDirectory
                                  ? 'Folder (click to open)'
                                  : '${entry.sizeBytes} bytes • Drag to Desktop or Save',
                            ),
                            onTap: entry.isDirectory
                                ? () => _loadRemoteDirectory(entry.relativePath)
                                : null,
                            trailing: entry.isDirectory
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.download),
                                    tooltip: 'Save to PC',
                                    onPressed: () =>
                                        _saveRemoteFileToPc(entry),
                                  ),
                          );

                          if (entry.isDirectory ||
                              !widget.enableNativeServices) {
                            return row;
                          }

                          return DragItemWidget(
                            dragItemProvider: (request) async {
                              final item = DragItem(
                                suggestedName: entry.name,
                              );
                              item.add(
                                Formats.fileUri.lazy(() async {
                                  final file = await _pullForDragOut(entry);
                                  return file.uri;
                                }),
                              );
                              return item;
                            },
                            allowedOperations: () => const [DropOperation.copy],
                            child: DraggableWidget(child: row),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewportDropWrapper({required Widget child}) {
    if (!widget.enableNativeServices) {
      return child;
    }
    return DropTarget(
      onEnter: (_) => setState(() => _dragHovering = true),
      onLeave: () => setState(() => _dragHovering = false),
      onDrop: _handleDrop,
      child: child,
    );
  }

  IconData _iconForTask(
    TransferTaskStatus status,
    TransferDirection direction,
  ) {
    return switch (status) {
      TransferTaskStatus.queued => Icons.schedule,
      TransferTaskStatus.hashing => Icons.fingerprint,
      TransferTaskStatus.sending => Icons.upload,
      TransferTaskStatus.receiving => Icons.download,
      TransferTaskStatus.completed => direction == TransferDirection.uploadToPhone
          ? Icons.check_circle
          : Icons.download_done,
      TransferTaskStatus.failed => Icons.error,
    };
  }
}
