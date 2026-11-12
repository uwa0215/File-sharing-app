import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_protocol/shared_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolMessage JSON round-trip', () {
    test('round-trips HandshakeHello and TransferOffer', () {
      const hello = HandshakeHello(
        deviceId: 'win-01',
        deviceName: 'Workstation',
        platform: DevicePlatform.windows,
        capabilities: ['chunk_v1', 'pull'],
      );
      final decodedHello = ProtocolMessage.decodeJson(hello.encodeJson());
      expect(decodedHello, isA<HandshakeHello>());
      final h = decodedHello as HandshakeHello;
      expect(h.deviceId, 'win-01');
      expect(h.platform, DevicePlatform.windows);
      expect(h.capabilities, ['chunk_v1', 'pull']);

      const offer = TransferOffer(
        transferId: 'tx-123',
        fileName: 'photo.png',
        relativePath: 'DCIM/photo.png',
        sizeBytes: 4096,
        sha256: 'abc123',
        mimeType: 'image/png',
      );
      final decodedOffer =
          ProtocolMessage.decodeJson(offer.encodeJson()) as TransferOffer;
      expect(decodedOffer.transferId, 'tx-123');
      expect(decodedOffer.relativePath, 'DCIM/photo.png');
      expect(decodedOffer.sizeBytes, 4096);
      expect(decodedOffer.sha256, 'abc123');
      expect(decodedOffer.mimeType, 'image/png');
    });

    test('rejects unsupported protocol version', () {
      expect(
        () => ProtocolMessage.decodeJson(
          '{"type":"handshake_hello","version":99,"payload":{}}',
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('ChunkFrame binary framing', () {
    test('encodes and decodes payload with offset and EOF flag', () {
      final payload = Uint8List.fromList(List<int>.generate(256, (i) => i));
      final frame = ChunkFrame(
        transferId: 'tx-utf8-✓',
        offset: 1 << 35,
        payload: payload,
        isEof: true,
      );

      final encoded = frame.encode();
      final decoded = ChunkFrame.decode(encoded);

      expect(decoded.transferId, 'tx-utf8-✓');
      expect(decoded.offset, 1 << 35);
      expect(decoded.isEof, isTrue);
      expect(decoded.payload, equals(payload));
    });

    test('rejects corrupted magic header or truncated buffer', () {
      final valid = ChunkFrame(
        transferId: 'tx-1',
        offset: 0,
        payload: Uint8List.fromList([1, 2, 3]),
      ).encode();

      final badMagic = Uint8List.fromList(valid)..[0] = 0x00;
      expect(
        () => ChunkFrame.decode(badMagic),
        throwsA(isA<ProtocolException>()),
      );

      final truncated = valid.sublist(0, valid.length - 1);
      expect(
        () => ChunkFrame.decode(truncated),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('IncrementalSha256', () {
    test('matches single-shot sha256 digest across arbitrary chunks', () async {
      final data = List<int>.generate(150000, (i) => (i * 31) & 0xFF);
      final expected = sha256.convert(data).toString();

      final hasher = IncrementalSha256()
        ..add(data.sublist(0, 1234))
        ..add(const [])
        ..add(data.sublist(1234, 90000))
        ..add(data.sublist(90000));

      expect(hasher.finalizeHex(), expected);

      final streamHash = await IncrementalSha256.hashStream(
        Stream<List<int>>.fromIterable([
          data.sublist(0, 50000),
          data.sublist(50000),
        ]),
      );
      expect(streamHash, expected);
    });
  });
}

