import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_protocol/shared_protocol.dart';
import 'package:windows_host/services/native_tools_locator.dart';
import 'package:windows_host/services/transfer_client.dart';

void main() {
  test('TransferClient streams upload and pull over local TCP/WebSocket',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('db_win_cli_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final sourceFile = File(p.join(tempDir.path, 'video_clip.bin'));
    final sourceBytes = Uint8List.fromList(
      List<int>.generate(300 * 1024 + 123, (i) => (i * 19 + 7) & 0xFF),
    );
    await sourceFile.writeAsBytes(sourceBytes);
    final expectedSha = await IncrementalSha256.hashStream(
      Stream.value(sourceBytes),
    );

    final pullSourceBytes = Uint8List.fromList(
      List<int>.generate(95000, (i) => (i * 7 + 3) & 0xFF),
    );
    final pullSha = await IncrementalSha256.hashStream(
      Stream.value(pullSourceBytes),
    );

    final receivedBytes = <int>[];
    TransferOffer? receivedOffer;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest req) async {
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        final hasher = IncrementalSha256();
        ws.listen((dynamic data) {
          if (data is String) {
            final msg = ProtocolMessage.decodeJson(data);
            if (msg is HandshakeHello) {
              ws.add(
                const HandshakeAck(
                  deviceId: 'mobile-sim',
                  deviceName: 'Test Phone',
                  platform: DevicePlatform.android,
                  maxChunkBytes: 65536,
                ).encodeJson(),
              );
            } else if (msg is TransferOffer) {
              receivedOffer = msg;
              ws.add(TransferAccept(transferId: msg.transferId).encodeJson());
            } else if (msg is DirectoryListRequest) {
              ws.add(
                DirectoryListResponse(
                  requestId: msg.requestId,
                  relativePath: msg.relativePath,
                  entries: const [
                    RemoteFileEntry(
                      name: 'from_phone.bin',
                      relativePath: 'from_phone.bin',
                      isDirectory: false,
                      sizeBytes: 95000,
                      modifiedAtMs: 1700000000000,
                    ),
                  ],
                ).encodeJson(),
              );
            } else if (msg is PullFileRequest) {
              ws.add(
                TransferOffer(
                  transferId: msg.transferId,
                  fileName: 'from_phone.bin',
                  relativePath: msg.relativePath,
                  sizeBytes: pullSourceBytes.length,
                  sha256: pullSha,
                ).encodeJson(),
              );
              const chunk = 65536;
              for (var off = 0; off < pullSourceBytes.length; off += chunk) {
                final end = (off + chunk < pullSourceBytes.length)
                    ? off + chunk
                    : pullSourceBytes.length;
                ws.add(
                  ChunkFrame(
                    transferId: msg.transferId,
                    offset: off,
                    payload: Uint8List.sublistView(pullSourceBytes, off, end),
                    isEof: end >= pullSourceBytes.length,
                  ).encode(),
                );
              }
            }
          } else if (data is List<int>) {
            final frame = ChunkFrame.decode(
              data is Uint8List ? data : Uint8List.fromList(data),
            );
            receivedBytes.addAll(frame.payload);
            hasher.add(frame.payload);
            if (frame.isEof) {
              final actualSha = hasher.finalizeHex();
              ws.add(
                TransferComplete(
                  transferId: frame.transferId,
                  sha256: actualSha,
                  savedLocation: '/sdcard/Download/${receivedOffer!.fileName}',
                ).encodeJson(),
              );
            }
          }
        });
      }
    });

    final client = TransferClient();
    addTearDown(() => client.dispose());

    final ack = await client.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    expect(ack.deviceName, 'Test Phone');

    final complete = await client.sendFile(
      sourceFile,
      relativePath: 'Camera/video_clip.bin',
    );
    expect(complete.sha256, expectedSha);
    expect(receivedBytes, equals(sourceBytes));

    final dirResp = await client.listDirectory();
    expect(dirResp.entries.single.name, 'from_phone.bin');

    final pullTargetDir = Directory(p.join(tempDir.path, 'pulled'));
    final pulledFile = await client.pullFile(
      remoteRelativePath: 'from_phone.bin',
      targetDir: pullTargetDir,
    );
    expect(await pulledFile.readAsBytes(), equals(pullSourceBytes));
    expect(client.currentTasks.length, 2);
  });

  test('NativeToolsLocator resolves bundled release sidecars', () async {
    final tempDir = await Directory.systemTemp.createTemp('db_tools_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final fakeExe = File(p.join(tempDir.path, 'windows_host.exe'));
    await fakeExe.create(recursive: true);

    final adb = File(p.join(tempDir.path, 'tools', 'android', 'adb.exe'));
    await adb.create(recursive: true);
    final iproxy = File(p.join(tempDir.path, 'tools', 'ios', 'iproxy.exe'));
    await iproxy.create(recursive: true);

    final locator = NativeToolsLocator(
      executablePath: fakeExe.path,
      workspaceToolsPath: p.join(tempDir.path, 'nonexistent'),
    );

    final resolvedAdb = locator.resolve(NativeToolKind.adb);
    expect(resolvedAdb.isAvailable, isTrue);
    expect(resolvedAdb.source, ToolResolutionSource.bundledRelease);

    final resolvedIproxy = locator.resolve(NativeToolKind.iproxy);
    expect(resolvedIproxy.isAvailable, isTrue);
    expect(resolvedIproxy.source, ToolResolutionSource.bundledRelease);
  });
}
