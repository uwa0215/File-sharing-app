import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shared_protocol/shared_protocol.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum TransferTaskStatus { queued, hashing, sending, receiving, completed, failed }

enum TransferDirection { uploadToPhone, downloadToPc }

/// Client-side state for an upload or pull transfer queued on Windows.
class TransferTask {
  const TransferTask({
    required this.transferId,
    required this.fileName,
    required this.relativePath,
    required this.totalBytes,
    required this.sentBytes,
    required this.status,
    this.direction = TransferDirection.uploadToPhone,
    this.sha256,
    this.savedLocation,
    this.errorMessage,
  });

  final String transferId;
  final String fileName;
  final String relativePath;
  final int totalBytes;
  final int sentBytes;
  final TransferTaskStatus status;
  final TransferDirection direction;
  final String? sha256;
  final String? savedLocation;
  final String? errorMessage;

  double get progress {
    if (status == TransferTaskStatus.completed) return 1.0;
    if (totalBytes <= 0) return 0.0;
    return (sentBytes / totalBytes).clamp(0.0, 1.0);
  }

  TransferTask copyWith({
    int? totalBytes,
    int? sentBytes,
    TransferTaskStatus? status,
    String? sha256,
    String? savedLocation,
    String? errorMessage,
  }) {
    return TransferTask(
      transferId: transferId,
      fileName: fileName,
      relativePath: relativePath,
      totalBytes: totalBytes ?? this.totalBytes,
      sentBytes: sentBytes ?? this.sentBytes,
      status: status ?? this.status,
      direction: direction,
      sha256: sha256 ?? this.sha256,
      savedLocation: savedLocation ?? this.savedLocation,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// WebSocket transfer client running inside the Windows desktop host.
class TransferClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  HandshakeAck? _connectedDevice;
  Future<void> _incomingQueue = Future<void>.value();
  int _nextId = 0;

  final Map<String, Completer<ProtocolMessage>> _pendingControl =
      <String, Completer<ProtocolMessage>>{};
  final Map<String, _ActivePullSession> _activePulls =
      <String, _ActivePullSession>{};
  Completer<HandshakeAck>? _handshakeCompleter;

  final List<TransferTask> _tasks = <TransferTask>[];
  final StreamController<List<TransferTask>> _tasksController =
      StreamController<List<TransferTask>>.broadcast();
  final StreamController<HandshakeAck?> _connectionController =
      StreamController<HandshakeAck?>.broadcast();

  Stream<List<TransferTask>> get tasksStream => _tasksController.stream;
  List<TransferTask> get currentTasks =>
      _tasks.reversed.toList(growable: false);

  Stream<HandshakeAck?> get connectionStream => _connectionController.stream;
  HandshakeAck? get connectedDevice => _connectedDevice;
  bool get isConnected => _channel != null && _connectedDevice != null;

  /// Connects to a mobile companion receiver over TCP/WebSocket.
  Future<HandshakeAck> connect({
    required String host,
    int port = kDefaultTransferPort,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await disconnect();

    final uri = Uri.parse('ws://$host:$port/ws');
    final channel = IOWebSocketChannel.connect(uri, connectTimeout: timeout);
    await channel.ready.timeout(timeout);

    _channel = channel;
    final handshakeCompleter = Completer<HandshakeAck>();
    _handshakeCompleter = handshakeCompleter;

    _subscription = channel.stream.listen(
      (dynamic raw) {
        _incomingQueue = _incomingQueue
            .then((_) => _onMessage(raw))
            .catchError((Object _) {});
      },
      onDone: _handleDisconnect,
      onError: (_) => _handleDisconnect(),
    );

    channel.sink.add(
      HandshakeHello(
        deviceId: 'windows-${Platform.localHostname}',
        deviceName: Platform.localHostname,
        platform: DevicePlatform.windows,
        capabilities: const ['chunk_v1', 'pull'],
      ).encodeJson(),
    );

    final ack = await handshakeCompleter.future.timeout(timeout);
    _connectedDevice = ack;
    if (!_connectionController.isClosed) {
      _connectionController.add(ack);
    }
    return ack;
  }

  /// Disconnects the active WebSocket session.
  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _connectedDevice = null;
    await _failAllPending('Disconnected from peer');
    if (!_connectionController.isClosed) {
      _connectionController.add(null);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _tasksController.close();
    await _connectionController.close();
  }

  /// Lists files/folders on the connected phone under [relativePath].
  Future<DirectoryListResponse> listDirectory({String relativePath = ''}) async {
    final channel = _channel;
    if (channel == null || _connectedDevice == null) {
      throw StateError('Not connected to a mobile companion device');
    }

    final requestId = 'dir-${DateTime.now().microsecondsSinceEpoch}-${++_nextId}';
    final completer = Completer<ProtocolMessage>();
    _pendingControl['dir:$requestId'] = completer;

    channel.sink.add(
      DirectoryListRequest(
        requestId: requestId,
        relativePath: relativePath,
      ).encodeJson(),
    );

    final resp = await completer.future.timeout(const Duration(seconds: 15));
    if (resp is TransferError) {
      throw ProtocolException('${resp.code}: ${resp.message}');
    }
    return resp as DirectoryListResponse;
  }

  /// Pulls a file from the connected phone into [targetDir], verifying SHA-256.
  Future<File> pullFile({
    required String remoteRelativePath,
    required Directory targetDir,
  }) async {
    final channel = _channel;
    if (channel == null || _connectedDevice == null) {
      throw StateError('Not connected to a mobile companion device');
    }

    await targetDir.create(recursive: true);
    final transferId = 'pull-${DateTime.now().microsecondsSinceEpoch}-${++_nextId}';
    final fileName = p.basename(remoteRelativePath);

    _upsertTask(
      TransferTask(
        transferId: transferId,
        fileName: fileName,
        relativePath: remoteRelativePath,
        totalBytes: 0,
        sentBytes: 0,
        status: TransferTaskStatus.receiving,
        direction: TransferDirection.downloadToPc,
      ),
    );

    final destFile = File(p.join(targetDir.path, fileName));
    final partFile = File('${destFile.path}.part');
    final session = _ActivePullSession(
      transferId: transferId,
      partFile: partFile,
      destFile: destFile,
    );
    _activePulls[transferId] = session;

    channel.sink.add(
      PullFileRequest(
        transferId: transferId,
        relativePath: remoteRelativePath,
      ).encodeJson(),
    );

    try {
      final resultFile = await session.completer.future.timeout(
        const Duration(minutes: 5),
      );
      return resultFile;
    } catch (e) {
      _activePulls.remove(transferId);
      await session.abort();
      _updateTask(
        transferId,
        (t) => t.copyWith(
          status: TransferTaskStatus.failed,
          errorMessage: e.toString(),
        ),
      );
      rethrow;
    }
  }

  /// Streams [file] to the connected mobile device with SHA-256 verification.
  Future<TransferComplete> sendFile(
    File file, {
    String? relativePath,
    String mimeType = 'application/octet-stream',
  }) async {
    final channel = _channel;
    if (channel == null || _connectedDevice == null) {
      throw StateError('Not connected to a mobile companion device');
    }

    final transferId = 'tx-${DateTime.now().microsecondsSinceEpoch}-${++_nextId}';
    final fileName = p.basename(file.path);
    final effectiveRelPath = (relativePath ?? fileName).replaceAll(r'\', '/');
    final sizeBytes = await file.length();

    _upsertTask(
      TransferTask(
        transferId: transferId,
        fileName: fileName,
        relativePath: effectiveRelPath,
        totalBytes: sizeBytes,
        sentBytes: 0,
        status: TransferTaskStatus.hashing,
        direction: TransferDirection.uploadToPhone,
      ),
    );

    try {
      final digest = await IncrementalSha256.hashStream(file.openRead());
      _updateTask(transferId, (t) => t.copyWith(sha256: digest));

      final acceptCompleter = Completer<ProtocolMessage>();
      _pendingControl['offer:$transferId'] = acceptCompleter;

      channel.sink.add(
        TransferOffer(
          transferId: transferId,
          fileName: fileName,
          relativePath: effectiveRelPath,
          sizeBytes: sizeBytes,
          sha256: digest,
          mimeType: mimeType,
        ).encodeJson(),
      );

      final response = await acceptCompleter.future.timeout(
        const Duration(seconds: 15),
      );
      if (response is TransferReject) {
        throw ProtocolException('Transfer rejected: ${response.reason}');
      }

      final completeCompleter = Completer<ProtocolMessage>();
      _pendingControl['done:$transferId'] = completeCompleter;

      _updateTask(
        transferId,
        (t) => t.copyWith(status: TransferTaskStatus.sending),
      );

      final maxChunk = _connectedDevice!.maxChunkBytes > 0
          ? _connectedDevice!.maxChunkBytes
          : ChunkFrame.defaultChunkBytes;

      if (sizeBytes == 0) {
        channel.sink.add(
          ChunkFrame(
            transferId: transferId,
            offset: 0,
            payload: Uint8List(0),
            isEof: true,
          ).encode(),
        );
      } else {
        var offset = 0;
        await for (final chunk in file.openRead()) {
          var cursor = 0;
          while (cursor < chunk.length) {
            final end = (cursor + maxChunk < chunk.length)
                ? cursor + maxChunk
                : chunk.length;
            final slice = Uint8List.fromList(chunk.sublist(cursor, end));
            final nextOffset = offset + slice.length;
            final isEof = nextOffset >= sizeBytes;

            channel.sink.add(
              ChunkFrame(
                transferId: transferId,
                offset: offset,
                payload: slice,
                isEof: isEof,
              ).encode(),
            );

            offset = nextOffset;
            cursor = end;
            _updateTask(transferId, (t) => t.copyWith(sentBytes: offset));
          }
        }
      }

      final finalMsg = await completeCompleter.future.timeout(
        const Duration(minutes: 5),
      );
      if (finalMsg is TransferError) {
        throw ProtocolException('${finalMsg.code}: ${finalMsg.message}');
      }

      final complete = finalMsg as TransferComplete;
      _updateTask(
        transferId,
        (t) => t.copyWith(
          sentBytes: sizeBytes,
          status: TransferTaskStatus.completed,
          savedLocation: complete.savedLocation,
        ),
      );
      return complete;
    } catch (e) {
      _pendingControl.remove('offer:$transferId');
      _pendingControl.remove('done:$transferId');
      _updateTask(
        transferId,
        (t) => t.copyWith(
          status: TransferTaskStatus.failed,
          errorMessage: e.toString(),
        ),
      );
      rethrow;
    }
  }

  /// Sends local file paths and recursively expands any directories.
  Future<void> sendPaths(List<String> paths) async {
    for (final rawPath in paths) {
      final type = FileSystemEntity.typeSync(rawPath);
      if (type == FileSystemEntityType.file) {
        await sendFile(File(rawPath));
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(rawPath);
        final rootName = p.basename(dir.path);
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final rel = p.join(rootName, p.relative(entity.path, from: dir.path));
            await sendFile(entity, relativePath: rel);
          }
        }
      }
    }
  }

  Future<void> _onMessage(dynamic raw) async {
    if (raw is List<int>) {
      await _onBinaryMessage(
        raw is Uint8List ? raw : Uint8List.fromList(raw),
      );
      return;
    }
    if (raw is! String) return;

    final ProtocolMessage msg;
    try {
      msg = ProtocolMessage.decodeJson(raw);
    } on ProtocolException {
      return;
    }

    switch (msg) {
      case HandshakeAck():
        final c = _handshakeCompleter;
        _handshakeCompleter = null;
        if (c != null && !c.isCompleted) {
          c.complete(msg);
        }
      case TransferOffer(:final transferId, :final sizeBytes, :final sha256):
        final pull = _activePulls[transferId];
        if (pull != null) {
          await pull.begin(msg);
          _updateTask(
            transferId,
            (t) => t.copyWith(totalBytes: sizeBytes, sha256: sha256),
          );
        }
      case TransferAccept():
        _completeControl('offer:${msg.transferId}', msg);
      case TransferReject():
        _completeControl('offer:${msg.transferId}', msg);
      case TransferProgress(:final transferId, :final receivedBytes):
        _updateTask(transferId, (t) => t.copyWith(sentBytes: receivedBytes));
      case TransferComplete():
        _completeControl('done:${msg.transferId}', msg);
      case DirectoryListResponse():
        _completeControl('dir:${msg.requestId}', msg);
      case TransferError():
        final pull = _activePulls.remove(msg.transferId);
        if (pull != null) {
          await pull.abort();
          if (!pull.completer.isCompleted) {
            pull.completer.completeError(
              ProtocolException('${msg.code}: ${msg.message}'),
            );
          }
        } else if (_pendingControl.containsKey('dir:${msg.transferId}')) {
          _completeControl('dir:${msg.transferId}', msg);
        } else if (_pendingControl.containsKey('offer:${msg.transferId}')) {
          _completeControl('offer:${msg.transferId}', msg);
        } else {
          _completeControl('done:${msg.transferId}', msg);
        }
      default:
        break;
    }
  }

  Future<void> _onBinaryMessage(Uint8List bytes) async {
    final ChunkFrame frame;
    try {
      frame = ChunkFrame.decode(bytes);
    } on ProtocolException {
      return;
    }

    final pull = _activePulls[frame.transferId];
    if (pull == null) return;

    try {
      await pull.appendFrame(frame);
      _updateTask(
        frame.transferId,
        (t) => t.copyWith(sentBytes: pull.receivedBytes),
      );
      if (frame.isEof) {
        final saved = await pull.finalize();
        _activePulls.remove(frame.transferId);
        _updateTask(
          frame.transferId,
          (t) => t.copyWith(
            sentBytes: pull.receivedBytes,
            status: TransferTaskStatus.completed,
            savedLocation: saved.path,
          ),
        );
        if (!pull.completer.isCompleted) {
          pull.completer.complete(saved);
        }
      }
    } catch (e) {
      _activePulls.remove(frame.transferId);
      await pull.abort();
      if (!pull.completer.isCompleted) {
        pull.completer.completeError(e);
      }
    }
  }

  void _completeControl(String key, ProtocolMessage msg) {
    final completer = _pendingControl.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.complete(msg);
    }
  }

  void _handleDisconnect() {
    _channel = null;
    _connectedDevice = null;
    unawaited(_failAllPending('Connection closed'));
    if (!_connectionController.isClosed) {
      _connectionController.add(null);
    }
  }

  Future<void> _failAllPending(String reason) async {
    final hs = _handshakeCompleter;
    _handshakeCompleter = null;
    if (hs != null && !hs.isCompleted) {
      hs.completeError(StateError(reason));
    }
    for (final completer in _pendingControl.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(reason));
      }
    }
    _pendingControl.clear();

