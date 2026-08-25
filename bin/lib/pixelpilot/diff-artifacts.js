const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { decodePngToRgba } = require('./image-diff');

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function createRawDiffMaskArtifact(currentBuffer, baselineBuffer) {
  const current = decodePngToRgba(currentBuffer);
  const baseline = decodePngToRgba(baselineBuffer);

  if (current.width !== baseline.width || current.height !== baseline.height) {
    throw new Error('Cannot build a diff mask for PNGs with different dimensions');
  }

  const mask = Buffer.alloc(current.width * current.height * 4);
  let hasDiff = false;

  for (let offset = 0; offset < current.rgba.length; offset += 4) {
    const isDifferent =
      current.rgba[offset] !== baseline.rgba[offset] ||
      current.rgba[offset + 1] !== baseline.rgba[offset + 1] ||
      current.rgba[offset + 2] !== baseline.rgba[offset + 2] ||
      current.rgba[offset + 3] !== baseline.rgba[offset + 3];

    if (isDifferent) {
      hasDiff = true;
      mask[offset] = 0xff;
      mask[offset + 1] = 0xff;
      mask[offset + 2] = 0xff;
      mask[offset + 3] = 0xff;
    }
  }

  if (!hasDiff) {
    return null;
  }

  return encodeRgbaPng(current.width, current.height, mask);
}

function writeRawDiffMaskArtifact({
  currentBuffer,
  baselineBuffer,
  outputDir,
  artifactName = 'diff-mask.png'
}) {
  let artifactBuffer;
  let isFallback = false;

  try {
    artifactBuffer = createRawDiffMaskArtifact(currentBuffer, baselineBuffer);
  } catch (error) {
    if (error.message.includes('different dimensions')) {
      const current = decodePngToRgba(currentBuffer);
      const baseline = decodePngToRgba(baselineBuffer);
      artifactBuffer = createDimensionMismatchSvg(
        current.width,
        current.height,
        baseline.width,
        baseline.height
      );
      isFallback = true;
    } else {
      throw error;
    }
  }

  if (!artifactBuffer) {
    return null;
  }

  fs.mkdirSync(outputDir, { recursive: true });
  const svgName = artifactName.replace(/\.png$/, '.svg');
  const artifactPath = path.join(outputDir, isFallback ? svgName : artifactName);
  fs.writeFileSync(artifactPath, artifactBuffer);

  return artifactPath;
}

function createDimensionMismatchSvg(currentWidth, currentHeight, baselineWidth, baselineHeight) {
  const width = Math.max(currentWidth, baselineWidth);
  const height = Math.max(currentHeight, baselineHeight);

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <style>
      .overlay { fill: rgba(100, 100, 100, 0.3); }
      .text { fill: rgba(60, 60, 60, 0.8); font-family: system-ui, -apple-system, sans-serif; font-size: 18px; font-weight: 500; text-anchor: middle; }
      .subtext { fill: rgba(60, 60, 60, 0.6); font-family: system-ui, -apple-system, sans-serif; font-size: 14px; text-anchor: middle; }
    </style>
  </defs>
  <rect class="overlay" width="${width}" height="${height}"/>
  <text class="text" x="${width / 2}" y="${height / 2 - 20}">Diff not generated</text>
  <text class="subtext" x="${width / 2}" y="${height / 2 + 10}">Baseline: ${baselineWidth}×${baselineHeight} | Current: ${currentWidth}×${currentHeight}</text>
</svg>`;
}

function encodeRgbaPng(width, height, rgba) {
  const signature = PNG_SIGNATURE;
  const ihdr = chunk('IHDR', Buffer.from([
    (width >>> 24) & 0xff, (width >>> 16) & 0xff, (width >>> 8) & 0xff, width & 0xff,
    (height >>> 24) & 0xff, (height >>> 16) & 0xff, (height >>> 8) & 0xff, height & 0xff,
    0x08, 0x06, 0x00, 0x00, 0x00
  ]));

  const raw = Buffer.alloc(height * (width * 4 + 1));
  let sourceOffset = 0;
  let targetOffset = 0;

  for (let y = 0; y < height; y += 1) {
    raw[targetOffset] = 0;
    targetOffset += 1;

    for (let x = 0; x < width * 4; x += 1) {
      raw[targetOffset] = rgba[sourceOffset];
      targetOffset += 1;
      sourceOffset += 1;
    }
  }

  return Buffer.concat([signature, ihdr, chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

function chunk(type, data) {
  const typeBuffer = Buffer.from(type, 'ascii');
  const lengthBuffer = Buffer.alloc(4);
  lengthBuffer.writeUInt32BE(data.length, 0);
  const crcBuffer = Buffer.alloc(4);
  crcBuffer.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0);
  return Buffer.concat([lengthBuffer, typeBuffer, data, crcBuffer]);
}

function crc32(buffer) {
  let crc = 0xffffffff;

  for (let i = 0; i < buffer.length; i += 1) {
    crc = CRC_TABLE[(crc ^ buffer[i]) & 0xff] ^ (crc >>> 8);
  }

  return (crc ^ 0xffffffff) >>> 0;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);

  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }

  return table;
})();

module.exports = {
  createRawDiffMaskArtifact,
  writeRawDiffMaskArtifact
};
