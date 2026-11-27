import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' as dd;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../models/usb_device_models.dart';
import '../services/qr_transfer_server.dart';

/// Interactive QR Wireless Pairing & Bidirectional Bulk Transfer Window.
/// Generates a live scannable QR code on the left and hosts a drag-and-drop
/// Transfer Window on the right (plus a focused expandable Transfer Window dialog).
class QrTransferPanel extends StatefulWidget {
  const QrTransferPanel({
    super.key,
    required this.server,
    this.enableNativeServices = true,
  });

  final QrTransferServer server;
  final bool enableNativeServices;

  @override
  State<QrTransferPanel> createState() => _QrTransferPanelState();
}

class _QrTransferPanelState extends State<QrTransferPanel> {
  StreamSubscription<void>? _stateSub;
  StreamSubscription<QrConnectedClient>? _scanSub;

  List<LanInterfaceInfo> _interfaces = const [];
  String? _selectedIp;
  bool _dropHovering = false;
  bool _transferWindowDialogOpen = false;
  bool _hasFirewallRule = true;
  bool _isPublicNetwork = false;
  String _networkProfileLabel = '';
  bool _checkingFirewall = false;
  String? _lastScannedAnnouncement;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.server.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _scanSub = widget.server.deviceScannedStream.listen((client) {
      if (!mounted) return;
      setState(() {
        _lastScannedAnnouncement =
            'Scanned & connected: ${client.deviceLabel} (${client.remoteAddress})';
      });
      if (!_transferWindowDialogOpen) {
        _openDedicatedTransferWindow();
      }
    });
    if (widget.enableNativeServices) {
      unawaited(_initServerAndNetwork());
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _scanSub?.cancel();
    super.dispose();
  }

