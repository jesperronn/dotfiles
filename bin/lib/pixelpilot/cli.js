#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const { computeDiff } = require("./pixel-diff");
const { buildHeatmapPng } = require("./heatmap");
const { buildRegions } = require("./regions");
const { renderReviewHtml } = require("./review-html");

// Config file precedence: CLI flags > config file > built-in defaults.
// The config file is either ./screenshot-review.config.json in the current
// working directory, or a "screenshotReview" key in ./package.json. The
// config file is optional; a missing/unparseable one is silently ignored so
// the tool keeps working with just CLI flags and defaults.
const CONFIG_FILE_NAME = "screenshot-review.config.json";

const CONFIG_KEYS = {
	baseline: "baseline",
	currentDir: "currentDir",
	currentRef: "currentRef",
	baselineDir: "baselineDir",
	outputHtml: "outputHtml",
	title: "title",
	screenshotsDir: "screenshotsDir",
};

function printUsage() {
	const usage = `Usage: pixelpilot [options]

Options:
  --baseline <ref>, --from <ref>
                                git ref to extract the baseline from
                                (config: baseline, default: HEAD)
  --current-ref <ref>, --to <ref>
                                git ref to extract the "current" side from
                                (config: currentRef); mutually exclusive
                                with --current-dir
  --current-dir <path>          directory of current capture PNGs
                                (config: currentDir, default: tmp/screenshot-output;
                                mutually exclusive with --current-ref)
  --baseline-dir <path>         scratch dir the baseline is extracted into
                                (config: baselineDir, default: tmp/screenshot-review/baseline/<ref>)
  --output-html <path>          where the review HTML page is written
                                (config: outputHtml, default: tmp/screenshot-review/index.html)
  --screenshots-dir <path>      git-tracked directory the baseline PNGs are read from
                                (config: screenshotsDir, default: doc/screenshots)
  --title <text>                page <title> and on-page heading
                                (config: title, default: Screenshot Review)
  --help, -h                    show this help message

Configuration file layering (highest precedence first):
  1. CLI flags
  2. Config file: screenshot-review.config.json (in current directory) or
     "screenshotReview" key in package.json (dedicated file wins if both exist)
  3. Built-in defaults

Example:
  pixelpilot --baseline HEAD --current-dir ./captures --output-html ./review.html
  pixelpilot --from v20.0.0 --to v21.1.0
`;
	process.stdout.write(usage);
}

function readJsonFileIfExists(filePath) {
	try {
		return JSON.parse(fs.readFileSync(filePath, "utf8"));
	} catch {
		return null;
	}
}

function loadConfigFile(cwd = process.cwd()) {
	const dedicated = readJsonFileIfExists(path.join(cwd, CONFIG_FILE_NAME));
	if (dedicated) return dedicated;

	const pkg = readJsonFileIfExists(path.join(cwd, "package.json"));
	if (pkg?.screenshotReview && typeof pkg.screenshotReview === "object") {
		return pkg.screenshotReview;
	}

	return {};
}

