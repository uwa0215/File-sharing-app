import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { upgradeWebSocket } from './lib/websocket.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');

const DEFAULT_ROOM_TTL_MS = 2 * 60 * 60 * 1000;
const DEFAULT_MAX_ROOMS = 250;
const DEFAULT_MAX_UPLOAD_BYTES = 500 * 1024 * 1024;

export function sanitizeFilename(rawName) {
  const decoded = (() => {
    try {
      return decodeURIComponent(rawName || '');
    } catch {
      return String(rawName || '');
    }
  })();
  const base = path.posix
    .basename(decoded.replace(/\\/g, '/'))
    .replace(/[/:*?"<>|]/g, '_')
    .replace(/\.{2,}/g, '.')
    .replace(/^\.+/, '')
    .trim();
  return base || `received_${Date.now()}.bin`;
}

export function isLoopbackAddress(remoteAddress = '') {
  return (
    remoteAddress === '127.0.0.1' ||
    remoteAddress === '::1' ||
    remoteAddress === '::ffff:127.0.0.1'
  );
}

/**
 * Ensures desktop-only admin UI and routes cannot be accessed through a public
 * reverse tunnel in single-PC local mode.
 */
export function isTrueDesktopRequest(req) {
  const remote = req.socket?.remoteAddress || '';
  if (!isLoopbackAddress(remote)) return false;
  const h = req.headers || {};
  if (h['cf-ray'] || h['cf-connecting-ip'] || h['x-forwarded-for']) {
    return false;
  }
  const host = String(h.host || '');
  return /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i.test(host);
}

export function parseDeviceLabel(userAgent = '') {
  const ua = userAgent.toLowerCase();
  if (ua.includes('iphone')) return 'iPhone';
  if (ua.includes('ipad')) return 'iPad';
  if (ua.includes('android')) return 'Android Phone';
  if (ua.includes('macintosh')) return 'Mac';
  if (ua.includes('windows')) return 'Windows PC';
  if (ua.includes('linux')) return 'Linux Device';
  return 'Mobile Device';
}

function generateToken(byteCount = 8) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const bytes = crypto.randomBytes(byteCount);
  let out = '';
  for (const b of bytes) out += chars[b % chars.length];
  return out;
}

function generatePin() {
  return String(crypto.randomInt(100000, 999999));
}

function generateSigningKeyHex() {
  return crypto.randomBytes(32).toString('hex');
}

function safeEqualString(a = '', b = '') {
  const bufA = Buffer.from(String(a), 'utf8');
  const bufB = Buffer.from(String(b), 'utf8');
  if (bufA.length === 0 || bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

export function signPayloadManifest(signingKeyHex, fileName, sizeBytes, sha256Hex) {
  const manifest = `${fileName}|${sizeBytes}|${sha256Hex.toLowerCase()}`;
  return crypto
    .createHmac('sha256', Buffer.from(signingKeyHex, 'hex'))
    .update(manifest, 'utf8')
    .digest('hex');
}

export function verifyPayloadManifest(
  signingKeyHex,
  fileName,
  sizeBytes,
  sha256Hex,
  providedSigHex,
) {
  if (
    typeof sha256Hex !== 'string' ||
    typeof providedSigHex !== 'string' ||
    !/^[0-9a-f]{64}$/i.test(sha256Hex) ||
    !/^[0-9a-f]{64}$/i.test(providedSigHex)
  ) {
    return false;
  }
  const expected = signPayloadManifest(signingKeyHex, fileName, sizeBytes, sha256Hex);
  return crypto.timingSafeEqual(
    Buffer.from(expected, 'hex'),
    Buffer.from(providedSigHex.toLowerCase(), 'hex'),
  );
}

async function computeFileSha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

async function uniqueDestPath(dir, fileName) {
  let candidate = path.join(dir, fileName);
  if (!fs.existsSync(candidate)) return candidate;
  const ext = path.extname(fileName);
  const stem = path.basename(fileName, ext);
  for (let i = 1; i < 10000; i++) {
    candidate = path.join(dir, `${stem} (${i})${ext}`);
    if (!fs.existsSync(candidate)) return candidate;
  }
  return path.join(dir, `${stem}_${Date.now()}${ext}`);
}

function resolveCloudflaredBinary() {
  const exeName = process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared';
  const bundled = path.join(__dirname, 'node_modules', 'cloudflared', 'bin', exeName);
  if (fs.existsSync(bundled)) return bundled;
  return exeName;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) reject(new Error('Body too large'));
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

function extractMobileToken(req, urlObj) {
  const match = urlObj.pathname.match(/^\/s\/([^/?#]+)/);
  return (
    urlObj.searchParams.get('token') ||
    req.headers['x-devicebridge-token'] ||
    (match ? decodeURIComponent(match[1]) : '')
  ).trim();
}

function extractClientIdentity(req, urlObj) {
  const sessionKey = (
    urlObj.searchParams.get('session') ||
    req.headers['x-session-key'] ||
    ''
  ).trim();
  const clientId = (
    urlObj.searchParams.get('cid') ||
    req.headers['x-client-id'] ||
    ''
  ).trim();
  return { sessionKey, clientId };
}

/**
 * Resolves the public origin (scheme + host) for QR links in cloud deployments.
 */
export function resolvePublicBaseUrl(req, explicitBaseUrl, activePort) {
  if (explicitBaseUrl) {
    return explicitBaseUrl.replace(/\/+$/, '');
  }
  if (!req) {
    return `http://localhost:${activePort}`;
  }
  const h = req.headers || {};
  const protoHeader = String(h['x-forwarded-proto'] || '').split(',')[0].trim();
  const hostHeader = String(h['x-forwarded-host'] || h.host || `localhost:${activePort}`)
    .split(',')[0]
    .trim();
  const proto = protoHeader || 'http';
  return `${proto}://${hostHeader}`;
}

export function isCloudEnvironment(env = process.env) {
  if (env.CLOUD_MODE === '0' || env.CLOUD_MODE === 'false') return false;
  return Boolean(
    env.CLOUD_MODE === '1' ||
      env.CLOUD_MODE === 'true' ||
      env.PORT ||
      env.RENDER ||
      env.RAILWAY_ENVIRONMENT ||
      env.FLY_APP_NAME ||
      env.K_SERVICE ||
      env.HEROKU_APP_NAME ||
      env.DYNO,
  );
}

/**
 * Creates a self-contained pairing room (used once in local mode, or per-user in cloud mode).
 */
function createTransferRoom({
  roomId,
  hostKey,
  receiveDir,
  outboxDir,
  cloudMode,
  maxUploadBytes,
  getPublicBaseUrl,
  getTunnelInfo,
  onReconnectTunnel,
  onTokenRotated,
  removeOnClose = false,
}) {
  let token = generateToken();
  let signingKeyHex = generateSigningKeyHex();
  let pairingPin = generatePin();
  let failedPinAttempts = 0;
  let nextId = 1;
  let lastActiveAt = Date.now();
  let lastKnownBaseUrl = '';

  const security = {
    requireSignature: true,
    requirePin: false,
    requireApproval: false,
  };

  const desktopSockets = new Set();
  const mobileClients = new Map();
  const authorizedSessionKeys = new Set();
  const approvedClientIds = new Set();
  const blockedClientIds = new Set();
  const outboxFiles = new Map();
  const transferRecords = [];
  const activeChunkUploads = new Map();

  function touch() {
    lastActiveAt = Date.now();
  }

  function getQrUrl(req) {
    const base = getPublicBaseUrl(req, lastKnownBaseUrl);
    return `${base}/s/${token}`;
  }

  function resetSessionCredentials() {
    const oldToken = token;
    token = generateToken();
    signingKeyHex = generateSigningKeyHex();
    pairingPin = generatePin();
    failedPinAttempts = 0;
    authorizedSessionKeys.clear();
    approvedClientIds.clear();
    blockedClientIds.clear();
    for (const c of mobileClients.values()) c.ws.close();
    mobileClients.clear();
    onTokenRotated?.(oldToken, token);
  }

  function serializeOutboxForMobile() {
    return Array.from(outboxFiles.values()).reverse().map((f) => ({
      id: f.id,
      name: f.name,
      sizeBytes: f.sizeBytes,
      sha256: f.sha256,
      signature: f.signature,
    }));
  }

  async function buildStateSnapshot(req) {
    if (req) {
      lastKnownBaseUrl = getPublicBaseUrl(req, lastKnownBaseUrl);
    }
    const tunnel = getTunnelInfo();
    const url = getQrUrl(req);
    const ready = cloudMode ? true : tunnel.ready;
    const qrSvg = ready
      ? await QRCode.toString(url, {
          type: 'svg',
          margin: 2,
          width: 260,
          color: { dark: '#0b1120', light: '#ffffff' },
        })
      : '';

    return {
      cloudMode,
      ...(cloudMode ? { roomId, hostKey } : {}),
      url,
      qrSvg,
      tunnelReady: ready,
      tunnelState: cloudMode ? 'cloud' : tunnel.state,
      tunnelError: cloudMode ? null : tunnel.error,
      token,
      port: tunnel.port,
      receiveDir: cloudMode ? 'Browser Downloads (Temporary Cloud Room)' : receiveDir,
      security: {
        ...security,
        pin: pairingPin,
        signingFingerprint: signingKeyHex.slice(0, 12).toUpperCase(),
      },
      clients: Array.from(mobileClients.values()).map((c) => c.client),
      outbox: serializeOutboxForMobile(),
      transfers: transferRecords,
    };
  }

  function broadcastDesktop(eventObj) {
    for (const ws of desktopSockets) {
      ws.sendJson(eventObj);
    }
  }

  async function broadcastFullState(req) {
    const state = await buildStateSnapshot(req);
    broadcastDesktop({ type: 'state', state });
  }

  function broadcastMobileState() {
    const files = serializeOutboxForMobile();
    for (const entry of mobileClients.values()) {
      entry.ws.sendJson({
        type: 'session_update',
        security: {
          requireSignature: security.requireSignature,
          requirePin: security.requirePin,
          requireApproval: security.requireApproval,
          pinVerified: !security.requirePin || authorizedSessionKeys.has(entry.client.sessionKey),
          approved: !security.requireApproval || approvedClientIds.has(entry.client.id),
          blocked: blockedClientIds.has(entry.client.id),
        },
        signingKeyHex: security.requireSignature ? signingKeyHex : '',
        files,
      });
    }
  }

  function upsertRecord(rec) {
    transferRecords.unshift(rec);
    if (transferRecords.length > 100) transferRecords.length = 100;
    broadcastDesktop({ type: 'transfers', transfers: transferRecords });
  }

  function updateRecord(id, patch) {
    const idx = transferRecords.findIndex((r) => r.id === id);
    if (idx >= 0) {
      transferRecords[idx] = { ...transferRecords[idx], ...patch };
      broadcastDesktop({ type: 'transfers', transfers: transferRecords });
    }
  }

  function checkMobileTransferAccess(req, urlObj) {
    const { sessionKey, clientId } = extractClientIdentity(req, urlObj);
    if (clientId && blockedClientIds.has(clientId)) {
      return { allowed: false, reason: 'This device was blocked by the host.' };
    }
    if (security.requirePin && !authorizedSessionKeys.has(sessionKey)) {
      return { allowed: false, reason: 'Enter the 6-digit PIN shown on the desktop first.' };
    }
    if (security.requireApproval && (!clientId || !approvedClientIds.has(clientId))) {
      return { allowed: false, reason: 'Waiting for desktop approval before transferring files.' };
    }
    return { allowed: true };
  }

  async function handleDesktopApi(req, res, urlObj, pathname) {
    touch();

    if (pathname === '/api/desktop/state' && req.method === 'GET') {
      const snapshot = await buildStateSnapshot(req);
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(snapshot));
      return;
    }

    if (pathname === '/api/desktop/security' && req.method === 'POST') {
      const body = await readJsonBody(req);
      if (typeof body.requireSignature === 'boolean') {
        security.requireSignature = body.requireSignature;
      }
      if (typeof body.requirePin === 'boolean') {
        security.requirePin = body.requirePin;
        if (body.requirePin) {
          pairingPin = generatePin();
          failedPinAttempts = 0;
          authorizedSessionKeys.clear();
        }
      }
      if (typeof body.requireApproval === 'boolean') {
        security.requireApproval = body.requireApproval;
      }
      if (body.regeneratePin === true) {
        pairingPin = generatePin();
        failedPinAttempts = 0;
        authorizedSessionKeys.clear();
      }
      broadcastMobileState();
      const snapshot = await buildStateSnapshot(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(snapshot));
      await broadcastFullState(req);
      return;
    }

    if (pathname === '/api/desktop/approve-client' && req.method === 'POST') {
      const body = await readJsonBody(req);
      const clientId = String(body.clientId || '');
      const approve = body.approve !== false;
      const entry = mobileClients.get(clientId);
      if (entry) {
        if (approve) {
          blockedClientIds.delete(clientId);
          approvedClientIds.add(clientId);
          entry.client.approved = true;
          entry.client.blocked = false;
        } else {
          approvedClientIds.delete(clientId);
          blockedClientIds.add(clientId);
          entry.client.approved = false;
          entry.client.blocked = true;
        }
      }
      broadcastMobileState();
      const snapshot = await buildStateSnapshot(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(snapshot));
      await broadcastFullState(req);
      return;
    }

    if (pathname === '/api/desktop/regenerate' && req.method === 'POST') {
      resetSessionCredentials();
      const snapshot = await buildStateSnapshot(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(snapshot));
      await broadcastFullState(req);
      return;
    }

    if (pathname === '/api/desktop/reconnect-tunnel' && req.method === 'POST') {
      if (!cloudMode) {
        await onReconnectTunnel();
      }
      const snapshot = await buildStateSnapshot(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(snapshot));
      return;
    }

    if (pathname === '/api/desktop/clear-transfers' && req.method === 'POST') {
      for (let i = transferRecords.length - 1; i >= 0; i--) {
        if (transferRecords[i].state !== 'transferring') {
          const removed = transferRecords.splice(i, 1)[0];
          if (cloudMode && removed?.savedPath) {
            fsp.unlink(removed.savedPath).catch(() => {});
          }
        }
      }
      broadcastDesktop({ type: 'transfers', transfers: transferRecords });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (pathname === '/api/desktop/open-folder' && req.method === 'POST') {
      if (cloudMode) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, cloudMode: true }));
        return;
      }
      await fsp.mkdir(receiveDir, { recursive: true });
      if (process.platform === 'win32') {
        spawn('explorer.exe', [receiveDir], { detached: true, stdio: 'ignore' }).unref();
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (pathname === '/api/desktop/share-file' && req.method === 'POST') {
      const contentLen = Number.parseInt(req.headers['content-length'] || '0', 10) || 0;
      if (maxUploadBytes > 0 && contentLen > maxUploadBytes) {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: 'File exceeds maximum upload size limit.' }));
        return;
      }
      const safeName = sanitizeFilename(urlObj.searchParams.get('name'));
      await fsp.mkdir(outboxDir, { recursive: true });
      const dest = await uniqueDestPath(outboxDir, safeName);
      const ws = fs.createWriteStream(dest);
      let written = 0;
      try {
        await new Promise((resolve, reject) => {
          req.on('data', (chunk) => {
            written += chunk.length;
            if (maxUploadBytes > 0 && written > maxUploadBytes) {
              req.destroy(new Error('File exceeds maximum upload size limit.'));
              return;
            }
            if (!ws.write(chunk)) {
              req.pause();
              ws.once('drain', () => req.resume());
            }
          });
          req.on('end', () => ws.end(resolve));
          ws.on('error', reject);
          req.on('error', reject);
        });
      } catch (err) {
        ws.destroy();
        await fsp.unlink(dest).catch(() => {});
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: err.message }));
        return;
      }
      const stat = await fsp.stat(dest);
      const finalName = path.basename(dest);
      const sha256 = await computeFileSha256(dest);
      const signature = signPayloadManifest(signingKeyHex, finalName, stat.size, sha256);
      const id = `out_${nextId++}`;
      outboxFiles.set(id, {
        id,
        name: finalName,
        filePath: dest,
        sizeBytes: stat.size,
        sha256,
        signature,
      });
      broadcastMobileState();
      await broadcastFullState(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, id, sha256, signature }));
      return;
    }

    if (pathname.startsWith('/api/desktop/outbox/') && req.method === 'DELETE') {
      const id = decodeURIComponent(pathname.slice('/api/desktop/outbox/'.length));
      const item = outboxFiles.get(id);
      if (item) {
        outboxFiles.delete(id);
        fsp.unlink(item.filePath).catch(() => {});
        broadcastMobileState();
        await broadcastFullState(req);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (pathname.startsWith('/api/desktop/received/') && req.method === 'GET') {
      const recId = decodeURIComponent(pathname.slice('/api/desktop/received/'.length));
      const rec = transferRecords.find((r) => r.id === recId && r.savedPath);
      if (!rec || !fs.existsSync(rec.savedPath)) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }
      const stat = await fsp.stat(rec.savedPath);
      const isInline = urlObj.searchParams.get('inline') === '1';
      const ext = path.extname(rec.fileName).toLowerCase();
      const mime =
        {
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.png': 'image/png',
          '.gif': 'image/gif',
          '.webp': 'image/webp',
        }[ext] || 'application/octet-stream';
      const encoded = encodeURIComponent(rec.fileName);
      const asciiFallback = rec.fileName.replace(/[^\x20-\x7E]|"/g, '_');
      res.writeHead(200, {
        'Content-Type': mime,
        'Content-Length': stat.size,
        ...(isInline
          ? {}
          : {
              'Content-Disposition': `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encoded}`,
            }),
      });
      fs.createReadStream(rec.savedPath).pipe(res);
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }

  async function handleMobileApi(req, res, urlObj, pathname) {
    touch();

    if ((pathname === '/' || pathname.startsWith('/s/')) && req.method === 'GET') {
      const html = await fsp.readFile(path.join(PUBLIC_DIR, 'mobile.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(html);
      return;
    }

    if (pathname === '/api/session-config' && req.method === 'GET') {
      const { sessionKey, clientId } = extractClientIdentity(req, urlObj);
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(
        JSON.stringify({
          security: {
            requireSignature: security.requireSignature,
            requirePin: security.requirePin,
            requireApproval: security.requireApproval,
            pinVerified: !security.requirePin || authorizedSessionKeys.has(sessionKey),
            approved: !security.requireApproval || approvedClientIds.has(clientId),
            blocked: blockedClientIds.has(clientId),
          },
          signingKeyHex: security.requireSignature ? signingKeyHex : '',
        }),
      );
      return;
    }

    if (pathname === '/api/auth/pin' && req.method === 'POST') {
      const body = await readJsonBody(req);
      const pinInput = String(body.pin || '').trim();
      const sessionKey = String(body.sessionKey || '').trim() || generateToken();

      if (failedPinAttempts >= 5) {
        res.writeHead(429, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: 'Too many wrong PIN attempts. Generate a new PIN or QR code on desktop.' }));
        return;
      }

      if (pinInput !== pairingPin) {
        failedPinAttempts++;
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: `Wrong PIN (${5 - failedPinAttempts} attempts left)` }));
        return;
      }

      failedPinAttempts = 0;
      authorizedSessionKeys.add(sessionKey);
      for (const entry of mobileClients.values()) {
        if (entry.client.sessionKey === sessionKey) {
          entry.client.pinVerified = true;
        }
      }
      broadcastMobileState();
      await broadcastFullState(req);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, sessionKey }));
      return;
    }

    const access = checkMobileTransferAccess(req, urlObj);
    if (!access.allowed) {
      res.writeHead(403, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: access.reason }));
      return;
    }

    if (pathname === '/api/files' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ files: serializeOutboxForMobile() }));
      return;
    }

    if (pathname.startsWith('/api/download/') && req.method === 'GET') {
      const id = decodeURIComponent(pathname.slice('/api/download/'.length));
      const shared = outboxFiles.get(id);
      if (!shared || !fs.existsSync(shared.filePath)) {
        res.writeHead(404);
        res.end('File not found');
        return;
      }
      const stat = await fsp.stat(shared.filePath);
      const txId = `dl_${nextId++}`;
      upsertRecord({
        id: txId,
        fileName: shared.name,
        direction: 'to_phone',
        state: 'transferring',
        totalBytes: stat.size,
        transferredBytes: 0,
        verified: true,
        sha256: shared.sha256,
      });

      const encoded = encodeURIComponent(shared.name);
      const asciiFallback = shared.name.replace(/[^\x20-\x7E]|"/g, '_');
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': stat.size,
        'X-File-SHA256': shared.sha256,
        'X-File-Signature': shared.signature,
        'Content-Disposition': `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encoded}`,
      });

      let sent = 0;
      let lastEmit = 0;
      const stream = fs.createReadStream(shared.filePath);
      stream.on('data', (chunk) => {
        sent += chunk.length;
        const now = Date.now();
        if (now - lastEmit >= 120) {
          lastEmit = now;
          updateRecord(txId, { transferredBytes: sent });
        }
      });
      stream.on('end', () => {
        updateRecord(txId, { state: 'completed', transferredBytes: stat.size });
      });
      stream.on('error', (err) => {
        updateRecord(txId, { state: 'failed', error: err.message });
      });
      stream.pipe(res);
      return;
    }

    if (pathname === '/api/upload-chunk' && req.method === 'POST') {
      const uploadId = (urlObj.searchParams.get('uploadId') || '').trim();
      const offset = Number.parseInt(urlObj.searchParams.get('offset') || '0', 10) || 0;
      const total = Number.parseInt(urlObj.searchParams.get('total') || '0', 10) || 0;
      const rawOriginalName = urlObj.searchParams.get('name') || 'upload.bin';
      const safeName = sanitizeFilename(rawOriginalName);
      const isFinal = urlObj.searchParams.get('final') === '1';

      if (!uploadId) {
        res.writeHead(400);
        res.end('uploadId required');
        return;
      }
      if (maxUploadBytes > 0 && total > maxUploadBytes) {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: 'File exceeds maximum upload size limit.' }));
        return;
      }

      await fsp.mkdir(receiveDir, { recursive: true });
      let session = activeChunkUploads.get(uploadId);
      if (!session) {
        const destPath = await uniqueDestPath(receiveDir, safeName);
        const partPath = `${destPath}.part`;
        const finalName = path.basename(destPath);
        const txId = `ul_${nextId++}`;
        const deviceLabel = parseDeviceLabel(req.headers['user-agent'] || '');
        session = {
          destPath,
          partPath,
          finalName,
          rawNameForSig: (() => {
            try {
              return decodeURIComponent(rawOriginalName);
            } catch {
              return rawOriginalName;
            }
          })(),
          txId,
          hash: crypto.createHash('sha256'),
          expectedBytes: total,
          receivedBytes: 0,
        };
        activeChunkUploads.set(uploadId, session);
        upsertRecord({
          id: txId,
          fileName: finalName,
          deviceLabel,
          direction: 'from_phone',
          state: 'transferring',
          totalBytes: total,
          transferredBytes: 0,
          verified: false,
        });
      }

      const writeStream = fs.createWriteStream(session.partPath, {
        flags: offset === 0 ? 'w' : 'a',
      });
      let chunkBytes = 0;
      try {
        await new Promise((resolve, reject) => {
          req.on('data', (chunk) => {
            chunkBytes += chunk.length;
            if (maxUploadBytes > 0 && session.receivedBytes + chunkBytes > maxUploadBytes) {
              req.destroy(new Error('File exceeds maximum upload size limit.'));
              return;
            }
            session.hash.update(chunk);
            if (!writeStream.write(chunk)) {
              req.pause();
              writeStream.once('drain', () => req.resume());
            }
          });
          req.on('end', () => writeStream.end(resolve));
          req.on('error', reject);
          writeStream.on('error', reject);
        });

        session.receivedBytes += chunkBytes;
        if (isFinal) {
          const actualSha = session.hash.digest('hex');
          const claimedSha = String(req.headers['x-file-sha256'] || '').trim().toLowerCase();
          const claimedSig = String(req.headers['x-file-signature'] || '').trim().toLowerCase();
          const sigValid =
            actualSha === claimedSha &&
            verifyPayloadManifest(
              signingKeyHex,
              session.rawNameForSig,
              session.receivedBytes,
              actualSha,
              claimedSig,
            );

          if (security.requireSignature && !sigValid) {
            activeChunkUploads.delete(uploadId);
            await fsp.unlink(session.partPath).catch(() => {});
            updateRecord(session.txId, {
              state: 'failed',
              error: 'Rejected: Missing or invalid HMAC-SHA256 file signature.',
            });
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(
              JSON.stringify({
                ok: false,
                error: 'File signature verification failed.',
              }),
            );
            return;
          }

          await fsp.rename(session.partPath, session.destPath);
          activeChunkUploads.delete(uploadId);
          updateRecord(session.txId, {
            state: 'completed',
            totalBytes: session.receivedBytes,
            transferredBytes: session.receivedBytes,
            savedPath: session.destPath,
            sha256: actualSha,
            verified: sigValid,
          });
        } else {
          updateRecord(session.txId, { transferredBytes: session.receivedBytes });
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, savedName: session.finalName }));
      } catch (err) {
        writeStream.destroy();
        activeChunkUploads.delete(uploadId);
        fsp.unlink(session.partPath).catch(() => {});
        updateRecord(session.txId, { state: 'failed', error: err.message });
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: err.message }));
      }
      return;
    }

    if (pathname === '/api/upload' && req.method === 'POST') {
      const rawOriginalName =
        urlObj.searchParams.get('name') || req.headers['x-file-name'] || 'upload.bin';
      const decodedOriginalName = (() => {
        try {
          return decodeURIComponent(rawOriginalName);
        } catch {
          return rawOriginalName;
        }
      })();
      const safeName = sanitizeFilename(decodedOriginalName);
      const expectedBytes =
        Number.parseInt(
          urlObj.searchParams.get('size') || req.headers['content-length'] || '0',
          10,
        ) || 0;

      if (maxUploadBytes > 0 && expectedBytes > maxUploadBytes) {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: 'File exceeds maximum upload size limit.' }));
        return;
      }

      await fsp.mkdir(receiveDir, { recursive: true });
      const destPath = await uniqueDestPath(receiveDir, safeName);
      const partPath = `${destPath}.part`;
      const finalName = path.basename(destPath);
      const txId = `ul_${nextId++}`;
      const deviceLabel = parseDeviceLabel(req.headers['user-agent'] || '');

      upsertRecord({
        id: txId,
        fileName: finalName,
        deviceLabel,
        direction: 'from_phone',
        state: 'transferring',
        totalBytes: expectedBytes,
        transferredBytes: 0,
        verified: false,
      });

      const hash = crypto.createHash('sha256');
      const writeStream = fs.createWriteStream(partPath);
      let received = 0;
      let lastEmit = 0;

      try {
        await new Promise((resolve, reject) => {
          req.on('data', (chunk) => {
            received += chunk.length;
            if (maxUploadBytes > 0 && received > maxUploadBytes) {
              req.destroy(new Error('File exceeds maximum upload size limit.'));
              return;
            }
            hash.update(chunk);
            const ok = writeStream.write(chunk);
            if (!ok) {
              req.pause();
              writeStream.once('drain', () => req.resume());
            }
            const now = Date.now();
            if (now - lastEmit >= 100) {
              lastEmit = now;
              updateRecord(txId, {
                transferredBytes: received,
                totalBytes: expectedBytes > 0 ? expectedBytes : received,
              });
            }
          });
          req.on('end', () => writeStream.end(resolve));
          req.on('error', reject);
          writeStream.on('error', reject);
        });

        const actualSha = hash.digest('hex');
        const claimedSha = String(req.headers['x-file-sha256'] || '').trim().toLowerCase();
        const claimedSig = String(req.headers['x-file-signature'] || '').trim().toLowerCase();
        const sigValid =
          actualSha === claimedSha &&
          verifyPayloadManifest(
            signingKeyHex,
            decodedOriginalName,
            received,
            actualSha,
            claimedSig,
          );

        if (security.requireSignature && !sigValid) {
          await fsp.unlink(partPath).catch(() => {});
          updateRecord(txId, {
            state: 'failed',
            error: 'Rejected: Missing or invalid HMAC-SHA256 file signature.',
          });
          res.writeHead(403, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              ok: false,
              error: 'File signature verification failed.',
            }),
          );
          return;
        }

        await fsp.rename(partPath, destPath);
        updateRecord(txId, {
          state: 'completed',
          totalBytes: received,
          transferredBytes: received,
          savedPath: destPath,
          sha256: actualSha,
          verified: sigValid,
        });

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            ok: true,
            savedName: finalName,
            bytes: received,
            sha256: actualSha,
            verified: sigValid,
          }),
        );
      } catch (err) {
        writeStream.destroy();
        fsp.unlink(partPath).catch(() => {});
        updateRecord(txId, { state: 'failed', error: err.message });
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: err.message }));
      }
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }

  async function handleDesktopWs(req, socket) {
    touch();
    const ws = upgradeWebSocket(req, socket);
    if (!ws) return;
    desktopSockets.add(ws);
    ws.sendJson({ type: 'state', state: await buildStateSnapshot(req) });
    ws.onClose(() => desktopSockets.delete(ws));
  }

  async function handleMobileWs(req, socket, urlObj) {
    touch();
    const ws = upgradeWebSocket(req, socket);
    if (!ws) return;
    const { sessionKey } = extractClientIdentity(req, urlObj);
    const clientId = `mob_${nextId++}`;
    const effectiveSessionKey = sessionKey || generateToken();
    const client = {
      id: clientId,
      sessionKey: effectiveSessionKey,
      deviceLabel: parseDeviceLabel(req.headers['user-agent'] || ''),
      remoteAddress: req.headers['cf-connecting-ip'] || socket.remoteAddress || 'Remote',
      connectedAt: new Date().toISOString(),
      pinVerified: !security.requirePin || authorizedSessionKeys.has(effectiveSessionKey),
      approved: !security.requireApproval,
      blocked: false,
    };

    if (!security.requireApproval) {
      approvedClientIds.add(clientId);
    }

    mobileClients.set(clientId, { client, ws });
    ws.sendJson({
      type: 'welcome',
      clientId,
      sessionKey: effectiveSessionKey,
      security: {
        requireSignature: security.requireSignature,
        requirePin: security.requirePin,
        requireApproval: security.requireApproval,
        pinVerified: client.pinVerified,
        approved: client.approved,
        blocked: false,
      },
      signingKeyHex: security.requireSignature ? signingKeyHex : '',
      files: serializeOutboxForMobile(),
    });

    await broadcastFullState(req);

    ws.onClose(async () => {
      mobileClients.delete(clientId);
      approvedClientIds.delete(clientId);
      blockedClientIds.delete(clientId);
      await broadcastFullState();
    });
  }

  async function close() {
    for (const ws of desktopSockets) ws.close();
    for (const c of mobileClients.values()) c.ws.close();
    desktopSockets.clear();
    mobileClients.clear();
    await fsp.rm(outboxDir, { recursive: true, force: true }).catch(() => {});
    if (removeOnClose) {
      await fsp.rm(receiveDir, { recursive: true, force: true }).catch(() => {});
    }
  }

  return {
    roomId,
    hostKey,
    getToken: () => token,
    getSigningKeyHex: () => signingKeyHex,
    getPin: () => pairingPin,
    getReceiveDir: () => receiveDir,
    getQrUrl,
    getLastActiveAt: () => lastActiveAt,
    hasActiveSockets: () => desktopSockets.size > 0 || mobileClients.size > 0,
    broadcastFullState,
    handleDesktopApi,
    handleMobileApi,
    handleDesktopWs,
    handleMobileWs,
    close,
  };
}

