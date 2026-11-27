# DeviceBridge User Guide

Welcome to **DeviceBridge** — a fast, native Windows file-sharing application supporting **QR Code Wireless Transfer** (scan from iPhone, Android, or any device with zero app install) and **USB Cable** plug-and-play transfer.

---

## Step 1: Install DeviceBridge on Windows

1. Download and run `DeviceBridge-Windows-1.0.0-Setup.exe`.
2. Finish the Windows Setup Wizard and open **DeviceBridge** from the Start Menu or Desktop shortcut.

---

## Method 1: Scan QR Code & Transfer Wirelessly (Recommended — Any Device)

Works with **iPhone, iPad, Android, Mac, or another Windows PC** on the same Wi-Fi network without installing any mobile app.

1. Open **DeviceBridge** on Windows (it launches directly on the **`QR Transfer`** tab).
2. A **QR Code** appears on the left side.
   - *(If your laptop has virtual network adapters like VMware/Hyper-V, pick your Wi-Fi IP from the **Wi-Fi / LAN Adapter** dropdown so the QR code uses your Wi-Fi address.)*
3. On your phone or other device, open the **Camera app** (or any QR scanner) and point it at the QR code on your Windows screen, then tap the link notification.
4. Your Windows app will immediately detect the scan and show **`Device(s) Connected`**. Click **`Open Transfer Window`** (or use the **Transfer Window** panel right next to the QR code):
   - **Send Files FROM Windows TO Your Device:** Drag & drop any files or folders from Windows File Explorer into the **Transfer Window** (or click **Add Files** / **Add Folder**). They appear live on your phone's screen with **Download** and **Download All** buttons.
   - **Send Files FROM Your Device TO Windows:** Tap **Choose Files** on your phone's browser page (you can select multiple photos, videos, or documents at once). They stream directly into your Windows **`Downloads\DeviceBridge`** folder (or click **Change** to pick any folder).

> **Wi-Fi Tip:** If scanning opens an unreachable page, allow `windows_host.exe` through **Windows Defender Firewall** on Private networks and confirm both devices are on the same Wi-Fi (not a guest network with client isolation).

---

## Method 2: USB Cable Mode (`USB Cable` Tab)

Switch to **`USB Cable`** in the top bar anytime you want wired USB browsing or Android screen mirroring (`scrcpy`):

1. Plug in your **Android** phone (set USB notification to **File Transfer / MTP**, or enable **USB Debugging** for fast ADB bulk transfers + **Mirror**) or **iPhone / iPad** (tap **Trust** to copy `DCIM` photos/videos to PC).
2. Use **Phone Explorer** on the right to open folders, select files, click **`Export to PC`**, or drag files straight onto your Windows Desktop or Explorer.
