// Generates the PNG icons the PWA needs (Android install prompt and iOS home-screen icon
// both require raster icons; an SVG-only manifest is not enough).
//
// Zero dependencies: the shield from public/shield.svg is rasterised here and encoded with
// Node's built-in zlib. Runs automatically before `npm run build` (see "prebuild").

import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'public');
mkdirSync(outDir, { recursive: true });

const BACKGROUND = [0x09, 0x0d, 0x16];
const SHIELD = [0x63, 0x66, 0xf1];

// --- Shield outline, in the same 24x24 box as shield.svg -------------------------------
// M12 22 s8-4 8-10 V5 l-8-3 -8 3 v7 c0 6 8 10 8 10 z
function cubic(p0, p1, p2, p3, steps = 24) {
  const pts = [];
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    const u = 1 - t;
    pts.push([
      u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
      u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    ]);
  }
  return pts;
}

const outline = [
  [12, 22],
  ...cubic([12, 22], [12, 22], [20, 18], [20, 12]), // right-hand curve up to (20,12)
  [20, 5],
  [12, 2],
  [4, 5],
  [4, 12],
  ...cubic([4, 12], [4, 18], [12, 22], [12, 22]), // left-hand curve back to the tip
];

function insidePolygon(x, y, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i];
    const [xj, yj] = poly[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

// The exclamation mark from the SVG, knocked out of the shield: a bar and a dot.
function insideMark(x, y) {
  const bar = x >= 11 && x <= 13 && y >= 7.5 && y <= 13;
  const dot = (x - 12) ** 2 + (y - 16.2) ** 2 <= 1.25 ** 2;
  return bar || dot;
}

function render(size, shieldHeightFraction) {
  // Shield is 20 units tall inside the 24-unit box and is centred on the canvas.
  const scale = (size * shieldHeightFraction) / 20;
  const offsetX = size / 2 - 12 * scale;
  const offsetY = size / 2 - 12 * scale;
  const samples = 3;
  const pixels = Buffer.alloc(size * size * 4);

  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let shieldHits = 0;
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const ux = (px + (sx + 0.5) / samples - offsetX) / scale;
          const uy = (py + (sy + 0.5) / samples - offsetY) / scale;
          // Mark pixels keep the background colour, so only shield-minus-mark counts.
          if (insidePolygon(ux, uy, outline) && !insideMark(ux, uy)) shieldHits++;
        }
      }
      const coverage = shieldHits / (samples * samples);
      const i = (py * size + px) * 4;
      for (let c = 0; c < 3; c++) {
        pixels[i + c] = Math.round(BACKGROUND[c] * (1 - coverage) + SHIELD[c] * coverage);
      }
      pixels[i + 3] = 255;
    }
  }
  return pixels;
}

// --- Minimal PNG encoder ---------------------------------------------------------------
const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function encodePng(size, rgba) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8; // bit depth
  header[9] = 6; // RGBA
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// "any" icons use a large shield; the maskable icon keeps it inside the 80% safe zone so
// Android's adaptive-icon masks never clip it.
const icons = [
  { name: 'icon-180.png', size: 180, fraction: 0.66 }, // iOS apple-touch-icon
  { name: 'icon-192.png', size: 192, fraction: 0.66 },
  { name: 'icon-512.png', size: 512, fraction: 0.66 },
  { name: 'icon-maskable-512.png', size: 512, fraction: 0.5 },
];

for (const { name, size, fraction } of icons) {
  writeFileSync(join(outDir, name), encodePng(size, render(size, fraction)));
  console.log(`generated public/${name}`);
}
