import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Sink-style incremental SHA-256 calculator for streaming transfers.
class IncrementalSha256 {
  IncrementalSha256() {
    _inputSink = sha256.startChunkedConversion(_DigestCaptureSink((digest) {
      _digest = digest;
    }));
  }

  late final ByteConversionSink _inputSink;
  Digest? _digest;
  bool _closed = false;

  /// Feeds the next chunk of bytes into the SHA-256 computation.
  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot add bytes after finalizeHex() has been called');
    }
    if (bytes.isNotEmpty) {
      _inputSink.add(bytes);
    }
  }

  /// Completes hashing and returns the lowercase hex digest.
  String finalizeHex() {
    if (!_closed) {
      _inputSink.close();
      _closed = true;
    }
    return _digest!.toString();
  }

  /// Computes the lowercase SHA-256 hex digest of a byte stream.
  static Future<String> hashStream(Stream<List<int>> stream) async {
    final hasher = IncrementalSha256();
    await for (final chunk in stream) {
      hasher.add(chunk);
    }
    return hasher.finalizeHex();
  }
}

class _DigestCaptureSink implements Sink<Digest> {
  _DigestCaptureSink(this._onDigest);

  final void Function(Digest digest) _onDigest;

  @override
  void add(Digest data) => _onDigest(data);

  @override
  void close() {}
}

