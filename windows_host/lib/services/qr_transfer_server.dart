import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// A local IPv4 network interface candidate for generating a QR pairing URL.
class LanInterfaceInfo {
  const LanInterfaceInfo({
    required this.interfaceName,
    required this.ipAddress,
    required this.isPreferred,
  });

  final String interfaceName;
  final String ipAddress;
  final bool isPreferred;

  String get displayLabel => '$ipAddress ($interfaceName)';
}

/// A remote phone, tablet, or computer that scanned the QR code and connected.
class QrConnectedClient {
  const QrConnectedClient({
    required this.id,
    required this.deviceLabel,
    required this.remoteAddress,
    required this.connectedAt,
  });

  final String id;
  final String deviceLabel;
  final String remoteAddress;
  final DateTime connectedAt;
}

/// A Windows file or folder entry shared out to connected QR devices.
class QrSharedFile {
  const QrSharedFile({
    required this.id,
    required this.file,
    required this.name,
    required this.relativePath,
    required this.sizeBytes,
  });

  final String id;
  final File file;
  final String name;
  final String relativePath;
  final int sizeBytes;
}

enum QrTransferDirection { toDevice, fromDevice }

enum QrTransferState { transferring, completed, failed }

/// Activity record shown inside the Windows QR Transfer Window.
class QrTransferRecord {
  const QrTransferRecord({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.state,
    required this.totalBytes,
    required this.transferredBytes,
    this.savedPath,
    this.error,
  });

  final String id;
  final String fileName;
  final QrTransferDirection direction;
  final QrTransferState state;
  final int totalBytes;
  final int transferredBytes;
  final String? savedPath;
  final String? error;

  double get fraction =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  QrTransferRecord copyWith({
    QrTransferState? state,
    int? totalBytes,
    int? transferredBytes,
    String? savedPath,
    String? error,
  }) {
    return QrTransferRecord(
      id: id,
      fileName: fileName,
      direction: direction,
      state: state ?? this.state,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      savedPath: savedPath ?? this.savedPath,
      error: error ?? this.error,
    );
  }
}

/// Native Windows HTTP + WebSocket server that powers the QR-scanned browser
/// transfer portal so any phone, tablet, or computer can exchange bulk files
/// with this Windows app without installing any client software.
class QrTransferServer {
  QrTransferServer({required Directory receiveDir}) : _receiveDir = receiveDir; // ignore: prefer_initializing_formals

  static const int defaultPort = 49180;

  HttpServer? _server;
  String _token = _generateToken();
  Directory _receiveDir;

  final Map<String, QrSharedFile> _sharedOutbox = <String, QrSharedFile>{};
  final Map<String, ({QrConnectedClient client, WebSocket socket})> _clients =
      <String, ({QrConnectedClient client, WebSocket socket})>{};
  final List<QrTransferRecord> _records = <QrTransferRecord>[];

  final StreamController<void> _stateController =
      StreamController<void>.broadcast();
  final StreamController<QrConnectedClient> _deviceScannedController =
      StreamController<QrConnectedClient>.broadcast();

  int _nextId = 0;

  Stream<void> get stateStream => _stateController.stream;
  Stream<QrConnectedClient> get deviceScannedStream =>
      _deviceScannedController.stream;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String get token => _token;
  Directory get receiveDir => _receiveDir;

  List<QrSharedFile> get sharedFiles =>
      List.unmodifiable(_sharedOutbox.values.toList().reversed);

  List<QrConnectedClient> get connectedClients => List.unmodifiable(
        _clients.values.map((e) => e.client),
      );

  List<QrTransferRecord> get transferRecords => List.unmodifiable(_records);

  String buildQrUrl(String hostIp) {
    final pNum = _server?.port ?? defaultPort;
    return 'http://$hostIp:$pNum/s/$_token';
  }