function parseArgs(argv, { config = loadConfigFile() } = {}) {
	const options = {};

	Object.entries(CONFIG_KEYS).forEach(([optionKey, configKey]) => {
		if (config && config[configKey] !== undefined) {
			options[optionKey] = config[configKey];
		}
	});

	if (options.baseline === undefined) {
		options.baseline = "HEAD";
	}

	// CLI flags override config; a CLI-given current-dir/current-ref replaces
	// a config-supplied one of the other kind instead of conflicting with it.
	let cliCurrentDir = false;
	let cliCurrentRef = false;

	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		const next = argv[index + 1];

		switch (arg) {
			case "--help":
			case "-h":
				printUsage();
				process.exit(0);
				break;
			case "--current-dir":
				options.currentDir = next;
				cliCurrentDir = true;
				index += 1;
				break;
			case "--baseline-dir":
				options.baselineDir = next;
				index += 1;
				break;
			case "--output-html":
				options.outputHtml = next;
				index += 1;
				break;
			case "--current-ref":
			case "--to":
				options.currentRef = next;
				cliCurrentRef = true;
				index += 1;
				break;
			case "--from":
			case "--baseline":
				options.baseline = next;
				index += 1;
				break;
			case "--title":
				options.title = next;
				index += 1;
				break;
			case "--screenshots-dir":
				options.screenshotsDir = next;
				index += 1;
				break;
			default:
				throw new Error(
					`Unknown option: ${arg}. Use --help for usage information.`
				);
		}
	}

	if (cliCurrentRef && !cliCurrentDir) delete options.currentDir;
	if (cliCurrentDir && !cliCurrentRef) delete options.currentRef;
	if (options.currentRef !== undefined && options.currentDir !== undefined) {
		throw new Error(
			"--current-ref (--to) and --current-dir are mutually exclusive: " +
				"use --current-ref to compare two git refs, or --current-dir for a capture directory."
		);
	}

	return applyDefaults(options);
}

// doc/screenshots is the default git-tracked source directory that baseline
// PNGs are read *from* (via `git show <ref>:<screenshotsDir>/<file>`). It
// must never also be the --baseline-dir extraction target - see the guard in
// buildManifest. Overridable via --screenshots-dir / the "screenshotsDir"
// config key so this tool can be used outside this repo.
const DEFAULT_SCREENSHOTS_DIR = path.join("doc", "screenshots");

function applyDefaults(options) {
	const resolved = { ...options };

	if (!resolved.currentDir && !resolved.currentRef) {
		resolved.currentDir = path.join("tmp", "screenshot-output");
	}
	if (!resolved.screenshotsDir) {
		resolved.screenshotsDir = DEFAULT_SCREENSHOTS_DIR;
	}
	if (!resolved.baselineDir) {
		resolved.baselineDir = baselineScratchDir(resolved.baseline);
	}
	if (!resolved.outputHtml) {
		resolved.outputHtml = path.join("tmp", "screenshot-review", "index.html");
	}
	if (!resolved.title) {
		resolved.title = "Screenshot Review";
	}

	return resolved;
}

// Builds the extra args `git describe`/`git log` need to restrict matches to
// a configured tag pattern (e.g. "v[0-9]*" for semver-style tags). Always
// matches any tag now (no pattern restriction).
function describeMatchArgs() {
	return [];
}

function validateGitRef(ref) {
	try {
		execFileSync("git", ["cat-file", "-t", ref], {
			encoding: "utf8",
			stdio: ["pipe", "pipe", "pipe"],
		});
	} catch {
		throw new Error(`Invalid git reference: ${ref}`);
	}
}

// Directory names must not contain slashes or other path-breaking characters,
// since a ref (branch name, tag) can contain "/" (e.g. "origin/main").
function sanitizeRefForPath(ref) {
	return ref.replace(/[^A-Za-z0-9._-]+/g, "-");
}

// Where extracted baseline PNGs for a given ref are written. Always a scratch
// location under tmp/ - never doc/screenshots, which is the tracked directory
// these images are extracted *from*. Writing into doc/screenshots would (a)
// dirty the working tree on every review run, and (b) silently substitute the
// current on-disk file whenever a screenshot doesn't exist at the ref, since
// leftover files from a previous run (or the committed current copy) would
// still be sitting there looking like a legitimate baseline.
function baselineScratchDir(ref) {
	return path.join(
		"tmp",
		"screenshot-review",
		"baseline",
		sanitizeRefForPath(ref)
	);
}

// Scratch dir the "current" side is extracted into when --current-ref is used.
function currentScratchDir(ref) {
	return path.join(
		"tmp",
		"screenshot-review",
		"current",
		sanitizeRefForPath(ref)
	);
}

