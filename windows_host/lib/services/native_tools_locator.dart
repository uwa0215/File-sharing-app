import 'dart:io';

import 'package:path/path.dart' as p;

enum NativeToolKind { adb, scrcpy, iproxy, uxplay }

enum ToolResolutionSource { bundledRelease, devWorkspace, systemPath, missing }

class ResolvedNativeTool {
  const ResolvedNativeTool({
    required this.kind,
    required this.executableName,
    required this.source,
    this.resolvedPath,
  });

  final NativeToolKind kind;
  final String executableName;
  final ToolResolutionSource source;
  final String? resolvedPath;

  bool get isAvailable => resolvedPath != null;
}

/// Locates sidecar native binaries (`adb`, `scrcpy`, `iproxy`, `uxplay`) from
/// the packaged `<exe_dir>/tools/` bundle, dev `native_tools/`, or `PATH`.
class NativeToolsLocator {
  NativeToolsLocator({
    String? executablePath,
    this._workspaceToolsPath,
  }) : _executablePath = executablePath ?? Platform.resolvedExecutable;

  final String _executablePath;
  final String? _workspaceToolsPath;

  static const Map<NativeToolKind, (String subdir, String exeName)> _toolSpec = {
    NativeToolKind.adb: ('android', 'adb.exe'),
    NativeToolKind.scrcpy: ('android', 'scrcpy.exe'),
    NativeToolKind.iproxy: ('ios', 'iproxy.exe'),
    NativeToolKind.uxplay: ('airplay', 'uxplay.exe'),
  };

  /// Resolves a single native sidecar tool.
  ResolvedNativeTool resolve(NativeToolKind kind) {
    final (subdir, exeName) = _toolSpec[kind]!;

    // 1. Release sidecar layout next to windows_host.exe: <exe_dir>/tools/<subdir>/<exe>
    final exeDir = File(_executablePath).parent.path;
    final bundled = File(p.join(exeDir, 'tools', subdir, exeName));
    if (bundled.existsSync()) {
      return ResolvedNativeTool(
        kind: kind,
        executableName: exeName,
        source: ToolResolutionSource.bundledRelease,
        resolvedPath: bundled.path,
      );
    }

    // 2. Development workspace layout: windows_host/native_tools/<subdir>/<exe>
    final devBase = _workspaceToolsPath ?? p.join(Directory.current.path, 'native_tools');
    final devFile = File(p.join(devBase, subdir, exeName));
    if (devFile.existsSync()) {
      return ResolvedNativeTool(
        kind: kind,
        executableName: exeName,
        source: ToolResolutionSource.devWorkspace,
        resolvedPath: devFile.path,
      );
    }

    // 3. System PATH fallback
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final rawDir in pathEnv.split(';')) {
      final trimmed = rawDir.trim();
      if (trimmed.isEmpty) continue;
      final candidate = File(p.join(trimmed, exeName));
      if (candidate.existsSync()) {
        return ResolvedNativeTool(
          kind: kind,
          executableName: exeName,
          source: ToolResolutionSource.systemPath,
          resolvedPath: candidate.path,
        );
      }
    }

    return ResolvedNativeTool(
      kind: kind,
      executableName: exeName,
      source: ToolResolutionSource.missing,
    );
  }

  /// Resolves all sidecar tools for diagnostics UI.
  List<ResolvedNativeTool> resolveAll() {
    return NativeToolKind.values.map(resolve).toList(growable: false);
  }
}

