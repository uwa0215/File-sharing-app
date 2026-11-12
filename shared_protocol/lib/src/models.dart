import 'dart:convert';

import 'package:meta/meta.dart';

/// Current DeviceBridge wire protocol version.
const int kProtocolVersion = 1;

/// Default local TCP port used by DeviceBridge receivers and USB tunnels.
const int kDefaultTransferPort = 49152;

/// Bonjour / NSD service type for DeviceBridge LAN discovery.
const String kMdnsServiceType = '_devicebridge._tcp';

/// Supported DeviceBridge endpoint platforms.
enum DevicePlatform {
  windows,
  android,
  ios;

  static DevicePlatform fromWire(String value) {
    return DevicePlatform.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw ProtocolException('Unknown platform: $value'),
    );
  }
}

/// Control-channel JSON message types.
enum ProtocolMessageType {
  handshakeHello('handshake_hello'),
  handshakeAck('handshake_ack'),
  transferOffer('transfer_offer'),
  transferAccept('transfer_accept'),
  transferReject('transfer_reject'),
  transferProgress('transfer_progress'),
  transferComplete('transfer_complete'),
  transferError('transfer_error'),
  directoryListRequest('directory_list_request'),
  directoryListResponse('directory_list_response'),
  pullFileRequest('pull_file_request');

  const ProtocolMessageType(this.wireName);

  final String wireName;

  static ProtocolMessageType fromWire(String value) {
    return ProtocolMessageType.values.firstWhere(
      (e) => e.wireName == value,
      orElse: () => throw ProtocolException('Unknown message type: $value'),
    );
  }
}

/// Exception thrown when a wire message or binary frame is malformed.
class ProtocolException implements Exception {
  ProtocolException(this.message);

  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

/// Base class for all JSON control messages exchanged over WebSocket.
@immutable
sealed class ProtocolMessage {
  const ProtocolMessage();

  ProtocolMessageType get type;

  Map<String, dynamic> toPayload();

  /// Encodes this message into a JSON text frame.
  String encodeJson() => jsonEncode({
        'type': type.wireName,
        'version': kProtocolVersion,
        'payload': toPayload(),
      });

  /// Decodes a JSON text frame into a concrete [ProtocolMessage].
  static ProtocolMessage decodeJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw ProtocolException('Invalid JSON frame: ${e.message}');
    }

    if (decoded is! Map<String, dynamic>) {
      throw ProtocolException('Control message root must be a JSON object');
    }

    final typeRaw = decoded['type'];
    final versionRaw = decoded['version'];
    final payloadRaw = decoded['payload'];

    if (typeRaw is! String) {
      throw ProtocolException('Missing or invalid message "type"');
    }
    if (versionRaw is! int || versionRaw != kProtocolVersion) {
      throw ProtocolException('Unsupported protocol version: $versionRaw');
    }
    if (payloadRaw is! Map<String, dynamic>) {
      throw ProtocolException('Missing or invalid message "payload"');
    }

    final messageType = ProtocolMessageType.fromWire(typeRaw);
    return switch (messageType) {
      ProtocolMessageType.handshakeHello => HandshakeHello.fromPayload(payloadRaw),
      ProtocolMessageType.handshakeAck => HandshakeAck.fromPayload(payloadRaw),
      ProtocolMessageType.transferOffer => TransferOffer.fromPayload(payloadRaw),
      ProtocolMessageType.transferAccept => TransferAccept.fromPayload(payloadRaw),
      ProtocolMessageType.transferReject => TransferReject.fromPayload(payloadRaw),
      ProtocolMessageType.transferProgress =>
        TransferProgress.fromPayload(payloadRaw),
      ProtocolMessageType.transferComplete =>
        TransferComplete.fromPayload(payloadRaw),
      ProtocolMessageType.transferError => TransferError.fromPayload(payloadRaw),
      ProtocolMessageType.directoryListRequest =>
        DirectoryListRequest.fromPayload(payloadRaw),
      ProtocolMessageType.directoryListResponse =>
        DirectoryListResponse.fromPayload(payloadRaw),
      ProtocolMessageType.pullFileRequest =>
        PullFileRequest.fromPayload(payloadRaw),
    };
  }
}

T _require<T>(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! T) {
    throw ProtocolException('Expected "$key" of type $T');
  }
  return value;
}

/// Initial greeting sent when a client opens a control WebSocket.
final class HandshakeHello extends ProtocolMessage {
  const HandshakeHello({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.capabilities = const <String>[],
  });

