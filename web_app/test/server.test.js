import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import {
  createQrWebApp,
  isTrueDesktopRequest,
  sanitizeFilename,
  signPayloadManifest,
} from '../server.js';

function signFile(signingKeyHex, fileName, buf) {
  const sha = crypto.createHash('sha256').update(buf).digest('hex');
  const sig = signPayloadManifest(signingKeyHex, fileName, buf.length, sha);
  return { sha, sig };
}

describe('DeviceBridge QR Web App', () => {
  let tempDir;
  let app;
  let port;

  beforeEach(async () => {
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'db_web_test_'));
    app = createQrWebApp({
      receiveDir: path.join(tempDir, 'received'),
      outboxDir: path.join(tempDir, 'outbox'),
      port: 0,
      enableTunnel: false,
    });
    port = await app.start();
  });

  afterEach(async () => {
    await app.close();
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  it('sanitizes unsafe filenames cleanly', () => {
    assert.equal(sanitizeFilename('../secret/photo.jpg'), 'photo.jpg');
    assert.equal(sanitizeFilename('..\\a:b*c?.png'), 'a_b_c_.png');
  });

  it('blocks tunneled external requests from accessing desktop admin endpoints', () => {
    assert.equal(
      isTrueDesktopRequest({
        socket: { remoteAddress: '127.0.0.1' },
        headers: { host: 'localhost:3000' },
      }),
      true,
    );
    assert.equal(
      isTrueDesktopRequest({
        socket: { remoteAddress: '127.0.0.1' },
        headers: {
          host: 'demo.trycloudflare.com',
          'cf-ray': '1234',
          'cf-connecting-ip': '203.0.113.10',
        },
      }),
      false,
    );
  });

  it('rejects missing or invalid HMAC file signatures when signing is enabled', async () => {
    const token = app.getToken();
    const payload = Buffer.from('Tampered or unsigned photo');

    // Unsigned attempt rejected with 403
    const unsignedRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${token}&name=unsigned.jpg&size=${payload.length}`,
      { method: 'POST', body: payload },
    );
    assert.equal(unsignedRes.status, 403);

    // Wrong signature rejected with 403
    const sha = crypto.createHash('sha256').update(payload).digest('hex');
    const badSigRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${token}&name=bad.jpg&size=${payload.length}`,
      {
        method: 'POST',
        headers: {
          'x-file-sha256': sha,
          'x-file-signature': '0'.repeat(64),
        },
        body: payload,
      },
    );
    assert.equal(badSigRes.status, 403);
  });

  it('enforces 6-digit PIN and device approval gates when enabled', async () => {
    const token = app.getToken();
    const payload = Buffer.from('PIN gated file!');
    const { sha, sig } = signFile(app.getSigningKeyHex(), 'secret.txt', payload);

    // Enable Require PIN on desktop
    const secRes = await fetch(`http://127.0.0.1:${port}/api/desktop/security`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ requirePin: true }),
    });
    assert.equal(secRes.status, 200);
    const pin = app.getPin();

    // Upload without PIN unlocked fails 403
    const lockedRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${token}&name=secret.txt&size=${payload.length}`,
      {
        method: 'POST',
        headers: {
          'x-session-key': 'sess1',
          'x-file-sha256': sha,
          'x-file-signature': sig,
        },
        body: payload,
      },
    );
    assert.equal(lockedRes.status, 403);

    // Wrong PIN rejected
    const badPin = await fetch(
      `http://127.0.0.1:${port}/api/auth/pin?token=${token}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin: '000000', sessionKey: 'sess1' }),
      },
    );
    assert.equal(badPin.status, 403);

    // Correct PIN unlocks session
    const goodPin = await fetch(
      `http://127.0.0.1:${port}/api/auth/pin?token=${token}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin, sessionKey: 'sess1' }),
      },
    );
    assert.equal(goodPin.status, 200);

    const unlockedRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${token}&name=secret.txt&size=${payload.length}`,
      {
        method: 'POST',
        headers: {
          'x-session-key': 'sess1',
          'x-file-sha256': sha,
          'x-file-signature': sig,
        },
        body: payload,
      },
    );
    assert.equal(unlockedRes.status, 200);
  });

  it('streams verified single + chunked mobile uploads, signed downloads, and WebSocket scans', async () => {
    const token = app.getToken();
    const keyHex = app.getSigningKeyHex();

    // 1. Mobile portal loads cleanly with valid token
    const mobRes = await fetch(`http://127.0.0.1:${port}/s/${token}`);
    assert.equal(mobRes.status, 200);

    // 2. Signed single-request upload
    const payload = Buffer.from('Photo bytes from mobile camera!');
    const { sha, sig } = signFile(keyHex, '../IMG_001.jpg', payload);
    const ulRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${token}&name=${encodeURIComponent('../IMG_001.jpg')}&size=${payload.length}`,
      {
        method: 'POST',
        headers: {
          'x-file-sha256': sha,
          'x-file-signature': sig,
        },
        body: payload,
      },
    );
    assert.equal(ulRes.status, 200);
    const ulJson = await ulRes.json();
    assert.equal(ulJson.verified, true);
    assert.equal(ulJson.savedName, 'IMG_001.jpg');

    // 3. Signed chunked upload (2 chunks)
    const partA = Buffer.from('FirstHalfVideo-');
    const partB = Buffer.from('SecondHalfVideo');
    const fullVideo = Buffer.concat([partA, partB]);
    const vidSigned = signFile(keyHex, 'clip.mp4', fullVideo);
    const c1 = await fetch(
      `http://127.0.0.1:${port}/api/upload-chunk?token=${token}&uploadId=vid1&offset=0&total=${fullVideo.length}&final=0&name=clip.mp4`,
      { method: 'POST', body: partA },
    );
    assert.equal(c1.status, 200);
    const c2 = await fetch(
      `http://127.0.0.1:${port}/api/upload-chunk?token=${token}&uploadId=vid1&offset=${partA.length}&total=${fullVideo.length}&final=1&name=clip.mp4`,
      {
        method: 'POST',
        headers: {
          'x-file-sha256': vidSigned.sha,
          'x-file-signature': vidSigned.sig,
        },
        body: partB,
      },
    );
    assert.equal(c2.status, 200);
    const savedVideo = await fs.readFile(path.join(app.getReceiveDir(), 'clip.mp4'));
    assert.deepEqual(savedVideo, fullVideo);

    // 4. Desktop shares a signed file back to mobile
    const shareRes = await fetch(
      `http://127.0.0.1:${port}/api/desktop/share-file?name=report.txt`,
      { method: 'POST', body: 'Hello Phone!' },
    );
    assert.equal(shareRes.status, 200);
    const shareJson = await shareRes.json();
    assert.ok(shareJson.signature);

    const dlRes = await fetch(
      `http://127.0.0.1:${port}/api/download/${shareJson.id}?token=${token}`,
    );
    assert.equal(dlRes.status, 200);
    assert.equal(dlRes.headers.get('x-file-signature'), shareJson.signature);
    assert.equal(await dlRes.text(), 'Hello Phone!');

    // 5. WebSocket scan registers device
    await new Promise((resolve, reject) => {
      const req = http.request({
        host: '127.0.0.1',
        port,
        path: `/ws?role=mobile&token=${token}`,
        headers: {
          Connection: 'Upgrade',
          Upgrade: 'websocket',
          'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': Buffer.from('1234567890123456').toString('base64'),
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)',
        },
      });
      req.on('upgrade', async (_res, socket) => {
        try {
          const stRes = await fetch(`http://127.0.0.1:${port}/api/desktop/state`);
          const st = await stRes.json();
          assert.equal(st.clients.length, 1);
          assert.equal(st.clients[0].deviceLabel, 'iPhone');
          socket.destroy();
          resolve();
        } catch (err) {
          socket.destroy();
          reject(err);
        }
      });
      req.on('error', reject);
      req.end();
    });
  });
});

