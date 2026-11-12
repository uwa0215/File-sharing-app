import 'package:bonsoir/bonsoir.dart';
import 'package:shared_protocol/shared_protocol.dart';

/// Advertises this mobile companion over LAN mDNS (`_devicebridge._tcp`).
class DiscoveryBroadcaster {
  BonsoirBroadcast? _broadcast;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int port,
  }) async {
    await stop();
    final service = BonsoirService(
      name: deviceName,
      type: kMdnsServiceType,
      port: port,
      attributes: {
        'id': deviceId,
        'platform': platform.name,
        'ver': '$kProtocolVersion',
      },
    );

    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
    _running = true;
  }

  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    _running = false;
    if (broadcast != null && !broadcast.isStopped) {
      await broadcast.stop();
    }
  }
}

