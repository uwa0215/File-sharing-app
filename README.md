# DeviceBridge (Windows App)

**DeviceBridge** is a native Windows desktop application (`windows_host`) for fast bulk file sharing with **any phone, tablet, or computer** — featuring **Instant No-Wi-Fi Transfer (USB + Bluetooth)**, **USB Explorer & Mirror**, and **QR Code Wi-Fi Transfer**.

---

## Transfer Modes

### 1. `No Wi-Fi Send` (Default — Zero Wi-Fi Required)
- **Bluetooth Direct OBEX Push (`bluetooth_bridge.cpp`):** Pair your Android phone or Windows PC once in Windows Bluetooth settings, select it in DeviceBridge, and **drop any files or folders** to push them immediately over Bluetooth (`AF_BTH` RFCOMM OBEX) with zero Wi-Fi and zero mobile app required.
- **USB Cable Instant Send:** Plug any Android phone via USB and drop files/folders to send immediately at full USB speed.

### 2. `USB Explorer` (Android & iPhone/iPad USB + Live Mirror)
- Native Win32 WPD (MTP & Apple PTP) C++ bridge + parallel 3-stream ADB pipelines + `scrcpy` Android live screen mirroring.
- Open phone folders, select multiple photos/videos, drag files straight onto your Windows Desktop, or export in bulk.

### 3. `QR Wi-Fi` (Browser-Based Wireless Transfer)
- Displays a scannable QR code (`/s/<token>`) with 1-click **Allow Windows Firewall Access** so iPhone, Android, Mac, or any browser can upload/download bulk files over private Wi-Fi/Hotspot without installing any app.

---

## Documentation

Read the full user tutorial: **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)**
