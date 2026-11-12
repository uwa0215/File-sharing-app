import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_companion/services/transfer_server.dart';
import 'package:path/path.dart' as p;
import 'package:shared_protocol/shared_protocol.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  late Directory tempRoot;
  late TransferServer server;
  late int port;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('db_mobile_srv_test_');
    server = TransferServer(
      deviceId: 'android-test',
      deviceName: 'Pixel Test',
      platform: DevicePlatform.android,
      storageDir: tempRoot,
    );
    port = await server.start(
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
  });

  tearDown(() async {
    await server.dispose();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('receives multi-chunk binary file over WebSocket and verifies SHA-256',
      () async {
    final payload = Uint8List.fromList(
      List<int>.generate(256 * 1024 + 777, (i) => (i * 13) & 0xFF),
    );
    final digest = await IncrementalSha256.hashStream(Stream.value(payload));

    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;

    final incoming = StreamIterator<dynamic>(channel.stream);

    channel.sink.add(
      const HandshakeHello(
        deviceId: 'win-test',
        deviceName: 'WinHost',
        platform: DevicePlatform.windows,
      ).encodeJson(),
    );
    expect(await incoming.moveNext(), isTrue);
    final ack = ProtocolMessage.decodeJson(incoming.current as String);
    expect(ack, isA<HandshakeAck>());

    channel.sink.add(
      TransferOffer(
        transferId: 'tx-valid',
        fileName: 'sample.bin',
        relativePath: 'Documents/sample.bin',
        sizeBytes: payload.length,
        sha256: digest,
      ).encodeJson(),
    );
    expect(await incoming.moveNext(), isTrue);
    final accept = ProtocolMessage.decodeJson(incoming.current as String);
    expect(accept, isA<TransferAccept>());

    const chunkSize = 64 * 1024;
    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = (offset + chunkSize < payload.length)
          ? offset + chunkSize
          : payload.length;
      channel.sink.add(
        ChunkFrame(
          transferId: 'tx-valid',
          offset: offset,
          payload: Uint8List.sublistView(payload, offset, end),
          isEof: end >= payload.length,
        ).encode(),
      );
    }

    TransferComplete? complete;
    while (await incoming.moveNext()) {
      final msg = ProtocolMessage.decodeJson(incoming.current as String);
      if (msg is TransferComplete) {
        complete = msg;
        break;
      }
      expect(msg, isNot(isA<TransferError>()));
    }

    expect(complete, isNotNull);
    expect(complete!.sha256, digest);

    final saved = File(p.join(tempRoot.path, 'received', 'Documents', 'sample.bin'));
    expect(await saved.exists(), isTrue);
    expect(await saved.readAsBytes(), equals(payload));

    await channel.sink.close();
  });

  test('rejects transfer when SHA-256 does not match', () async {
    final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;
    final incoming = StreamIterator<dynamic>(channel.stream);

    channel.sink.add(
      const TransferOffer(
        transferId: 'tx-bad-sha',
        fileName: 'bad.bin',
        relativePath: 'bad.bin',
        sizeBytes: 8,
        sha256: '0000000000000000000000000000000000000000000000000000000000000000',
      ).encodeJson(),
    );
    expect(await incoming.moveNext(), isTrue);
    expect(
      ProtocolMessage.decodeJson(incoming.current as String),
      isA<TransferAccept>(),
    );

    channel.sink.add(
      ChunkFrame(
        transferId: 'tx-bad-sha',
        offset: 0,
        payload: payload,
        isEof: true,
      ).encode(),
    );

    TransferError? error;
    while (await incoming.moveNext()) {
      final msg = ProtocolMessage.decodeJson(incoming.current as String);
      if (msg is TransferError) {
        error = msg;
        break;
      }
    }

    expect(error, isNotNull);
    expect(error!.code, 'CHECKSUM_MISMATCH');
    expect(
      await File(p.join(tempRoot.path, 'received', 'bad.bin')).exists(),
      isFalse,
    );

    await channel.sink.close();
  });

  test('rejects path traversal attempts', () async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;
    final incoming = StreamIterator<dynamic>(channel.stream);

    channel.sink.add(
      const TransferOffer(
        transferId: 'tx-evil',
        fileName: 'evil.txt',
        relativePath: '../../evil.txt',
        sizeBytes: 4,
        sha256: 'abcd',
      ).encodeJson(),
    );
    expect(await incoming.moveNext(), isTrue);
    expect(
      ProtocolMessage.decodeJson(incoming.current as String),
      isA<TransferReject>(),
    );

    await channel.sink.close();
  });

  test('lists received files and streams PullFileRequest with SHA-256',
      () async {
    final sampleDir = Directory(p.join(tempRoot.path, 'received', 'Exports'));
    await sampleDir.create(recursive: true);
    final payload = Uint8List.fromList(List<int>.generate(90000, (i) => i & 0xFF));
    final sampleFile = File(p.join(sampleDir.path, 'notes.bin'));
    await sampleFile.writeAsBytes(payload);
    final expectedSha = await IncrementalSha256.hashStream(Stream.value(payload));

    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;
    final incoming = StreamIterator<dynamic>(channel.stream);

    channel.sink.add(
      const DirectoryListRequest(requestId: 'dir-1', relativePath: 'Exports')
          .encodeJson(),
    );
    expect(await incoming.moveNext(), isTrue);
    final dirResp = ProtocolMessage.decodeJson(incoming.current as String)
        as DirectoryListResponse;
    expect(dirResp.entries.map((e) => e.name), contains('notes.bin'));

    channel.sink.add(
      const PullFileRequest(
        transferId: 'pull-1',
        relativePath: 'Exports/notes.bin',
      ).encodeJson(),
    );

    expect(await incoming.moveNext(), isTrue);
    final offer =
        ProtocolMessage.decodeJson(incoming.current as String) as TransferOffer;
    expect(offer.sha256, expectedSha);
    expect(offer.sizeBytes, payload.length);

    final pulled = <int>[];
    while (await incoming.moveNext()) {
      final raw = incoming.current;
      if (raw is List<int>) {
        final frame = ChunkFrame.decode(
          raw is Uint8List ? raw : Uint8List.fromList(raw),
        );
        pulled.addAll(frame.payload);
        if (frame.isEof) break;
      }
    }
    expect(pulled, equals(payload));

    await channel.sink.close();
  });
}

