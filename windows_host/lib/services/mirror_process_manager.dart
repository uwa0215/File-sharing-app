import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/usb_device_models.dart';
import 'native_tools_locator.dart';

enum MirrorState { idle, starting, running, error }

class MirrorStatus {
  const MirrorStatus({
    required this.state,
    this.platform,
    this.docked = false,
    this.message,
  });

  final MirrorState state;
  final MobileOs? platform;
  final bool docked;
  final String? message;
}

/// Manages `scrcpy.exe` (Android) and `uxplay.exe` (iOS AirPlay) child
/// processes and docks their native window inside the Flutter mirror viewport
/// using Win32 `SetParent` / `SetWindowPos`.
class MirrorProcessManager {
  MirrorProcessManager({required this._locator});

  static const String _scrcpyWindowTitle = 'DeviceBridge-Mirror';

  final NativeToolsLocator _locator;
  Process? _process;
  int? _childHwnd;
  int? _hostHwnd;
  bool _docked = true;
  Rect? _lastBounds;
  MobileOs? _activePlatform;

  final StreamController<MirrorStatus> _statusController =
      StreamController<MirrorStatus>.broadcast();

  Stream<MirrorStatus> get statusStream => _statusController.stream;
  bool get isRunning => _process != null;
  bool get isDocked => _docked;

  /// Starts mirroring for [platform] (`android` -> `scrcpy`, `ios` -> `uxplay`).
  Future<void> startMirror({
    required MobileOs platform,
    String? androidSerial,
    Rect? viewportRect,
    bool dockInsideViewport = true,
  }) async {
    await stopMirror();
    _docked = dockInsideViewport;
    _lastBounds = viewportRect;
    _activePlatform = platform;

    if (platform == MobileOs.android) {
      await _startScrcpy(serial: androidSerial);
    } else if (platform == MobileOs.ios) {
      await _startUxPlay();
    } else {
      _emit(
        const MirrorStatus(
          state: MirrorState.error,
          message: 'Screen mirroring is only supported for Android and iOS.',
        ),
      );
    }
  }

  Future<void> _startScrcpy({String? serial}) async {
    final scrcpy = _locator.resolve(NativeToolKind.scrcpy);
    if (!scrcpy.isAvailable) {
      _emit(
        const MirrorStatus(
          state: MirrorState.error,
          platform: MobileOs.android,
          message:
              'scrcpy.exe not found. Place scrcpy files in native_tools/android/ (or tools/android/).',
        ),
      );
      return;
    }

    _emit(
      const MirrorStatus(
        state: MirrorState.starting,
        platform: MobileOs.android,
        message: 'Starting scrcpy mirror...',
      ),
    );

    final args = <String>[
      if (serial != null && serial.isNotEmpty) ...['-s', serial],
      '--window-title=$_scrcpyWindowTitle',
      '--window-borderless',
      '--max-size=1280',
      '--video-bit-rate=8M',
      '--stay-awake',
    ];

    try {
      final proc = await Process.start(scrcpy.resolvedPath!, args);
      _process = proc;
      unawaited(proc.exitCode.then((code) {
        if (_process == proc) {
          _process = null;
          _childHwnd = null;
          _emit(
            MirrorStatus(
              state: MirrorState.idle,
              platform: MobileOs.android,
              message: 'Mirror stopped (exit $code)',
            ),
          );
        }
      }));

      await _attachWindowWhenReady(_scrcpyWindowTitle, MobileOs.android);
    } catch (e) {
      _emit(
        MirrorStatus(
          state: MirrorState.error,
          platform: MobileOs.android,
          message: 'Failed to launch scrcpy: $e',
        ),
      );
    }
  }

