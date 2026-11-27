import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class BluetoothDeviceInfo {
  const BluetoothDeviceInfo({
    required this.address,
    required this.name,
    required this.deviceKind,
    required this.connected,
    required this.authenticated,
  });

  final String address;
  final String name;
  final String deviceKind;
  final bool connected;
  final bool authenticated;

  bool get isLikelyApple {
    final lower = name.toLowerCase();
    return lower.contains('iphone') || lower.contains('ipad');
  }
}

class BluetoothSendProgress {
  const BluetoothSendProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.currentFile,
  });

  final int completedFiles;
  final int totalFiles;
  final int bytesTransferred;
  final int totalBytes;
  final String currentFile;

  double get fraction =>
      totalBytes > 0 ? (bytesTransferred / totalBytes).clamp(0.0, 1.0) : 0.0;
}

class BluetoothBatchResult {
  const BluetoothBatchResult({
    required this.succeededCount,
    required this.failureCount,
    required this.bytesTransferred,
    required this.cancelled,
    this.firstError,
  });

  final int succeededCount;
  final int failureCount;
  final int bytesTransferred;
  final bool cancelled;
  final String? firstError;
}

/// Dart interface to native Win32 Bluetooth device discovery + OBEX Object Push.
/// Enables instant wireless transfers with no Wi-Fi network required.
class BluetoothTransferService {
  BluetoothTransferService({
    MethodChannel? channel,
    EventChannel? eventsChannel,
  })  : _channel = channel ?? const MethodChannel('devicebridge/bluetooth'),
        _eventsChannel =
            eventsChannel ?? const EventChannel('devicebridge/bluetooth_events');

  final MethodChannel _channel;
  final EventChannel _eventsChannel;

  Stream<BluetoothSendProgress>? _progressBroadcast;

  Stream<BluetoothSendProgress> get progressStream {
    if (!Platform.isWindows) {
      return const Stream<BluetoothSendProgress>.empty();
    }
    return _progressBroadcast ??= _eventsChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) {
          final map = e as Map;
          return BluetoothSendProgress(
            completedFiles: (map['completedFiles'] as num?)?.toInt() ?? 0,
            totalFiles: (map['totalFiles'] as num?)?.toInt() ?? 0,
            bytesTransferred: (map['bytesTransferred'] as num?)?.toInt() ?? 0,
            totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
            currentFile: (map['currentFile'] ?? '').toString(),
          );
        })
        .asBroadcastStream();
  }

  Future<List<BluetoothDeviceInfo>> listDevices({
    bool includeAudio = false,
    bool inquiry = false,
  }) async {
    if (!Platform.isWindows) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('listDevices', {
        'includeAudio': includeAudio,
        'inquiry': inquiry,
      });
      if (raw == null) return const [];
      return raw.whereType<Map>().map((map) {
        return BluetoothDeviceInfo(
          address: (map['address'] ?? '').toString(),
          name: (map['name'] ?? 'Bluetooth Device').toString(),
          deviceKind: (map['deviceKind'] ?? 'other').toString(),
          connected: map['connected'] == true,
          authenticated: map['authenticated'] == true,
        );
      }).toList(growable: false);
    } on MissingPluginException {
      return const [];
    }
  }

  Future<BluetoothBatchResult> sendPaths({
    required BluetoothDeviceInfo device,
    required List<String> localPaths,
  }) async {
    final items = <Map<String, String>>[];
    for (final rawPath in localPaths) {
      final type = await FileSystemEntity.type(rawPath);
      if (type == FileSystemEntityType.file) {
        items.add({
          'localPath': rawPath,
          'fileName': p.basename(rawPath),
        });
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(rawPath);
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            items.add({
              'localPath': entity.path,
              'fileName': p.basename(entity.path),
            });
          }
        }
      }
    }

    if (items.isEmpty) {
      return const BluetoothBatchResult(
        succeededCount: 0,
        failureCount: 0,
        bytesTransferred: 0,
        cancelled: false,
      );
    }

    final res = await _channel.invokeMapMethod<dynamic, dynamic>('sendBatch', {
      'address': device.address,
      'items': items,
    });
    final failed = res?['failed'] as List<dynamic>? ?? const [];
    String? firstError;
    if (failed.isNotEmpty && failed.first is Map) {
      firstError = (failed.first as Map)['error']?.toString();
    }
    return BluetoothBatchResult(
      succeededCount: (res?['succeededCount'] as num?)?.toInt() ?? 0,
      failureCount: failed.length,
      bytesTransferred: (res?['bytesTransferred'] as num?)?.toInt() ?? 0,
      cancelled: res?['cancelled'] == true,
      firstError: firstError,
    );
  }

  Future<void> cancelSend() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('cancelSend');
    } on MissingPluginException {
      // Ignored in tests.
    }
  }

  Future<void> openReceiveWizard() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('openReceiveWizard');
    } on MissingPluginException {
      // Ignored in tests.
    }
  }

  Future<void> openBluetoothSettings() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('openBluetoothSettings');
    } on MissingPluginException {
      // Ignored in tests.
    }
  }
}
