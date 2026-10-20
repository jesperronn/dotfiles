// Pixel diff computation for the screenshot review overlay (task 5c).
//
// Wraps pixelmatch + pngjs: decodes two PNG buffers and computes a diff PNG
// (red pixels where they differ) plus changed_pixels/changed_percent counts.
//
// Real screenshots routinely differ in size (different viewport, or a
// full-page capture whose height depends on page content), so this no
// longer bails out on a size mismatch. Instead both images are conceptually
// padded, anchored top-left, onto a shared canvas sized
// max(widthA, widthB) x max(heightA, heightB). The padding - the area
// outside whichever image is smaller in that dimension - has no real pixel
// data on one side, so every padded pixel counts as changed rather than
// being compared. The overlapping top-left rectangle (min(widthA, widthB) x
// min(heightA, heightB), which is the whole image when sizes match) is
// compared pixel-by-pixel with pixelmatch as before. changed_percent is
// always relative to the full padded canvas, so a size mismatch is reflected
// in the percentage too, not just in the `sizeMismatch` note.

const { PNG } = require("./png");
const pixelmatch = require("./pixelmatch");

// includeAA: false ignores anti-aliased pixels so font/edge rendering noise
// doesn't dominate the diff. threshold is pixelmatch's per-pixel matching
// sensitivity (0-1, lower is stricter); 0.1 is pixelmatch's own documented
// default and works well for screenshot-style UI comparisons. diffMask:
// true makes matching pixels fully transparent in the output, so the diff
// PNG can be laid over the current screenshot as an overlay (mix-blend-mode
// screen) and only the changed pixels show through.
const PIXELMATCH_OPTIONS = { includeAA: false, threshold: 0.1, diffMask: true };

// Solid, opaque red - matches pixelmatch's own default diffColor - used to
// mark the padded (out-of-bounds-for-one-side) region of the diff canvas as
// changed, since there is no real pixel data there to run pixelmatch on.
const PADDING_DIFF_COLOR = [255, 0, 0, 255];

// Copies the top-left `width` x `height` rectangle out of a decoded PNG
// (which may be larger) into a fresh, tightly-packed RGBA buffer that
// pixelmatch can compare directly.
function extractRegion(png, width, height) {
	const out = Buffer.alloc(width * height * 4);
	if (width === 0 || height === 0) return out;
	const rowBytes = width * 4;
	for (let y = 0; y < height; y += 1) {
		const srcStart = y * png.width * 4;
		png.data.copy(out, y * rowBytes, srcStart, srcStart + rowBytes);
	}
	return out;
}

function computeDiff(currentBuffer, baselineBuffer) {
	const current = PNG.sync.read(currentBuffer);
	const baseline = PNG.sync.read(baselineBuffer);

	const sizeMismatch =
		current.width !== baseline.width || current.height !== baseline.height;

	const width = Math.max(current.width, baseline.width);
	const height = Math.max(current.height, baseline.height);
	const overlapWidth = Math.min(current.width, baseline.width);
	const overlapHeight = Math.min(current.height, baseline.height);

	const totalPixels = width * height;
	const overlapPixels = overlapWidth * overlapHeight;
	const paddingPixels = totalPixels - overlapPixels;

	const diff = new PNG({ width, height });

	let overlapChangedPixels = 0;
	if (overlapWidth > 0 && overlapHeight > 0) {
		const currentRegion = extractRegion(current, overlapWidth, overlapHeight);
		const baselineRegion = extractRegion(baseline, overlapWidth, overlapHeight);
		const regionDiff = Buffer.alloc(overlapWidth * overlapHeight * 4);

		overlapChangedPixels = pixelmatch(
			currentRegion,
			baselineRegion,
			regionDiff,
			overlapWidth,
			overlapHeight,
			PIXELMATCH_OPTIONS
		);

		const rowBytes = overlapWidth * 4;
		for (let y = 0; y < overlapHeight; y += 1) {
			regionDiff.copy(
				diff.data,
				y * width * 4,
				y * rowBytes,
				y * rowBytes + rowBytes
			);
		}
	}

	// Anything outside the overlap rectangle exists in at most one of the two
	// images (that's the definition of padding here) - there's nothing to
	// compare it against, so it always counts as changed.
	if (paddingPixels > 0) {
		for (let y = 0; y < height; y += 1) {
			for (let x = 0; x < width; x += 1) {
				if (x >= overlapWidth || y >= overlapHeight) {
					const idx = (y * width + x) * 4;
					diff.data[idx] = PADDING_DIFF_COLOR[0];
					diff.data[idx + 1] = PADDING_DIFF_COLOR[1];
					diff.data[idx + 2] = PADDING_DIFF_COLOR[2];
					diff.data[idx + 3] = PADDING_DIFF_COLOR[3];
				}
			}
		}
	}

	const changedPixels = overlapChangedPixels + paddingPixels;
	const changedPercent =
		totalPixels === 0 ? 0 : (changedPixels / totalPixels) * 100;

	return {
		sizeMismatch,
		width,
		height,
		currentWidth: current.width,
		currentHeight: current.height,
		baselineWidth: baseline.width,
		baselineHeight: baseline.height,
		changedPixels,
		changedPercent,
		diffBuffer: PNG.sync.write(diff),
	};
}

module.exports = {
	computeDiff,
	PIXELMATCH_OPTIONS,
};
