# Deploying DeviceBridge QR Web App for Multi-User Public Access

`web_app/server.js` automatically runs in **Multi-Room Cloud Mode** whenever `CLOUD_MODE=1` or a platform `PORT` environment variable is present (Render, Railway, Fly.io, Google Cloud Run, Heroku, or Docker).

In Cloud Mode:
- Every browser visitor automatically receives an isolated, private QR pairing room (`roomId` + secret `hostKey`).
- Files transferred between phones and computers are HMAC-SHA256 verified per room, never shared across users, and auto-cleaned after inactivity (`2h` default).
- QR links automatically use `https://<your-deployed-domain>/s/<token>` via `x-forwarded-proto` / `x-forwarded-host` (or optional `PUBLIC_BASE_URL`).

---

## Option 1: Deploy Free / Managed on Render (Recommended)

1. Push this repository to GitHub.
2. Open [Render](https://dashboard.render.com/) -> **New +** -> **Blueprint** (or **Web Service**).
3. Select your GitHub repository — Render detects `render.yaml` automatically (`rootDir: web_app`, `healthCheckPath: /healthz`, `CLOUD_MODE=1`).
4. Click **Deploy** and share the `https://*.onrender.com` URL with anyone!

---

## Option 2: Deploy on Railway

1. Connect your GitHub repo in [Railway](https://railway.app/).
2. Railway automatically uses `railway.json` and `Dockerfile`, exposing `/healthz` and public HTTPS + WebSockets.

---

## Option 3: Self-Host Anywhere with Docker

```bash
docker build -t devicebridge-qr .
docker run -d -p 3000:3000 --name devicebridge devicebridge-qr
```

Check health:

```bash
curl http://localhost:3000/healthz
```

### Optional Environment Variables
| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | HTTP + WebSocket listening port |
| `CLOUD_MODE` | Auto (`1` when `PORT` is set) | Force `1` for public multi-room hosting, `0` for single-PC local mode |
| `PUBLIC_BASE_URL` | Auto from request headers | Override public QR origin (e.g. `https://drop.yourdomain.com`) |
