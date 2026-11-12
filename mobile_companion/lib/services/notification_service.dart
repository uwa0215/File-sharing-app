import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Displays local OS notifications when incoming file transfers complete.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 1;

  Future<void> initialize() async {
    if (_initialized) return;

    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
      ),
    );

    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  Future<void> showTransferComplete({
    required String fileName,
    required String savedLocation,
  }) async {
    if (!_initialized) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'devicebridge_transfers',
        'File Transfers',
        channelDescription: 'Notifications for completed DeviceBridge file transfers',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.show(
      id: _nextId++,
      title: 'Received $fileName',
      body: 'Verified SHA-256 • Saved to $savedLocation',
      notificationDetails: details,
      payload: savedLocation,
    );
  }
}

