# DeviceBridge QR (Signed Multi-User Web File Sharing)

**DeviceBridge QR** is a responsive, animated **QR-based web application** (`web_app/`) for transferring files between phones and computers — supporting **Public Multi-Room Cloud Hosting** (Render, Railway, Docker) and **Local PC + Cloudflare Tunnel** mode.

---

## Features & Security

- **Automatic HMAC-SHA256 File Signing:** Every upload and download is SHA-256 hashed and verified with a 256-bit per-room HMAC key; tampered or unsigned payloads are rejected (`403`).
- **Approve Device Before Transfer:** Optional gate holding scanned phones until you tap **Allow** or **Block**.
- **Isolated Multi-User Cloud Rooms:** When deployed publicly (`PORT` / `CLOUD_MODE=1`), each browser visitor receives an isolated temporary pairing room (`roomId` + `hostKey`), auto-cleaned after inactivity (`2h` TTL).
- **Large Video Support:** Automatically splits uploads over `25 MB` into streamed verified chunks.

---

## Deploy for Everyone (Render / Railway / Docker)

See [`docs/DEPLOY.md`](docs/DEPLOY.md) for step-by-step deployment instructions using [`render.yaml`](render.yaml), [`railway.json`](railway.json), or [`Dockerfile`](Dockerfile).

## Run Locally on PC

1. Run [`start_qr_web.bat`](start_qr_web.bat) (or `cd web_app && npm install && node server.js`).
2. Open **`http://localhost:3000`** in your browser and scan the **HTTPS QR code** with your phone camera.