  factory HandshakeHello.fromPayload(Map<String, dynamic> payload) {
    final capsRaw = payload['capabilities'];
    final caps = capsRaw is List
        ? capsRaw.whereType<String>().toList(growable: false)
        : const <String>[];
    return HandshakeHello(
      deviceId: _require<String>(payload, 'deviceId'),
      deviceName: _require<String>(payload, 'deviceName'),
      platform: DevicePlatform.fromWire(_require<String>(payload, 'platform')),
      capabilities: caps,
    );
  }

  final String deviceId;
  final String deviceName;
  final DevicePlatform platform;
  final List<String> capabilities;

  @override
  ProtocolMessageType get type => ProtocolMessageType.handshakeHello;

  @override
  Map<String, dynamic> toPayload() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform.name,
        'capabilities': capabilities,
      };
}

/// Receiver response accepting the session handshake.
final class HandshakeAck extends ProtocolMessage {
  const HandshakeAck({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.maxChunkBytes,
  });

  factory HandshakeAck.fromPayload(Map<String, dynamic> payload) {
    return HandshakeAck(
      deviceId: _require<String>(payload, 'deviceId'),
      deviceName: _require<String>(payload, 'deviceName'),
      platform: DevicePlatform.fromWire(_require<String>(payload, 'platform')),
      maxChunkBytes: _require<int>(payload, 'maxChunkBytes'),
    );
  }

  final String deviceId;
  final String deviceName;
  final DevicePlatform platform;
  final int maxChunkBytes;

  @override
  ProtocolMessageType get type => ProtocolMessageType.handshakeAck;

  @override
  Map<String, dynamic> toPayload() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform.name,
        'maxChunkBytes': maxChunkBytes,
      };
}

/// Offer sent before streaming binary file chunks.
final class TransferOffer extends ProtocolMessage {
  const TransferOffer({
    required this.transferId,
    required this.fileName,
    required this.relativePath,
    required this.sizeBytes,
    required this.sha256,
    this.mimeType = 'application/octet-stream',
  });

  factory TransferOffer.fromPayload(Map<String, dynamic> payload) {
    return TransferOffer(
      transferId: _require<String>(payload, 'transferId'),
      fileName: _require<String>(payload, 'fileName'),
      relativePath: _require<String>(payload, 'relativePath'),
      sizeBytes: _require<int>(payload, 'sizeBytes'),
      sha256: _require<String>(payload, 'sha256'),
      mimeType: (payload['mimeType'] as String?) ?? 'application/octet-stream',
    );
  }

  final String transferId;
  final String fileName;
  final String relativePath;
  final int sizeBytes;
  final String sha256;
  final String mimeType;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferOffer;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'fileName': fileName,
        'relativePath': relativePath,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'mimeType': mimeType,
      };
}

/// Receiver acceptance allowing binary frames for [transferId].
final class TransferAccept extends ProtocolMessage {
  const TransferAccept({
    required this.transferId,
    this.resumeOffset = 0,
  });

  factory TransferAccept.fromPayload(Map<String, dynamic> payload) {
    return TransferAccept(
      transferId: _require<String>(payload, 'transferId'),
      resumeOffset: (payload['resumeOffset'] as int?) ?? 0,
    );
  }

  final String transferId;
  final int resumeOffset;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferAccept;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'resumeOffset': resumeOffset,
      };
}

/// Receiver rejection of an offered transfer.
final class TransferReject extends ProtocolMessage {
  const TransferReject({
    required this.transferId,
    required this.reason,
  });

  factory TransferReject.fromPayload(Map<String, dynamic> payload) {
    return TransferReject(
      transferId: _require<String>(payload, 'transferId'),
      reason: _require<String>(payload, 'reason'),
    );
  }

  final String transferId;
  final String reason;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferReject;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'reason': reason,
      };
}

/// Incremental receiver progress notification.
final class TransferProgress extends ProtocolMessage {
  const TransferProgress({
    required this.transferId,
    required this.receivedBytes,
    required this.totalBytes,
  });

  factory TransferProgress.fromPayload(Map<String, dynamic> payload) {
    return TransferProgress(
      transferId: _require<String>(payload, 'transferId'),
      receivedBytes: _require<int>(payload, 'receivedBytes'),
      totalBytes: _require<int>(payload, 'totalBytes'),
    );
  }

  final String transferId;
  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes <= 0 ? 1.0 : receivedBytes / totalBytes;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferProgress;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
      };
}