function screenshotFilesAtRef(ref, screenshotsDir) {
	try {
		const output = execFileSync(
			"git",
			["ls-tree", "-r", "--name-only", ref, screenshotsDir],
			{
				encoding: "utf8",
				maxBuffer: 10 * 1024 * 1024,
				stdio: ["pipe", "pipe", "pipe"],
			}
		);
		return output
			.split("\n")
			.map((line) => line.trim())
			.filter((line) => line.endsWith(".png"));
	} catch {
		return [];
	}
}

// Extracts the doc/screenshots/*.png blobs tracked at `ref` into a fresh,
// emptied `outputDir` (expected to be a baselineScratchDir(ref), not
// doc/screenshots itself). Returns the basenames of the files that exist at
// the ref, so callers can tell "missing baseline" apart from "extraction
// failed".
function extractBaselineFromGit(ref, outputDir, screenshotsDir) {
	const screenshotFiles = screenshotFilesAtRef(ref, screenshotsDir);

	fs.rmSync(outputDir, { recursive: true, force: true });
	fs.mkdirSync(outputDir, { recursive: true });

	screenshotFiles.forEach((filePath) => {
		const fileName = path.basename(filePath);
		const outputPath = path.join(outputDir, fileName);

		try {
			const content = execFileSync("git", ["show", `${ref}:${filePath}`], {
				encoding: null,
				maxBuffer: 50 * 1024 * 1024,
				stdio: ["pipe", "pipe", "pipe"],
			});
			fs.writeFileSync(outputPath, content);
		} catch (error) {
			throw new Error(
				`Failed to extract ${filePath} from ${ref}: ${error.message}`
			);
		}
	});

	return screenshotFiles.map((filePath) => path.basename(filePath));
}

function gitDescribe(ref) {
	return execFileSync(
		"git",
		["describe", "--tags", ...describeMatchArgs(), ref],
		{ encoding: "utf8" }
	).trim();
}

function shortSha(commitSha) {
	return execFileSync("git", ["rev-parse", "--short", commitSha], {
		encoding: "utf8",
		stdio: ["pipe", "pipe", "pipe"],
	}).trim();
}

