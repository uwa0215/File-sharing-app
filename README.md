# DeviceBridge USB (Windows Only)

**DeviceBridge USB** is a native Windows desktop application (`windows_host`) that automatically detects and reads **Android** and **iPhone / iPad** devices as soon as you plug them in via USB — **with zero companion app needed on the phone**.

---

## Key Capabilities

- **Zero Mobile App Required:** Just plug your Android or iPhone/iPad into a Windows USB port.
- **Automatic USB Detection (`WM_DEVICECHANGE` + WPD + ADB):**
  - **Android (MTP or ADB):** Automatically reads `Internal Storage` (`DCIM`, `Download`, `Pictures`, `Documents`, etc.), supports dragging files **from Windows to Phone** AND **from Phone to Windows Desktop / File Explorer**, plus **Live Screen Mirroring (`scrcpy.exe`)** when USB Debugging is enabled.
  - **iPhone / iPad (Apple USB PTP):** After tapping **Trust** on your iPhone/iPad, Windows mounts `DCIM` photos & videos automatically so you can drag them straight onto your Windows Desktop or export selected files in bulk.
- **Phone Explorer First:** Instant breadcrumb browsing, quick-jump folder chips, filename search filter, multi-select batch export, and native Win32 drag-and-drop (`super_drag_and_drop` + `desktop_drop`).

---

## Project Layout

- [`windows_host/`](windows_host) — Native Flutter Windows C++/Dart application + Win32 WPD (`PortableDeviceApi`) COM bridge + bundled `adb.exe` / `scrcpy.exe` + Inno Setup installer (`installer/devicebridge.iss`).
- [`scripts/build_installers.ps1`](scripts/build_installers.ps1) — Local Windows build & test script generating `dist/DeviceBridge-Windows-1.0.0-Setup.exe`.
- [`.github/workflows/build_installers.yml`](.github/workflows/build_installers.yml) — GitHub Actions CI building and uploading `DeviceBridge-Windows-1.0.0-Setup.exe`.

---

## Documentation

Read the full user tutorial: **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)**
