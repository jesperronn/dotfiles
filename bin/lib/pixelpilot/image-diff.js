const fs = require('node:fs');
const zlib = require('node:zlib');

function comparePngFiles(currentPath, baselinePath) {
  const current = decodePngToRgba(fs.readFileSync(currentPath));
  const baseline = decodePngToRgba(fs.readFileSync(baselinePath));

  return compareDecodedImages(current, baseline);
}

function comparePngBuffers(currentBuffer, baselineBuffer) {
  return compareDecodedImages(decodePngToRgba(currentBuffer), decodePngToRgba(baselineBuffer));
}

function compareDecodedImages(current, baseline) {
  if (current.width !== baseline.width || current.height !== baseline.height) {
    return false;
  }

  const pixelCount = current.width * current.height * 4;
  for (let index = 0; index < pixelCount; index += 1) {
    if (current.rgba[index] !== baseline.rgba[index]) {
      return false;
    }
  }

  return true;
}

function decodePngToRgba(buffer) {
  if (!Buffer.isBuffer(buffer)) {
    throw new TypeError('PNG input must be a Buffer');
  }

  const signature = buffer.subarray(0, 8);
  if (!signature.equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    throw new Error('Invalid PNG signature');
  }

  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  const idatChunks = [];

  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const data = buffer.subarray(dataStart, dataEnd);

    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data.readUInt8(8);
      colorType = data.readUInt8(9);
    } else if (type === 'IDAT') {
      idatChunks.push(data);
    } else if (type === 'IEND') {
      break;
    }

    offset = dataEnd + 4;
  }

  if (!width || !height) {
    throw new Error('PNG missing IHDR');
  }
  if (bitDepth !== 8) {
    throw new Error(`Unsupported PNG bit depth: ${bitDepth}`);
  }

  const source = zlib.inflateSync(Buffer.concat(idatChunks));
  const bytesPerPixel = bytesPerPixelForColorType(colorType);
  const rowLength = width * bytesPerPixel;
  const expectedLength = height * (rowLength + 1);
  if (source.length !== expectedLength) {
    throw new Error('Invalid PNG data length');
  }

  const rgba = Buffer.alloc(width * height * 4);
  const previousRow = Buffer.alloc(rowLength);
  const currentRow = Buffer.alloc(rowLength);

  let inputOffset = 0;
  let outputOffset = 0;
  for (let y = 0; y < height; y += 1) {
    const filterType = source[inputOffset];
    inputOffset += 1;
    source.copy(currentRow, 0, inputOffset, inputOffset + rowLength);
    inputOffset += rowLength;

    unfilterRow(filterType, currentRow, previousRow, bytesPerPixel);
    writeRgbaRow(rgba, outputOffset, currentRow, colorType);

    currentRow.copy(previousRow);
    outputOffset += width * 4;
  }

  return { width, height, rgba };
}

function bytesPerPixelForColorType(colorType) {
  switch (colorType) {
    case 0:
      return 1;
    case 2:
      return 3;
    case 4:
      return 2;
    case 6:
      return 4;
    default:
      throw new Error(`Unsupported PNG color type: ${colorType}`);
  }
}

function unfilterRow(filterType, row, previousRow, bytesPerPixel) {
  switch (filterType) {
    case 0:
      return;
    case 1:
      for (let i = bytesPerPixel; i < row.length; i += 1) {
        row[i] = (row[i] + row[i - bytesPerPixel]) & 0xff;
      }
      return;
    case 2:
      for (let i = 0; i < row.length; i += 1) {
        row[i] = (row[i] + previousRow[i]) & 0xff;
      }
      return;
    case 3:
      for (let i = 0; i < row.length; i += 1) {
        const left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
        const up = previousRow[i];
        row[i] = (row[i] + Math.floor((left + up) / 2)) & 0xff;
      }
      return;
    case 4:
      for (let i = 0; i < row.length; i += 1) {
        const left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
        const up = previousRow[i];
        const upLeft = i >= bytesPerPixel ? previousRow[i - bytesPerPixel] : 0;
        row[i] = (row[i] + paethPredictor(left, up, upLeft)) & 0xff;
      }
      return;
    default:
      throw new Error(`Unsupported PNG filter type: ${filterType}`);
  }
}

function paethPredictor(left, up, upLeft) {
  const p = left + up - upLeft;
  const pa = Math.abs(p - left);
  const pb = Math.abs(p - up);
  const pc = Math.abs(p - upLeft);

  if (pa <= pb && pa <= pc) return left;
  if (pb <= pc) return up;
  return upLeft;
}

function writeRgbaRow(target, targetOffset, row, colorType) {
  switch (colorType) {
    case 0:
      for (let i = 0; i < row.length; i += 1) {
        const value = row[i];
        const offset = targetOffset + i * 4;
        target[offset] = value;
        target[offset + 1] = value;
        target[offset + 2] = value;
        target[offset + 3] = 0xff;
      }
      return;
    case 2:
      for (let i = 0; i < row.length; i += 3) {
        const offset = targetOffset + (i / 3) * 4;
        target[offset] = row[i];
        target[offset + 1] = row[i + 1];
        target[offset + 2] = row[i + 2];
        target[offset + 3] = 0xff;
      }
      return;
    case 4:
      for (let i = 0; i < row.length; i += 2) {
        const value = row[i];
        const offset = targetOffset + (i / 2) * 4;
        target[offset] = value;
        target[offset + 1] = value;
        target[offset + 2] = value;
        target[offset + 3] = row[i + 1];
      }
      return;
    case 6:
      for (let i = 0; i < row.length; i += 4) {
        const offset = targetOffset + i;
        target[offset] = row[i];
        target[offset + 1] = row[i + 1];
        target[offset + 2] = row[i + 2];
        target[offset + 3] = row[i + 3];
      }
      return;
    default:
      throw new Error(`Unsupported PNG color type: ${colorType}`);
  }
}

module.exports = {
  comparePngBuffers,
  comparePngFiles,
  decodePngToRgba
};

if (require.main === module) {
  const [currentPath, baselinePath] = process.argv.slice(2);

  if (!currentPath || !baselinePath) {
    process.stderr.write('Usage: node tools/screenshot/image-diff.js <current.png> <baseline.png>\n');
    process.exit(2);
  }

  try {
    process.exit(comparePngFiles(currentPath, baselinePath) ? 0 : 1);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
