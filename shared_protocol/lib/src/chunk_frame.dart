import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// Binary WebSocket chunk frame used for streaming file payloads without
/// base64 overhead.
///
/// Wire layout (big-endian):
/// - `[0..1]`: Magic bytes `'DB'` (`0x44, 0x42`)
/// - `[2]`: Protocol version (`uint8`)
/// - `[3]`: Flags (`0x01` = end-of-file)
/// - `[4..5]`: `transferId` UTF-8 byte length (`uint16`)
/// - `[6..6+idLen-1]`: `transferId` UTF-8 bytes
/// - `[6+idLen .. 13+idLen]`: Byte offset (`uint64`)
/// - `[14+idLen .. 17+idLen]`: Payload length (`uint32`)
/// - `[18+idLen .. end]`: Raw chunk payload bytes
class ChunkFrame {
  const ChunkFrame({
    required this.transferId,
    required this.offset,
    required this.payload,
    this.isEof = false,
  });

  static const int magic0 = 0x44; // 'D'
  static const int magic1 = 0x42; // 'B'
  static const int flagEof = 0x01;
  static const int defaultChunkBytes = 64 * 1024;
  static const int _fixedHeaderBeforeId = 6;
  static const int _fixedHeaderAfterId = 12;

  final String transferId;
  final int offset;
  final Uint8List payload;
  final bool isEof;

  /// Encodes this frame into a single binary WebSocket message.
  Uint8List encode() {
    final idBytes = utf8.encode(transferId);
    if (idBytes.length > 0xFFFF) {
      throw ProtocolException('transferId exceeds 65535 UTF-8 bytes');
    }
    if (offset < 0) {
      throw ProtocolException('offset must be non-negative');
    }

    final totalLength =
        _fixedHeaderBeforeId + idBytes.length + _fixedHeaderAfterId + payload.length;
    final buffer = Uint8List(totalLength);
    final view = ByteData.sublistView(buffer);

    view.setUint8(0, magic0);
    view.setUint8(1, magic1);
    view.setUint8(2, kProtocolVersion);
    view.setUint8(3, isEof ? flagEof : 0);
    view.setUint16(4, idBytes.length, Endian.big);

    var cursor = _fixedHeaderBeforeId;
    buffer.setRange(cursor, cursor + idBytes.length, idBytes);
    cursor += idBytes.length;

    view.setUint64(cursor, offset, Endian.big);
    cursor += 8;

    view.setUint32(cursor, payload.length, Endian.big);
    cursor += 4;

    if (payload.isNotEmpty) {
      buffer.setRange(cursor, cursor + payload.length, payload);
    }
    return buffer;
  }

  /// Decodes a binary WebSocket message into a [ChunkFrame].
  static ChunkFrame decode(Uint8List bytes) {
    const minHeaderSize = _fixedHeaderBeforeId + _fixedHeaderAfterId;
    if (bytes.length < minHeaderSize) {
      throw ProtocolException('ChunkFrame too short: ${bytes.length} bytes');
    }

    final view = ByteData.sublistView(bytes);
    if (view.getUint8(0) != magic0 || view.getUint8(1) != magic1) {
      throw ProtocolException('Invalid ChunkFrame magic header');
    }

    final version = view.getUint8(2);
    if (version != kProtocolVersion) {
      throw ProtocolException('Unsupported ChunkFrame version: $version');
    }

    final flags = view.getUint8(3);
    final isEof = (flags & flagEof) != 0;
    final idLen = view.getUint16(4, Endian.big);

    final expectedHeaderEnd = _fixedHeaderBeforeId + idLen + _fixedHeaderAfterId;
    if (bytes.length < expectedHeaderEnd) {
      throw ProtocolException('Truncated ChunkFrame header');
    }

    var cursor = _fixedHeaderBeforeId;
    final transferId = utf8.decode(bytes.sublist(cursor, cursor + idLen));
    cursor += idLen;

    final offset = view.getUint64(cursor, Endian.big);
    cursor += 8;

    final payloadLen = view.getUint32(cursor, Endian.big);
    cursor += 4;

    if (bytes.length != cursor + payloadLen) {
      throw ProtocolException(
        'ChunkFrame payload length mismatch: expected $payloadLen, '
        'got ${bytes.length - cursor}',
      );
    }

    final payload = Uint8List.sublistView(bytes, cursor, cursor + payloadLen);
    return ChunkFrame(
      transferId: transferId,
      offset: offset,
      payload: payload,
      isEof: isEof,
    );
  }
}

