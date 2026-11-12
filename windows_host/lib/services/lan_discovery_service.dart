import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:shared_protocol/shared_protocol.dart';

enum DeviceTransport { lanMdns, usbAndroid, usbIos }

/// Unified representation of an auto-discovered phone (USB tunnel or LAN mDNS).
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.transport,
    required this.host,
    required this.port,
    this.serial,
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  final DeviceTransport transport;
  final String host;
  final int port;
  final String? serial;

  String get transportLabel => switch (transport) {
        DeviceTransport.lanMdns => 'Wi-Fi (mDNS)',
        DeviceTransport.usbAndroid => 'USB (ADB)',
        DeviceTransport.usbIos => 'USB (usbmuxd)',
      };
}

/// Discovers mobile DeviceBridge instances on the local network via mDNS.
class LanDiscoveryService {
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  final Map<String, DiscoveredDevice> _devices = <String, DiscoveredDevice>{};
  final StreamController<List<DiscoveredDevice>> _controller =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devicesStream => _controller.stream;
  List<DiscoveredDevice> get currentDevices =>
      _devices.values.toList(growable: false);

  Future<void> start() async {
    await stop();
    final discovery = BonsoirDiscovery(type: kMdnsServiceType);
    await discovery.initialize();
    _discovery = discovery;

    _sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          service.resolve(discovery.serviceResolver);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          _handleResolved(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          _devices.remove(service.name);
          _emit();
        default:
          break;
      }
    });

    await discovery.start();
  }

  void _handleResolved(BonsoirService service) {
    final host = _pickBestHost(service);
    if (host == null || service.port <= 0) return;

    final platformRaw = service.attributes['platform'] ?? 'android';
    final platform = switch (platformRaw) {
      'ios' => DevicePlatform.ios,
      'windows' => DevicePlatform.windows,
      _ => DevicePlatform.android,
    };

    _devices[service.name] = DiscoveredDevice(
      id: service.attributes['id'] ?? service.name,
      name: service.name,
      platform: platform,
      transport: DeviceTransport.lanMdns,
      host: host,
      port: service.port,
    );
    _emit();
  }

  String? _pickBestHost(BonsoirService service) {
    for (final addr in service.hostAddresses) {
      if (addr.contains('.') && !addr.startsWith('127.')) {
        return addr;
      }
    }
    if (service.hostAddresses.isNotEmpty) {
      return service.hostAddresses.first;
    }
    return service.hostname;
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(currentDevices);
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null && !discovery.isStopped) {
      await discovery.stop();
    }
    _devices.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

