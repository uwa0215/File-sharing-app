import fs from 'node:fs';
import path from 'node:path';

const CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let k = 0; k < 8; k++) {
    c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  CRC_TABLE[i] = c >>> 0;
}

export function crc32Update(crc, buf) {
  let c = (crc ^ 0xffffffff) >>> 0;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

export function crc32Buffer(buf) {
  return crc32Update(0, buf);
}

export function computeFileCrc32(filePath) {
  return new Promise((resolve, reject) => {
    let crc = 0;
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => {
      crc = crc32Update(crc, chunk);
    });
    stream.on('end', () => resolve(crc >>> 0));
    stream.on('error', reject);
  });
}

function dosTimeDate(date = new Date()) {
  const time =
    ((date.getHours() & 0x1f) << 11) |
    ((date.getMinutes() & 0x3f) << 5) |
    ((date.getSeconds() >> 1) & 0x1f);
  const year = Math.max(1980, date.getFullYear()) - 1980;
  const dosDate = ((year & 0x7f) << 9) | (((date.getMonth() + 1) & 0x0f) << 5) | (date.getDate() & 0x1f);
  return { time, dosDate };
}

function deduplicateZipNames(entries) {
  const used = new Set();
  return entries.map((entry) => {
    const raw = String(entry.name || 'file.bin').replace(/\\/g, '/').split('/').pop() || 'file.bin';
    if (!used.has(raw)) {
      used.add(raw);
      return { ...entry, zipName: raw };
    }
    const ext = path.posix.extname(raw);
    const stem = path.posix.basename(raw, ext);
    for (let i = 1; i < 10000; i++) {
      const candidate = `${stem} (${i})${ext}`;
      if (!used.has(candidate)) {
        used.add(candidate);
        return { ...entry, zipName: candidate };
      }
    }
    const fallback = `${stem}_${Date.now()}${ext}`;
    used.add(fallback);
    return { ...entry, zipName: fallback };
  });
}

/**
 * Streams a valid STORE (method 0) ZIP archive of files on disk directly to an HTTP response
 * without loading entire file payloads into memory.
 */
export async function streamZipFiles(res, rawEntries, archiveName = 'DeviceBridge_Files.zip') {
  const uniqueEntries = deduplicateZipNames(rawEntries);
  const prepared = [];
  let totalDataSection = 0;
  let totalCentralSize = 0;
  const { time, dosDate } = dosTimeDate();

  for (const entry of uniqueEntries) {
    if (!entry.filePath || !fs.existsSync(entry.filePath)) continue;
    const stat = await fs.promises.stat(entry.filePath);
    const crc32 = await computeFileCrc32(entry.filePath);
    const nameBuf = Buffer.from(entry.zipName, 'utf8');
    const localHeaderOffset = totalDataSection;

    totalDataSection += 30 + nameBuf.length + stat.size;
    totalCentralSize += 46 + nameBuf.length;

    prepared.push({
      filePath: entry.filePath,
      nameBuf,
      sizeBytes: stat.size,
      crc32,
      localHeaderOffset,
    });
  }

  const totalZipBytes = totalDataSection + totalCentralSize + 22;
  const safeArchive = archiveName.replace(/[^\w.-]+/g, '_');

  res.writeHead(200, {
    'Content-Type': 'application/zip',
    'Content-Length': totalZipBytes,
    'Content-Disposition': `attachment; filename="${safeArchive}"`,
    'Cache-Control': 'no-store',
  });

  const centralParts = [];

  for (const item of prepared) {
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); // Local file header signature
    lh.writeUInt16LE(20, 4); // Version needed to extract (2.0)
    lh.writeUInt16LE(0x0800, 6); // UTF-8 filename flag
    lh.writeUInt16LE(0, 8); // STORE (no compression)
    lh.writeUInt16LE(time, 10);
    lh.writeUInt16LE(dosDate, 12);
    lh.writeUInt32LE(item.crc32, 14);
    lh.writeUInt32LE(item.sizeBytes, 18);
    lh.writeUInt32LE(item.sizeBytes, 22);
    lh.writeUInt16LE(item.nameBuf.length, 26);
    lh.writeUInt16LE(0, 28); // Extra field length
    res.write(Buffer.concat([lh, item.nameBuf]));

    await new Promise((resolve, reject) => {
      const stream = fs.createReadStream(item.filePath);
      stream.on('data', (chunk) => {
        if (!res.write(chunk)) {
          stream.pause();
          res.once('drain', () => stream.resume());
        }
      });
      stream.on('end', resolve);
      stream.on('error', reject);
    });

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0); // Central directory header signature
    cd.writeUInt16LE(20, 4); // Version made by
    cd.writeUInt16LE(20, 6); // Version needed
    cd.writeUInt16LE(0x0800, 8); // UTF-8 flag
    cd.writeUInt16LE(0, 10); // STORE
    cd.writeUInt16LE(time, 12);
    cd.writeUInt16LE(dosDate, 14);
    cd.writeUInt32LE(item.crc32, 16);
    cd.writeUInt32LE(item.sizeBytes, 20);
    cd.writeUInt32LE(item.sizeBytes, 24);
    cd.writeUInt16LE(item.nameBuf.length, 28);
    cd.writeUInt16LE(0, 30); // Extra length
    cd.writeUInt16LE(0, 32); // Comment length
    cd.writeUInt16LE(0, 34); // Disk start
    cd.writeUInt16LE(0, 36); // Internal attrs
    cd.writeUInt32LE(0, 38); // External attrs
    cd.writeUInt32LE(item.localHeaderOffset, 42);
    centralParts.push(cd, item.nameBuf);
  }

  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); // End of central directory signature
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(prepared.length, 8);
  eocd.writeUInt16LE(prepared.length, 10);
  eocd.writeUInt32LE(totalCentralSize, 12);
  eocd.writeUInt32LE(totalDataSection, 16);
  eocd.writeUInt16LE(0, 20);
  centralParts.push(eocd);

  res.end(Buffer.concat(centralParts));
}