// The baseline PNGs are whatever `git show <ref>:doc/screenshots/*` last committed them as,
// which is usually an older commit than `ref` itself (ref defaults to HEAD). Describing
// `ref` would just repeat the current version on both sides of the review page, so instead
// resolve the actual commit that last touched the baseline directory at that ref.
function lastCommitTouching(ref, dirPath) {
	try {
		const output = execFileSync(
			"git",
			["log", "-1", "--format=%H", ref, "--", dirPath],
			{ encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
		).trim();
		return output || ref;
	} catch {
		return ref;
	}
}

function workingTreeDirty() {
	try {
		const output = execFileSync(
			"git",
			["status", "--porcelain", "--untracked-files=no"],
			{ encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
		);
		return output.trim().length > 0;
	} catch {
		return false;
	}
}

function isoTimestamp() {
	return new Date().toISOString();
}

// Committer date (ISO 8601) of the commit `lastCommitTouching` resolved, i.e. when the
// baseline PNGs were actually committed - not "now".
function commitDate(commitSha) {
	return execFileSync("git", ["log", "-1", "--format=%cI", commitSha], {
		encoding: "utf8",
	}).trim();
}

function pngFiles(dir) {
	return fs
		.readdirSync(dir)
		.filter((file) => file.endsWith(".png"))
		.sort();
}

// Oldest commit that added `filePath` (usually doc/screenshots/<file>), i.e.
// when that specific screenshot first showed up in the repo - not necessarily
// related to the baseline ref at all. `git log` lists newest-first, so the
// oldest add is the last line. Returns null when the file has no history yet
// (e.g. captured locally but never committed).
function firstAddCommit(filePath) {
	try {
		const output = execFileSync(
			"git",
			["log", "--diff-filter=A", "--format=%H", "--", filePath],
			{ encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
		).trim();
		if (!output) return null;
		const commits = output.split("\n").filter(Boolean);
		return commits[commits.length - 1];
	} catch {
		return null;
	}
}

// Describes when a screenshot "first appeared": the nearest tag containing
// the commit (i.e. the first tagged release it shipped in), falling back to
// any reachable tag, and finally to the short sha if the repo has no tags at
// all near that commit.
// "--contains" appends "^0" when the commit IS the tagged commit itself
// (git's "exactly this, dereferenced" notation) - strip it for a clean label.
function stripExactTagSuffix(describeOutput) {
	return describeOutput.replace(/\^0$/, "");
}

function describeFirstSeen(commitSha) {
	const matchArgs = describeMatchArgs();
	try {
		return stripExactTagSuffix(
			execFileSync(
				"git",
				["describe", "--tags", ...matchArgs, "--contains", commitSha],
				{ encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
			).trim()
		);
	} catch {
		try {
			return execFileSync(
				"git",
				["describe", "--tags", ...matchArgs, commitSha],
				{ encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
			).trim();
		} catch {
			return shortSha(commitSha);
		}
	}
}

function trackedScreenshotPath(file, screenshotsDir) {
	return path.join(screenshotsDir, file);
}

// Extracts a single tracked file as it existed at `ref` into `outputPath`.
// Used for the fallback image of a "new" scenario (its first_seen commit),
// as opposed to extractBaselineFromGit which extracts every screenshot at
// once for the main baseline. Throws if git can't produce the blob (e.g. the
// ref doesn't actually contain that path) - callers treat that as "no
// fallback available".
function extractFileFromGit(ref, filePath, outputPath) {
	const content = execFileSync("git", ["show", `${ref}:${filePath}`], {
		encoding: null,
		maxBuffer: 50 * 1024 * 1024,
		stdio: ["pipe", "pipe", "pipe"],
	});
	fs.mkdirSync(path.dirname(outputPath), { recursive: true });
	fs.writeFileSync(outputPath, content);
	return outputPath;
}

// Builds the fallback baseline for a "new" scenario: the image as it existed
// at its first_seen commit (the earliest commit where the file exists),
// diffed against the current capture with the same padded-canvas pixel-diff
// used for the main baseline comparison. Returns null when there's nothing
// committed to fall back to (extraction fails) or no current image to diff
// it against - callers treat that as "no committed fallback" and leave the
// scenario's fallback_* fields null.
function buildFallbackResult({
	firstSeenCommit,
	trackedPath,
	file,
	currentDir,
	fallbackOutputDir,
	diffOutputDir,
}) {
	const fallbackImagePath = path.join(fallbackOutputDir, file);

	try {
		extractFileFromGit(firstSeenCommit, trackedPath, fallbackImagePath);
	} catch {
		return null;
	}

	const currentPath = path.join(currentDir, file);
	if (!fs.existsSync(currentPath)) {
		return null;
	}

	// One or both of the fallback/current images can fail to decode as PNG -
	// e.g. a corrupted capture, or (as covered by the rspec) a tracked file
	// whose content was never a real PNG in the first place. That must never
	// crash the whole review: report it as a per-scenario diff_error instead,
	// still carrying the fallback's own commit/label/date so the UI can show
	// *something* in place of the image/percent.
	let diff;
	try {
		diff = computeDiff(
			fs.readFileSync(currentPath),
			fs.readFileSync(fallbackImagePath)
		);
	} catch (err) {
		return {
			image: fallbackImagePath,
			diffError: `could not decode image for fallback diff: ${err.message}`,
			commit: shortSha(firstSeenCommit),
			label: describeFirstSeen(firstSeenCommit),
			date: commitDate(firstSeenCommit),
		};
	}

	fs.mkdirSync(diffOutputDir, { recursive: true });
	const fallbackDiffPath = path.join(diffOutputDir, `fallback-${file}`);
	fs.writeFileSync(fallbackDiffPath, diff.diffBuffer);

	const fallbackHeatmapPath = path.join(
		diffOutputDir,
		`fallback-heatmap-${file}`
	);
	fs.writeFileSync(fallbackHeatmapPath, buildHeatmapPng(diff.diffBuffer));

	const regions = buildRegions(diff.diffBuffer);

	return {
		image: fallbackImagePath,
		diffPath: fallbackDiffPath,
		heatmapPath: fallbackHeatmapPath,
		commit: shortSha(firstSeenCommit),
		label: describeFirstSeen(firstSeenCommit),
		date: commitDate(firstSeenCommit),
		regions,
		regionCount: regions.length,
		changedPercent: diff.changedPercent,
		sizeMismatchLabel: diff.sizeMismatch
			? `size differs (${diff.baselineWidth}×${diff.baselineHeight} vs ${diff.currentWidth}×${diff.currentHeight})`
			: null,
		width: diff.width,
		height: diff.height,
		currentWidth: diff.currentWidth,
		currentHeight: diff.currentHeight,
		baselineWidth: diff.baselineWidth,
		baselineHeight: diff.baselineHeight,
	};
}

function buildManifest(inputOptions) {
	let options = inputOptions;
	const currentRef = options.currentRef;
	if (currentRef) {
		validateGitRef(currentRef);
		const currentExtractDir = currentScratchDir(currentRef);
		if (
			path.resolve(currentExtractDir) === path.resolve(options.screenshotsDir)
		) {
			throw new Error(
				`current scratch dir must not be ${options.screenshotsDir}: that directory is the tracked source.`
			);
		}
		extractBaselineFromGit(
			currentRef,
			currentExtractDir,
			options.screenshotsDir
		);
		options = { ...options, currentDir: currentExtractDir };
	}
	const baselineRef = options.baseline;
	validateGitRef(baselineRef);

	if (
		path.resolve(options.baselineDir) === path.resolve(options.screenshotsDir)
	) {
		throw new Error(
			`--baseline-dir must not be ${options.screenshotsDir}: that directory is the git-tracked ` +
				"source the baseline is extracted from, not a scratch output location. " +
				`Leave --baseline-dir unset to use the default (${baselineScratchDir(baselineRef)}).`
		);
	}

	const baselineExtractDir = options.baselineDir;
	const baselineFiles = extractBaselineFromGit(
		baselineRef,
		baselineExtractDir,
		options.screenshotsDir
	);

	const baselineDescribe = gitDescribe(baselineRef);
	const currentDescribe = gitDescribe(currentRef || "HEAD");
	const currentDirty = currentRef ? false : workingTreeDirty();
	const generatedAt = isoTimestamp();
	const diffOutputDir = path.join(path.dirname(options.outputHtml), "diffs");
	const fallbackOutputDir = path.join(
		path.dirname(options.outputHtml),
		"fallback"
	);

	const currentFiles = pngFiles(options.currentDir);
	const allFiles = Array.from(
		new Set([...currentFiles, ...baselineFiles])
	).sort();

	const scenarios = allFiles.map((file) => {
		const inBaseline = baselineFiles.includes(file);
		const inCurrent = currentFiles.includes(file);
		const trackedPath = trackedScreenshotPath(file, options.screenshotsDir);

		const baselineCommit = inBaseline
			? lastCommitTouching(baselineRef, trackedPath)
			: null;
		const diffResult =
			inBaseline && inCurrent
				? buildDiffResult({
						currentDir: options.currentDir,
						baselineDir: baselineExtractDir,
						diffOutputDir,
						file,
					})
				: null;

		const status = !inBaseline
			? "new"
			: !inCurrent
				? "removed"
				: diffResult &&
						!diffResult.sizeMismatchLabel &&
						diffResult.changedPixels === 0
					? "unchanged"
					: "changed";

		const firstSeenCommit =
			status === "new" ? firstAddCommit(trackedPath) : null;

		// A committed fallback only exists for a "new" scenario whose file has
		// real git history (firstSeenCommit is null when the capture only
		// exists in the working tree / HEAD hasn't been committed yet - see
		// firstAddCommit above) - that's exactly the "no committed fallback"
		// case the task calls out.
		const fallback =
			status === "new" && firstSeenCommit
				? buildFallbackResult({
						firstSeenCommit,
						trackedPath,
						file,
						currentDir: options.currentDir,
						fallbackOutputDir,
						diffOutputDir,
					})
				: null;

		return {
			file,
			status,
			baseline_path: inBaseline
				? relativeAssetPath(
						options.outputHtml,
						path.join(baselineExtractDir, file)
					)
				: null,
			current_path: inCurrent
				? relativeAssetPath(
						options.outputHtml,
						path.join(options.currentDir, file)
					)
				: null,
			diff_path: diffResult?.diffPath
				? relativeAssetPath(options.outputHtml, diffResult.diffPath)
				: null,
			heatmap_path: diffResult?.heatmapPath
				? relativeAssetPath(options.outputHtml, diffResult.heatmapPath)
				: null,
			regions: diffResult ? diffResult.regions || null : null,
			region_count: diffResult
				? diffResult.regionCount === undefined
					? null
					: diffResult.regionCount
				: null,
			size_mismatch: diffResult ? diffResult.sizeMismatchLabel || null : null,
			diff_error: diffResult ? diffResult.diffError || null : null,
			changed_pixels: diffResult
				? diffResult.changedPixels === undefined
					? null
					: diffResult.changedPixels
				: null,
			changed_percent: diffResult
				? diffResult.changedPercent === undefined
					? null
					: diffResult.changedPercent
				: null,
			diff_width: diffResult
				? diffResult.width === undefined
					? null
					: diffResult.width
				: null,
			diff_height: diffResult
				? diffResult.height === undefined
					? null
					: diffResult.height
				: null,
			current_width: diffResult
				? diffResult.currentWidth === undefined
					? null
					: diffResult.currentWidth
				: null,
			current_height: diffResult
				? diffResult.currentHeight === undefined
					? null
					: diffResult.currentHeight
				: null,
			baseline_width: diffResult
				? diffResult.baselineWidth === undefined
					? null
					: diffResult.baselineWidth
				: null,
			baseline_height: diffResult
				? diffResult.baselineHeight === undefined
					? null
					: diffResult.baselineHeight
				: null,
			baseline_commit: baselineCommit ? shortSha(baselineCommit) : null,
			baseline_date: baselineCommit ? commitDate(baselineCommit) : null,
			first_seen: firstSeenCommit
				? {
						describe: describeFirstSeen(firstSeenCommit),
						date: commitDate(firstSeenCommit),
					}
				: null,
			fallback_image: fallback
				? relativeAssetPath(options.outputHtml, fallback.image)
				: null,
			fallback_diff_path: fallback?.diffPath
				? relativeAssetPath(options.outputHtml, fallback.diffPath)
				: null,
			fallback_heatmap_path: fallback?.heatmapPath
				? relativeAssetPath(options.outputHtml, fallback.heatmapPath)
				: null,
			fallback_error: fallback ? fallback.diffError || null : null,
			fallback_regions: fallback ? fallback.regions || null : null,
			fallback_region_count: fallback
				? fallback.regionCount === undefined
					? null
					: fallback.regionCount
				: null,
			fallback_commit: fallback ? fallback.commit : null,
			fallback_label: fallback ? fallback.label : null,
			fallback_date: fallback ? fallback.date : null,
			fallback_changed_percent: fallback ? fallback.changedPercent : null,
			fallback_size_mismatch: fallback ? fallback.sizeMismatchLabel : null,
			fallback_width: fallback ? fallback.width : null,
			fallback_height: fallback ? fallback.height : null,
			fallback_current_width: fallback ? fallback.currentWidth : null,
			fallback_current_height: fallback ? fallback.currentHeight : null,
			fallback_baseline_width: fallback ? fallback.baselineWidth : null,
			fallback_baseline_height: fallback ? fallback.baselineHeight : null,
		};
	});

	return {
		// Single baseline version line, per the task: describes the ref itself.
		// Per-directory generated_at/images_sha were dropped in favour of the
		// per-scenario baseline_commit/baseline_date below, since a single date
		// for the whole doc/screenshots directory was misleading once different
		// screenshots can legitimately have been last touched at different times.
		baseline: {
			ref: baselineRef,
			describe: baselineDescribe,
		},
		current: {
			describe: currentDescribe,
			dirty: currentDirty,
			generated_at: generatedAt,
		},
		scenarios,
	};
}

// Computes the pixelmatch diff for one scenario at generation time and
// writes the resulting diff PNG into diffOutputDir (next to the other
// copied images). This works even when the two images are different sizes
// - computeDiff pads both onto a shared canvas (see tools/screenshot/
// pixel-diff.js) - so the overlay and changed_percent are always available.
// Returns null when either side is missing on disk; otherwise
// { diffPath, changedPixels, changedPercent, width, height, currentWidth,
// currentHeight, baselineWidth, baselineHeight, sizeMismatchLabel } where
// sizeMismatchLabel is only set (alongside the percentage, not instead of
// it) when the two images differ in size.
function buildDiffResult({ currentDir, baselineDir, diffOutputDir, file }) {
	const currentPath = path.join(currentDir, file);
	const baselinePath = path.join(baselineDir, file);

	if (!fs.existsSync(currentPath) || !fs.existsSync(baselinePath)) {
		return null;
	}

	// Same tolerance as buildFallbackResult: a PNG that pngjs can't decode
	// (corrupt/truncated capture, or non-PNG bytes) must degrade to a
	// diff_error on this one scenario, not blow up the whole manifest build.
	let diff;
	try {
		diff = computeDiff(
			fs.readFileSync(currentPath),
			fs.readFileSync(baselinePath)
		);
	} catch (err) {
		return { diffError: `could not decode image for diff: ${err.message}` };
	}

	fs.mkdirSync(diffOutputDir, { recursive: true });
	const diffPath = path.join(diffOutputDir, file);
	fs.writeFileSync(diffPath, diff.diffBuffer);

	const heatmapPath = path.join(diffOutputDir, `heatmap-${file}`);
	fs.writeFileSync(heatmapPath, buildHeatmapPng(diff.diffBuffer));

	const regions = buildRegions(diff.diffBuffer);

	return {
		diffPath,
		heatmapPath,
		regions,
		regionCount: regions.length,
		changedPixels: diff.changedPixels,
		changedPercent: diff.changedPercent,
		width: diff.width,
		height: diff.height,
		currentWidth: diff.currentWidth,
		currentHeight: diff.currentHeight,
		baselineWidth: diff.baselineWidth,
		baselineHeight: diff.baselineHeight,
		sizeMismatchLabel: diff.sizeMismatch
			? `size differs (${diff.baselineWidth}×${diff.baselineHeight} vs ${diff.currentWidth}×${diff.currentHeight})`
			: null,
	};
}

function relativeAssetPath(outputHtml, assetPath) {
	return path.relative(path.dirname(outputHtml), assetPath);
}

function bundledScriptSource() {
	const reviewPagePath = path.join(__dirname, "review-page.js");
	return fs.readFileSync(reviewPagePath, "utf8");
}

function printStartSummary(options) {
	process.stdout.write(
		`${[
			"Generating screenshot review page with:",
			`  baseline: ${options.baseline}`,
			options.currentRef
				? `  current-ref: ${options.currentRef}`
				: `  current-dir: ${options.currentDir}`,
			`  baseline-dir: ${options.baselineDir}`,
			`  output-html: ${options.outputHtml}`,
			options.title !== "Screenshot Review"
				? `  title: ${options.title}`
				: null,
		]
			.filter(Boolean)
			.join("\n")}\n`
	);
}

function writeReview(options) {
	printStartSummary(options);
	const manifest = buildManifest(options);
	const html = renderReviewHtml({
		manifest,
		scriptSource: bundledScriptSource(),
		title: options.title,
	});
	fs.mkdirSync(path.dirname(options.outputHtml), { recursive: true });
	fs.writeFileSync(options.outputHtml, html);
	process.stdout.write(
		`Wrote screenshot review page to ${options.outputHtml}\n`
	);
	return options.outputHtml;
}

function openInBrowser(filePath) {
	const { execSync } = require("node:child_process");
	const isWin = process.platform === "win32";
	const isMac = process.platform === "darwin";
	const isLinux = process.platform === "linux";

	let cmd;
	if (isMac) {
		cmd = `open "${filePath}"`;
	} else if (isWin) {
		cmd = `start "" "${filePath}"`;
	} else if (isLinux) {
		cmd = `xdg-open "${filePath}"`;
	} else {
		return false;
	}

	try {
		execSync(cmd, { stdio: "ignore" });
		return true;
	} catch {
		return false;
	}
}

function promptForOpen(filePath) {
	return new Promise((resolve) => {
		const countdownSeconds = 5;
		let secondsLeft = countdownSeconds;

		if (process.stdin.isTTY) {
			process.stdin.setRawMode(true);
		}
		process.stdin.resume();
		process.stdin.setEncoding("utf8");

		const printStatus = () => {
			process.stdout.write(
				`\rDone. press 'o' to open in browser (${secondsLeft}s) `
			);
		};

		printStatus();

		const interval = setInterval(() => {
			secondsLeft -= 1;
			if (secondsLeft < 0) {
				clearInterval(interval);
				process.stdin.pause();
				if (process.stdin.isTTY) {
					process.stdin.setRawMode(false);
				}
				process.stdout.write("\n");
				const relativePath = path.relative(process.cwd(), filePath);
				process.stdout.write(`\nopen ${relativePath}\n`);
				resolve(false);
				return;
			}
			printStatus();
		}, 1000);

		const keyHandler = (char) => {
			if (char === "o" || char === "O") {
				clearInterval(interval);
				process.stdin.removeListener("data", keyHandler);
				process.stdin.pause();
				if (process.stdin.isTTY) {
					process.stdin.setRawMode(false);
				}
				process.stdout.write("\n");
				resolve(true);
			} else if (char === "" || char === "") {
				clearInterval(interval);
				process.stdin.removeListener("data", keyHandler);
				process.stdin.pause();
				if (process.stdin.isTTY) {
					process.stdin.setRawMode(false);
				}
				process.stdout.write("\n");
				const relativePath = path.relative(process.cwd(), filePath);
				process.stdout.write(`\nopen ${relativePath}\n`);
				resolve(false);
			}
		};

		process.stdin.on("data", keyHandler);
	});
}

function main() {
	try {
		const options = parseArgs(process.argv.slice(2));
		const htmlPath = writeReview(options);

		if (!process.stdin.isTTY) {
			const relativePath = path.relative(process.cwd(), htmlPath);
			process.stdout.write(`\nopen ${relativePath}\n`);
			process.exit(0);
		}

		promptForOpen(htmlPath).then((shouldOpen) => {
			if (shouldOpen) {
				openInBrowser(htmlPath);
			}
			process.exit(0);
		});
	} catch (error) {
		process.stderr.write(`${error.message}\n`);
		process.exit(1);
	}
}

if (require.main === module) {
	main();
}

module.exports = {
	applyDefaults,
	baselineScratchDir,
	currentScratchDir,
	buildDiffResult,
	buildFallbackResult,
	buildManifest,
	commitDate,
	describeFirstSeen,
	extractBaselineFromGit,
	extractFileFromGit,
	firstAddCommit,
	lastCommitTouching,
	loadConfigFile,
	printUsage,
	sanitizeRefForPath,
	screenshotFilesAtRef,
	main,
	openInBrowser,
	parseArgs,
	promptForOpen,
	validateGitRef,
	workingTreeDirty,
	writeReview,
};
