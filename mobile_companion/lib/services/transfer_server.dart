import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shared_protocol/shared_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Callback that persists a verified staging file into final storage and
/// returns a human-readable destination path or URI.
typedef FileCommitHandler = Future<String> Function(
  TransferOffer offer,
  File stagedFile,
);

/// Snapshot of an active or completed transfer on the mobile receiver.
class ReceivedTransferRecord {
  const ReceivedTransferRecord({
    required this.transferId,
    required this.fileName,
    required this.relativePath,
    required this.totalBytes,
    required this.receivedBytes,
    required this.sha256,
    required this.status,
    this.savedLocation,
    this.errorMessage,
  });

  final String transferId;
  final String fileName;
  final String relativePath;
  final int totalBytes;
  final int receivedBytes;
  final String sha256;
  final TransferRecordStatus status;
  final String? savedLocation;
  final String? errorMessage;

  double get progress =>
      totalBytes <= 0 ? (status == TransferRecordStatus.completed ? 1.0 : 0.0) : receivedBytes / totalBytes;

  ReceivedTransferRecord copyWith({
    int? receivedBytes,
    TransferRecordStatus? status,
    String? savedLocation,
    String? errorMessage,
  }) {
    return ReceivedTransferRecord(
      transferId: transferId,
      fileName: fileName,
      relativePath: relativePath,
      totalBytes: totalBytes,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      sha256: sha256,
      status: status ?? this.status,
      savedLocation: savedLocation ?? this.savedLocation,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

enum TransferRecordStatus { receiving, verifying, completed, failed }

/// Lightweight HTTP + WebSocket receiver embedded in the mobile companion app.
class TransferServer {
  TransferServer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this._storageDir,
    this._browsableDir,
    this._onCommitFile,
  });

  final String deviceId;
  final String deviceName;
  final DevicePlatform platform;
  final Directory _storageDir;
  final Directory? _browsableDir;
  final FileCommitHandler? _onCommitFile;

  HttpServer? _httpServer;
  final Set<WebSocketChannel> _clients = <WebSocketChannel>{};
  final Map<String, ReceivedTransferRecord> _records =
      <String, ReceivedTransferRecord>{};
  final StreamController<List<ReceivedTransferRecord>> _recordsController =
      StreamController<List<ReceivedTransferRecord>>.broadcast();

  Stream<List<ReceivedTransferRecord>> get recordsStream =>
      _recordsController.stream;

  List<ReceivedTransferRecord> get currentRecords =>
      _records.values.toList(growable: false).reversed.toList(growable: false);

  bool get isRunning => _httpServer != null;
  int? get boundPort => _httpServer?.port;

  /// Starts the shelf HTTP/WebSocket server on [port] (use `0` for ephemeral).
  Future<int> start({
    InternetAddress? address,
    int port = kDefaultTransferPort,
  }) async {
    if (_httpServer != null) {
      return _httpServer!.port;
    }

    await _storageDir.create(recursive: true);
    await _stagingDir.create(recursive: true);
    await _receivedDir.create(recursive: true);

    final router = Router()
      ..get('/health', _handleHealth)
      ..get('/ws', webSocketHandler(_handleWebSocket));

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    final server = await shelf_io.serve(
      handler,
      address ?? InternetAddress.anyIPv4,
      port,
    );
    _httpServer = server;
    return server.port;
  }

  /// Gracefully shuts down the server and closes connected WebSocket clients.
  Future<void> stop() async {
    for (final client in _clients.toList()) {
      await client.sink.close();
    }
    _clients.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> dispose() async {
    await stop();
    await _recordsController.close();
  }

  Directory get _stagingDir => Directory(p.join(_storageDir.path, '.staging'));
  Directory get _receivedDir =>
      _browsableDir ?? Directory(p.join(_storageDir.path, 'received'));

  Response _handleHealth(Request request) {
    return Response.ok(
      jsonEncode({
        'status': 'ok',
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform.name,
        'protocolVersion': kProtocolVersion,
        'port': boundPort,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  void _handleWebSocket(WebSocketChannel channel, String? protocol) {
    _clients.add(channel);
    final activeSessions = <String, _ActiveIncomingTransfer>{};
    var queue = Future<void>.value();

    channel.stream.listen(
      (dynamic message) {
        queue = queue.then((_) async {
          if (message is String) {
            await _handleControlMessage(channel, message, activeSessions);
          } else if (message is List<int>) {
            final bytes =
                message is Uint8List ? message : Uint8List.fromList(message);
            await _handleBinaryFrame(channel, bytes, activeSessions);
          }
        }).catchError((Object _) {});
      },
      onDone: () async {
        await queue;
        _clients.remove(channel);
        for (final session in activeSessions.values) {
          await session.abort();
        }
        activeSessions.clear();
      },
      onError: (_) async {
        await queue;
        _clients.remove(channel);
        for (final session in activeSessions.values) {
          await session.abort();
        }
        activeSessions.clear();
      },
    );
  }

  Future<void> _handleControlMessage(
    WebSocketChannel channel,
    String raw,
    Map<String, _ActiveIncomingTransfer> activeSessions,
  ) async {
    final ProtocolMessage msg;
    try {
      msg = ProtocolMessage.decodeJson(raw);
    } on ProtocolException catch (e) {
      channel.sink.add(
        TransferError(
          transferId: '',
          code: 'BAD_MESSAGE',
          message: e.message,
        ).encodeJson(),
      );
      return;
    }

    switch (msg) {
      case HandshakeHello():
        channel.sink.add(
          HandshakeAck(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            maxChunkBytes: ChunkFrame.defaultChunkBytes,
          ).encodeJson(),
        );
      case TransferOffer():
        await _acceptOffer(channel, msg, activeSessions);
      case DirectoryListRequest():
        await _handleDirectoryList(channel, msg);
      case PullFileRequest():
        await _handlePullFile(channel, msg);
      default:
        break;
    }
  }

  Future<void> _acceptOffer(
    WebSocketChannel channel,
    TransferOffer offer,
    Map<String, _ActiveIncomingTransfer> activeSessions,
  ) async {
    if (offer.sizeBytes < 0) {
      channel.sink.add(
        TransferReject(
          transferId: offer.transferId,
          reason: 'Invalid negative file size',
        ).encodeJson(),
      );
      return;
    }

    final safeRel = _sanitizeRelativePath(offer.relativePath);
    if (safeRel == null) {
      channel.sink.add(
        TransferReject(
          transferId: offer.transferId,
          reason: 'Unsafe relative path',
        ).encodeJson(),
      );
      return;
    }

    final stagedFile = File(
      p.join(_stagingDir.path, '${_safeFileToken(offer.transferId)}.part'),
    );
    await stagedFile.parent.create(recursive: true);
    final sink = stagedFile.openWrite(mode: FileMode.writeOnly);

    activeSessions[offer.transferId] = _ActiveIncomingTransfer(
      offer: offer,
      sanitizedRelativePath: safeRel,
      stagedFile: stagedFile,
      sink: sink,
    );

    _updateRecord(
      ReceivedTransferRecord(
        transferId: offer.transferId,
        fileName: offer.fileName,
        relativePath: safeRel,
        totalBytes: offer.sizeBytes,
        receivedBytes: 0,
        sha256: offer.sha256,
        status: TransferRecordStatus.receiving,
      ),
    );

    channel.sink.add(TransferAccept(transferId: offer.transferId).encodeJson());
  }

  Future<void> _handleBinaryFrame(
    WebSocketChannel channel,
    Uint8List bytes,
    Map<String, _ActiveIncomingTransfer> activeSessions,
  ) async {
    final ChunkFrame frame;
    try {
      frame = ChunkFrame.decode(bytes);
    } on ProtocolException catch (e) {
      channel.sink.add(
        TransferError(
          transferId: '',
          code: 'BAD_FRAME',
          message: e.message,
        ).encodeJson(),
      );
      return;
    }

    final session = activeSessions[frame.transferId];
    if (session == null) {
      channel.sink.add(
        TransferError(
          transferId: frame.transferId,
          code: 'UNKNOWN_TRANSFER',
          message: 'No active transfer offer for ${frame.transferId}',
        ).encodeJson(),
      );
      return;
    }

    if (frame.offset != session.receivedBytes) {
      await _failSession(
        channel,
        activeSessions,
        session,
        code: 'OFFSET_MISMATCH',
        message:
            'Expected offset ${session.receivedBytes}, got ${frame.offset}',
      );
      return;
    }

    if (frame.payload.isNotEmpty) {
      session.sink.add(frame.payload);
      session.hasher.add(frame.payload);
      session.receivedBytes += frame.payload.length;
    }

    final current = _records[session.offer.transferId];
    if (current != null) {
      _updateRecord(current.copyWith(receivedBytes: session.receivedBytes));
    }

    if (session.shouldEmitProgress(frame.isEof)) {
      channel.sink.add(
        TransferProgress(
          transferId: session.offer.transferId,
          receivedBytes: session.receivedBytes,
          totalBytes: session.offer.sizeBytes,
        ).encodeJson(),
      );
    }

    if (frame.isEof) {
      await _finalizeSession(channel, activeSessions, session);
    }
  }

  Future<void> _finalizeSession(
    WebSocketChannel channel,
    Map<String, _ActiveIncomingTransfer> activeSessions,
    _ActiveIncomingTransfer session,
  ) async {
    final transferId = session.offer.transferId;
    final current = _records[transferId];
    if (current != null) {
      _updateRecord(current.copyWith(status: TransferRecordStatus.verifying));
    }

    await session.sink.flush();
    await session.sink.close();

    if (session.receivedBytes != session.offer.sizeBytes) {
      await _failSession(
        channel,
        activeSessions,
        session,
        code: 'SIZE_MISMATCH',
        message:
            'Expected ${session.offer.sizeBytes} bytes, received ${session.receivedBytes}',
        alreadyClosed: true,
      );
      return;
    }

    final actualSha = session.hasher.finalizeHex();
    if (actualSha.toLowerCase() != session.offer.sha256.toLowerCase()) {
      await _failSession(
        channel,
        activeSessions,
        session,
        code: 'CHECKSUM_MISMATCH',
        message:
            'SHA-256 mismatch: expected ${session.offer.sha256}, got $actualSha',
        alreadyClosed: true,
      );
      return;
    }

    try {
      final savedLocation = _onCommitFile != null
          ? await _onCommitFile(session.offer, session.stagedFile)
          : await _defaultCommitFile(session);

      activeSessions.remove(transferId);
      final doneRecord = _records[transferId];
      if (doneRecord != null) {
        _updateRecord(
          doneRecord.copyWith(
            receivedBytes: session.receivedBytes,
            status: TransferRecordStatus.completed,
            savedLocation: savedLocation,
          ),
        );
      }

      channel.sink.add(
        TransferComplete(
          transferId: transferId,
          sha256: actualSha,
          savedLocation: savedLocation,
        ).encodeJson(),
      );
    } catch (e) {
      await _failSession(
        channel,
        activeSessions,
        session,
        code: 'STORAGE_ERROR',
        message: e.toString(),
        alreadyClosed: true,
      );
    }
  }

  Future<String> _defaultCommitFile(_ActiveIncomingTransfer session) async {
    final dest = File(p.join(_receivedDir.path, session.sanitizedRelativePath));
    await dest.parent.create(recursive: true);
    if (await dest.exists()) {
      await dest.delete();
    }
    await session.stagedFile.rename(dest.path);
    return dest.path;
  }

  Future<void> _failSession(
    WebSocketChannel channel,
    Map<String, _ActiveIncomingTransfer> activeSessions,
    _ActiveIncomingTransfer session, {
    required String code,
    required String message,
    bool alreadyClosed = false,
  }) async {
    activeSessions.remove(session.offer.transferId);
    if (!alreadyClosed) {
      await session.abort();
    } else if (await session.stagedFile.exists()) {
      await session.stagedFile.delete();
    }

    final existing = _records[session.offer.transferId];
    if (existing != null) {
      _updateRecord(
        existing.copyWith(
          status: TransferRecordStatus.failed,
          errorMessage: message,
        ),
      );
    }

    channel.sink.add(
      TransferError(
        transferId: session.offer.transferId,
        code: code,
        message: message,
      ).encodeJson(),
    );
  }

  Future<void> _handleDirectoryList(
    WebSocketChannel channel,
    DirectoryListRequest request,
  ) async {
    final safeRel = _sanitizeRelativePath(request.relativePath, allowEmpty: true);
    if (safeRel == null) {
      channel.sink.add(
        TransferError(
          transferId: request.requestId,
          code: 'INVALID_PATH',
          message: 'Unsafe directory path',
        ).encodeJson(),
      );
      return;
    }

    final targetDir = safeRel.isEmpty
        ? _receivedDir
        : Directory(p.join(_receivedDir.path, safeRel));
    final entries = <RemoteFileEntry>[];

    if (await targetDir.exists()) {
      await for (final entity in targetDir.list(followLinks: false)) {
        final stat = await entity.stat();
        final rel = p.relative(entity.path, from: _receivedDir.path);
        entries.add(
          RemoteFileEntry(
            name: p.basename(entity.path),
            relativePath: rel.replaceAll(r'\', '/'),
            isDirectory: entity is Directory,
            sizeBytes: entity is File ? stat.size : 0,
            modifiedAtMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
    }

    channel.sink.add(
      DirectoryListResponse(
        requestId: request.requestId,
        relativePath: safeRel,
        entries: entries,
      ).encodeJson(),
    );
  }

  Future<void> _handlePullFile(
    WebSocketChannel channel,
    PullFileRequest request,
  ) async {
    final safeRel = _sanitizeRelativePath(request.relativePath);
    if (safeRel == null) {
      channel.sink.add(
        TransferError(
          transferId: request.transferId,
          code: 'INVALID_PATH',
          message: 'Unsafe file path',
        ).encodeJson(),
      );
      return;
    }

    final file = File(p.join(_receivedDir.path, safeRel));
    if (!await file.exists()) {
      channel.sink.add(
        TransferError(
          transferId: request.transferId,
          code: 'NOT_FOUND',
          message: 'File not found: $safeRel',
        ).encodeJson(),
      );
      return;
    }

    final sizeBytes = await file.length();
    final digest = await IncrementalSha256.hashStream(file.openRead());
    channel.sink.add(
      TransferOffer(
        transferId: request.transferId,
        fileName: p.basename(file.path),
        relativePath: safeRel.replaceAll(r'\', '/'),
        sizeBytes: sizeBytes,
        sha256: digest,
      ).encodeJson(),
    );

    if (sizeBytes == 0) {
      channel.sink.add(
        ChunkFrame(
          transferId: request.transferId,
          offset: 0,
          payload: Uint8List(0),
          isEof: true,
        ).encode(),
      );
      return;
    }

    var offset = 0;
    await for (final chunk in file.openRead()) {
      var cursor = 0;
      while (cursor < chunk.length) {
        final end = (cursor + ChunkFrame.defaultChunkBytes < chunk.length)
            ? cursor + ChunkFrame.defaultChunkBytes
            : chunk.length;
        final slice = Uint8List.fromList(chunk.sublist(cursor, end));
        final nextOffset = offset + slice.length;
        final isEof = nextOffset >= sizeBytes;
        channel.sink.add(
          ChunkFrame(
            transferId: request.transferId,
            offset: offset,
            payload: slice,
            isEof: isEof,
          ).encode(),
        );
        offset = nextOffset;
        cursor = end;
      }
    }
  }

  void _updateRecord(ReceivedTransferRecord record) {
    _records[record.transferId] = record;
    if (!_recordsController.isClosed) {
      _recordsController.add(currentRecords);
    }
  }

  static String? _sanitizeRelativePath(
    String raw, {
    bool allowEmpty = false,
  }) {
    final normalized = raw.replaceAll(r'\', '/').trim();
    if (normalized.isEmpty) {
      return allowEmpty ? '' : null;
    }
    if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      return null;
    }
    final segments =
        normalized.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (segments.isEmpty) {
      return allowEmpty ? '' : null;
    }
    if (segments.any((s) => s == '..')) {
      return null;
    }
    return p.joinAll(segments);
  }

  static String _safeFileToken(String raw) {
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }
}

class _ActiveIncomingTransfer {
  _ActiveIncomingTransfer({
    required this.offer,
    required this.sanitizedRelativePath,
    required this.stagedFile,
    required this.sink,
  });

  final TransferOffer offer;
  final String sanitizedRelativePath;
  final File stagedFile;
  final IOSink sink;
  final IncrementalSha256 hasher = IncrementalSha256();
  int receivedBytes = 0;
  int _lastProgressEmitBytes = 0;

  bool shouldEmitProgress(bool isEof) {
    if (isEof) return true;
    if (receivedBytes - _lastProgressEmitBytes >= 256 * 1024) {
      _lastProgressEmitBytes = receivedBytes;
      return true;
    }
    return false;
  }

  Future<void> abort() async {
    try {
      await sink.close();
    } catch (_) {}
    if (await stagedFile.exists()) {
      await stagedFile.delete();
    }
  }
}

