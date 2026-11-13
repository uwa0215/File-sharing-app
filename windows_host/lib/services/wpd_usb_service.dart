import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/usb_device_models.dart';

class WpdBatchPullItem {
  const WpdBatchPullItem({
    required this.objectId,
    required this.destPath,
    required this.fileName,
  });

  final String objectId;
  final String destPath;
  final String fileName;
}

class WpdBatchPushItem {
  const WpdBatchPushItem({
    required this.targetFolderObjectId,
    required this.localPath,
    required this.fileName,
  });

  final String targetFolderObjectId;
  final String localPath;
  final String fileName;
}

class WpdNativeProgressEvent {
  const WpdNativeProgressEvent({
    required this.direction,
    required this.completedFiles,
    required this.totalFiles,
    required this.bytesTransferred,
    required this.currentFile,
  });

  final UsbTransferDirection direction;
  final int completedFiles;
  final int totalFiles;
  final int bytesTransferred;
  final String currentFile;
}

class WpdBatchResult {
  const WpdBatchResult({
    required this.succeededPaths,
    required this.failureCount,
    required this.bytesTransferred,
    required this.cancelled,
  });

  final List<String> succeededPaths;
  final int failureCount;
  final int bytesTransferred;
  final bool cancelled;
}

/// Dart wrapper over the native Win32 WPD (Windows Portable Devices) COM bridge.
/// Automatically reads Android MTP and Apple iPhone/iPad PTP devices plugged via USB.
class WpdUsbService {
  WpdUsbService({
    MethodChannel? channel,
    EventChannel? usbEventsChannel,
  })  : _channel = channel ?? const MethodChannel('devicebridge/wpd'),
        _eventsChannel =
            usbEventsChannel ?? const EventChannel('devicebridge/usb_events');

  final MethodChannel _channel;
  final EventChannel _eventsChannel;

  Stream<dynamic>? _sharedBroadcast;

  Stream<dynamic> get _rawEvents {
    if (!Platform.isWindows) {
      return const Stream<dynamic>.empty();
    }
    return _sharedBroadcast ??=
        _eventsChannel.receiveBroadcastStream().asBroadcastStream();
  }

  /// Broadcast stream emitting when Windows notifies `WM_DEVICECHANGE`.
  Stream<void> get usbHardwareChangeStream {
    return _rawEvents
        .where((event) => event == 'device_change')
        .map((_) {})
        .handleError((_) {});
  }

  /// Live throttled progress emitted by native `pullBatch` / `pushBatch`.
  Stream<WpdNativeProgressEvent> get batchProgressStream {
    return _rawEvents
        .where((event) => event is Map && event['type'] == 'batch_progress')
        .map((event) {
          final map = event as Map;
          final dirStr = (map['direction'] ?? 'phoneToPc').toString();
          return WpdNativeProgressEvent(
            direction: dirStr == 'pcToPhone'
                ? UsbTransferDirection.pcToPhone
                : UsbTransferDirection.phoneToPc,
            completedFiles: (map['completedFiles'] as num?)?.toInt() ?? 0,
            totalFiles: (map['totalFiles'] as num?)?.toInt() ?? 0,
            bytesTransferred: (map['bytesTransferred'] as num?)?.toInt() ?? 0,
            currentFile: (map['currentFile'] ?? '').toString(),
          );
        })
        .handleError((_) {});
  }

