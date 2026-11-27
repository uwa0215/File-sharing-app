import zlib from 'node:zlib';
import { crc32Buffer } from './zip.js';

function pngChunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(data.length, 0);
  const crc = crc32Buffer(Buffer.concat([typeBuf, data]));
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc, 0);
  return Buffer.concat([lenBuf, typeBuf, data, crcBuf]);
}

function insideCircle(x, y, cx, cy, r) {
  const dx = x - cx;
  const dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function generateCloudIconPng(size) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  const pad = size * 0.08;
  const cornerR = size * 0.22;

  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 4 + 1);
    raw[rowStart] = 0; // Filter type 0

    for (let x = 0; x < size; x++) {
      const px = rowStart + 1 + x * 4;

      // Rounded-square dark backdrop gradient (#1b1742 -> #0f0d23)
      let inBg = true;
      if (x < pad || x > size - pad || y < pad || y > size - pad) {
        inBg = false;
      } else {
        const lx = pad + cornerR;
        const rx = size - pad - cornerR;
        const ty = pad + cornerR;
        const by = size - pad - cornerR;
        if (x < lx && y < ty && !insideCircle(x, y, lx, ty, cornerR)) inBg = false;
        if (x > rx && y < ty && !insideCircle(x, y, rx, ty, cornerR)) inBg = false;
        if (x < lx && y > by && !insideCircle(x, y, lx, by, cornerR)) inBg = false;
        if (x > rx && y > by && !insideCircle(x, y, rx, by, cornerR)) inBg = false;
      }

      if (!inBg) {
        raw[px] = 0;
        raw[px + 1] = 0;
        raw[px + 2] = 0;
        raw[px + 3] = 0;
        continue;
      }

      // Check pastel cloud silhouette
      const nx = x / size;
      const ny = y / size;
      const inCloud =
        insideCircle(nx, ny, 0.34, 0.56, 0.14) ||
        insideCircle(nx, ny, 0.50, 0.44, 0.18) ||
        insideCircle(nx, ny, 0.67, 0.55, 0.14) ||
        (nx >= 0.32 && nx <= 0.69 && ny >= 0.50 && ny <= 0.70);

      if (inCloud) {
        // Pink -> Sky -> Mint pastel diagonal gradient
        const t = Math.min(1, Math.max(0, (nx - 0.2) / 0.6));
        raw[px] = Math.round(255 * (1 - t) + 125 * t);
        raw[px + 1] = Math.round(180 * (1 - t) + 231 * t);
        raw[px + 2] = Math.round(225 * (1 - t) + 235 * t);
        raw[px + 3] = 255;
      } else {
        const bgT = ny;
        raw[px] = Math.round(31 * (1 - bgT) + 15 * bgT);
        raw[px + 1] = Math.round(26 * (1 - bgT) + 13 * bgT);
        raw[px + 2] = Math.round(72 * (1 - bgT) + 35 * bgT);
        raw[px + 3] = 255;
      }
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // Bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const idat = zlib.deflateSync(raw, { level: 6 });

  return Buffer.concat([
    sig,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', idat),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

const iconCache = new Map();

export function getPwaIconPng(size) {
  if (!iconCache.has(size)) {
    iconCache.set(size, generateCloudIconPng(size));
  }
  return iconCache.get(size);
}
