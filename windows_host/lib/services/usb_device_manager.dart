import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/usb_device_models.dart';
import 'adb_usb_service.dart';
import 'wpd_usb_service.dart';

class BulkPullSummary {
  const BulkPullSummary({
    required this.files,
    required this.failureCount,
    required this.bytesTransferred,
    required this.cancelled,
  });

  final List<File> files;
  final int failureCount;
  final int bytesTransferred;
  final bool cancelled;
}

class BulkPushSummary {
  const BulkPushSummary({
    required this.succeededCount,
    required this.failureCount,
    required this.bytesTransferred,
    required this.cancelled,
  });

  final int succeededCount;
  final int failureCount;
  final int bytesTransferred;
  final bool cancelled;
}

/// Unified plug-and-play USB orchestrator for Android (ADB + MTP/WPD) and iOS (Apple PTP/WPD).
/// Optimized for high-speed bulk transfers with persistent WPD sessions and parallel ADB streams.
class UsbDeviceManager {
  UsbDeviceManager({
    required WpdUsbService wpdService,
    required AdbUsbService adbService,
  })  : _wpd = wpdService,
        _adb = adbService;

  final WpdUsbService _wpd;
  final AdbUsbService _adb;

  final StreamController<List<UsbPhoneDevice>> _devicesController =
      StreamController<List<UsbPhoneDevice>>.broadcast();
  final StreamController<List<UsbTransferItem>> _transfersController =
      StreamController<List<UsbTransferItem>>.broadcast();
  final StreamController<BatchTransferProgress> _batchProgressController =
      StreamController<BatchTransferProgress>.broadcast();

  final List<UsbTransferItem> _transfers = [];
  List<UsbPhoneDevice> _devices = const [];

  Timer? _pollTimer;
  StreamSubscription<void>? _hwSub;
  StreamSubscription<WpdNativeProgressEvent>? _wpdProgressSub;

  bool _scanning = false;
  bool _batchActive = false;
  bool _batchCancelled = false;
  int _nextTxId = 0;

  Stopwatch? _activeBatchClock;
  int _activeBatchTotalFiles = 0;
  int _activeBatchTotalBytes = 0;

  Stream<List<UsbPhoneDevice>> get devicesStream => _devicesController.stream;
  Stream<List<UsbTransferItem>> get transfersStream =>
      _transfersController.stream;
  Stream<BatchTransferProgress> get batchProgressStream =>
      _batchProgressController.stream;

  List<UsbPhoneDevice> get currentDevices => List.unmodifiable(_devices);
  List<UsbTransferItem> get currentTransfers => List.unmodifiable(_transfers);

