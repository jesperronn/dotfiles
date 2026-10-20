// Change-region extraction (Regions diff view).
//
// Reuses the heatmap's unblurred change-density grid (16px blocks, see
// computeDensityGrid in tools/screenshot/heatmap.js) to find distinct
// "regions" of change on the padded diff canvas: connected groups of blocks
// that have any changed pixels, merged across a 1-block gap so changes
// within about one block-width (~16px) of each other read as one region
// instead of many slivers.
//
// This module is deliberately pure/synchronous, like heatmap.js - callers in
// cli.js decide how the resulting regions get into the manifest.
"use strict";

const { PNG } = require("./png");
const { computeDensityGrid, BLOCK_SIZE } = require("./heatmap");

// A block counts as "changed" once it has more than this fraction of
// changed pixels. 0 means "any changed pixel in the block at all" - the
// task's "density > 0, or a small constant" default.
const DEFAULT_DENSITY_THRESHOLD = 0;

// Regions with fewer than this many total changed pixels are dropped as
// noise (the task's "fewer than N changed pixels, e.g. 20").
const DEFAULT_MIN_CHANGED_PIXELS = 20;

// The pixel bounds (on the padded canvas) of block (bx, by), sized down at
// the grid's right/bottom edge exactly like computeDensityGrid does.
function blockBounds(bx, by, blockSize, width, height) {
	const x0 = bx * blockSize;
	const y0 = by * blockSize;
	const x1 = Math.min(width, x0 + blockSize);
	const y1 = Math.min(height, y0 + blockSize);
	return { x0, y0, x1, y1 };
}

// Connected-components labeling over a boolean `mask` (cols x rows,
// row-major): two hot cells are in the same component when they're within
// Chebyshev distance 2 of each other (an 8-neighbourhood connection, PLUS a
// 1-block dilation - i.e. one empty block of gap between them still joins
// them, since that gap is exactly Chebyshev distance 2). Only ever walks
// between cells that are themselves hot - a chain of two separate blobs
// that don't individually come within that gap of each other never merges
// through the empty space between them. Returns an Int32Array of component
// ids, -1 for cells not in the mask.
function labelComponents(mask, cols, rows) {
	const labels = new Int32Array(cols * rows).fill(-1);
	let nextLabel = 0;

	for (let start = 0; start < mask.length; start += 1) {
		if (!mask[start] || labels[start] !== -1) continue;

		const label = nextLabel;
		nextLabel += 1;
		const stack = [start];
		labels[start] = label;

		while (stack.length) {
			const idx = stack.pop();
			const x = idx % cols;
			const y = Math.floor(idx / cols);

			for (let dy = -2; dy <= 2; dy += 1) {
				const ny = y + dy;
				if (ny < 0 || ny >= rows) continue;
				for (let dx = -2; dx <= 2; dx += 1) {
					if (dx === 0 && dy === 0) continue;
					const nx = x + dx;
					if (nx < 0 || nx >= cols) continue;
					const nIdx = ny * cols + nx;
					if (mask[nIdx] && labels[nIdx] === -1) {
						labels[nIdx] = label;
						stack.push(nIdx);
					}
				}
			}
		}
	}

	return { labels, count: nextLabel };
}

// Extracts regions from an already-computed density grid (see
// computeDensityGrid in heatmap.js) plus the canvas size the grid was built
// from. Returns regions sorted by changed_pixels descending, numbered
// #1..n, each as { id, x, y, w, h, changed_pixels, changed_percent }
// (x/y/w/h are pixel coordinates/size on the padded canvas).
function extractRegionsFromGrid(grid, width, height, options = {}) {
	const {
		blockSize = BLOCK_SIZE,
		densityThreshold = DEFAULT_DENSITY_THRESHOLD,
		minChangedPixels = DEFAULT_MIN_CHANGED_PIXELS,
	} = options;

	const { cols, rows, values } = grid;
	const hot = new Uint8Array(cols * rows);
	for (let i = 0; i < values.length; i += 1) {
		hot[i] = values[i] > densityThreshold ? 1 : 0;
	}

	// Merge blocks within a 1-block gap: labelComponents already treats hot
	// cells within Chebyshev distance 2 (8-neighbourhood + 1-block dilation)
	// as connected.
	const { labels, count } = labelComponents(hot, cols, rows);

	const groups = new Map(); // label -> accumulator

	for (let by = 0; by < rows; by += 1) {
		for (let bx = 0; bx < cols; bx += 1) {
			const idx = by * cols + bx;
			if (!hot[idx]) continue; // only original hot blocks contribute stats

			const label = labels[idx];
			if (label === -1) continue; // unreachable: hot implies dilated

			const bounds = blockBounds(bx, by, blockSize, width, height);
			const blockPixels = (bounds.x1 - bounds.x0) * (bounds.y1 - bounds.y0);
			const changedInBlock = Math.round(values[idx] * blockPixels);

			let group = groups.get(label);
			if (!group) {
				group = {
					x0: bounds.x0,
					y0: bounds.y0,
					x1: bounds.x1,
					y1: bounds.y1,
					changedPixels: 0,
				};
				groups.set(label, group);
			}
			group.x0 = Math.min(group.x0, bounds.x0);
			group.y0 = Math.min(group.y0, bounds.y0);
			group.x1 = Math.max(group.x1, bounds.x1);
			group.y1 = Math.max(group.y1, bounds.y1);
			group.changedPixels += changedInBlock;
		}
	}

	void count; // only used to size labelComponents' internal loop; not needed here

	const regions = Array.from(groups.values())
		.filter((group) => group.changedPixels >= minChangedPixels)
		.map((group) => {
			const w = group.x1 - group.x0;
			const h = group.y1 - group.y0;
			const area = w * h;
			return {
				x: group.x0,
				y: group.y0,
				w,
				h,
				changed_pixels: group.changedPixels,
				changed_percent: area === 0 ? 0 : (group.changedPixels / area) * 100,
			};
		})
		.sort((a, b) => b.changed_pixels - a.changed_pixels)
		.map((region, index) => ({ id: index + 1, ...region }));

	return regions;
}

// End-to-end helper mirroring computeHeatGrid/buildHeatmapPng: builds the
// (unblurred) density grid from a diff buffer's raw pixel data and extracts
// regions from it in one call.
function extractRegions(diffData, width, height, options = {}) {
	const { blockSize = BLOCK_SIZE } = options;
	const grid = computeDensityGrid(diffData, width, height, blockSize);
	return extractRegionsFromGrid(grid, width, height, options);
}

// Convenience wrapper matching buildHeatmapPng's calling convention: given a
// decoded diff PNG buffer (as produced by computeDiff's diffBuffer), returns
// the regions found on it. This is what cli.js calls.
function buildRegions(diffBuffer, options = {}) {
	const diff = PNG.sync.read(diffBuffer);
	return extractRegions(diff.data, diff.width, diff.height, options);
}

module.exports = {
	DEFAULT_DENSITY_THRESHOLD,
	DEFAULT_MIN_CHANGED_PIXELS,
	extractRegionsFromGrid,
	extractRegions,
	buildRegions,
};
