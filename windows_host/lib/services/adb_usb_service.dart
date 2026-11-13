import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/usb_device_models.dart';
import 'native_tools_locator.dart';

class AdbBatchPullTask {
  const AdbBatchPullTask({
    required this.remotePosixPath,
    required this.destFile,
    required this.expectedBytes,
    required this.fileName,
  });

  final String remotePosixPath;
  final File destFile;
  final int expectedBytes;
  final String fileName;
}

class AdbBatchPushTask {
  const AdbBatchPushTask({
    required this.localFile,
    required this.targetFolderPosix,
    required this.sizeBytes,
    required this.fileName,
  });

  final File localFile;
  final String targetFolderPosix;
  final int sizeBytes;
  final String fileName;
}

class AdbBatchResult {
  const AdbBatchResult({
    required this.succeededFiles,
    required this.failureCount,
    required this.bytesTransferred,
    required this.cancelled,
  });

  final List<File> succeededFiles;
  final int failureCount;
  final int bytesTransferred;
  final bool cancelled;
}

/// Direct USB Android file reader/writer backed by bundled `adb.exe`.
/// Uses serial metadata caching and concurrent worker pools for bulk transfers.
class AdbUsbService {
  AdbUsbService({required this.locator});

  final NativeToolsLocator locator;

  static const String defaultRootPath = '/sdcard';
  static const int defaultBulkConcurrency = 3;

  final Map<String, ({String model, String manufacturer})> _deviceMetaCache = {};

  bool get isAvailable => locator.resolve(NativeToolKind.adb).isAvailable;

  String? get adbPath => locator.resolve(NativeToolKind.adb).resolvedPath;

  /// Lists Android devices detected by `adb devices -l` with cached properties.
  Future<List<UsbPhoneDevice>> listDevices() async {
    final exe = adbPath;
    if (exe == null) return const [];

    try {
      final result = await Process.run(exe, const ['devices', '-l']);
      if (result.exitCode != 0) return const [];

      final parsed = parseAdbDevicesOutput(result.stdout.toString());
      final activeSerials = parsed.map((d) => d.serial).toSet();
      _deviceMetaCache.removeWhere((serial, _) => !activeSerials.contains(serial));

      final devices = <UsbPhoneDevice>[];

      for (final raw in parsed) {
        if (!raw.authorized) {
          devices.add(
            UsbPhoneDevice(
              id: 'adb:${raw.serial}',
              name: raw.model.isNotEmpty ? raw.model : raw.serial,
              manufacturer: 'Android',
              os: MobileOs.android,
              backend: UsbBackendMode.adb,
              authorized: false,
              adbSerial: raw.serial,
            ),
          );
          continue;
        }

        var meta = _deviceMetaCache[raw.serial];
        if (meta == null) {
          var friendly = raw.model.replaceAll('_', ' ');
          var manufacturer = 'Android';
          try {
            final res = await Process.run(
              exe,
              [
                '-s',
                raw.serial,
                'shell',
                'getprop ro.product.model; getprop ro.product.manufacturer',
              ],
            ).timeout(const Duration(seconds: 3));
            final lines = res.stdout
                .toString()
                .split(RegExp(r'\r?\n'))
                .map((s) => s.trim())
                .toList();
            if (lines.isNotEmpty && lines[0].isNotEmpty) {
              friendly = lines[0];
            }
            if (lines.length > 1 && lines[1].isNotEmpty) {
              manufacturer = lines[1];
            }
          } catch (_) {
            // Keep parsed fallback model.
          }
          meta = (
            model: friendly.isEmpty ? raw.serial : friendly,
            manufacturer: manufacturer,
          );
          _deviceMetaCache[raw.serial] = meta;
        }

        devices.add(
          UsbPhoneDevice(
            id: 'adb:${raw.serial}',
            name: meta.model,
            manufacturer: meta.manufacturer,
            os: MobileOs.android,
            backend: UsbBackendMode.adb,
            authorized: true,
            adbSerial: raw.serial,
          ),
        );
      }
      return devices;
    } catch (_) {
      return const [];
    }
  }

  /// Lists directory entries on Android at [posixPath] (defaults to `/sdcard`).
  Future<List<UsbFileEntry>> listDirectory({
    required String serial,
    String posixPath = defaultRootPath,
  }) async {
    final exe = adbPath;
    if (exe == null) {
      throw StateError('adb.exe not found in native tools.');
    }

    final target = posixPath.isEmpty ? defaultRootPath : posixPath;
    final quoted = _shellQuote(target);
    final res = await Process.run(
      exe,
      ['-s', serial, 'shell', 'ls -lApL $quoted 2>/dev/null || ls -lAp $quoted'],
    );
    if (res.exitCode != 0 && res.stdout.toString().trim().isEmpty) {
      throw ProcessException(
        exe,
        ['-s', serial, 'shell', 'ls -lAp', target],
        res.stderr.toString().trim(),
        res.exitCode,
      );
    }

    return parseLsLongOutput(
      res.stdout.toString(),
      parentPosixPath: target,
    );
  }