export function createQrWebApp({
  receiveDir = path.join(os.homedir(), 'Downloads', 'DeviceBridge'),
  outboxDir = path.join(os.tmpdir(), 'DeviceBridgeWebOutbox'),
  cloudDataDir = path.join(os.tmpdir(), 'DeviceBridgeCloudRooms'),
  port = 3000,
  host,
  cloudMode = false,
  enableTunnel = !cloudMode,
  publicBaseUrl = process.env.PUBLIC_BASE_URL || '',
  roomTtlMs = DEFAULT_ROOM_TTL_MS,
  maxRooms = DEFAULT_MAX_ROOMS,
  maxUploadBytes = cloudMode ? DEFAULT_MAX_UPLOAD_BYTES : 0,
} = {}) {
  let activePort = port;
  const listenHost = host || (cloudMode ? '0.0.0.0' : '127.0.0.1');

  let tunnelProc = null;
  let tunnelBaseUrl = null;
  let tunnelState = !cloudMode && enableTunnel ? 'starting' : 'disabled';
  let tunnelError = null;

  const rooms = new Map();
  const tokenToRoom = new Map();

  function getPublicBaseUrl(req, fallbackBaseUrl = '') {
    if (cloudMode) {
      return resolvePublicBaseUrl(req, publicBaseUrl || fallbackBaseUrl, activePort);
    }
    if (tunnelBaseUrl) return tunnelBaseUrl;
    return `http://localhost:${activePort}`;
  }

  function getTunnelInfo() {
    return {
      ready: Boolean(tunnelBaseUrl) || !enableTunnel,
      state: tunnelState,
      error: tunnelError,
      port: activePort,
    };
  }

  function registerRoom(room) {
    rooms.set(room.roomId, room);
    tokenToRoom.set(room.getToken(), room);
  }

  async function evictIfNeeded() {
    if (rooms.size < maxRooms) return;
    let oldest = null;
    for (const r of rooms.values()) {
      if (!oldest || r.getLastActiveAt() < oldest.getLastActiveAt()) {
        oldest = r;
      }
    }
    if (oldest) {
      rooms.delete(oldest.roomId);
      tokenToRoom.delete(oldest.getToken());
      await oldest.close();
    }
  }

  async function spawnCloudRoom() {
    await evictIfNeeded();
    const roomId = generateToken(10);
    const hostKey = crypto.randomBytes(24).toString('hex');
    const roomRoot = path.join(cloudDataDir, roomId);
    const room = createTransferRoom({
      roomId,
      hostKey,
      receiveDir: path.join(roomRoot, 'received'),
      outboxDir: path.join(roomRoot, 'outbox'),
      cloudMode: true,
      maxUploadBytes,
      getPublicBaseUrl,
      getTunnelInfo,
      onReconnectTunnel: async () => {},
      onTokenRotated: (oldTok, newTok) => {
        tokenToRoom.delete(oldTok);
        tokenToRoom.set(newTok, room);
      },
      removeOnClose: true,
    });
    registerRoom(room);
    return room;
  }

  const localRoom = !cloudMode
    ? createTransferRoom({
        roomId: 'local',
        hostKey: '',
        receiveDir,
        outboxDir,
        cloudMode: false,
        maxUploadBytes,
        getPublicBaseUrl,
        getTunnelInfo,
        onReconnectTunnel: () => startTunnel(),
        onTokenRotated: (oldTok, newTok) => {
          tokenToRoom.delete(oldTok);
          tokenToRoom.set(newTok, localRoom);
        },
        removeOnClose: false,
      })
    : null;

  if (localRoom) {
    registerRoom(localRoom);
  }

  const cleanupTimer = cloudMode
    ? setInterval(() => {
        const now = Date.now();
        for (const r of Array.from(rooms.values())) {
          const idleMs = now - r.getLastActiveAt();
          const expired = (!r.hasActiveSockets() && idleMs > roomTtlMs) || idleMs > roomTtlMs * 3;
          if (expired) {
            rooms.delete(r.roomId);
            tokenToRoom.delete(r.getToken());
            void r.close();
          }
        }
      }, 5 * 60 * 1000)
    : null;
  if (cleanupTimer) cleanupTimer.unref();

  function startTunnel() {
    if (cloudMode || !enableTunnel) return Promise.resolve(null);
    stopTunnel();
    tunnelBaseUrl = null;
    tunnelState = 'starting';
    tunnelError = null;
    void localRoom?.broadcastFullState();

    return new Promise((resolve) => {
      const bin = resolveCloudflaredBinary();
      const proc = spawn(
        bin,
        ['tunnel', '--url', `http://127.0.0.1:${activePort}`, '--no-autoupdate'],
        { stdio: ['ignore', 'pipe', 'pipe'] },
      );
      tunnelProc = proc;

      let settled = false;
      const urlRegex = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i;

      const handleOutput = (chunk) => {
        const text = chunk.toString('utf8');
        const match = text.match(urlRegex);
        if (match && tunnelProc === proc && !tunnelBaseUrl) {
          tunnelBaseUrl = match[0];
          tunnelState = 'ready';
          tunnelError = null;
          void localRoom?.broadcastFullState();
          if (!settled) {
            settled = true;
            resolve(tunnelBaseUrl);
          }
        }
      };

      proc.stdout.on('data', handleOutput);
      proc.stderr.on('data', handleOutput);
      proc.on('error', (err) => {
        if (tunnelProc === proc) {
          tunnelState = 'error';
          tunnelError = `Could not launch tunnel tool: ${err.message}`;
          void localRoom?.broadcastFullState();
        }
        if (!settled) {
          settled = true;
          resolve(null);
        }
      });
      proc.on('exit', (code) => {
        if (tunnelProc === proc && !tunnelBaseUrl) {
          tunnelState = 'error';
          tunnelError = `Tunnel exited with code ${code}`;
          void localRoom?.broadcastFullState();
        }
        if (!settled) {
          settled = true;
          resolve(null);
        }
      });

      setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(tunnelBaseUrl);
        }
      }, 15000);
    });
  }

  function stopTunnel() {
    if (tunnelProc) {
      try {
        tunnelProc.kill();
      } catch {
        // Ignore.
      }
      tunnelProc = null;
    }
    tunnelBaseUrl = null;
  }

  function resolveCloudDesktopRoom(req, urlObj) {
    const roomId = String(urlObj.searchParams.get('room') || req.headers['x-room-id'] || '').trim();
    const hostKey = String(urlObj.searchParams.get('hostKey') || req.headers['x-host-key'] || '').trim();
    if (!roomId) return { status: 'missing' };
    const room = rooms.get(roomId);
    if (!room) return { status: 'expired' };
    if (!safeEqualString(room.hostKey, hostKey)) return { status: 'forbidden' };
    return { status: 'ok', room };
  }

  const server = http.createServer(async (req, res) => {
    const urlObj = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    const pathname = urlObj.pathname;

    if (pathname === '/healthz' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ok: true, cloudMode, activeRooms: rooms.size }));
      return;
    }

    // --- Desktop / Host UI ---
    if (pathname === '/' && req.method === 'GET' && !urlObj.searchParams.has('token')) {
      if (!cloudMode && !isTrueDesktopRequest(req)) {
        res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Scan the QR code to open the mobile transfer page.');
        return;
      }
      const html = await fsp.readFile(path.join(PUBLIC_DIR, 'desktop.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(html);
      return;
    }

    // --- Desktop Admin / Room API Routes ---
    if (pathname.startsWith('/api/desktop/')) {
      if (!cloudMode) {
        if (!isTrueDesktopRequest(req)) {
          res.writeHead(403, { 'Content-Type': 'text/plain' });
          res.end('Forbidden');
          return;
        }
        await localRoom.handleDesktopApi(req, res, urlObj, pathname);
        return;
      }

      const auth = resolveCloudDesktopRoom(req, urlObj);
      if (auth.status === 'ok') {
        await auth.room.handleDesktopApi(req, res, urlObj, pathname);
        return;
      }
      if (pathname === '/api/desktop/state' && req.method === 'GET' && auth.status !== 'forbidden') {
        const freshRoom = await spawnCloudRoom();
        await freshRoom.handleDesktopApi(req, res, urlObj, pathname);
        return;
      }
      res.writeHead(403, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'Invalid or expired room credentials.' }));
      return;
    }

    // --- Mobile Token-Guarded Routes ---
    const suppliedToken = extractMobileToken(req, urlObj);
    const mobileRoom = tokenToRoom.get(suppliedToken);
    if (!mobileRoom) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Invalid or expired QR link. Please rescan the QR code on the computer screen.');
      return;
    }

    await mobileRoom.handleMobileApi(req, res, urlObj, pathname);
  });

  server.on('upgrade', async (req, socket) => {
    const urlObj = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (urlObj.pathname !== '/ws') {
      socket.destroy();
      return;
    }

    const role = urlObj.searchParams.get('role');
    if (role === 'desktop') {
      if (!cloudMode) {
        if (!isTrueDesktopRequest(req)) {
          socket.destroy();
          return;
        }
        await localRoom.handleDesktopWs(req, socket);
        return;
      }

      const auth = resolveCloudDesktopRoom(req, urlObj);
      if (auth.status !== 'ok') {
        socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
        socket.destroy();
        return;
      }
      await auth.room.handleDesktopWs(req, socket);
      return;
    }

    const supplied = extractMobileToken(req, urlObj);
    const mobileRoom = tokenToRoom.get(supplied);
    if (!mobileRoom) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      return;
    }
    await mobileRoom.handleMobileWs(req, socket, urlObj);
  });

  return {
    async start() {
      if (!cloudMode) {
        await fsp.mkdir(receiveDir, { recursive: true });
      } else {
        await fsp.mkdir(cloudDataDir, { recursive: true });
      }
      await new Promise((resolve, reject) => {
        const onErr = async (err) => {
          if (err.code === 'EADDRINUSE' && activePort !== 0 && !cloudMode) {
            activePort = 0;
            server.listen(0, listenHost, resolve);
          } else {
            reject(err);
          }
        };
        server.once('error', onErr);
        server.listen(activePort, listenHost, () => {
          server.removeListener('error', onErr);
          activePort = server.address().port;
          resolve();
        });
      });

      if (!cloudMode && enableTunnel) {
        await startTunnel();
      }
      return activePort;
    },
    async close() {
      if (cleanupTimer) clearInterval(cleanupTimer);
      stopTunnel();
      for (const room of rooms.values()) {
        await room.close();
      }
      rooms.clear();
      tokenToRoom.clear();
      await new Promise((resolve) => server.close(() => resolve()));
      if (cloudMode) {
        await fsp.rm(cloudDataDir, { recursive: true, force: true }).catch(() => {});
      }
    },
    isCloudMode: () => cloudMode,
    getActiveRoomCount: () => rooms.size,
    getPort: () => activePort,
    getToken: () => localRoom?.getToken() || '',
    getSigningKeyHex: () => localRoom?.getSigningKeyHex() || '',
    getPin: () => localRoom?.getPin() || '',
    getQrUrl: (req) => localRoom?.getQrUrl(req) || '',
    getReceiveDir: () => localRoom?.getReceiveDir() || cloudDataDir,
  };
}

// Run directly when invoked as CLI: `node server.js`
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const cloud = isCloudEnvironment();
  const port = Number.parseInt(process.env.PORT || '3000', 10) || 3000;
  const app = createQrWebApp({
    port,
    cloudMode: cloud,
    enableTunnel: !cloud,
  });
  const activePort = await app.start();

  const shutdown = async () => {
    await app.close();
    process.exit(0);
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);

  if (cloud) {
    console.log(`DeviceBridge QR Cloud running in public multi-room mode on port ${activePort}!`);
    console.log(`Health check: /healthz`);
  } else {
    console.log(`DeviceBridge QR Cloud Web running!`);
    console.log(`Desktop UI: http://localhost:${activePort}`);
    console.log(`QR Link:    ${app.getQrUrl()}`);
  }
}