  /// Checks whether Windows Firewall has an inbound rule for this executable
  /// and whether any active interface is marked as Public.
  Future<({bool hasFirewallRule, bool isPublicNetwork, String profileLabel})>
      checkWindowsFirewallStatus() async {
    if (!Platform.isWindows) {
      return (
        hasFirewallRule: true,
        isPublicNetwork: false,
        profileLabel: 'Private',
      );
    }
    var hasRule = false;
    var isPublic = false;
    var profileLabel = 'Unknown';
    try {
      final fwRes = await Process.run(
        'netsh',
        const ['advfirewall', 'firewall', 'show', 'rule', 'name=DeviceBridge'],
      );
      final exePath = Platform.resolvedExecutable.toLowerCase();
      final stdoutLower = fwRes.stdout.toString().toLowerCase();
      hasRule = fwRes.exitCode == 0 && stdoutLower.contains(exePath);
    } catch (_) {}

    try {
      final netRes = await Process.run('powershell', const [
        '-NoProfile',
        '-Command',
        "(Get-NetConnectionProfile | Select-Object -ExpandProperty NetworkCategory) -join ','",
      ]);
      final raw = netRes.stdout.toString().trim();
      if (raw.isNotEmpty) {
        profileLabel = raw;
        isPublic = raw.toLowerCase().contains('public');
      }
    } catch (_) {}

    return (
      hasFirewallRule: hasRule,
      isPublicNetwork: isPublic,
      profileLabel: profileLabel,
    );
  }