  Future<void> _initServerAndNetwork() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      await widget.server.setReceiveDirectory(
        Directory(p.join(downloads.path, 'DeviceBridge')),
      );
    }
    await widget.server.start();
    await Future.wait([
      _refreshInterfaces(),
      _refreshFirewallStatus(),
    ]);
  }

  Future<void> _refreshFirewallStatus() async {
    final status = await widget.server.checkWindowsFirewallStatus();
    if (!mounted) return;
    setState(() {
      _hasFirewallRule = status.hasFirewallRule;
      _isPublicNetwork = status.isPublicNetwork;
      _networkProfileLabel = status.profileLabel;
    });
  }

  Future<void> _allowFirewallPressed() async {
    setState(() => _checkingFirewall = true);
    try {
      await widget.server.requestFirewallAllowRule();
      await _refreshFirewallStatus();
    } finally {
      if (mounted) setState(() => _checkingFirewall = false);
    }
  }

  Future<void> _refreshInterfaces() async {
    final list = await widget.server.discoverLanInterfaces();
    if (!mounted) return;
    setState(() {
      _interfaces = list;
      if (list.isNotEmpty &&
          (_selectedIp == null ||
              !list.any((iface) => iface.ipAddress == _selectedIp))) {
        _selectedIp = list.first.ipAddress;
      }
    });
  }

  Future<void> _pickOutboxFiles() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    final paths = res.paths.whereType<String>().toList();
    if (paths.isNotEmpty) {
      await widget.server.addOutboxPaths(paths);
    }
  }

  Future<void> _pickOutboxFolder() async {
    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder to send via QR session',
    );
    if (dirPath != null) {
      await widget.server.addOutboxPaths([dirPath]);
    }
  }

  Future<void> _chooseReceiveFolder() async {
    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Windows folder for incoming QR files',
    );
    if (dirPath != null) {
      await widget.server.setReceiveDirectory(Directory(dirPath));
    }
  }

  Future<void> _openFolderInExplorer(String path) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', [path]);
  }

  Future<void> _revealFileInExplorer(String filePath) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', ['/select,$filePath']);
  }

  Future<void> _handleOutboxDrop(dd.DropDetails details) async {
    setState(() => _dropHovering = false);
    final paths = <String>[];
    for (final item in details.items) {
      if (item is dd.DropFileItem && item.localPath != null) {
        paths.add(item.localPath!);
      } else if (item is dd.DropDirectoryItem && item.localPath != null) {
        paths.add(item.localPath!);
      }
    }
    if (paths.isNotEmpty) {
      await widget.server.addOutboxPaths(paths);
    }
  }

  void _openDedicatedTransferWindow() {
    if (_transferWindowDialogOpen) return;
    _transferWindowDialogOpen = true;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.all(28),
          child: SizedBox(
            width: 860,
            height: 620,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.swap_horiz, color: Color(0xFF38BDF8)),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'QR File Transfer Window',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Chip(
                        avatar: Icon(
                          widget.server.connectedClients.isNotEmpty
                              ? Icons.check_circle
                              : Icons.qr_code_2,
                          size: 16,
                          color: widget.server.connectedClients.isNotEmpty
                              ? Colors.tealAccent
                              : Colors.amberAccent,
                        ),
                        label: Text(
                          widget.server.connectedClients.isNotEmpty
                              ? '${widget.server.connectedClients.length} device connected'
                              : 'Waiting for QR scan',
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close Transfer Window',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: StreamBuilder<void>(
                    stream: widget.server.stateStream,
                    builder: (context, _) => _buildTransferWindowBody(
                      inModal: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _transferWindowDialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeIp = _selectedIp ?? '127.0.0.1';
    final qrUrl = widget.server.buildQrUrl(activeIp);
    final clients = widget.server.connectedClients;

    return Row(
      children: [
        // Left Panel: Scannable QR Code + Connected Devices + Receive Folder
        SizedBox(
          width: 375,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Scan QR Code on Other Device',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Open Camera on iPhone, Android, or another device on the same Wi-Fi and scan this code — no app install needed.',
                  style: TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.25),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: qrUrl,
                      version: QrVersions.auto,
                      size: 210,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // LAN IP selector + Copy + Reset
                if (_interfaces.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: _selectedIp,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Wi-Fi / LAN Adapter',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: _interfaces
                        .map(
                          (iface) => DropdownMenuItem(
                            value: iface.ipAddress,
                            child: Text(
                              iface.displayLabel,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (ip) {
                      if (ip != null) setState(() => _selectedIp = ip);
                    },
                  ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          qrUrl,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copy Pairing URL',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: qrUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Copied QR URL to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.lock_reset, size: 18),
                        tooltip: 'Generate New QR Session Token',
                        onPressed: widget.server.regenerateToken,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Live Scan / Connection Status Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: clients.isNotEmpty
                        ? const Color(0xFF14B8A6).withValues(alpha: 0.14)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: clients.isNotEmpty
                          ? const Color(0xFF14B8A6).withValues(alpha: 0.5)
                          : Colors.white12,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            clients.isNotEmpty
                                ? Icons.verified
                                : Icons.qr_code_scanner,
                            size: 18,
                            color: clients.isNotEmpty
                                ? Colors.tealAccent
                                : Colors.amberAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              clients.isNotEmpty
                                  ? '${clients.length} Device(s) Connected'
                                  : (_lastScannedAnnouncement ??
                                      'Waiting for device scan...'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (clients.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final c in clients)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(Icons.devices, size: 15),
                                label:
                                    Text('${c.deviceLabel} (${c.remoteAddress})'),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _openDedicatedTransferWindow,
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: const Text('Open Transfer Window'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                if (widget.enableNativeServices && !_hasFirewallRule) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.amberAccent.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.security,
                              size: 18,
                              color: Colors.amberAccent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _isPublicNetwork
                                    ? 'Windows Firewall (${_networkProfileLabel.isEmpty ? "Public" : _networkProfileLabel}) may block phone scans'
                                    : 'Allow Windows Firewall for phone scans',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                  color: Colors.amberAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'If scanning the QR code does not open the page on your phone, allow DeviceBridge in Windows Firewall (or try Mobile Hotspot if office/school Wi-Fi blocks local devices).',
                          style: TextStyle(fontSize: 11.5, color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            onPressed: _checkingFirewall
                                ? null
                                : _allowFirewallPressed,
                            icon: const Icon(Icons.shield_outlined, size: 17),
                            label: Text(
                              _checkingFirewall
                                  ? 'Waiting for permission...'
                                  : 'Allow Windows Firewall Access',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Incoming Save Folder Settings
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Windows Save Folder (Incoming Files)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.server.receiveDir.path,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.white70,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _chooseReceiveFolder,
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: const Text('Change'),
                          ),
                          TextButton.icon(
                            onPressed: () => _openFolderInExplorer(
                              widget.server.receiveDir.path,
                            ),
                            icon: const Icon(Icons.launch, size: 16),
                            label: const Text('Open Folder'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),

        // Right Panel: Live Transfer Window
        Expanded(
          child: _buildTransferWindowBody(inModal: false),
        ),
      ],
    );
  }

  Widget _buildTransferWindowBody({required bool inModal}) {
    final shared = widget.server.sharedFiles;
    final records = widget.server.transferRecords;

    final outboxArea = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.upload_file, color: Color(0xFF38BDF8), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Transfer Window — Send Files to Scanned Device (${shared.length})',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilledButton.icon(
                onPressed: _pickOutboxFiles,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Files'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _pickOutboxFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Add Folder'),
              ),
              if (shared.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.server.clearOutbox,
                  child: const Text('Clear'),
                ),
              ],
              if (!inModal) ...[
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _openDedicatedTransferWindow,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  tooltip: 'Pop Out Transfer Window',
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _wrapDropZone(
              child: Container(
                decoration: BoxDecoration(
                  color: _dropHovering
                      ? const Color(0xFF0EA5E9).withValues(alpha: 0.14)
                      : const Color(0xFF0B1120),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _dropHovering
                        ? const Color(0xFF38BDF8)
                        : Colors.white.withValues(alpha: 0.12),
                    width: _dropHovering ? 2 : 1,
                  ),
                ),
                child: shared.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _dropHovering
                                    ? Icons.file_download_outlined
                                    : Icons.cloud_upload_outlined,
                                size: 42,
                                color: const Color(0xFF38BDF8),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _dropHovering
                                    ? 'Release files or folders to share with scanned device'
                                    : 'Drag & Drop Files or Folders Here',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Any file dropped here appears instantly on the scanned device to download at full Wi-Fi speed.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.white60,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: shared.length,
                        itemExtent: 58,
                        itemBuilder: (ctx, i) {
                          final item = shared[i];
                          return ListTile(
                            leading: const Icon(
                              Icons.insert_drive_file_outlined,
                              color: Color(0xFF38BDF8),
                            ),
                            title: Text(
                              item.relativePath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${formatByteCount(item.sizeBytes)} • Ready on scanned device',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Remove from shared list',
                              onPressed: () =>
                                  widget.server.removeOutboxFile(item.id),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
        ),
      ],
    );

    final transfersArea = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              const Icon(Icons.swap_vert, color: Colors.tealAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Live Transfer Activity (${records.length})',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (records.isNotEmpty)
                TextButton(
                  onPressed: widget.server.clearCompletedRecords,
                  child: const Text('Clear Finished'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: records.isEmpty
              ? const Center(
                  child: Text(
                    'Files sent from the scanned phone or downloaded to the phone will stream live here.',
                    style: TextStyle(fontSize: 12.5, color: Colors.white60),
                  ),
                )
              : ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (ctx, i) {
                    final rec = records[i];
                    final isFromPhone =
                        rec.direction == QrTransferDirection.fromDevice;
                    final savedPath = rec.savedPath;

                    Widget tile = ListTile(
                      dense: true,
                      leading: Icon(
                        isFromPhone ? Icons.download : Icons.upload,
                        color: switch (rec.state) {
                          QrTransferState.transferring =>
                            const Color(0xFF38BDF8),
                          QrTransferState.completed => Colors.tealAccent,
                          QrTransferState.failed => Colors.redAccent,
                        },
                      ),
                      title: Text(
                        rec.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rec.state == QrTransferState.failed
                                ? (rec.error ?? 'Failed')
                                : '${isFromPhone ? "From device" : "To device"} • '
                                    '${formatByteCount(rec.transferredBytes)}'
                                    '${rec.totalBytes > 0 ? " / ${formatByteCount(rec.totalBytes)}" : ""}',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          if (rec.state == QrTransferState.transferring)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: LinearProgressIndicator(
                                value: rec.totalBytes > 0 ? rec.fraction : null,
                              ),
                            ),
                        ],
                      ),
                      trailing: (savedPath != null &&
                              rec.state == QrTransferState.completed)
                          ? IconButton(
                              icon: const Icon(Icons.folder_open, size: 18),
                              tooltip: 'Show in File Explorer',
                              onPressed: () =>
                                  _revealFileInExplorer(savedPath),
                            )
                          : null,
                    );

                    if (widget.enableNativeServices &&
                        savedPath != null &&
                        rec.state == QrTransferState.completed) {
                      tile = DragItemWidget(
                        dragItemProvider: (_) async {
                          final item = DragItem(suggestedName: rec.fileName);
                          item.add(Formats.fileUri(File(savedPath).uri));
                          return item;
                        },
                        allowedOperations: () => const [DropOperation.copy],
                        child: DraggableWidget(child: tile),
                      );
                    }
                    return tile;
                  },
                ),
        ),
      ],
    );

    return Column(
      children: [
        Expanded(flex: 3, child: outboxArea),
        const Divider(height: 1),
        Expanded(flex: 2, child: transfersArea),
      ],
    );
  }

  Widget _wrapDropZone({required Widget child}) {
    if (!widget.enableNativeServices) return child;
    return dd.DropTarget(
      onEnter: (_) => setState(() => _dropHovering = true),
      onLeave: () => setState(() => _dropHovering = false),
      onDrop: _handleOutboxDrop,
      child: child,
    );
  }
}