    for (final pull in _activePulls.values.toList()) {
      await pull.abort();
      if (!pull.completer.isCompleted) {
        pull.completer.completeError(StateError(reason));
      }
    }
    _activePulls.clear();
  }

  void _upsertTask(TransferTask task) {
    _tasks.add(task);
    if (!_tasksController.isClosed) {
      _tasksController.add(currentTasks);
    }
  }

  void _updateTask(
    String transferId,
    TransferTask Function(TransferTask) transform,
  ) {
    final index = _tasks.indexWhere((t) => t.transferId == transferId);
    if (index == -1) return;
    _tasks[index] = transform(_tasks[index]);
    if (!_tasksController.isClosed) {
      _tasksController.add(currentTasks);
    }
  }
}

class _ActivePullSession {
  _ActivePullSession({
    required this.transferId,
    required this.partFile,
    required this.destFile,
  });

  final String transferId;
  final File partFile;
  final File destFile;
  final Completer<File> completer = Completer<File>();
  final IncrementalSha256 _hasher = IncrementalSha256();

  TransferOffer? _offer;
  IOSink? _sink;
  int receivedBytes = 0;

  Future<void> begin(TransferOffer offer) async {
    _offer = offer;
    await partFile.parent.create(recursive: true);
    _sink = partFile.openWrite(mode: FileMode.writeOnly);
  }