  /// Prompts Windows UAC to add an inbound firewall rule allowing DeviceBridge on Private & Public Wi-Fi.
  Future<bool> requestFirewallAllowRule() async {
    if (!Platform.isWindows) return true;
    final exe = Platform.resolvedExecutable.replaceAll('"', '');
    final cmdArgs =
        '/c netsh advfirewall firewall delete rule name="DeviceBridge" >nul 2>&1 & '
        'netsh advfirewall firewall add rule name="DeviceBridge" dir=in action=allow '
        'program="$exe" enable=yes profile=any';
    final escapedArgs = cmdArgs.replaceAll("'", "''");
    final res = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath 'cmd.exe' -ArgumentList '$escapedArgs' -Verb RunAs -Wait",
    ]);
    return res.exitCode == 0;
  }

  /// Opens Windows Mobile Hotspot settings so users on restricted office Wi-Fi
  /// can share directly with their phone without an external Wi-Fi router.
  Future<void> openMobileHotspotSettings() async {
    if (!Platform.isWindows) return;
    await Process.start(
      'cmd',
      const ['/c', 'start', 'ms-settings:network-mobilehotspot'],
      runInShell: false,
    );
  }

  Future<void> setReceiveDirectory(Directory dir) async {
    _receiveDir = dir;
    await _receiveDir.create(recursive: true);
    _notifyState();
  }

  Future<int> start({int preferredPort = defaultPort}) async {
    if (_server != null) return _server!.port;
    await _receiveDir.create(recursive: true);

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }

    _server = server;
    server.listen(_handleHttpRequest, onError: (_) {});
    _notifyState();
    return server.port;
  }

  void regenerateToken() {
    _token = _generateToken();
    for (final entry in _clients.values.toList()) {
      unawaited(entry.socket.close(WebSocketStatus.normalClosure, 'Reset'));
    }
    _clients.clear();
    _notifyState();
  }

  /// Adds Windows files or directories recursively to the QR outbox.
  Future<int> addOutboxPaths(List<String> localPaths) async {
    var added = 0;
    for (final rawPath in localPaths) {
      final type = await FileSystemEntity.type(rawPath);
      if (type == FileSystemEntityType.file) {
        final file = File(rawPath);
        await _addSingleOutboxFile(file, p.basename(file.path));
        added++;
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(rawPath);
        final rootName = p.basename(dir.path);
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final rel = p
                .join(rootName, p.relative(entity.path, from: dir.path))
                .replaceAll(r'\', '/');
            await _addSingleOutboxFile(entity, rel);
            added++;
          }
        }
      }
    }
    if (added > 0) {
      _notifyState();
      _broadcastOutboxUpdate();
    }
    return added;
  }

  Future<void> _addSingleOutboxFile(File file, String relativePath) async {
    // Deduplicate identical file paths already shared.
    for (final existing in _sharedOutbox.values) {
      if (existing.file.path == file.path) return;
    }
    final size = await file.length();
    final id = 'f${++_nextId}_${DateTime.now().millisecondsSinceEpoch}';
    _sharedOutbox[id] = QrSharedFile(
      id: id,
      file: file,
      name: p.basename(file.path),
      relativePath: relativePath,
      sizeBytes: size,
    );
  }

  void removeOutboxFile(String id) {
    if (_sharedOutbox.remove(id) != null) {
      _notifyState();
      _broadcastOutboxUpdate();
    }
  }

  void clearOutbox() {
    _sharedOutbox.clear();
    _notifyState();
    _broadcastOutboxUpdate();
  }

  void clearCompletedRecords() {
    _records.removeWhere((r) => r.state != QrTransferState.transferring);
    _notifyState();
  }

  Future<List<LanInterfaceInfo>> discoverLanInterfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final results = <LanInterfaceInfo>[];
    for (final iface in interfaces) {
      final lowerName = iface.name.toLowerCase();
      final isVirtual = lowerName.contains('vethernet') ||
          lowerName.contains('vmware') ||
          lowerName.contains('virtualbox') ||
          lowerName.contains('wsl') ||
          lowerName.contains('docker') ||
          lowerName.contains('hyper-v') ||
          lowerName.contains('tailscale') ||
          lowerName.contains('loopback');
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        final isHotspot = ip == '192.168.137.1';
        final isCommonLan = ip.startsWith('192.168.') || ip.startsWith('10.');
        results.add(
          LanInterfaceInfo(
            interfaceName: isHotspot ? 'Windows Mobile Hotspot' : iface.name,
            ipAddress: ip,
            isPreferred: isHotspot || (!isVirtual && isCommonLan),
          ),
        );
      }
    }
    results.sort((a, b) {
      final aHotspot = a.ipAddress == '192.168.137.1';
      final bHotspot = b.ipAddress == '192.168.137.1';
      if (aHotspot != bHotspot) return aHotspot ? -1 : 1;
      if (a.isPreferred != b.isPreferred) {
        return a.isPreferred ? -1 : 1;
      }
      return a.ipAddress.compareTo(b.ipAddress);
    });
    return results;
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final uri = request.uri;
    final pathToken = uri.path.startsWith('/s/')
        ? uri.path.substring('/s/'.length).split('/').first
        : '';
    final suppliedToken = (uri.queryParameters['token'] ??
            request.headers.value('x-devicebridge-token') ??
            pathToken)
        .trim();

    if (suppliedToken != _token) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.text;
      request.response
          .write('Invalid or expired QR session token. Rescan the QR code.');
      await request.response.close();
      return;
    }

    if (uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      await _handleWebSocketUpgrade(request);
      return;
    }

    if ((uri.path == '/' || uri.path.startsWith('/s/')) &&
        request.method == 'GET') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(_buildPortalHtml());
      await request.response.close();
      return;
    }

    if (uri.path == '/api/files' && request.method == 'GET') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(jsonEncode({'files': _serializeOutbox()}));
      await request.response.close();
      return;
    }

    if (uri.path.startsWith('/api/download/') && request.method == 'GET') {
      final id = Uri.decodeComponent(uri.path.substring('/api/download/'.length));
      await _handleDownload(request, id);
      return;
    }

    if (uri.path == '/api/upload' && request.method == 'POST') {
      await _handleUpload(request);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    final ua = request.headers.value(HttpHeaders.userAgentHeader) ?? '';
    final label = parseDeviceLabel(ua);
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'LAN';

    final socket = await WebSocketTransformer.upgrade(request);
    final clientId = 'cli_${++_nextId}';
    final client = QrConnectedClient(
      id: clientId,
      deviceLabel: label,
      remoteAddress: remoteIp,
      connectedAt: DateTime.now(),
    );

    _clients[clientId] = (client: client, socket: socket);
    _notifyState();
    if (!_deviceScannedController.isClosed) {
      _deviceScannedController.add(client);
    }

    socket.add(jsonEncode({
      'type': 'outbox',
      'files': _serializeOutbox(),
    }));

    socket.listen(
      (_) {},
      onDone: () {
        _clients.remove(clientId);
        _notifyState();
      },
      onError: (_) {
        _clients.remove(clientId);
        _notifyState();
      },
    );
  }

  Future<void> _handleDownload(HttpRequest request, String fileId) async {
    final shared = _sharedOutbox[fileId];
    if (shared == null || !await shared.file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final totalBytes = await shared.file.length();
    final txId = 'dl_${++_nextId}';
    _upsertRecord(
      QrTransferRecord(
        id: txId,
        fileName: shared.name,
        direction: QrTransferDirection.toDevice,
        state: QrTransferState.transferring,
        totalBytes: totalBytes,
        transferredBytes: 0,
      ),
    );

    final encodedName = Uri.encodeComponent(shared.name);
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.contentLength = totalBytes;
    request.response.headers.set(
      'Content-Disposition',
      'attachment; filename="${_asciiFallbackName(shared.name)}"; filename*=UTF-8\'\'$encodedName',
    );

    var sent = 0;
    var lastNotifyMs = 0;
    final sw = Stopwatch()..start();

    try {
      await for (final chunk in shared.file.openRead()) {
        request.response.add(chunk);
        sent += chunk.length;
        if (sw.elapsedMilliseconds - lastNotifyMs >= 100) {
          lastNotifyMs = sw.elapsedMilliseconds;
          _updateRecord(
            txId,
            (r) => r.copyWith(transferredBytes: sent),
          );
        }
      }
      await request.response.flush();
      await request.response.close();
      _updateRecord(
        txId,
        (r) => r.copyWith(
          state: QrTransferState.completed,
          transferredBytes: totalBytes,
        ),
      );
    } catch (e) {
      _updateRecord(
        txId,
        (r) => r.copyWith(
          state: QrTransferState.failed,
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final rawName = request.uri.queryParameters['name'] ??
        request.headers.value('x-file-name') ??
        'received_${DateTime.now().millisecondsSinceEpoch}.bin';
    final safeName = sanitizeFilename(Uri.decodeComponent(rawName));
    final expectedBytes =
        int.tryParse(request.uri.queryParameters['size'] ?? '') ??
            request.contentLength;

    await _receiveDir.create(recursive: true);
    final destFile = await _uniqueDestinationFile(_receiveDir, safeName);
    final partFile = File('${destFile.path}.part');

    final txId = 'ul_${++_nextId}';
    _upsertRecord(
      QrTransferRecord(
        id: txId,
        fileName: p.basename(destFile.path),
        direction: QrTransferDirection.fromDevice,
        state: QrTransferState.transferring,
        totalBytes: expectedBytes > 0 ? expectedBytes : 0,
        transferredBytes: 0,
      ),
    );

    final sink = partFile.openWrite();
    var received = 0;
    var lastNotifyMs = 0;
    final sw = Stopwatch()..start();

    try {
      await for (final chunk in request) {
        sink.add(chunk);
        received += chunk.length;
        if (sw.elapsedMilliseconds - lastNotifyMs >= 100) {
          lastNotifyMs = sw.elapsedMilliseconds;
          _updateRecord(
            txId,
            (r) => r.copyWith(
              transferredBytes: received,
              totalBytes: expectedBytes > 0 ? expectedBytes : received,
            ),
          );
        }
      }
      await sink.flush();
      await sink.close();
      await partFile.rename(destFile.path);

      _updateRecord(
        txId,
        (r) => r.copyWith(
          state: QrTransferState.completed,
          totalBytes: received,
          transferredBytes: received,
          savedPath: destFile.path,
        ),
      );

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'ok': true,
        'savedName': p.basename(destFile.path),
        'bytes': received,
      }));
      await request.response.close();
    } catch (e) {
      await sink.close();
      if (await partFile.exists()) {
        await partFile.delete();
      }
      _updateRecord(
        txId,
        (r) => r.copyWith(
          state: QrTransferState.failed,
          error: e.toString(),
        ),
      );
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Upload failed: $e');
      await request.response.close();
    }
  }

  List<Map<String, dynamic>> _serializeOutbox() {
    return sharedFiles
        .map((f) => {
              'id': f.id,
              'name': f.name,
              'relativePath': f.relativePath,
              'sizeBytes': f.sizeBytes,
            })
        .toList(growable: false);
  }

  void _broadcastOutboxUpdate() {
    final payload = jsonEncode({
      'type': 'outbox',
      'files': _serializeOutbox(),
    });
    for (final entry in _clients.values.toList()) {
      try {
        entry.socket.add(payload);
      } catch (_) {}
    }
  }

  void _upsertRecord(QrTransferRecord record) {
    _records.insert(0, record);
    if (_records.length > 150) {
      _records.removeRange(150, _records.length);
    }
    _notifyState();
  }

  void _updateRecord(
    String id,
    QrTransferRecord Function(QrTransferRecord) updater,
  ) {
    final idx = _records.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _records[idx] = updater(_records[idx]);
      _notifyState();
    }
  }

  void _notifyState() {
    if (!_stateController.isClosed) {
      _stateController.add(null);
    }
  }

  Future<void> dispose() async {
    for (final entry in _clients.values.toList()) {
      await entry.socket.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    await _stateController.close();
    await _deviceScannedController.close();
  }

  static String parseDeviceLabel(String userAgent) {
    final ua = userAgent.toLowerCase();
    if (ua.contains('iphone')) return 'iPhone';
    if (ua.contains('ipad')) return 'iPad';
    if (ua.contains('android')) return 'Android Phone';
    if (ua.contains('macintosh')) return 'Mac Browser';
    if (ua.contains('windows')) return 'Windows PC';
    if (ua.contains('linux')) return 'Linux Device';
    return 'Scanned Device';
  }

  static String sanitizeFilename(String input) {
    final rawBase = p.posix.basename(input.replaceAll(r'\', '/'));
    var base = rawBase.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    base = base.replaceAll(RegExp(r'\.{2,}'), '.').replaceFirst(RegExp(r'^\.+'), '');
    if (base.isEmpty || base == '.' || base == '..') {
      return 'received_file';
    }
    return base;
  }

  static String _asciiFallbackName(String name) =>
      name.replaceAll(RegExp(r'[^\x20-\x7E]|"'), '_');

  static Future<File> _uniqueDestinationFile(Directory dir, String name) async {
    var candidate = File(p.join(dir.path, name));
    if (!await candidate.exists()) return candidate;
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var i = 1; i < 10000; i++) {
      candidate = File(p.join(dir.path, '$stem ($i)$ext'));
      if (!await candidate.exists()) return candidate;
    }
    return File(p.join(
        dir.path, '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext'));
  }

  static String _generateToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final rng = Random.secure();
    return List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  String _buildPortalHtml() => _portalHtmlTemplate;
}

const String _portalHtmlTemplate = r'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
  <title>DeviceBridge QR Transfer</title>
  <style>
    :root {
      --bg: #0b1120;
      --card: #111c33;
      --border: rgba(255,255,255,0.10);
      --accent: #38bdf8;
      --accent2: #14b8a6;
      --text: #f8fafc;
      --muted: #94a3b8;
    }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { margin: 0; background: var(--bg); color: var(--text); padding: 16px; }
    .wrap { max-width: 720px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; }
    .header { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .brand { font-size: 20px; font-weight: 700; display: flex; align-items: center; gap: 8px; }
    .pill { font-size: 12px; padding: 5px 10px; border-radius: 999px; background: rgba(20,184,166,0.16); color: #5eead4; border: 1px solid rgba(20,184,166,0.4); }
    .pill.offline { background: rgba(251,191,36,0.16); color: #fcd34d; border-color: rgba(251,191,36,0.4); }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 16px; }
    h2 { margin: 0 0 10px; font-size: 16px; }
    .muted { color: var(--muted); font-size: 13px; margin: 0 0 12px; }
    .dropzone {
      border: 2px dashed rgba(56,189,248,0.5);
      border-radius: 14px;
      padding: 24px 16px;
      text-align: center;
      cursor: pointer;
      background: rgba(56,189,248,0.06);
      transition: background 0.15s;
    }
    .dropzone.active { background: rgba(56,189,248,0.16); border-color: var(--accent); }
    .btn {
      display: inline-flex; align-items: center; justify-content: center; gap: 6px;
      border: 0; border-radius: 10px; padding: 10px 16px; font-weight: 600; font-size: 14px;
      cursor: pointer; background: var(--accent); color: #082f49; text-decoration: none;
    }
    .btn.secondary { background: rgba(255,255,255,0.09); color: var(--text); }
    .list { display: flex; flex-direction: column; gap: 8px; }
    .row {
      display: flex; align-items: center; justify-content: space-between; gap: 12px;
      padding: 10px 12px; border-radius: 12px; background: rgba(255,255,255,0.04); border: 1px solid var(--border);
    }
    .meta { min-width: 0; flex: 1; }
    .name { font-size: 14px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .sub { font-size: 12px; color: var(--muted); margin-top: 2px; }
    progress { width: 100%; height: 8px; accent-color: var(--accent); margin-top: 8px; }
    .row-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <div class="brand">DeviceBridge QR</div>
      <div id="connPill" class="pill offline">Connecting...</div>
    </div>

    <div class="card">
      <h2>Send Files to Windows PC</h2>
      <p class="muted">Select multiple photos, videos, or documents for high-speed bulk upload straight to your Windows folder.</p>
      <div id="dropzone" class="dropzone">
        <div style="font-size:15px;font-weight:600;margin-bottom:8px;">Tap to Pick Files (Bulk Supported)</div>
        <div class="muted" style="margin-bottom:12px;">Or drag & drop files here</div>
        <button id="pickBtn" class="btn" type="button">Choose Files</button>
        <input id="fileInput" type="file" multiple style="display:none" />
      </div>
      <div id="uploadStatus" style="display:none;margin-top:12px;">
        <div id="uploadText" class="sub">Uploading...</div>
        <progress id="uploadBar" value="0" max="100"></progress>
      </div>
    </div>

    <div class="card">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:10px;">
        <h2 style="margin:0;">Files From Windows PC</h2>
        <button id="downloadAllBtn" class="btn secondary" type="button" style="display:none;">Download All</button>
      </div>
      <div id="outboxList" class="list">
        <div class="muted">No files shared from Windows yet. Drop files into the Windows QR window to see them here!</div>
      </div>
    </div>
  </div>

  <script>
    const params = new URLSearchParams(location.search);
    const pathMatch = location.pathname.match(/^\/s\/([^/?#]+)/);
    const token = params.get('token') || (pathMatch ? decodeURIComponent(pathMatch[1]) : '');
    const pill = document.getElementById('connPill');
    const outboxList = document.getElementById('outboxList');
    const downloadAllBtn = document.getElementById('downloadAllBtn');
    const dropzone = document.getElementById('dropzone');
    const fileInput = document.getElementById('fileInput');
    const pickBtn = document.getElementById('pickBtn');
    const uploadStatus = document.getElementById('uploadStatus');
    const uploadText = document.getElementById('uploadText');
    const uploadBar = document.getElementById('uploadBar');

    let currentFiles = [];

    function fmtBytes(n) {
      if (n < 1024) return n + ' B';
      if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
      if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
      return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    }

    function renderOutbox(files) {
      currentFiles = files || [];
      if (!currentFiles.length) {
        downloadAllBtn.style.display = 'none';
        outboxList.innerHTML = '<div class="muted">No files shared from Windows yet. Drop files into the Windows QR window to see them here!</div>';
        return;
      }
      downloadAllBtn.style.display = currentFiles.length > 1 ? 'inline-flex' : 'none';
      outboxList.innerHTML = '';
      for (const f of currentFiles) {
        const row = document.createElement('div');
        row.className = 'row';
        const meta = document.createElement('div');
        meta.className = 'meta';
        const name = document.createElement('div');
        name.className = 'name';
        name.textContent = f.relativePath || f.name;
        const sub = document.createElement('div');
        sub.className = 'sub';
        sub.textContent = fmtBytes(f.sizeBytes || 0);
        meta.appendChild(name);
        meta.appendChild(sub);

        const dl = document.createElement('a');
        dl.className = 'btn';
        dl.textContent = 'Download';
        dl.href = '/api/download/' + encodeURIComponent(f.id) + '?token=' + encodeURIComponent(token);
        dl.setAttribute('download', f.name);

        row.appendChild(meta);
        row.appendChild(dl);
        outboxList.appendChild(row);
      }
    }

    downloadAllBtn.addEventListener('click', () => {
      currentFiles.forEach((f, idx) => {
        setTimeout(() => {
          const a = document.createElement('a');
          a.href = '/api/download/' + encodeURIComponent(f.id) + '?token=' + encodeURIComponent(token);
          a.download = f.name;
          document.body.appendChild(a);
          a.click();
          a.remove();
        }, idx * 350);
      });
    });

    function connectWs() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const ws = new WebSocket(proto + '//' + location.host + '/ws?token=' + encodeURIComponent(token));
      ws.onopen = () => {
        pill.textContent = 'Connected to Windows';
        pill.classList.remove('offline');
      };
      ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.type === 'outbox') renderOutbox(msg.files);
        } catch (_) {}
      };
      ws.onclose = () => {
        pill.textContent = 'Reconnecting...';
        pill.classList.add('offline');
        setTimeout(connectWs, 1500);
      };
    }

    async function uploadFiles(fileList) {
      const files = Array.from(fileList || []);
      if (!files.length) return;
      uploadStatus.style.display = 'block';
      const totalBytes = files.reduce((a, f) => a + f.size, 0);
      const loadedPerFile = new Array(files.length).fill(0);
      let completed = 0;
      let nextIdx = 0;

      function updateProgress(activeName) {
        const loaded = loadedPerFile.reduce((a, b) => a + b, 0);
        const pct = totalBytes > 0 ? Math.round((loaded / totalBytes) * 100) : Math.round((completed / files.length) * 100);
        uploadBar.value = pct;
        uploadText.textContent = 'Sent ' + completed + '/' + files.length + ' (' + fmtBytes(loaded) + ' / ' + fmtBytes(totalBytes) + ') • ' + activeName;
      }

      async function worker() {
        while (true) {
          const i = nextIdx++;
          if (i >= files.length) return;
          const file = files[i];
          await new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('POST', '/api/upload?token=' + encodeURIComponent(token) + '&name=' + encodeURIComponent(file.name) + '&size=' + file.size);
            xhr.upload.onprogress = (e) => {
              if (e.lengthComputable) {
                loadedPerFile[i] = e.loaded;
                updateProgress(file.name);
              }
            };
            xhr.onload = () => {
              loadedPerFile[i] = file.size;
              completed++;
              updateProgress(file.name);
              xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new Error('HTTP ' + xhr.status));
            };
            xhr.onerror = () => reject(new Error('Network error'));
            xhr.send(file);
          });
        }
      }

      try {
        const workers = Math.min(3, files.length);
        await Promise.all(Array.from({ length: workers }, worker));
        uploadBar.value = 100;
        uploadText.textContent = 'Completed: ' + files.length + ' file(s) (' + fmtBytes(totalBytes) + ') sent to Windows!';
      } catch (err) {
        uploadText.textContent = 'Upload error: ' + err.message;
      }
      fileInput.value = '';
    }

    pickBtn.addEventListener('click', (e) => { e.stopPropagation(); fileInput.click(); });
    dropzone.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', (e) => uploadFiles(e.target.files));
    dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('active'); });
    dropzone.addEventListener('dragleave', () => dropzone.classList.remove('active'));
    dropzone.addEventListener('drop', (e) => {
      e.preventDefault();
      dropzone.classList.remove('active');
      uploadFiles(e.dataTransfer.files);
    });

    connectWs();
  </script>
</body>
</html>
''';
