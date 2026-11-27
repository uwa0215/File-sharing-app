import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:windows_host/services/qr_transfer_server.dart';

void main() {
  group('QrTransferServer', () {
    late Directory tempRoot;
    late Directory receiveDir;
    late QrTransferServer server;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('db_qr_test_');
      receiveDir = Directory(p.join(tempRoot.path, 'received'));
      server = QrTransferServer(receiveDir: receiveDir);
    });

    tearDown(() async {
      await server.dispose();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('rejects invalid token with 403 Forbidden', () async {
      final port = await server.start(preferredPort: 0);
      final client = HttpClient();
      try {
        final req = await client.get('127.0.0.1', port, '/?token=wrong');
        final res = await req.close();
        expect(res.statusCode, HttpStatus.forbidden);
      } finally {
        client.close(force: true);
      }
    });

    test('streams outbox downloads, incoming uploads, and WebSocket scans',
        () async {
      final port = await server.start(preferredPort: 0);
      final token = server.token;

      // Prepare an outbox file on Windows.
      final srcFile = File(p.join(tempRoot.path, 'hello.txt'));
      await srcFile.writeAsString('Hello from Windows QR Server!');
      await server.addOutboxPaths([srcFile.path]);

      // Verify short /s/<token> landing page works and rejects bad token.
      final htmlClient = HttpClient();
      try {
        final qrUrl = server.buildQrUrl('127.0.0.1');
        expect(qrUrl, contains('/s/$token'));
        final pageReq = await htmlClient.getUrl(Uri.parse(qrUrl));
        final pageRes = await pageReq.close();
        expect(pageRes.statusCode, HttpStatus.ok);
        final pageHtml = await utf8.decoder.bind(pageRes).join();
        expect(pageHtml, contains('DeviceBridge QR'));
      } finally {
        htmlClient.close(force: true);
      }

      // Connect WebSocket simulating scanned phone browser.
      final scannedFuture = server.deviceScannedStream.first;
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws?token=$token',
      );
      final scannedClient = await scannedFuture;
      expect(scannedClient.id, isNotEmpty);
      expect(server.connectedClients.length, 1);

      // Verify initial outbox WebSocket push + HTTP file download.
      final firstWsMsg =
          jsonDecode(await ws.first as String) as Map<String, dynamic>;
      expect(firstWsMsg['type'], 'outbox');
      final wsFiles = firstWsMsg['files'] as List<dynamic>;
      expect(wsFiles.length, 1);
      final fileId = (wsFiles.first as Map<String, dynamic>)['id'] as String;

      final httpClient = HttpClient();
      try {
        // Download file shared from Windows.
        final dlReq = await httpClient.get(
          '127.0.0.1',
          port,
          '/api/download/$fileId?token=$token',
        );
        final dlRes = await dlReq.close();
        expect(dlRes.statusCode, HttpStatus.ok);
        final dlBody = await utf8.decoder.bind(dlRes).join();
        expect(dlBody, 'Hello from Windows QR Server!');

        // Upload file from scanned device to Windows receive folder.
        final payload = utf8.encode('Uploaded from phone camera!');
        final ulReq = await httpClient.post(
          '127.0.0.1',
          port,
          '/api/upload?token=$token&name=${Uri.encodeComponent("../phone_pic.txt")}&size=${payload.length}',
        );
        ulReq.add(payload);
        final ulRes = await ulReq.close();
        expect(ulRes.statusCode, HttpStatus.ok);

        final saved = File(p.join(receiveDir.path, 'phone_pic.txt'));
        expect(await saved.exists(), isTrue);
        expect(await saved.readAsString(), 'Uploaded from phone camera!');
      } finally {
        httpClient.close(force: true);
        await ws.close();
      }
    });
  });
}
