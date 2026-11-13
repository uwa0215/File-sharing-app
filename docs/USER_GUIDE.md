# DeviceBridge USB User Guide (Windows Only)

Welcome to **DeviceBridge USB** — a native Windows desktop application for reading, browsing, mirroring, and transferring files with your **Android** or **iPhone / iPad** simply by plugging in a **USB cable**.

**No mobile app installation is required on your phone.**

---

## Step 1: Install DeviceBridge on Windows

1. Download and run `DeviceBridge-Windows-1.0.0-Setup.exe`.
2. Complete the Windows Setup Wizard and open **DeviceBridge USB** from the Start Menu or Desktop shortcut.

---

## Step 2: Plug In Your Phone via USB

DeviceBridge monitors USB ports automatically — no IP addresses or pairing codes needed.

### Option A: Android Phone (Automatic MTP — No Settings Required)

1. Connect your Android phone to your Windows laptop using a data-capable USB cable.
2. Unlock your phone. If Android shows a USB notification saying *Charging this device via USB*, tap it and choose **File Transfer / Android Auto (MTP)**.
3. **DeviceBridge USB** detects your phone automatically in the top **USB Connected** bar and opens its storage folders in **Phone Explorer** on the right.

### Option B: Android Phone with Full `/sdcard` Access + Live Screen Mirroring (ADB)

1. *(One-time setup)* Enable **USB Debugging** on Android (**Settings -> About phone -> tap Build number 7 times -> Developer options -> USB debugging**).
2. Plug in your USB cable and tap **Allow** on *"Allow USB debugging?"*.
3. DeviceBridge automatically connects via **`USB (ADB • Full Storage)`**, unlocking:
   - Instant quick-jump buttons (`DCIM`, `Download`, `Pictures`, `Documents`)
   - High-speed USB file transfers both ways
   - **Mirror** button on the left panel to view & control your live Android screen inside DeviceBridge (`scrcpy`).

### Option C: iPhone or iPad (Photos & Videos — No iOS App Needed)

1. Make sure **Apple Mobile Device Support** / **iTunes** or **Apple Devices** drivers are installed on Windows.
2. Plug your iPhone or iPad into your Windows laptop with a USB cable.
3. Unlock the iPhone/iPad and tap **Trust** on *"Trust This Computer?"*.
4. DeviceBridge automatically mounts your iPhone under **`USB (Apple PTP • Photos & Videos)`** and opens **`Internal Storage -> DCIM`**.

> **Note for iPhone / iPad:** Apple allows reading and copying **photos & videos (`DCIM`)** from iPhone to Windows over USB PTP, but blocks writing arbitrary files back onto the iPhone over USB PTP.

---

## Step 3: Drag Files Between Your Phone and Windows

### Copy / Drag Files FROM Your Phone TO Windows

> **Important:** Do **not** try to drag files directly off the mirrored phone screen (`scrcpy`) on the left — the mirror only displays your phone screen. Always use **Phone Explorer** on the right!

1. Look at **Phone Explorer** on the **right side** of DeviceBridge.
2. Click any folder (for example **`DCIM` -> `Camera`** or **`100APPLE`**) to open it.
3. Move files to Windows using any of these three ways:
   - **Drag & Drop:** Click and drag any file row directly out of **Phone Explorer** onto your **Windows Desktop** or into an open **File Explorer** folder.
   - **Single File Save:** Click the **`Save` (`↓`)** button on the right side of any file row.
   - **Bulk Export:** Check the boxes next to multiple photos/files, then click **`Export Selected to PC`** to save them all into one folder at once.

### Send Files or Folders FROM Windows TO Your Android Phone

1. *(Optional)* In **Phone Explorer** on the right, open the destination folder where you want the files saved (for example `Download` or `Pictures`).
2. Drag any file(s) or folder(s) from **Windows File Explorer** and drop them onto **either**:
   - The phone-shaped **Mirror & Send to Phone** panel on the left, **or**
   - Directly onto the **Phone Explorer** list on the right.
   - *(Or click **Select PC Files to Send** on the left panel.)*
3. Progress and completion appear in the **USB Transfers** bar at the bottom right.

---

## Troubleshooting

- **Phone does not show up when plugged in:**
  - Try a different USB cable or USB port (some charging-only cables lack data wires).
  - **Android:** Unlock the screen and change USB mode to **File Transfer (MTP)**, or accept **Allow USB debugging**.
  - **iPhone / iPad:** Unlock the screen, unplug/replug, tap **Trust**, and verify Windows recognizes it in File Explorer (`This PC -> Apple iPhone`).
- **`Mirror` does not start for Android:**
  - Make sure **USB Debugging** is enabled and allowed on the phone. Click the wrench icon in the top-right corner of DeviceBridge to confirm `adb.exe` and `scrcpy.exe` are detected.