  Future<void> appendFrame(ChunkFrame frame) async {
    final sink = _sink;
    if (sink == null || _offer == null) {
      throw ProtocolException('Received chunk before TransferOffer for $transferId');
    }
    if (frame.offset != receivedBytes) {
      throw ProtocolException(
        'Pull offset mismatch: expected $receivedBytes, got ${frame.offset}',
      );
    }
    if (frame.payload.isNotEmpty) {
      sink.add(frame.payload);
      _hasher.add(frame.payload);
      receivedBytes += frame.payload.length;
    }
  }

  Future<File> finalize() async {
    final offer = _offer!;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;

    if (receivedBytes != offer.sizeBytes) {
      throw ProtocolException(
        'Pull size mismatch: expected ${offer.sizeBytes}, got $receivedBytes',
      );
    }

    final actualSha = _hasher.finalizeHex();
    if (actualSha.toLowerCase() != offer.sha256.toLowerCase()) {
      throw ProtocolException(
        'Pull SHA-256 mismatch: expected ${offer.sha256}, got $actualSha',
      );
    }

    if (await destFile.exists()) {
      await destFile.delete();
    }
    return partFile.rename(destFile.path);
  }

  Future<void> abort() async {
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    if (await partFile.exists()) {
      await partFile.delete();
    }
  }
}