  void startMonitoring() {
    _hwSub ??= _wpd.usbHardwareChangeStream.listen((_) {
      Future<void>.delayed(
        const Duration(milliseconds: 500),
        () => scanDevices(force: true),
      );
    });
    _wpdProgressSub ??= _wpd.batchProgressStream.listen(_handleWpdProgress);
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => scanDevices(),
    );
    unawaited(scanDevices(force: true));
  }

  void _handleWpdProgress(WpdNativeProgressEvent ev) {
    if (!_batchActive) return;
    final elapsedSec =
        (_activeBatchClock?.elapsedMilliseconds ?? 1) / 1000.0;
    final speed = elapsedSec > 0.05 ? ev.bytesTransferred / elapsedSec : 0.0;
    _emitBatchProgress(
      BatchTransferProgress(
        active: true,
        direction: ev.direction,
        totalFiles: ev.totalFiles > 0 ? ev.totalFiles : _activeBatchTotalFiles,
        completedFiles: ev.completedFiles,
        failedFiles: 0,
        totalBytes: _activeBatchTotalBytes,
        transferredBytes: ev.bytesTransferred,
        bytesPerSecond: speed,
        currentFileName: ev.currentFile,
      ),
    );
  }

  Future<List<UsbPhoneDevice>> scanDevices({bool force = false}) async {
    if (_scanning) return _devices;
    if (_batchActive && !force) return _devices;
    _scanning = true;
    try {
      final results = await Future.wait([
        _adb.listDevices(),
        _wpd.listDevices(),
      ]);
      final merged = mergeDevices(
        adbDevices: results[0],
        wpdDevices: results[1],
      );

      if (!_deviceListsEqual(_devices, merged) || force) {
        _devices = merged;
        if (!_devicesController.isClosed) {
          _devicesController.add(merged);
        }
      }
      return merged;
    } finally {
      _scanning = false;
    }
  }

  static bool _deviceListsEqual(
    List<UsbPhoneDevice> a,
    List<UsbPhoneDevice> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<UsbPhoneDevice> mergeDevices({
    required List<UsbPhoneDevice> adbDevices,
    required List<UsbPhoneDevice> wpdDevices,
  }) {
    final authorizedAdb = adbDevices.where((d) => d.authorized).toList();
    final unauthorizedAdb = adbDevices.where((d) => !d.authorized).toList();

    final merged = <UsbPhoneDevice>[...authorizedAdb];

    for (final wpd in wpdDevices) {
      final matchesAuthorizedAdb = authorizedAdb.any((adb) {
        if (wpd.os != MobileOs.android) return false;
        final a = adb.name.toLowerCase().trim();
        final w = wpd.name.toLowerCase().trim();
        return a.isNotEmpty &&
            w.isNotEmpty &&
            (w.contains(a) || a.contains(w));
      });
      if (!matchesAuthorizedAdb) {
        final matchingUnauth =
            wpd.os == MobileOs.android && unauthorizedAdb.isNotEmpty
                ? unauthorizedAdb.first.adbSerial
                : null;
        merged.add(
          UsbPhoneDevice(
            id: wpd.id,
            name: wpd.name,
            manufacturer: wpd.manufacturer,
            os: wpd.os,
            backend: UsbBackendMode.wpd,
            authorized: true,
            adbSerial: matchingUnauth,
            wpdDeviceId: wpd.wpdDeviceId,
          ),
        );
      }
    }

    if (merged.isEmpty && unauthorizedAdb.isNotEmpty) {
      merged.addAll(unauthorizedAdb);
    }

    return merged;
  }

  /// Cancels any active bulk pull or push operation as soon as the current chunk finishes.
  Future<void> cancelActiveBatch() async {
    _batchCancelled = true;
    await _wpd.cancelBatch();
  }

  /// Opens the initial folder breadcrumbs + entries for [device].
  Future<({List<UsbPathSegment> breadcrumbs, List<UsbFileEntry> entries})>
      openInitialDirectory(UsbPhoneDevice device) async {
    if (!device.authorized && device.backend == UsbBackendMode.adb) {
      return (
        breadcrumbs: const [
          UsbPathSegment(id: AdbUsbService.defaultRootPath, label: 'Phone'),
        ],
        entries: const <UsbFileEntry>[],
      );
    }

    if (device.backend == UsbBackendMode.adb) {
      final entries = await _adb.listDirectory(
        serial: device.adbSerial!,
        posixPath: AdbUsbService.defaultRootPath,
      );
      return (
        breadcrumbs: const [
          UsbPathSegment(
            id: AdbUsbService.defaultRootPath,
            label: 'Internal Storage',
          ),
        ],
        entries: entries,
      );
    }

    final rootEntries = await _wpd.listChildren(
      wpdDeviceId: device.wpdDeviceId!,
      folderObjectId: '',
    );

    if (rootEntries.length == 1 && rootEntries.first.isDirectory) {
      final storage = rootEntries.first;
      final childEntries = await _wpd.listChildren(
        wpdDeviceId: device.wpdDeviceId!,
        folderObjectId: storage.id,
        parentDisplayPath: storage.name,
      );
      return (
        breadcrumbs: [
          const UsbPathSegment(id: '', label: 'Device'),
          UsbPathSegment(id: storage.id, label: storage.name),
        ],
        entries: childEntries,
      );
    }

    return (
      breadcrumbs: const [UsbPathSegment(id: '', label: 'Device')],
      entries: rootEntries,
    );
  }

  Future<List<UsbFileEntry>> listFolder({
    required UsbPhoneDevice device,
    required String folderId,
    String displayPath = '',
  }) {
    if (device.backend == UsbBackendMode.adb) {
      return _adb.listDirectory(
        serial: device.adbSerial!,
        posixPath: folderId,
      );
    }
    return _wpd.listChildren(
      wpdDeviceId: device.wpdDeviceId!,
      folderObjectId: folderId,
      parentDisplayPath: displayPath,
    );
  }

  /// Pulls a single file from [device] to [targetDir] (fast direct path for single drag/save).
  Future<File> pullFile({
    required UsbPhoneDevice device,
    required UsbFileEntry entry,
    required Directory targetDir,
  }) async {
    final summary = await pullBatch(
      device: device,
      entries: [entry],
      targetDir: targetDir,
    );
    if (summary.files.isEmpty) {
      throw StateError('Failed to copy ${entry.name} over USB.');
    }
    return summary.files.first;
  }

  /// High-speed bulk pull for exporting or multi-file dragging from phone to Windows.
  Future<BulkPullSummary> pullBatch({
    required UsbPhoneDevice device,
    required List<UsbFileEntry> entries,
    required Directory targetDir,
  }) async {
    if (entries.isEmpty) {
      return const BulkPullSummary(
        files: [],
        failureCount: 0,
        bytesTransferred: 0,
        cancelled: false,
      );
    }

    await targetDir.create(recursive: true);

    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);
    final label = entries.length == 1
        ? entries.first.name
        : '${entries.length} files (${formatByteCount(totalBytes)})';
    final txId = 'pull-${++_nextTxId}';

    _upsertTransfer(
      UsbTransferItem(
        id: txId,
        fileName: label,
        direction: UsbTransferDirection.phoneToPc,
        status: UsbTransferStatus.running,
        totalBytes: totalBytes,
        detail: 'Copying over USB...',
      ),
    );

    _beginBatch(
      direction: UsbTransferDirection.phoneToPc,
      totalFiles: entries.length,
      totalBytes: totalBytes,
      firstFile: entries.first.name,
    );

    try {
      List<File> pulledFiles;
      int failureCount;
      int transferredBytes;
      bool cancelled;

      if (device.backend == UsbBackendMode.adb) {
        final tasks = entries
            .map(
              (entry) => AdbBatchPullTask(
                remotePosixPath: entry.id,
                destFile: File(p.join(targetDir.path, entry.name)),
                expectedBytes: entry.sizeBytes,
                fileName: entry.name,
              ),
            )
            .toList(growable: false);

        var lastEmitMs = 0;
        final res = await _adb.pullBatch(
          serial: device.adbSerial!,
          tasks: tasks,
          isCancelled: () => _batchCancelled,
          onProgress: (completed, failed, bytes, currentFile) {
            final nowMs = _activeBatchClock?.elapsedMilliseconds ?? 0;
            if (completed == entries.length || nowMs - lastEmitMs >= 80) {
              lastEmitMs = nowMs;
              final sec = nowMs / 1000.0;
              _emitBatchProgress(
                BatchTransferProgress(
                  active: true,
                  direction: UsbTransferDirection.phoneToPc,
                  totalFiles: entries.length,
                  completedFiles: completed,
                  failedFiles: failed,
                  totalBytes: totalBytes,
                  transferredBytes: bytes,
                  bytesPerSecond: sec > 0.05 ? bytes / sec : 0.0,
                  currentFileName: currentFile,
                ),
              );
            }
          },
        );
        pulledFiles = res.succeededFiles;
        failureCount = res.failureCount;
        transferredBytes = res.bytesTransferred;
        cancelled = res.cancelled;
      } else {
        final items = entries
            .map(
              (entry) => WpdBatchPullItem(
                objectId: entry.id,
                destPath: p.join(targetDir.path, entry.name),
                fileName: entry.name,
              ),
            )
            .toList(growable: false);

        final res = await _wpd.pullBatch(
          wpdDeviceId: device.wpdDeviceId!,
          items: items,
        );
        pulledFiles =
            res.succeededPaths.map(File.new).toList(growable: false);
        failureCount = res.failureCount;
        transferredBytes = res.bytesTransferred;
        cancelled = res.cancelled;
      }

      final elapsedSec =
          (_activeBatchClock?.elapsedMilliseconds ?? 1).clamp(1, 36000000) /
              1000.0;
      final avgMbPerSec =
          (transferredBytes / (1024 * 1024) / elapsedSec).toStringAsFixed(1);

      _updateTransfer(
        txId,
        (t) => t.copyWith(
          status: cancelled
              ? UsbTransferStatus.cancelled
              : (pulledFiles.isEmpty && failureCount > 0)
                  ? UsbTransferStatus.failed
                  : UsbTransferStatus.completed,
          detail: cancelled
              ? 'Cancelled (${pulledFiles.length}/${entries.length} saved)'
              : '${pulledFiles.length} saved ($avgMbPerSec MB/s)${failureCount > 0 ? " • $failureCount failed" : ""}',
        ),
      );

      return BulkPullSummary(
        files: pulledFiles,
        failureCount: failureCount,
        bytesTransferred: transferredBytes,
        cancelled: cancelled,
      );
    } catch (e) {
      _updateTransfer(
        txId,
        (t) => t.copyWith(
          status: UsbTransferStatus.failed,
          detail: e.toString(),
        ),
      );
      rethrow;
    } finally {
      _endBatch();
    }
  }

  /// High-speed bulk push for dropped Windows files or entire folder trees.
  Future<BulkPushSummary> pushLocalPaths({
    required UsbPhoneDevice device,
    required List<String> localPaths,
    required String targetFolderId,
  }) async {
    if (!device.canWriteFiles) {
      throw UnsupportedError(
        'Apple iPhone/iPad USB (PTP) only allows reading & copying photos/videos to Windows. Writing files back to iPhone over USB PTP is blocked by iOS.',
      );
    }

    if (device.backend == UsbBackendMode.adb) {
      final basePosix = targetFolderId.isEmpty
          ? '${AdbUsbService.defaultRootPath}/Download/DeviceBridge'
          : targetFolderId;

      final tasks = <AdbBatchPushTask>[];
      var totalBytes = 0;

      for (final rawPath in localPaths) {
        final type = await FileSystemEntity.type(rawPath);
        if (type == FileSystemEntityType.file) {
          final file = File(rawPath);
          final size = await file.length();
          totalBytes += size;
          tasks.add(
            AdbBatchPushTask(
              localFile: file,
              targetFolderPosix: basePosix,
              sizeBytes: size,
              fileName: p.basename(file.path),
            ),
          );
        } else if (type == FileSystemEntityType.directory) {
          final dir = Directory(rawPath);
          final rootName = p.basename(dir.path);
          await for (final entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is File) {
              final size = await entity.length();
              totalBytes += size;
              final relDir =
                  p.dirname(p.relative(entity.path, from: dir.path));
              final subPosix = (relDir == '.' || relDir.isEmpty)
                  ? '$basePosix/$rootName'
                  : '$basePosix/$rootName/${relDir.replaceAll(r'\', '/')}';
              tasks.add(
                AdbBatchPushTask(
                  localFile: entity,
                  targetFolderPosix: subPosix,
                  sizeBytes: size,
                  fileName: p.basename(entity.path),
                ),
              );
            }
          }
        }
      }

      if (tasks.isEmpty) {
        return const BulkPushSummary(
          succeededCount: 0,
          failureCount: 0,
          bytesTransferred: 0,
          cancelled: false,
        );
      }

      final txId = 'push-${++_nextTxId}';
      _upsertTransfer(
        UsbTransferItem(
          id: txId,
          fileName: tasks.length == 1
              ? tasks.first.fileName
              : '${tasks.length} files (${formatByteCount(totalBytes)})',
          direction: UsbTransferDirection.pcToPhone,
          status: UsbTransferStatus.running,
          totalBytes: totalBytes,
          detail: 'Pushing via ADB USB...',
        ),
      );

      _beginBatch(
        direction: UsbTransferDirection.pcToPhone,
        totalFiles: tasks.length,
        totalBytes: totalBytes,
        firstFile: tasks.first.fileName,
      );

      try {
        var lastEmitMs = 0;
        final res = await _adb.pushBatch(
          serial: device.adbSerial!,
          tasks: tasks,
          isCancelled: () => _batchCancelled,
          onProgress: (completed, failed, bytes, currentFile) {
            final nowMs = _activeBatchClock?.elapsedMilliseconds ?? 0;
            if (completed == tasks.length || nowMs - lastEmitMs >= 80) {
              lastEmitMs = nowMs;
              final sec = nowMs / 1000.0;
              _emitBatchProgress(
                BatchTransferProgress(
                  active: true,
                  direction: UsbTransferDirection.pcToPhone,
                  totalFiles: tasks.length,
                  completedFiles: completed,
                  failedFiles: failed,
                  totalBytes: totalBytes,
                  transferredBytes: bytes,
                  bytesPerSecond: sec > 0.05 ? bytes / sec : 0.0,
                  currentFileName: currentFile,
                ),
              );
            }
          },
        );

        final succeededCount = tasks.length - res.failureCount;
        final elapsedSec =
            (_activeBatchClock?.elapsedMilliseconds ?? 1).clamp(1, 36000000) /
                1000.0;
        final avgMbPerSec =
            (res.bytesTransferred / (1024 * 1024) / elapsedSec)
                .toStringAsFixed(1);

        _updateTransfer(
          txId,
          (t) => t.copyWith(
            status: res.cancelled
                ? UsbTransferStatus.cancelled
                : (succeededCount == 0 && res.failureCount > 0)
                    ? UsbTransferStatus.failed
                    : UsbTransferStatus.completed,
            detail: res.cancelled
                ? 'Cancelled'
                : 'Sent $succeededCount file(s) ($avgMbPerSec MB/s)',
          ),
        );

        return BulkPushSummary(
          succeededCount: succeededCount,
          failureCount: res.failureCount,
          bytesTransferred: res.bytesTransferred,
          cancelled: res.cancelled,
        );
      } catch (e) {
        _updateTransfer(
          txId,
          (t) => t.copyWith(
            status: UsbTransferStatus.failed,
            detail: e.toString(),
          ),
        );
        rethrow;
      } finally {
        _endBatch();
      }
    }

    // WPD / MTP persistent-session bulk push
    final wpdId = device.wpdDeviceId!;
    final resolvedRootFolderId = await _resolveWritableWpdFolder(
      wpdDeviceId: wpdId,
      preferredFolderId: targetFolderId,
    );

    final pushItems = <WpdBatchPushItem>[];
    var totalBytes = 0;

    for (final rawPath in localPaths) {
      final type = await FileSystemEntity.type(rawPath);
      if (type == FileSystemEntityType.file) {
        final file = File(rawPath);
        totalBytes += await file.length();
        pushItems.add(
          WpdBatchPushItem(
            targetFolderObjectId: resolvedRootFolderId,
            localPath: file.path,
            fileName: p.basename(file.path),
          ),
        );
      } else if (type == FileSystemEntityType.directory) {
        await _collectWpdDirTasks(
          wpdDeviceId: wpdId,
          localDir: Directory(rawPath),
          parentObjectId: resolvedRootFolderId,
          outItems: pushItems,
          onBytes: (b) => totalBytes += b,
        );
      }
    }

    if (pushItems.isEmpty) {
      return const BulkPushSummary(
        succeededCount: 0,
        failureCount: 0,
        bytesTransferred: 0,
        cancelled: false,
      );
    }

    final txId = 'push-${++_nextTxId}';
    _upsertTransfer(
      UsbTransferItem(
        id: txId,
        fileName: pushItems.length == 1
            ? pushItems.first.fileName
            : '${pushItems.length} files (${formatByteCount(totalBytes)})',
        direction: UsbTransferDirection.pcToPhone,
        status: UsbTransferStatus.running,
        totalBytes: totalBytes,
        detail: 'Writing over USB MTP...',
      ),
    );

    _beginBatch(
      direction: UsbTransferDirection.pcToPhone,
      totalFiles: pushItems.length,
      totalBytes: totalBytes,
      firstFile: pushItems.first.fileName,
    );

    try {
      final res = await _wpd.pushBatch(
        wpdDeviceId: wpdId,
        items: pushItems,
      );
      final succeededCount = pushItems.length - res.failureCount;
      final elapsedSec =
          (_activeBatchClock?.elapsedMilliseconds ?? 1).clamp(1, 36000000) /
              1000.0;
      final avgMbPerSec =
          (res.bytesTransferred / (1024 * 1024) / elapsedSec)
              .toStringAsFixed(1);

      _updateTransfer(
        txId,
        (t) => t.copyWith(
          status: res.cancelled
              ? UsbTransferStatus.cancelled
              : (succeededCount == 0 && res.failureCount > 0)
                  ? UsbTransferStatus.failed
                  : UsbTransferStatus.completed,
          detail: res.cancelled
              ? 'Cancelled'
              : 'Sent $succeededCount file(s) ($avgMbPerSec MB/s)',
        ),
      );

      return BulkPushSummary(
        succeededCount: succeededCount,
        failureCount: res.failureCount,
        bytesTransferred: res.bytesTransferred,
        cancelled: res.cancelled,
      );
    } catch (e) {
      _updateTransfer(
        txId,
        (t) => t.copyWith(
          status: UsbTransferStatus.failed,
          detail: e.toString(),
        ),
      );
      rethrow;
    } finally {
      _endBatch();
    }
  }

  Future<void> _collectWpdDirTasks({
    required String wpdDeviceId,
    required Directory localDir,
    required String parentObjectId,
    required List<WpdBatchPushItem> outItems,
    required void Function(int) onBytes,
  }) async {
    final targetId = await _getOrCreateWpdChildFolder(
      wpdDeviceId: wpdDeviceId,
      parentId: parentObjectId,
      folderName: p.basename(localDir.path),
    );

    await for (final entity in localDir.list(followLinks: false)) {
      if (entity is File) {
        onBytes(await entity.length());
        outItems.add(
          WpdBatchPushItem(
            targetFolderObjectId: targetId,
            localPath: entity.path,
            fileName: p.basename(entity.path),
          ),
        );
      } else if (entity is Directory) {
        await _collectWpdDirTasks(
          wpdDeviceId: wpdDeviceId,
          localDir: entity,
          parentObjectId: targetId,
          outItems: outItems,
          onBytes: onBytes,
        );
      }
    }
  }

  Future<String> _resolveWritableWpdFolder({
    required String wpdDeviceId,
    required String preferredFolderId,
  }) async {
    if (preferredFolderId.isNotEmpty) {
      return preferredFolderId;
    }

    final storages = await _wpd.listChildren(
      wpdDeviceId: wpdDeviceId,
      folderObjectId: '',
    );
    final storage = storages.firstWhere(
      (e) => e.isDirectory,
      orElse: () => throw StateError('No writable storage found on USB device.'),
    );

    final topFolders = await _wpd.listChildren(
      wpdDeviceId: wpdDeviceId,
      folderObjectId: storage.id,
    );
    final download = topFolders.where(
      (e) => e.isDirectory && e.name.toLowerCase().startsWith('download'),
    );
    final baseFolderId = download.isNotEmpty ? download.first.id : storage.id;

    return _getOrCreateWpdChildFolder(
      wpdDeviceId: wpdDeviceId,
      parentId: baseFolderId,
      folderName: 'DeviceBridge',
    );
  }

  Future<String> _getOrCreateWpdChildFolder({
    required String wpdDeviceId,
    required String parentId,
    required String folderName,
  }) async {
    final children = await _wpd.listChildren(
      wpdDeviceId: wpdDeviceId,
      folderObjectId: parentId,
    );
    for (final child in children) {
      if (child.isDirectory &&
          child.name.toLowerCase() == folderName.toLowerCase()) {
        return child.id;
      }
    }
    return _wpd.createFolder(
      wpdDeviceId: wpdDeviceId,
      parentObjectId: parentId,
      folderName: folderName,
    );
  }

  void _beginBatch({
    required UsbTransferDirection direction,
    required int totalFiles,
    required int totalBytes,
    required String firstFile,
  }) {
    _batchActive = true;
    _batchCancelled = false;
    _activeBatchTotalFiles = totalFiles;
    _activeBatchTotalBytes = totalBytes;
    _activeBatchClock = Stopwatch()..start();

    _emitBatchProgress(
      BatchTransferProgress(
        active: true,
        direction: direction,
        totalFiles: totalFiles,
        completedFiles: 0,
        failedFiles: 0,
        totalBytes: totalBytes,
        transferredBytes: 0,
        bytesPerSecond: 0,
        currentFileName: firstFile,
      ),
    );
  }

  void _endBatch() {
    _batchActive = false;
    _activeBatchClock?.stop();
    _activeBatchClock = null;
    _emitBatchProgress(const BatchTransferProgress.idle());
  }

  void _emitBatchProgress(BatchTransferProgress progress) {
    if (!_batchProgressController.isClosed) {
      _batchProgressController.add(progress);
    }
  }

  void _upsertTransfer(UsbTransferItem item) {
    final idx = _transfers.indexWhere((t) => t.id == item.id);
    if (idx >= 0) {
      _transfers[idx] = item;
    } else {
      _transfers.insert(0, item);
      if (_transfers.length > 100) {
        _transfers.removeRange(100, _transfers.length);
      }
    }
    _emitTransfers();
  }

  void _updateTransfer(
    String id,
    UsbTransferItem Function(UsbTransferItem) transform,
  ) {
    final idx = _transfers.indexWhere((t) => t.id == id);
    if (idx >= 0) {
      _transfers[idx] = transform(_transfers[idx]);
      _emitTransfers();
    }
  }

  void _emitTransfers() {
    if (!_transfersController.isClosed) {
      _transfersController.add(List.unmodifiable(_transfers));
    }
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    await _hwSub?.cancel();
    await _wpdProgressSub?.cancel();
    await _devicesController.close();
    await _transfersController.close();
    await _batchProgressController.close();
  }
}
