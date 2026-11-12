import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_protocol/shared_protocol.dart';

import 'services/discovery_broadcaster.dart';
import 'services/native_storage_service.dart';
import 'services/notification_service.dart';
import 'services/transfer_server.dart';

void main() {
  runApp(const DeviceBridgeMobileApp());
}

class DeviceBridgeMobileApp extends StatelessWidget {
  const DeviceBridgeMobileApp({
    super.key,
    this.enableNativeServices = true,
  });

  final bool enableNativeServices;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeviceBridge Companion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0EA5E9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: CompanionHomePage(enableNativeServices: enableNativeServices),
    );
  }
}

class CompanionHomePage extends StatefulWidget {
  const CompanionHomePage({
    super.key,
    this.enableNativeServices = true,
  });

  final bool enableNativeServices;

  @override
  State<CompanionHomePage> createState() => _CompanionHomePageState();
}

class _CompanionHomePageState extends State<CompanionHomePage> {
  TransferServer? _server;
  DiscoveryBroadcaster? _broadcaster;
  NotificationService? _notifications;
  NativeStorageService? _storageService;

  StreamSubscription<List<ReceivedTransferRecord>>? _recordsSub;
  List<ReceivedTransferRecord> _records = const [];
  List<String> _localIps = const [];
  String _statusMessage = 'Initializing receiver...';
  bool _mdnsActive = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    if (widget.enableNativeServices) {
      _initServices();
    } else {
      _statusMessage = 'Receiver idle (test mode)';
    }
  }

  Future<void> _initServices() async {
    setState(() => _starting = true);
    try {
      final supportDir = await getApplicationSupportDirectory();
      final storageRoot = Directory(p.join(supportDir.path, 'DeviceBridge'));
      final fallbackReceived = Directory(p.join(storageRoot.path, 'received'));

      final storageService = NativeStorageService(
        fallbackReceivedDir: fallbackReceived,
      );
      await storageService.initialize();

      final notifications = NotificationService();
      await notifications.initialize();

      final platform = Platform.isIOS
          ? DevicePlatform.ios
          : Platform.isAndroid
              ? DevicePlatform.android
              : DevicePlatform.windows;

      final deviceName = Platform.localHostname;
      final deviceId = '${platform.name}-$deviceName';

      final server = TransferServer(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: platform,
        storageDir: storageRoot,
        browsableDir: storageService.browsableDirectory,
        onCommitFile: (offer, stagedFile) async {
          final saved = await storageService.commitFile(offer, stagedFile);
          await notifications.showTransferComplete(
            fileName: offer.fileName,
            savedLocation: saved,
          );
          return saved;
        },
      );

      final port = await server.start(port: kDefaultTransferPort);
      final ips = await _discoverLocalIpv4Addresses();

      final broadcaster = DiscoveryBroadcaster();
      var mdnsStarted = false;
      try {
        await broadcaster.start(
          deviceId: deviceId,
          deviceName: deviceName,
          platform: platform,
          port: port,
        );
        mdnsStarted = true;
      } catch (_) {
        mdnsStarted = false;
      }

      _recordsSub = server.recordsStream.listen((records) {
        if (mounted) {
          setState(() => _records = records);
        }
      });

      if (mounted) {
        setState(() {
          _storageService = storageService;
          _notifications = notifications;
          _server = server;
          _broadcaster = broadcaster;
          _localIps = ips;
          _mdnsActive = mdnsStarted;
          _statusMessage = 'Listening on port $port';
          _starting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Failed to start receiver: $e';
          _starting = false;
        });
      }
    }
  }

  Future<void> _toggleServer() async {
    final server = _server;
    if (server == null) return;
    if (server.isRunning) {
      await _broadcaster?.stop();
      await server.stop();
      setState(() {
        _mdnsActive = false;
        _statusMessage = 'Receiver paused';
      });
    } else {
      final port = await server.start(port: kDefaultTransferPort);
      final ips = await _discoverLocalIpv4Addresses();
      var mdnsStarted = false;
      try {
        await _broadcaster?.start(
          deviceId: server.deviceId,
          deviceName: server.deviceName,
          platform: server.platform,
          port: port,
        );
        mdnsStarted = true;
      } catch (_) {
        mdnsStarted = false;
      }
      setState(() {
        _localIps = ips;
        _mdnsActive = mdnsStarted;
        _statusMessage = 'Listening on port $port';
      });
    }
  }

  Future<List<String>> _discoverLocalIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final iface in interfaces)
        for (final addr in iface.addresses) addr.address,
    ];
  }

  @override
  void dispose() {
    _recordsSub?.cancel();
    _broadcaster?.stop();
    _server?.dispose();
    // Keep reference check explicit for clarity.
    _notifications;
    _storageService;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = _server?.isRunning ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('DeviceBridge Companion'),
        actions: [
          IconButton(
            onPressed: _starting ? null : _toggleServer,
            icon: Icon(running ? Icons.pause_circle : Icons.play_circle),
            tooltip: running ? 'Pause Receiver' : 'Start Receiver',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
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
                          running ? Icons.wifi_tethering : Icons.portable_wifi_off,
                          color: running ? Colors.tealAccent : Colors.orangeAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusMessage,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Chip(
                          label: Text(_mdnsActive ? 'mDNS Active' : 'USB / Direct'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _localIps.isEmpty
                          ? 'USB Loopback Ready: 127.0.0.1:$kDefaultTransferPort'
                          : 'LAN IPs: ${_localIps.join(', ')}:$kDefaultTransferPort • USB Ready',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Incoming Transfers (${_records.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _records.isEmpty
                  ? const Center(
                      child: Text(
                        'Waiting for files from Windows DeviceBridge...',
                      ),
                    )
                  : ListView.builder(
                      itemCount: _records.length,
                      itemBuilder: (context, index) {
                        final item = _records[index];
                        return Card(
                          child: ListTile(
                            leading: Icon(_iconForStatus(item.status)),
                            title: Text(item.fileName),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (item.status ==
                                    TransferRecordStatus.receiving)
                                  LinearProgressIndicator(value: item.progress),
                                Text(
                                  item.errorMessage ??
                                      item.savedLocation ??
                                      '${item.receivedBytes} / ${item.totalBytes} bytes',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForStatus(TransferRecordStatus status) {
    return switch (status) {
      TransferRecordStatus.receiving => Icons.downloading,
      TransferRecordStatus.verifying => Icons.verified_user_outlined,
      TransferRecordStatus.completed => Icons.check_circle,
      TransferRecordStatus.failed => Icons.error,
    };
  }
}
