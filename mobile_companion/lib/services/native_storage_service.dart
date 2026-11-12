import 'dart:io';

import 'package:media_store_plus/media_store_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_protocol/shared_protocol.dart';

/// Persists verified incoming files into native OS public storage:
/// - Android: MediaStore Downloads / Pictures / Movies / Music (Scoped Storage)
/// - iOS: App Documents directory (exposed to the native Files app)
class NativeStorageService {
  NativeStorageService({
    required this._fallbackReceivedDir,
  });

  final Directory _fallbackReceivedDir;
  bool _androidMediaStoreReady = false;
  Directory? _iosDocsDir;

  Future<void> initialize() async {
    if (Platform.isAndroid) {
      await _initAndroidMediaStore();
    } else if (Platform.isIOS) {
      _iosDocsDir = await getApplicationDocumentsDirectory();
    }
    await _fallbackReceivedDir.create(recursive: true);
  }

  Future<void> _initAndroidMediaStore() async {
    try {
      await MediaStore.ensureInitialized();
      MediaStore.appFolder = 'DeviceBridge';
      final mediaStore = MediaStore();
      final sdk = await mediaStore.getPlatformSDKInt();
      if (sdk <= 32) {
        await Permission.storage.request();
      } else {
        await [
          Permission.photos,
          Permission.videos,
          Permission.audio,
        ].request();
      }
      _androidMediaStoreReady = true;
    } catch (_) {
      _androidMediaStoreReady = false;
    }
  }

  /// Directory exposed to the Windows "Phone File Browser" tab.
  Directory get browsableDirectory {
    if (Platform.isIOS && _iosDocsDir != null) {
      return _iosDocsDir!;
    }
    return _fallbackReceivedDir;
  }

  /// Commits a verified [stagedFile] into OS storage and returns the display path/URI.
  Future<String> commitFile(TransferOffer offer, File stagedFile) async {
    if (Platform.isAndroid && _androidMediaStoreReady) {
      return _commitAndroidMediaStore(offer, stagedFile);
    }

    final baseDir = browsableDirectory;
    final cleanRel = _sanitizeForJoin(offer.relativePath);
    final dest = File(p.join(baseDir.path, cleanRel));
    await dest.parent.create(recursive: true);
    if (await dest.exists()) {
      await dest.delete();
    }
    await stagedFile.rename(dest.path);
    return dest.path;
  }

  Future<String> _commitAndroidMediaStore(
    TransferOffer offer,
    File stagedFile,
  ) async {
    // Rename staged .part file to original filename so MediaStore records the right name.
    final namedTemp = File(p.join(stagedFile.parent.path, p.basename(offer.fileName)));
    if (await namedTemp.exists()) {
      await namedTemp.delete();
    }
    final preparedFile = await stagedFile.rename(namedTemp.path);

    // Also mirror a copy in app-accessible received folder so Phone File Browser can read it.
    final fallbackCopy = File(p.join(_fallbackReceivedDir.path, _sanitizeForJoin(offer.relativePath)));
    await fallbackCopy.parent.create(recursive: true);
    await preparedFile.copy(fallbackCopy.path);

    final ext = p.extension(offer.fileName).toLowerCase();
    final (DirType dirType, DirName dirName) = _classifyMediaTarget(ext);

    final subDir = p.dirname(offer.relativePath.replaceAll(r'\', '/'));
    final relativeFolder =
        (subDir == '.' || subDir.isEmpty) ? 'DeviceBridge' : p.join('DeviceBridge', subDir);

    final info = await MediaStore().saveFile(
      tempFilePath: preparedFile.path,
      dirType: dirType,
      dirName: dirName,
      relativePath: relativeFolder,
    );

    if (await preparedFile.exists()) {
      await preparedFile.delete();
    }

    return info?.uri.toString() ?? fallbackCopy.path;
  }

  static (DirType, DirName) _classifyMediaTarget(String ext) {
    const imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp'};
    const videoExts = {'.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v'};
    const audioExts = {'.mp3', '.wav', '.aac', '.flac', '.ogg', '.m4a'};

    if (imageExts.contains(ext)) {
      return (DirType.photo, DirName.pictures);
    }
    if (videoExts.contains(ext)) {
      return (DirType.video, DirName.movies);
    }
    if (audioExts.contains(ext)) {
      return (DirType.audio, DirName.music);
    }
    return (DirType.download, DirName.download);
  }

  static String _sanitizeForJoin(String relativePath) {
    final segments = relativePath
        .replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    if (segments.isEmpty) return 'received_file';
    return p.joinAll(segments);
  }
}

