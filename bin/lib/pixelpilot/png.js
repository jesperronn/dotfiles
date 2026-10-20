// Minimal, dependency-free PNG decode/encode built on node:zlib.
//
// tools/screenshot/ needs to stay npm-dependency-free (see README.md), so
// this replaces pngjs. It only implements what real Playwright screenshots
// and this tool's own encoded diff/heatmap PNGs actually use:
//
//  - color types 0 (grayscale), 2 (RGB), 3 (palette, with optional tRNS
//    transparency), 4 (grayscale+alpha) and 6 (RGBA)
//  - bit depths 8 and 16 (16 is downscaled to 8 on decode)
//  - all 5 PNG filter types (None/Sub/Up/Average/Paeth) per scanline
//  - multiple IDAT chunks (concatenated before inflating)
//  - CRC-32 verification on every chunk
//  - non-interlaced images only (Adam7-interlaced PNGs are rejected with a
//    clear error - screenshots and this tool's own output are never
//    interlaced)
//
// The exported API intentionally mirrors the pngjs `PNG.sync` surface this
// codebase already used (`PNG.sync.read(buffer) -> {width, height, data}`,
// `PNG.sync.write({width, height, data}) -> Buffer`, `new PNG({width,
// height})`), so callers didn't need to change beyond the require() line.

"use strict";

const zlib = require("node:zlib");

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// ---------------------------------------------------------------------------
// CRC-32 (PNG's chunk checksum), per the PNG spec's reference implementation.
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
	const table = new Uint32Array(256);
	for (let n = 0; n < 256; n += 1) {
		let c = n;
		for (let k = 0; k < 8; k += 1) {
			c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		}
		table[n] = c >>> 0;
	}
	return table;
})();

