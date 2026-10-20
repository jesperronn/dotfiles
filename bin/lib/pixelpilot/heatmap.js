// Change-density heatmap generation (prototype).
//
// From a pixelmatch diff (the same padded-canvas diff pixel-diff.js already
// computes), builds a coarse density grid - one value per 16x16 block, the
// fraction of that block's pixels which were flagged as changed - lightly
// box-blurred so it reads as heat rather than discrete tiles, then renders it
// as a same-size, mostly-transparent PNG using the same green->red ramp as
// changedPercentColor (tools/screenshot/changed-percent-color.js), so the
// heatmap's colors always match the "% changed" badges.
//
// This module is deliberately pure/synchronous and has no knowledge of
// cli.js's file layout - callers there decide where to write the
// resulting PNG.

"use strict";

const { PNG } = require("./png");
const { changedPercentColor } = require("./changed-percent-color");

// Block size in pixels for the density grid. A constant per the task, so it
// can be tuned in one place.
const BLOCK_SIZE = 16;

// Below this density, a block still gets the minimum visible alpha (as long
// as it isn't exactly zero) so a lightly-changed region isn't blurred away to
// invisibility. Fully unchanged blocks stay alpha 0.
const MIN_VISIBLE_ALPHA = 90;
const MAX_ALPHA = 230;

// A diff PNG produced with PIXELMATCH_OPTIONS' diffMask: true is fully
// transparent (alpha 0) wherever the two images matched, and opaque
// (alpha 255) wherever pixelmatch (or the padding fill) flagged a change -
// so alpha alone tells us whether a given diff pixel counts as "changed".
function isChangedPixel(diffData, idx) {
	return diffData[idx + 3] !== 0;
}

// Splits a diffBuffer (RGBA, `width` x `height`, as produced by
// computeDiff/pixelmatch) into BLOCK_SIZE x BLOCK_SIZE blocks and returns a
// dense { cols, rows, values } grid of changed-pixel fractions (0..1), one
// value per block, row-major. Edge blocks (when width/height isn't an exact
// multiple of BLOCK_SIZE) are sized down to whatever remains, and their
// fraction is still relative to their own (smaller) pixel count.
function computeDensityGrid(diffData, width, height, blockSize = BLOCK_SIZE) {
	const cols = Math.max(1, Math.ceil(width / blockSize));
	const rows = Math.max(1, Math.ceil(height / blockSize));
	const values = new Array(cols * rows).fill(0);

	for (let by = 0; by < rows; by += 1) {
		const y0 = by * blockSize;
		const y1 = Math.min(height, y0 + blockSize);
		for (let bx = 0; bx < cols; bx += 1) {
			const x0 = bx * blockSize;
			const x1 = Math.min(width, x0 + blockSize);

			const blockPixels = (x1 - x0) * (y1 - y0);
			let changed = 0;
			if (blockPixels > 0) {
				for (let y = y0; y < y1; y += 1) {
					const rowStart = (y * width) << 2;
					for (let x = x0; x < x1; x += 1) {
						if (isChangedPixel(diffData, rowStart + (x << 2))) changed += 1;
					}
				}
			}

			values[by * cols + bx] = blockPixels === 0 ? 0 : changed / blockPixels;
		}
	}

	return { cols, rows, values };
}

// One pass of a 3x3 box blur over a dense (cols x rows) grid of values,
// clamped to the grid edges (edge/corner cells average over fewer
// neighbours rather than treating out-of-bounds as 0, so density doesn't
// artificially fade at the canvas border). Returns a new values array; the
// input is left untouched so callers can run multiple passes.
function boxBlur3x3(grid) {
	const { cols, rows, values } = grid;
	const out = new Array(cols * rows).fill(0);

	for (let y = 0; y < rows; y += 1) {
		for (let x = 0; x < cols; x += 1) {
			let sum = 0;
			let count = 0;
			for (let dy = -1; dy <= 1; dy += 1) {
				const ny = y + dy;
				if (ny < 0 || ny >= rows) continue;
				for (let dx = -1; dx <= 1; dx += 1) {
					const nx = x + dx;
					if (nx < 0 || nx >= cols) continue;
					sum += values[ny * cols + nx];
					count += 1;
				}
			}
			out[y * cols + x] = count === 0 ? 0 : sum / count;
		}
	}

	return { cols, rows, values: out };
}