describe('DeviceBridge Public Cloud Multi-Room Mode', () => {
  let cloudDir;
  let cloudApp;
  let port;

  beforeEach(async () => {
    cloudDir = await fs.mkdtemp(path.join(os.tmpdir(), 'db_cloud_test_'));
    cloudApp = createQrWebApp({
      cloudMode: true,
      cloudDataDir: cloudDir,
      port: 0,
      host: '127.0.0.1',
    });
    port = await cloudApp.start();
  });

  afterEach(async () => {
    await cloudApp.close();
    await fs.rm(cloudDir, { recursive: true, force: true });
  });

  it('exposes /healthz and isolates multi-user rooms with proxy-aware QR URLs', async () => {
    const healthRes = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(healthRes.status, 200);
    const health = await healthRes.json();
    assert.equal(health.ok, true);
    assert.equal(health.cloudMode, true);

    // Public visitor can load desktop UI directly
    const uiRes = await fetch(`http://127.0.0.1:${port}/`, {
      headers: { 'x-forwarded-proto': 'https', 'x-forwarded-host': 'drop.example.com' },
    });
    assert.equal(uiRes.status, 200);
    assert.ok((await uiRes.text()).includes('DeviceBridge'));

    // Alice and Bob each receive isolated rooms with https QR URLs
    const aliceRes = await fetch(`http://127.0.0.1:${port}/api/desktop/state`, {
      headers: { 'x-forwarded-proto': 'https', 'x-forwarded-host': 'drop.example.com' },
    });
    assert.equal(aliceRes.status, 200);
    const alice = await aliceRes.json();
    assert.equal(alice.cloudMode, true);
    assert.equal(alice.url, `https://drop.example.com/s/${alice.token}`);

    const bobRes = await fetch(`http://127.0.0.1:${port}/api/desktop/state`, {
      headers: { 'x-forwarded-proto': 'https', 'x-forwarded-host': 'drop.example.com' },
    });
    const bob = await bobRes.json();
    assert.notEqual(alice.roomId, bob.roomId);
    assert.notEqual(alice.token, bob.token);

    // Wrong hostKey cannot access Alice's room
    const hijackRes = await fetch(
      `http://127.0.0.1:${port}/api/desktop/state?room=${encodeURIComponent(alice.roomId)}&hostKey=wrong`,
    );
    assert.equal(hijackRes.status, 403);

    // Alice's phone uploads a signed file to Alice's room only
    const aliceCfgRes = await fetch(`http://127.0.0.1:${port}/api/session-config?token=${alice.token}`);
    const aliceCfg = await aliceCfgRes.json();
    const payload = Buffer.from('Alice private cloud photo');
    const { sha, sig } = signFile(aliceCfg.signingKeyHex, 'vacation.jpg', payload);

    const ulRes = await fetch(
      `http://127.0.0.1:${port}/api/upload?token=${alice.token}&name=vacation.jpg&size=${payload.length}`,
      {
        method: 'POST',
        headers: { 'x-file-sha256': sha, 'x-file-signature': sig },
        body: payload,
      },
    );
    assert.equal(ulRes.status, 200);

    const aliceStateAfter = await (
      await fetch(
        `http://127.0.0.1:${port}/api/desktop/state?room=${encodeURIComponent(alice.roomId)}&hostKey=${encodeURIComponent(alice.hostKey)}`,
      )
    ).json();
    const bobStateAfter = await (
      await fetch(
        `http://127.0.0.1:${port}/api/desktop/state?room=${encodeURIComponent(bob.roomId)}&hostKey=${encodeURIComponent(bob.hostKey)}`,
      )
    ).json();

    assert.equal(aliceStateAfter.transfers.length, 1);
    assert.equal(bobStateAfter.transfers.length, 0);

    const recId = aliceStateAfter.transfers[0].id;
    const dlForbidden = await fetch(
      `http://127.0.0.1:${port}/api/desktop/received/${encodeURIComponent(recId)}?room=${encodeURIComponent(alice.roomId)}&hostKey=${encodeURIComponent(bob.hostKey)}`,
    );
    assert.equal(dlForbidden.status, 403);

    const dlAllowed = await fetch(
      `http://127.0.0.1:${port}/api/desktop/received/${encodeURIComponent(recId)}?room=${encodeURIComponent(alice.roomId)}&hostKey=${encodeURIComponent(alice.hostKey)}`,
    );
    assert.equal(dlAllowed.status, 200);
    assert.deepEqual(Buffer.from(await dlAllowed.arrayBuffer()), payload);
  });
});