  /// Lists all portable devices currently mounted by Windows (Android MTP, iPhone/iPad PTP).
  Future<List<UsbPhoneDevice>> listDevices() async {
    if (!Platform.isWindows) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('listDevices');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((map) {
        final id = (map['id'] ?? '').toString();
        final friendly = (map['friendlyName'] ?? 'USB Phone').toString();
        final manufacturer = (map['manufacturer'] ?? '').toString();
        final hint = (map['platformHint'] ?? 'unknown').toString();
        final os = switch (hint) {
          'ios' => MobileOs.ios,
          'android' => MobileOs.android,
          _ => MobileOs.unknown,
        };
        return UsbPhoneDevice(
          id: 'wpd:$id',
          name: friendly.isEmpty ? 'USB Mobile Device' : friendly,
          manufacturer: manufacturer,
          os: os,
          backend: UsbBackendMode.wpd,
          wpdDeviceId: id,
        );
      }).toList(growable: false);
    } on MissingPluginException {
      return const [];
    }
  }

  /// Enumerates immediate children inside [folderObjectId] (`""` for device root).
  Future<List<UsbFileEntry>> listChildren({
    required String wpdDeviceId,
    String folderObjectId = '',
    String parentDisplayPath = '',
  }) async {
    final raw = await _channel.invokeListMethod<dynamic>('listChildren', {
      'deviceId': wpdDeviceId,
      'folderObjectId': folderObjectId,
    });
    if (raw == null) return const [];

    return raw.whereType<Map>().map((map) {
      final objId = (map['id'] ?? '').toString();
      final name = (map['name'] ?? objId).toString();
      final isDir = map['isDirectory'] == true;
      final sizeRaw = map['sizeBytes'];
      final sizeBytes = sizeRaw is int
          ? sizeRaw
          : int.tryParse(sizeRaw?.toString() ?? '0') ?? 0;

      return UsbFileEntry(
        id: objId,
        name: name,
        isDirectory: isDir,
        sizeBytes: sizeBytes,
        displayPath: parentDisplayPath.isEmpty
            ? name
            : '$parentDisplayPath/$name',
      );
    }).toList(growable: false);
  }

  /// Copies a single file from the USB phone (`objectId`) to [destFile] on Windows.
  Future<File> pullFile({
    required String wpdDeviceId,
    required String objectId,
    required File destFile,
  }) async {
    await destFile.parent.create(recursive: true);
    await _channel.invokeMethod<String>('pullFile', {
      'deviceId': wpdDeviceId,
      'objectId': objectId,
      'destPath': destFile.path,
    });
    return destFile;
  }

  /// High-speed persistent-session bulk pull using one COM `IPortableDevice` handle.
  Future<WpdBatchResult> pullBatch({
    required String wpdDeviceId,
    required List<WpdBatchPullItem> items,
  }) async {
    final res = await _channel.invokeMapMethod<dynamic, dynamic>('pullBatch', {
      'deviceId': wpdDeviceId,
      'items': items
          .map((i) => {
                'objectId': i.objectId,
                'destPath': i.destPath,
                'fileName': i.fileName,
              })
          .toList(growable: false),
    });

    final succeeded = (res?['succeeded'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    final failed = res?['failed'] as List<dynamic>? ?? const [];
    final bytes = (res?['bytesTransferred'] as num?)?.toInt() ?? 0;
    final cancelled = res?['cancelled'] == true;

    return WpdBatchResult(
      succeededPaths: succeeded,
      failureCount: failed.length,
      bytesTransferred: bytes,
      cancelled: cancelled,
    );
  }

  /// Uploads a local Windows file into a writable MTP folder on the phone.
  Future<void> pushFile({
    required String wpdDeviceId,
    required String targetFolderObjectId,
    required File localFile,
    String? remoteFileName,
  }) async {
    await _channel.invokeMethod<bool>('pushFile', {
      'deviceId': wpdDeviceId,
      'targetFolderObjectId': targetFolderObjectId,
      'localPath': localFile.path,
      'fileName': remoteFileName ?? p.basename(localFile.path),
    });
  }

  /// High-speed persistent-session bulk push using one COM `IPortableDevice` handle.
  Future<WpdBatchResult> pushBatch({
    required String wpdDeviceId,
    required List<WpdBatchPushItem> items,
  }) async {
    final res = await _channel.invokeMapMethod<dynamic, dynamic>('pushBatch', {
      'deviceId': wpdDeviceId,
      'items': items
          .map((i) => {
                'targetFolderObjectId': i.targetFolderObjectId,
                'localPath': i.localPath,
                'fileName': i.fileName,
              })
          .toList(growable: false),
    });

    final failed = res?['failed'] as List<dynamic>? ?? const [];
    final bytes = (res?['bytesTransferred'] as num?)?.toInt() ?? 0;
    final cancelled = res?['cancelled'] == true;

    return WpdBatchResult(
      succeededPaths: const [],
      failureCount: failed.length,
      bytesTransferred: bytes,
      cancelled: cancelled,
    );
  }

  Future<void> cancelBatch() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('cancelBatch');
    } on MissingPluginException {
      // Ignored in tests.
    }
  }

  /// Creates a subfolder inside a writable MTP folder and returns its new object ID.
  Future<String> createFolder({
    required String wpdDeviceId,
    required String parentObjectId,
    required String folderName,
  }) async {
    final id = await _channel.invokeMethod<String>('createFolder', {
      'deviceId': wpdDeviceId,
      'parentObjectId': parentObjectId,
      'folderName': folderName,
    });
    if (id == null || id.isEmpty) {
      throw StateError('Phone did not return a created folder ID.');
    }
    return id;
  }
}