// Computes the (already blurred) density grid for a diff buffer: builds the
// raw per-block density grid, then applies `passes` box-blur passes (default
// 2, per the task's "one or two passes"). All values stay within [0, 1]
// since both the raw fractions and every blur pass are plain averages of
// values already in that range.
function computeHeatGrid(
	diffData,
	width,
	height,
	{ blockSize = BLOCK_SIZE, passes = 2 } = {}
) {
	let grid = computeDensityGrid(diffData, width, height, blockSize);
	for (let i = 0; i < passes; i += 1) {
		grid = boxBlur3x3(grid);
	}
	return grid;
}

// Renders a density grid as a same-size (`width` x `height`) RGBA PNG
// buffer: each block's color comes from changedPercentColor (reusing the
// exact same green->red ramp as the "% changed" badges - changedPercentColor
// expects a 0-30 percent scale, so density [0,1] is scaled to [0,100] and
// then clamped by changedPercentColor itself), and its alpha scales with
// density - zero density is fully transparent, any density above zero gets
// at least MIN_VISIBLE_ALPHA so a faint change isn't blurred into
// invisibility, up to MAX_ALPHA at density 1.
function renderHeatmapPng(grid, width, height, blockSize = BLOCK_SIZE) {
	const { cols, values } = grid;
	const png = new PNG({ width, height });

	for (let y = 0; y < height; y += 1) {
		const by = Math.min(grid.rows - 1, Math.floor(y / blockSize));
		for (let x = 0; x < width; x += 1) {
			const bx = Math.min(cols - 1, Math.floor(x / blockSize));
			const density = values[by * cols + bx];
			const idx = (y * width + x) << 2;

			if (density <= 0) {
				png.data[idx] = 0;
				png.data[idx + 1] = 0;
				png.data[idx + 2] = 0;
				png.data[idx + 3] = 0;
				continue;
			}

			// changedPercentColor works in percent-changed (0-30+) space; density
			// is a 0..1 fraction, so use the same 0-100 "percent" framing (density
			// 1 == 100% of the block changed) - changedPercentColor's own 30%
			// ceiling still gives the fast-reddening curve for anything at/above
			// 30% block density.
			const color = changedPercentColor(density * 100);
			const [r, g, b] = hexOrHslToRgb(color.background);
			const alpha = Math.round(
				MIN_VISIBLE_ALPHA +
					(MAX_ALPHA - MIN_VISIBLE_ALPHA) * Math.min(1, density)
			);

			png.data[idx] = r;
			png.data[idx + 1] = g;
			png.data[idx + 2] = b;
			png.data[idx + 3] = alpha;
		}
	}

	return PNG.sync.write(png);
}

// changedPercentColor returns its background as an `hsl(h, s%, l%)` string
// (see changed-percent-color.js) - parse that back into 0-255 RGB for the
// PNG buffer rather than duplicating the HSL math here.
function hexOrHslToRgb(hslString) {
	const match = /^hsl\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%\s*\)$/.exec(
		hslString
	);
	if (!match) return [255, 0, 0];
	const [, h, s, l] = match.map(Number);
	return hslToRgb(h, s, l);
}

function hslToRgb(h, s, l) {
	const hue = ((h % 360) + 360) % 360;
	const sat = s / 100;
	const light = l / 100;
	const c = (1 - Math.abs(2 * light - 1)) * sat;
	const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
	const m = light - c / 2;
	let r1, g1, b1;
	if (hue < 60) [r1, g1, b1] = [c, x, 0];
	else if (hue < 120) [r1, g1, b1] = [x, c, 0];
	else if (hue < 180) [r1, g1, b1] = [0, c, x];
	else if (hue < 240) [r1, g1, b1] = [0, x, c];
	else if (hue < 300) [r1, g1, b1] = [x, 0, c];
	else [r1, g1, b1] = [c, 0, x];
	return [
		Math.round((r1 + m) * 255),
		Math.round((g1 + m) * 255),
		Math.round((b1 + m) * 255),
	];
}

// Convenience end-to-end helper: given a decoded diff PNG buffer (as
// produced by computeDiff's diffBuffer), returns a heatmap PNG buffer of the
// same dimensions. This is what cli.js calls.
function buildHeatmapPng(
	diffBuffer,
	{ blockSize = BLOCK_SIZE, passes = 2 } = {}
) {
	const diff = PNG.sync.read(diffBuffer);
	const grid = computeHeatGrid(diff.data, diff.width, diff.height, {
		blockSize,
		passes,
	});
	return renderHeatmapPng(grid, diff.width, diff.height, blockSize);
}

module.exports = {
	BLOCK_SIZE,
	computeDensityGrid,
	boxBlur3x3,
	computeHeatGrid,
	renderHeatmapPng,
	buildHeatmapPng,
};