/// Receiver confirmation that SHA-256 verification and OS save succeeded.
final class TransferComplete extends ProtocolMessage {
  const TransferComplete({
    required this.transferId,
    required this.sha256,
    required this.savedLocation,
  });

  factory TransferComplete.fromPayload(Map<String, dynamic> payload) {
    return TransferComplete(
      transferId: _require<String>(payload, 'transferId'),
      sha256: _require<String>(payload, 'sha256'),
      savedLocation: _require<String>(payload, 'savedLocation'),
    );
  }

  final String transferId;
  final String sha256;
  final String savedLocation;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferComplete;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'sha256': sha256,
        'savedLocation': savedLocation,
      };
}

/// Transfer failure notification (e.g., checksum mismatch or I/O failure).
final class TransferError extends ProtocolMessage {
  const TransferError({
    required this.transferId,
    required this.code,
    required this.message,
  });

  factory TransferError.fromPayload(Map<String, dynamic> payload) {
    return TransferError(
      transferId: _require<String>(payload, 'transferId'),
      code: _require<String>(payload, 'code'),
      message: _require<String>(payload, 'message'),
    );
  }

  final String transferId;
  final String code;
  final String message;

  @override
  ProtocolMessageType get type => ProtocolMessageType.transferError;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'code': code,
        'message': message,
      };
}

/// Metadata for a file or directory on the remote device.
@immutable
class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAtMs,
  });

  factory RemoteFileEntry.fromJson(Map<String, dynamic> json) {
    return RemoteFileEntry(
      name: _require<String>(json, 'name'),
      relativePath: _require<String>(json, 'relativePath'),
      isDirectory: _require<bool>(json, 'isDirectory'),
      sizeBytes: _require<int>(json, 'sizeBytes'),
      modifiedAtMs: _require<int>(json, 'modifiedAtMs'),
    );
  }

  final String name;
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final int modifiedAtMs;

  Map<String, dynamic> toJson() => {
        'name': name,
        'relativePath': relativePath,
        'isDirectory': isDirectory,
        'sizeBytes': sizeBytes,
        'modifiedAtMs': modifiedAtMs,
      };
}

/// Request to list a directory on the mobile companion.
final class DirectoryListRequest extends ProtocolMessage {
  const DirectoryListRequest({
    required this.requestId,
    this.relativePath = '',
  });

  factory DirectoryListRequest.fromPayload(Map<String, dynamic> payload) {
    return DirectoryListRequest(
      requestId: _require<String>(payload, 'requestId'),
      relativePath: (payload['relativePath'] as String?) ?? '',
    );
  }

  final String requestId;
  final String relativePath;

  @override
  ProtocolMessageType get type => ProtocolMessageType.directoryListRequest;

  @override
  Map<String, dynamic> toPayload() => {
        'requestId': requestId,
        'relativePath': relativePath,
      };
}

/// Directory listing returned by the mobile companion.
final class DirectoryListResponse extends ProtocolMessage {
  const DirectoryListResponse({
    required this.requestId,
    required this.relativePath,
    required this.entries,
  });

  factory DirectoryListResponse.fromPayload(Map<String, dynamic> payload) {
    final entriesRaw = _require<List<dynamic>>(payload, 'entries');
    return DirectoryListResponse(
      requestId: _require<String>(payload, 'requestId'),
      relativePath: _require<String>(payload, 'relativePath'),
      entries: entriesRaw
          .map((e) => RemoteFileEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  final String requestId;
  final String relativePath;
  final List<RemoteFileEntry> entries;

  @override
  ProtocolMessageType get type => ProtocolMessageType.directoryListResponse;

  @override
  Map<String, dynamic> toPayload() => {
        'requestId': requestId,
        'relativePath': relativePath,
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
      };
}

/// Request from desktop to pull a file from the mobile companion.
final class PullFileRequest extends ProtocolMessage {
  const PullFileRequest({
    required this.transferId,
    required this.relativePath,
  });

  factory PullFileRequest.fromPayload(Map<String, dynamic> payload) {
    return PullFileRequest(
      transferId: _require<String>(payload, 'transferId'),
      relativePath: _require<String>(payload, 'relativePath'),
    );
  }

  final String transferId;
  final String relativePath;

  @override
  ProtocolMessageType get type => ProtocolMessageType.pullFileRequest;

  @override
  Map<String, dynamic> toPayload() => {
        'transferId': transferId,
        'relativePath': relativePath,
      };
}

