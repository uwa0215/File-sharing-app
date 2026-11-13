// Data models for Windows USB-connected mobile devices, files, and transfers.

enum MobileOs { android, ios, unknown }

enum UsbBackendMode { adb, wpd }

enum UsbTransferDirection { pcToPhone, phoneToPc }

enum UsbTransferStatus { running, completed, failed, cancelled }

/// Represents a mobile device auto-detected over USB via ADB or Windows Portable Devices (WPD).
class UsbPhoneDevice {
  const UsbPhoneDevice({
    required this.id,
    required this.name,
    required this.manufacturer,
    required this.os,
    required this.backend,
    this.authorized = true,
    this.adbSerial,
    this.wpdDeviceId,
  });

  final String id;
  final String name;
  final String manufacturer;
  final MobileOs os;
  final UsbBackendMode backend;
  final bool authorized;
  final String? adbSerial;
  final String? wpdDeviceId;

  bool get canMirrorScreen =>
      (os == MobileOs.android && adbSerial != null && authorized) ||
      os == MobileOs.ios;

  /// Apple iPhone/iPad over Windows PTP only allows reading DCIM photos/videos;
  /// Android ADB and Android MTP allow both reading and writing.
  bool get canWriteFiles =>
      !(os == MobileOs.ios && backend == UsbBackendMode.wpd);

  String get backendBadge => switch (backend) {
        UsbBackendMode.adb => authorized
            ? 'USB (ADB • High-Speed Bulk)'
            : 'USB (ADB • Tap Allow on Phone)',
        UsbBackendMode.wpd =>
          os == MobileOs.ios ? 'USB (Apple PTP • Photos & Videos)' : 'USB (MTP)',
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsbPhoneDevice &&
          id == other.id &&
          name == other.name &&
          manufacturer == other.manufacturer &&
          os == other.os &&
          backend == other.backend &&
          authorized == other.authorized &&
          adbSerial == other.adbSerial &&
          wpdDeviceId == other.wpdDeviceId;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        manufacturer,
        os,
        backend,
        authorized,
        adbSerial,
        wpdDeviceId,
      );
}

/// A folder or file entry inside a USB-connected phone.
class UsbFileEntry {
  const UsbFileEntry({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.sizeBytes = 0,
    this.displayPath = '',
    this.modifiedLabel = '',
  });

  /// Backend identifier: POSIX path on ADB, or WPD Object ID on WPD/MTP/PTP.
  final String id;
  final String name;
  final bool isDirectory;
  final int sizeBytes;
  final String displayPath;
  final String modifiedLabel;

  String get formattedSize {
    if (isDirectory) return 'Folder';
    return formatByteCount(sizeBytes);
  }
}

/// Represents a folder breadcrumb step while navigating a phone.
class UsbPathSegment {
  const UsbPathSegment({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;
}

/// Real-time aggregate progress snapshot for bulk USB transfers.
class BatchTransferProgress {
  const BatchTransferProgress({
    required this.active,
    required this.direction,
    required this.totalFiles,
    required this.completedFiles,
    required this.failedFiles,
    required this.totalBytes,
    required this.transferredBytes,
    required this.bytesPerSecond,
    this.currentFileName = '',
    this.cancelled = false,
  });

  const BatchTransferProgress.idle()
      : active = false,
        direction = UsbTransferDirection.phoneToPc,
        totalFiles = 0,
        completedFiles = 0,
        failedFiles = 0,
        totalBytes = 0,
        transferredBytes = 0,
        bytesPerSecond = 0,
        currentFileName = '',
        cancelled = false;

  final bool active;
  final UsbTransferDirection direction;
  final int totalFiles;
  final int completedFiles;
  final int failedFiles;
  final int totalBytes;
  final int transferredBytes;
  final double bytesPerSecond;
  final String currentFileName;
  final bool cancelled;

  double get fraction {
    if (totalBytes > 0) {
      return (transferredBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles > 0) {
      return (completedFiles / totalFiles).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  String get formattedSpeed {
    if (bytesPerSecond <= 0) return '--';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

/// Tracks active or completed USB file/batch transfers between Windows and phone.
class UsbTransferItem {
  const UsbTransferItem({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.status,
    this.totalBytes = 0,
    this.detail,
  });

  final String id;
  final String fileName;
  final UsbTransferDirection direction;
  final UsbTransferStatus status;
  final int totalBytes;
  final String? detail;

  UsbTransferItem copyWith({
    UsbTransferStatus? status,
    int? totalBytes,
    String? detail,
  }) {
    return UsbTransferItem(
      id: id,
      fileName: fileName,
      direction: direction,
      status: status ?? this.status,
      totalBytes: totalBytes ?? this.totalBytes,
      detail: detail ?? this.detail,
    );
  }
}

String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