function crc32(buf) {
	let c = 0xffffffff;
	for (let i = 0; i < buf.length; i += 1) {
		c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
	}
	return (c ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

const COLOR_TYPE_CHANNELS = {
	0: 1, // grayscale
	2: 3, // RGB
	3: 1, // palette (index)
	4: 2, // grayscale + alpha
	6: 4, // RGBA
};

function readChunks(buffer) {
	if (buffer.length < 8 || !buffer.subarray(0, 8).equals(PNG_SIGNATURE)) {
		throw new Error("png.js: not a PNG file (bad signature)");
	}

	const chunks = [];
	let offset = 8;
	while (offset < buffer.length) {
		if (offset + 8 > buffer.length) {
			throw new Error("png.js: truncated chunk header");
		}
		const length = buffer.readUInt32BE(offset);
		const type = buffer.toString("ascii", offset + 4, offset + 8);
		const dataStart = offset + 8;
		const dataEnd = dataStart + length;
		if (dataEnd + 4 > buffer.length) {
			throw new Error(`png.js: truncated ${type} chunk`);
		}
		const data = buffer.subarray(dataStart, dataEnd);
		const storedCrc = buffer.readUInt32BE(dataEnd);
		const computedCrc = crc32(buffer.subarray(offset + 4, dataEnd));
		if (storedCrc !== computedCrc) {
			throw new Error(`png.js: CRC mismatch in ${type} chunk`);
		}
		chunks.push({ type, data });
		offset = dataEnd + 4;
		if (type === "IEND") break;
	}
	return chunks;
}

function paeth(a, b, c) {
	const p = a + b - c;
	const pa = Math.abs(p - a);
	const pb = Math.abs(p - b);
	const pc = Math.abs(p - c);
	if (pa <= pb && pa <= pc) return a;
	if (pb <= pc) return b;
	return c;
}

// Undoes per-scanline filtering in place on `raw` (bytesPerPixel-aware,
// operates on whole bytes even for bit depths < 8 - the filter byte and
// unfiltering algorithm are defined on bytes, not samples/pixels).
function unfilter(raw, height, bytesPerPixel, bytesPerRow) {
	const out = Buffer.alloc(height * bytesPerRow);
	let rawOffset = 0;
	let prevRowStart = -1;
	for (let y = 0; y < height; y += 1) {
		const filterType = raw[rawOffset];
		rawOffset += 1;
		const rowStart = y * bytesPerRow;
		for (let i = 0; i < bytesPerRow; i += 1) {
			const x = raw[rawOffset + i];
			const a = i >= bytesPerPixel ? out[rowStart + i - bytesPerPixel] : 0;
			const b = prevRowStart >= 0 ? out[prevRowStart + i] : 0;
			const c =
				prevRowStart >= 0 && i >= bytesPerPixel
					? out[prevRowStart + i - bytesPerPixel]
					: 0;
			let value;
			switch (filterType) {
				case 0: // None
					value = x;
					break;
				case 1: // Sub
					value = x + a;
					break;
				case 2: // Up
					value = x + b;
					break;
				case 3: // Average
					value = x + ((a + b) >> 1);
					break;
				case 4: // Paeth
					value = x + paeth(a, b, c);
					break;
				default:
					throw new Error(`png.js: unknown filter type ${filterType}`);
			}
			out[rowStart + i] = value & 0xff;
		}
		rawOffset += bytesPerRow;
		prevRowStart = rowStart;
	}
	return out;
}

// Reads one sample (grayscale/palette-index/channel value) of `bitDepth`
// bits starting at bit position `bitOffset` within `row`.
function readSample(row, bitOffset, bitDepth) {
	if (bitDepth === 8) return row[bitOffset >> 3];
	if (bitDepth === 16) {
		const byteOffset = bitOffset >> 3;
		return (row[byteOffset] << 8) | row[byteOffset + 1];
	}
	// bitDepth < 8: pack multiple samples per byte, MSB first.
	const byteOffset = bitOffset >> 3;
	const bitInByte = bitOffset & 7;
	const shift = 8 - bitDepth - bitInByte;
	const mask = (1 << bitDepth) - 1;
	return (row[byteOffset] >> shift) & mask;
}

function decode(buffer) {
	const chunks = readChunks(buffer);
	const ihdr = chunks.find((c) => c.type === "IHDR");
	if (!ihdr) throw new Error("png.js: missing IHDR chunk");

	const width = ihdr.data.readUInt32BE(0);
	const height = ihdr.data.readUInt32BE(4);
	const bitDepth = ihdr.data.readUInt8(8);
	const colorType = ihdr.data.readUInt8(9);
	const interlace = ihdr.data.readUInt8(12);

	if (interlace !== 0) {
		throw new Error("png.js: interlaced (Adam7) PNGs are not supported");
	}
	const channels = COLOR_TYPE_CHANNELS[colorType];
	if (channels === undefined) {
		throw new Error(`png.js: unsupported color type ${colorType}`);
	}
	if (![1, 2, 4, 8, 16].includes(bitDepth)) {
		throw new Error(`png.js: unsupported bit depth ${bitDepth}`);
	}
	if (colorType === 3 && bitDepth === 16) {
		throw new Error("png.js: palette images must not use 16-bit depth");
	}

	let palette = null;
	let paletteAlpha = null;
	if (colorType === 3) {
		const plte = chunks.find((c) => c.type === "PLTE");
		if (!plte) throw new Error("png.js: palette color type missing PLTE");
		palette = plte.data;
		const trns = chunks.find((c) => c.type === "tRNS");
		if (trns) paletteAlpha = trns.data;
	}

	const idatData = Buffer.concat(
		chunks.filter((c) => c.type === "IDAT").map((c) => c.data)
	);
	const inflated = zlib.inflateSync(idatData);

	const bitsPerPixel = channels * bitDepth;
	const bytesPerPixel = Math.max(1, bitsPerPixel >> 3);
	const bytesPerRow = Math.ceil((width * bitsPerPixel) / 8);
	const raw = unfilter(inflated, height, bytesPerPixel, bytesPerRow);

	const data = Buffer.alloc(width * height * 4);
	for (let y = 0; y < height; y += 1) {
		const rowStart = y * bytesPerRow;
		const row = raw.subarray(rowStart, rowStart + bytesPerRow);
		for (let x = 0; x < width; x += 1) {
			const outIdx = (y * width + x) * 4;
			const bitOffset = x * bitsPerPixel;

			let r, g, b, a;
			if (colorType === 0) {
				const v = readSample(row, bitOffset, bitDepth);
				const scaled = downscale(v, bitDepth);
				r = g = b = scaled;
				a = 255;
			} else if (colorType === 2) {
				r = downscale(readSample(row, bitOffset, bitDepth), bitDepth);
				g = downscale(
					readSample(row, bitOffset + bitDepth, bitDepth),
					bitDepth
				);
				b = downscale(
					readSample(row, bitOffset + 2 * bitDepth, bitDepth),
					bitDepth
				);
				a = 255;
			} else if (colorType === 3) {
				const index = readSample(row, bitOffset, bitDepth);
				r = palette[index * 3];
				g = palette[index * 3 + 1];
				b = palette[index * 3 + 2];
				a =
					paletteAlpha && index < paletteAlpha.length
						? paletteAlpha[index]
						: 255;
			} else if (colorType === 4) {
				const v = downscale(readSample(row, bitOffset, bitDepth), bitDepth);
				r = g = b = v;
				a = downscale(
					readSample(row, bitOffset + bitDepth, bitDepth),
					bitDepth
				);
			} else {
				// colorType === 6
				r = downscale(readSample(row, bitOffset, bitDepth), bitDepth);
				g = downscale(
					readSample(row, bitOffset + bitDepth, bitDepth),
					bitDepth
				);
				b = downscale(
					readSample(row, bitOffset + 2 * bitDepth, bitDepth),
					bitDepth
				);
				a = downscale(
					readSample(row, bitOffset + 3 * bitDepth, bitDepth),
					bitDepth
				);
			}

			data[outIdx] = r;
			data[outIdx + 1] = g;
			data[outIdx + 2] = b;
			data[outIdx + 3] = a;
		}
	}

	return { width, height, data };
}

// Scales an n-bit sample up to 8 bits (0..255), matching pngjs/libpng's
// "multiply up" behaviour (bit-replication, not a plain shift, so 16-bit
// downscales and sub-8-bit depths round the same way).
function downscale(value, bitDepth) {
	if (bitDepth === 8) return value;
	const maxIn = bitDepth === 16 ? 65535 : (1 << bitDepth) - 1;
	return Math.floor((value * 255) / maxIn + 0.5);
}

// ---------------------------------------------------------------------------
// Encode (always writes 8-bit RGBA, color type 6, filter type 0/None per row)
// ---------------------------------------------------------------------------

function chunk(type, data) {
	const typeBuf = Buffer.from(type, "ascii");
	const length = Buffer.alloc(4);
	length.writeUInt32BE(data.length, 0);
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
	return Buffer.concat([length, typeBuf, data, crc]);
}

function encode({ width, height, data }) {
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(width, 0);
	ihdr.writeUInt32BE(height, 4);
	ihdr.writeUInt8(8, 8); // bit depth
	ihdr.writeUInt8(6, 9); // color type: RGBA
	ihdr.writeUInt8(0, 10); // compression method
	ihdr.writeUInt8(0, 11); // filter method
	ihdr.writeUInt8(0, 12); // interlace method

	const bytesPerRow = width * 4;
	const raw = Buffer.alloc(height * (bytesPerRow + 1));
	for (let y = 0; y < height; y += 1) {
		const rawRowStart = y * (bytesPerRow + 1);
		raw[rawRowStart] = 0; // filter type: None
		data.copy(
			raw,
			rawRowStart + 1,
			y * bytesPerRow,
			y * bytesPerRow + bytesPerRow
		);
	}

	const idat = zlib.deflateSync(raw, { level: 9 });

	return Buffer.concat([
		PNG_SIGNATURE,
		chunk("IHDR", ihdr),
		chunk("IDAT", idat),
		chunk("IEND", Buffer.alloc(0)),
	]);
}

// ---------------------------------------------------------------------------
// pngjs-compatible API
// ---------------------------------------------------------------------------

class PNG {
	constructor({ width = 0, height = 0 } = {}) {
		this.width = width;
		this.height = height;
		this.data = Buffer.alloc(width * height * 4);
	}
}

PNG.sync = {
	read(buffer) {
		const { width, height, data } = decode(buffer);
		const png = new PNG({ width, height });
		png.data = data;
		return png;
	},
	write(png) {
		return encode(png);
	},
};

module.exports = { PNG, decode, encode };
