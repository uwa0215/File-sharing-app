import crypto from 'node:crypto';

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/**
 * Lightweight RFC 6455 WebSocket upgrade + text frame helper using Node built-ins.
 */
export function upgradeWebSocket(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key || typeof key !== 'string') {
    socket.destroy();
    return null;
  }

  const accept = crypto
    .createHash('sha1')
    .update(key + WS_MAGIC)
    .digest('base64');

  socket.write(
    [
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${accept}`,
      '\r\n',
    ].join('\r\n'),
  );

  let closed = false;
  let buffer = Buffer.alloc(0);
  const messageHandlers = [];
  const closeHandlers = [];

  function safeWrite(buf) {
    if (closed || socket.destroyed) return;
    try {
      socket.write(buf);
    } catch {
      close();
    }
  }

  function sendText(text) {
    if (closed || socket.destroyed) return;
    const payload = Buffer.from(text, 'utf8');
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.allocUnsafe(2);
      header[0] = 0x81;
      header[1] = len;
    } else if (len < 65536) {
      header = Buffer.allocUnsafe(4);
      header[0] = 0x81;
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.allocUnsafe(10);
      header[0] = 0x81;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    safeWrite(Buffer.concat([header, payload]));
  }

  function sendPong(data) {
    if (closed || socket.destroyed) return;
    const len = data.length;
    const header = Buffer.allocUnsafe(2);
    header[0] = 0x8a;
    header[1] = len;
    safeWrite(Buffer.concat([header, data]));
  }

  const heartbeatTimer = setInterval(() => {
    if (closed || socket.destroyed) return;
    safeWrite(Buffer.from([0x89, 0x00]));
  }, 25000);
  heartbeatTimer.unref();

  function close() {
    if (closed) return;
    closed = true;
    clearInterval(heartbeatTimer);
    try {
      socket.end(Buffer.from([0x88, 0x00]));
    } catch {
      socket.destroy();
    }
    for (const fn of closeHandlers) fn();
  }

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const b0 = buffer[0];
      const b1 = buffer[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;

      if (payloadLen === 126) {
        if (buffer.length < 4) return;
        payloadLen = buffer.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (buffer.length < 10) return;
        const bigLen = buffer.readBigUInt64BE(2);
        if (bigLen > 16n * 1024n * 1024n) {
          close();
          return;
        }
        payloadLen = Number(bigLen);
        offset = 10;
      }

      const maskLen = masked ? 4 : 0;
      if (buffer.length < offset + maskLen + payloadLen) return;

      const maskKey = masked ? buffer.subarray(offset, offset + 4) : null;
      const rawPayload = buffer.subarray(
        offset + maskLen,
        offset + maskLen + payloadLen,
      );
      buffer = buffer.subarray(offset + maskLen + payloadLen);

      const payload = Buffer.allocUnsafe(payloadLen);
      for (let i = 0; i < payloadLen; i++) {
        payload[i] = maskKey ? rawPayload[i] ^ maskKey[i % 4] : rawPayload[i];
      }

      if (opcode === 0x08) {
        close();
        return;
      }
      if (opcode === 0x09) {
        sendPong(payload);
        continue;
      }
      if (opcode === 0x01) {
        const text = payload.toString('utf8');
        for (const fn of messageHandlers) fn(text);
      }
    }
  });

  socket.on('close', () => {
    if (!closed) {
      closed = true;
      clearInterval(heartbeatTimer);
      for (const fn of closeHandlers) fn();
    }
  });

  socket.on('error', () => {
    if (!closed) {
      closed = true;
      clearInterval(heartbeatTimer);
      for (const fn of closeHandlers) fn();
    }
  });

  return {
    sendJson(obj) {
      sendText(JSON.stringify(obj));
    },
    onMessage(fn) {
      messageHandlers.push(fn);
    },
    onClose(fn) {
      closeHandlers.push(fn);
    },
    close,
  };
}