  Future<void> _startUxPlay() async {
    final uxplay = _locator.resolve(NativeToolKind.uxplay);
    if (!uxplay.isAvailable) {
      _emit(
        const MirrorStatus(
          state: MirrorState.error,
          platform: MobileOs.ios,
          message:
              'uxplay.exe not found. Place UxPlay + GStreamer in native_tools/airplay/ and ensure Apple Bonjour Service is installed.',
        ),
      );
      return;
    }

    _emit(
      const MirrorStatus(
        state: MirrorState.starting,
        platform: MobileOs.ios,
        message: 'Starting AirPlay receiver (DeviceBridge)...',
      ),
    );

    try {
      final proc = await Process.start(uxplay.resolvedPath!, [
        '-n',
        'DeviceBridge',
      ]);
      _process = proc;
      unawaited(proc.exitCode.then((code) {
        if (_process == proc) {
          _process = null;
          _childHwnd = null;
          _emit(
            MirrorStatus(
              state: MirrorState.idle,
              platform: MobileOs.ios,
              message: 'AirPlay stopped (exit $code)',
            ),
          );
        }
      }));

      _emit(
        const MirrorStatus(
          state: MirrorState.running,
          platform: MobileOs.ios,
          docked: false,
          message: 'AirPlay receiver ready — select "DeviceBridge" in iOS Screen Mirroring',
        ),
      );
    } catch (e) {
      _emit(
        MirrorStatus(
          state: MirrorState.error,
          platform: MobileOs.ios,
          message: 'Failed to launch UxPlay: $e',
        ),
      );
    }
  }

  Future<void> _attachWindowWhenReady(
    String windowTitle,
    MobileOs platform,
  ) async {
    if (!Platform.isWindows) return;

    final titlePtr = windowTitle.toNativeUtf16();
    try {
      for (var attempt = 0; attempt < 30; attempt++) {
        if (_process == null) return;
        final hwnd = FindWindow(nullptr, titlePtr);
        if (hwnd != 0) {
          _childHwnd = hwnd;
          _hostHwnd = GetActiveWindow();
          if (_docked && _hostHwnd != null && _hostHwnd != 0) {
            _dockChildWindow(hwnd, _hostHwnd!, _lastBounds);
          }
          _emit(
            MirrorStatus(
              state: MirrorState.running,
              platform: platform,
              docked: _docked,
              message: _docked
                  ? 'Mirroring live inside viewport'
                  : 'Mirroring in pop-out window',
            ),
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      calloc.free(titlePtr);
    }

    _emit(
      MirrorStatus(
        state: MirrorState.running,
        platform: platform,
        docked: false,
        message: 'Mirror running (window docking timed out)',
      ),
    );
  }

  /// Updates the embedded Win32 child window position when Flutter resizes.
  void updateViewportBounds(Rect bounds) {
    _lastBounds = bounds;
    if (!Platform.isWindows || !_docked) return;
    final child = _childHwnd;
    if (child == null || child == 0) return;

    SetWindowPos(
      child,
      HWND_TOP,
      bounds.left.round(),
      bounds.top.round(),
      bounds.width.round().clamp(1, 4096),
      bounds.height.round().clamp(1, 4096),
      SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
  }

  void setDocked(bool docked) {
    _docked = docked;
    final child = _childHwnd;
    if (!Platform.isWindows || child == null || child == 0) return;
    if (docked && _hostHwnd != null && _hostHwnd != 0) {
      _dockChildWindow(child, _hostHwnd!, _lastBounds);
    } else {
      SetParent(child, 0);
      final style = GetWindowLongPtr(child, GWL_STYLE);
      SetWindowLongPtr(
        child,
        GWL_STYLE,
        (style & ~WS_CHILD) | WS_OVERLAPPEDWINDOW,
      );
      SetWindowPos(
        child,
        HWND_TOP,
        120,
        120,
        420,
        820,
        SWP_FRAMECHANGED | SWP_SHOWWINDOW,
      );
    }
    _emit(
      MirrorStatus(
        state: MirrorState.running,
        platform: _activePlatform,
        docked: _docked,
        message: _docked
            ? 'Mirroring live inside viewport'
            : 'Mirroring in pop-out window',
      ),
    );
  }

  void _dockChildWindow(int childHwnd, int parentHwnd, Rect? bounds) {
    final style = GetWindowLongPtr(childHwnd, GWL_STYLE);
    SetWindowLongPtr(
      childHwnd,
      GWL_STYLE,
      (style & ~WS_POPUP & ~WS_CAPTION & ~WS_THICKFRAME) | WS_CHILD,
    );
    SetParent(childHwnd, parentHwnd);
    if (bounds != null) {
      updateViewportBounds(bounds);
    }
  }

  Future<void> stopMirror() async {
    final proc = _process;
    _process = null;
    _childHwnd = null;
    proc?.kill();
    _emit(const MirrorStatus(state: MirrorState.idle));
  }

  void _emit(MirrorStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Future<void> dispose() async {
    await stopMirror();
    await _statusController.close();
  }
}