  /// Pulls [remotePosixPath] from Android directly to [destFile] over USB.
  Future<File> pullFile({
    required String serial,
    required String remotePosixPath,
    required File destFile,
  }) async {
    final exe = adbPath;
    if (exe == null) {
      throw StateError('adb.exe not found.');
    }

    await destFile.parent.create(recursive: true);
    final partFile = File('${destFile.path}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }

    final res = await Process.run(
      exe,
      ['-s', serial, 'pull', remotePosixPath, partFile.path],
    );
    if (res.exitCode != 0 || !await partFile.exists()) {
      throw ProcessException(
        exe,
        ['pull', remotePosixPath],
        res.stderr.toString().trim().isNotEmpty
            ? res.stderr.toString().trim()
            : res.stdout.toString().trim(),
        res.exitCode,
      );
    }

    if (await destFile.exists()) {
      await destFile.delete();
    }
    return partFile.rename(destFile.path);
  }

  /// Concurrent bulk pull over ADB multiplexed USB channels.
  Future<AdbBatchResult> pullBatch({
    required String serial,
    required List<AdbBatchPullTask> tasks,
    required bool Function() isCancelled,
    void Function(int completed, int failed, int bytes, String currentFile)?
        onProgress,
    int concurrency = defaultBulkConcurrency,
  }) async {
    if (tasks.isEmpty) {
      return const AdbBatchResult(
        succeededFiles: [],
        failureCount: 0,
        bytesTransferred: 0,
        cancelled: false,
      );
    }

    final succeeded = <File>[];
    var failed = 0;
    var completed = 0;
    var bytesDone = 0;
    var nextIndex = 0;
    var cancelled = false;

    Future<void> worker() async {
      while (true) {
        if (isCancelled()) {
          cancelled = true;
          return;
        }
        final idx = nextIndex++;
        if (idx >= tasks.length) return;
        final task = tasks[idx];
        try {
          final file = await pullFile(
            serial: serial,
            remotePosixPath: task.remotePosixPath,
            destFile: task.destFile,
          );
          succeeded.add(file);
          bytesDone += task.expectedBytes > 0
              ? task.expectedBytes
              : (await file.length());
        } catch (_) {
          failed++;
        }
        completed++;
        onProgress?.call(completed, failed, bytesDone, task.fileName);
      }
    }

    final workerCount = tasks.length < concurrency ? tasks.length : concurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    return AdbBatchResult(
      succeededFiles: succeeded,
      failureCount: failed,
      bytesTransferred: bytesDone,
      cancelled: cancelled,
    );
  }

  /// Concurrent bulk push with batched `mkdir -p` and single post-transfer media scan.
  Future<AdbBatchResult> pushBatch({
    required String serial,
    required List<AdbBatchPushTask> tasks,
    required bool Function() isCancelled,
    void Function(int completed, int failed, int bytes, String currentFile)?
        onProgress,
    int concurrency = defaultBulkConcurrency,
  }) async {
    final exe = adbPath;
    if (exe == null) {
      throw StateError('adb.exe not found.');
    }
    if (tasks.isEmpty) {
      return const AdbBatchResult(
        succeededFiles: [],
        failureCount: 0,
        bytesTransferred: 0,
        cancelled: false,
      );
    }

    // Batch-create all unique target directories once up front.
    final uniqueDirs = tasks.map((t) => t.targetFolderPosix).toSet().toList();
    for (var i = 0; i < uniqueDirs.length; i += 20) {
      final slice = uniqueDirs.sublist(
        i,
        (i + 20) > uniqueDirs.length ? uniqueDirs.length : i + 20,
      );
      final quotedDirs = slice.map(_shellQuote).join(' ');
      await Process.run(exe, ['-s', serial, 'shell', 'mkdir -p $quotedDirs']);
    }

    final pushedRemotePaths = <String>[];
    var failed = 0;
    var completed = 0;
    var bytesDone = 0;
    var nextIndex = 0;
    var cancelled = false;

    Future<void> worker() async {
      while (true) {
        if (isCancelled()) {
          cancelled = true;
          return;
        }
        final idx = nextIndex++;
        if (idx >= tasks.length) return;
        final task = tasks[idx];
        final remoteFile = task.targetFolderPosix.endsWith('/')
            ? '${task.targetFolderPosix}${task.fileName}'
            : '${task.targetFolderPosix}/${task.fileName}';

        try {
          final res = await Process.run(
            exe,
            ['-s', serial, 'push', task.localFile.path, remoteFile],
          );
          if (res.exitCode == 0) {
            bytesDone += task.sizeBytes;
            pushedRemotePaths.add(remoteFile);
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
        completed++;
        onProgress?.call(completed, failed, bytesDone, task.fileName);
      }
    }

    final workerCount = tasks.length < concurrency ? tasks.length : concurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    // Trigger Android media scan once for the target directories/sample files.
    if (pushedRemotePaths.isNotEmpty) {
      final dirToScan = tasks.first.targetFolderPosix;
      unawaited(
        Process.run(
          exe,
          [
            '-s',
            serial,
            'shell',
            'am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d ${_shellQuote("file://$dirToScan")}',
          ],
        ),
      );
    }

    return AdbBatchResult(
      succeededFiles: const [],
      failureCount: failed,
      bytesTransferred: bytesDone,
      cancelled: cancelled,
    );
  }

  /// Pushes a single local Windows [localFile] to [targetFolderPosix] on Android.
  Future<void> pushFile({
    required String serial,
    required File localFile,
    required String targetFolderPosix,
    String? remoteFileName,
  }) async {
    final name = remoteFileName ?? p.basename(localFile.path);
    final size = await localFile.length();
    final res = await pushBatch(
      serial: serial,
      tasks: [
        AdbBatchPushTask(
          localFile: localFile,
          targetFolderPosix: targetFolderPosix.isEmpty
              ? '$defaultRootPath/Download/DeviceBridge'
              : targetFolderPosix,
          sizeBytes: size,
          fileName: name,
        ),
      ],
      isCancelled: () => false,
    );
    if (res.failureCount > 0) {
      throw ProcessException(
        adbPath ?? 'adb',
        ['push', localFile.path, targetFolderPosix],
        'Failed pushing $name via ADB',
      );
    }
  }

  static List<ParsedAdbDevice> parseAdbDevicesOutput(String output) {
    final devices = <ParsedAdbDevice>[];
    for (final rawLine in output.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('List of devices') ||
          line.startsWith('* daemon')) {
        continue;
      }

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final serial = parts[0];
      final state = parts[1];
      if (state == 'offline') continue;

      var model = '';
      for (final token in parts.skip(2)) {
        if (token.startsWith('model:')) {
          model = token.substring('model:'.length);
          break;
        }
      }

      devices.add(
        ParsedAdbDevice(
          serial: serial,
          state: state,
          authorized: state == 'device',
          model: model,
        ),
      );
    }
    return devices;
  }

  /// Parses `ls -lAp` / `ls -lApL` output into sorted [UsbFileEntry] items.
  static List<UsbFileEntry> parseLsLongOutput(
    String stdoutText, {
    required String parentPosixPath,
  }) {
    final entries = <UsbFileEntry>[];
    final isoPattern = RegExp(
      r'^([dl\-cbps][rwxstST\-]{9,11})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+(.+)$',
    );
    final monthPattern = RegExp(
      r'^([dl\-cbps][rwxstST\-]{9,11})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3}\s+\d{1,2}\s+[\d:]{4,5})\s+(.+)$',
    );

    final normalizedParent =
        parentPosixPath.endsWith('/') && parentPosixPath.length > 1
            ? parentPosixPath.substring(0, parentPosixPath.length - 1)
            : parentPosixPath;

    for (final rawLine in stdoutText.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith('total ')) continue;

      final match = isoPattern.firstMatch(line) ?? monthPattern.firstMatch(line);
      if (match == null) continue;

      final mode = match.group(1)!;
      final sizeBytes = int.tryParse(match.group(2)!) ?? 0;
      final timestamp = match.group(3)!;
      var rawName = match.group(4)!.trimRight();

      if (rawName == '.' ||
          rawName == './' ||
          rawName == '..' ||
          rawName == '../') {
        continue;
      }

      var isDir = mode.startsWith('d') || rawName.endsWith('/');
      if (mode.startsWith('l') && rawName.contains(' -> ')) {
        final idx = rawName.indexOf(' -> ');
        final target = rawName.substring(idx + 4);
        rawName = rawName.substring(0, idx);
        if (target.endsWith('/')) isDir = true;
      }

      if (rawName.endsWith('/')) {
        rawName = rawName.substring(0, rawName.length - 1);
      }
      if (rawName.isEmpty) continue;

      final fullPath = normalizedParent == '/'
          ? '/$rawName'
          : '$normalizedParent/$rawName';

      entries.add(
        UsbFileEntry(
          id: fullPath,
          name: rawName,
          isDirectory: isDir,
          sizeBytes: isDir ? 0 : sizeBytes,
          displayPath: fullPath,
          modifiedLabel: timestamp,
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static String _shellQuote(String value) {
    final escaped = value.replaceAll("'", r"'\''");
    return "'$escaped'";
  }
}

class ParsedAdbDevice {
  const ParsedAdbDevice({
    required this.serial,
    required this.state,
    required this.authorized,
    required this.model,
  });

  final String serial;
  final String state;
  final bool authorized;
  final String model;
}
