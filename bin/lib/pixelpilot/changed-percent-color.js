// Maps a screenshot diff's changed_percent to a Grafana-gauge-style color:
// green at 0% shading continuously to red at 30%+ changed. Used to color the
// "N.NN% changed" badges in both the sidebar (rendered here, at generation
// time, by review-html.js) and the header (re-rendered client-side per
// selected scenario by review-page.js, which keeps its own small duplicate
// of this function - see the comment there - since that script is injected
// into the page as a plain <script> body, not require()'d).
//
// The mapping uses HSL hue 120 (green) -> 0 (red), with percent clamped to
// [0, 30] before mapping so anything at or beyond 30% changed reads as fully
// red. A sqrt curve is applied to the clamped fraction so hue drops faster
// at low percentages - a 1-5% change already reads as yellowish-green rather
// than staying a reassuring green, which is the point of the gauge.
"use strict";

const MAX_PERCENT = 30;

function clamp(value, lo, hi) {
	return Math.max(lo, Math.min(hi, value));
}

// Standard HSL -> sRGB (0-255) conversion.
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

	return [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255];
}

// WCAG relative luminance, used to decide readable (dark vs white) text.
function relativeLuminance([r, g, b]) {
	const channel = (c) => {
		const cs = c / 255;
		return cs <= 0.03928 ? cs / 12.92 : ((cs + 0.055) / 1.055) ** 2.4;
	};
	const [rl, gl, bl] = [channel(r), channel(g), channel(b)];
	return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl;
}

function textColorFor(rgb) {
	// Empirically, these badge hues/lightnesses split cleanly around this
	// threshold; above it a dark label reads better, below it white does.
	return relativeLuminance(rgb) > 0.42 ? "#111111" : "#ffffff";
}

function colorForHsl(hue, saturation, lightness) {
	const rgb = hslToRgb(hue, saturation, lightness);
	return {
		hue,
		saturation,
		lightness,
		background: `hsl(${hue.toFixed(1)}, ${saturation}%, ${lightness}%)`,
		color: textColorFor(rgb),
	};
}

// Returns null for non-numeric input (callers use this for scenarios that
// have no changed_percent at all, e.g. new/removed, or a size-mismatch-only
// badge - those keep their own fixed styling instead).
function changedPercentColor(percent) {
	if (typeof percent !== "number" || Number.isNaN(percent)) return null;

	if (percent <= 0) {
		// "identical" gets a calm, slightly desaturated green rather than the
		// most vivid green on the gradient.
		return colorForHsl(120, 35, 38);
	}

	const clamped = clamp(percent, 0, MAX_PERCENT);
	const t = Math.sqrt(clamped / MAX_PERCENT);
	const hue = 120 - 120 * t;
	return colorForHsl(hue, 70, 45);
}

module.exports = {
	changedPercentColor,
};
