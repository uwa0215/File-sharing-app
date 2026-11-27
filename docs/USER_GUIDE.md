# DeviceBridge QR User Guide

**DeviceBridge QR** lets you pair any phone and computer with a single QR scan — either from a public cloud deployment (isolated rooms per user) or from your local PC (`http://localhost:3000` with Cloudflare Quick Tunnel).

---

## Security & Transfer Flow

1. **HMAC-SHA256 Signing (Always Active):**
   - Your phone signs every file's SHA-256 digest and manifest using WebCrypto (`HMAC-SHA256`) before uploading.
   - The host verifies the signature and marks completed transfers **`Signed`**.
2. **Approve Device Before Transfer (Optional Toggle):**
   - Switch **ON** so newly scanned phones wait until you click **Allow** (or **Block**) under **Access & Devices**.
3. **25 MB Chunked Streaming:**
   - Large videos and archives split automatically into 25 MB verified chunks with live WebSocket progress bars.

---

## How to Transfer

1. Open the hosted app URL (or run `start_qr_web.bat` / `node web_app/server.js` locally and open `http://localhost:3000`).
2. Scan the QR code with your **iPhone or Android Camera**.
3. Tap **`Select Files to Send`** on your phone, or drag and drop files onto **`Send Signed Files to Phone`** on your computer.
4. In Cloud Mode, click **Save Copy** (or enable **Auto-Save**) to download received files straight to your browser.
