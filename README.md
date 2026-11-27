# DeviceBridge (Windows App)

**DeviceBridge** is a native Windows desktop application (`windows_host`) for fast bulk file transfers with **any phone, tablet, or computer** — featuring **QR Code Wireless Transfer** (scan with your phone camera, no app install required) plus **USB Cable Plug & Play**.

---

## Key Capabilities

### 1. QR Code Wireless Transfer (`QR Transfer` Tab — Default)
- **Instant Scannable QR Code:** Windows generates a local LAN pairing QR code (`http://<lan-ip>:<port>/?token=...`).
- **Zero Mobile App Required:** Open the built-in Camera on **iPhone, iPad, Android, or any browser** on the same Wi-Fi and scan the QR code.
- **Dedicated Transfer Window:** Once scanned, Windows shows the connected device live and opens/updates the **Transfer Window**:
  - **Windows -> Device:** Drag & drop any files or whole folders from Windows Explorer to share them instantly with 1-tap **Download** / **Download All** on the scanned device.
  - **Device -> Windows:** Pick multiple photos, videos, or documents on your phone to stream at full Wi-Fi speed directly into your chosen Windows folder (defaults to `Downloads/DeviceBridge`).

### 2. Plug-and-Play USB Mode (`USB Cable` Tab)
- Built-in Win32 WPD (MTP & Apple PTP) C++ bridge + ADB bulk pipelines + `scrcpy` Android live screen mirroring.
- Read & bulk-drag files between Android/iPhone and Windows over USB.

---

## Project Layout

- [`windows_host/`](windows_host) — Native Flutter Windows C++/Dart application + LAN HTTP/WebSocket QR transfer engine (`QrTransferServer`) + Win32 WPD COM bridge (`wpd_bridge.cpp`) + Inno Setup installer (`installer/devicebridge.iss`).
- [`scripts/build_installers.ps1`](scripts/build_installers.ps1) — Windows build & test script generating `dist/DeviceBridge-Windows-1.0.0-Setup.exe`.
- [`.github/workflows/build_installers.yml`](.github/workflows/build_installers.yml) — GitHub Actions CI building and uploading `DeviceBridge-Windows-Installer`.

---

## Documentation

Read the full user tutorial: **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)**
