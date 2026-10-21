// Screenshot Review - Interactive Client Code

(() => {
	// All view-state fields below are "intent": what the user asked for, not
	// whether it currently applies to the screenshot on screen. Navigating
	// (j/k, Prev/Next, a sidebar click) never touches any of these - only an
	// explicit user action (clicking/pressing the control itself) changes an
	// intent. Whether an intent *applies* to the current scenario is computed
	// fresh on every render by scenarioSupportsDiff/effectiveScenario, never
	// baked into the stored value. See applyViewState(), the single function
	// that reconciles all of this onto the DOM after every navigation and
	// every intent change.
	const ZOOM_LEVELS = [2, 4, 8];
	const ZOOM_STEP = 10;
	const ZOOM_STEP_LARGE = 30;

	const state = {
		currentScenario: null,
		currentIndex: 0,
		// Diff-related intents persist across reloads (like theme/fallback)
		// since they're just user preferences, not tied to a particular
		// scenario or DOM node.
		showDiff: readLocalStorageBool("screenshot-review-diff", false),
		sidebarVisible:
			localStorage.getItem("screenshot-review-sidebar") !== "false",
		theme: localStorage.getItem("screenshot-review-theme") || "light-default",
		helpVisible: false,
		// Single shared view state driving both panels' zoom/pan. {scale, x, y}
		// where x/y are percentages (0-100) of the *image*, used as a CSS
		// transform-origin so panels of different heights still line up on the
		// same relative point. Kept generic so the future pixel-diff overlay
		// (task 5c) can add itself as another layer under the same transform.
		// Survives navigation (nothing here resets it) and, like the other view
		// prefs below, is persisted to localStorage so it also survives a
		// reload - see persistZoom(). x/y are percentages of *whichever*
		// screenshot is on screen, not tied to its pixel dimensions, so they
		// stay meaningful (and in bounds) even when navigating to a
		// differently-sized screenshot; clampZoomToScenario() (called from
		// updateView()) re-clamps them into [0, 100] on every navigation as a
		// defensive belt-and-braces measure.
		zoom: {
			active: readLocalStorageBool("screenshot-review-zoom-active", false),
			scale: Number(
				readLocalStorageEnum(
					"screenshot-review-zoom-scale",
					ZOOM_LEVELS.map(String),
					"2"
				)
			),
			x: readLocalStorageNumber("screenshot-review-zoom-x", 50, 0, 100),
			y: readLocalStorageNumber("screenshot-review-zoom-y", 50, 0, 100),
		},
		lastMouseClient: null,
		// Diff overlay controls (task 5c). Persisted across reloads like the
		// other view prefs above.
		// "Fade" cycles dark overlay -> white overlay -> none, replacing the old
		// dim-base boolean + a separate opacity slider. There's no user-facing
		// opacity control any more - each overlay (pixels/heatmap/regions) just
		// keeps a fixed default opacity (the slider's own former default, 0.7 -
		// see the .diff-overlay/.regions-layer CSS in review-html.js), so this
		// only needs to track the fade mode itself.
		fadeMode: readLocalStorageEnum(
			"screenshot-review-diff-fade",
			["dark", "white", "none"],
			"none"
		),
		blinkMode: readLocalStorageBool("screenshot-review-blink", false),
		// Diff overlay view mode: 'pixels' (the classic red diff), 'heatmap'
		// (the blurred change-density PNG - see tools/screenshot/heatmap.js), or
		// 'regions' (outlined change-region boxes - see tools/screenshot/
		// regions.js). Persisted like the other view prefs; falls back to
		// 'pixels' for any unrecognized/missing stored value.
		diffViewMode: readLocalStorageEnum(
			"screenshot-review-diff-view",
			["pixels", "heatmap", "regions"],
			"pixels"
		),
		// Whether the diff view mode dropdown menu is open. Transient UI state
		// (like helpVisible), not persisted - it always starts closed.
		diffViewMenuOpen: false,
		// "Show fallback" (task: fallback baseline for new scenarios) - a
		// global toggle, like the theme, so it applies across every new
		// scenario rather than per-file. Wrapped in try/catch like theme's
		// storage access, since localStorage can throw (private browsing etc).
		fallbackActive: readLocalStorageBool("screenshot-review-fallback", false),
	};

	function readLocalStorageBool(key, fallback) {
		try {
			const value = localStorage.getItem(key);
			return value === null ? fallback : value === "true";
		} catch {
			return fallback;
		}
	}

	function readLocalStorageEnum(key, allowed, fallback) {
		try {
			const value = localStorage.getItem(key);
			return allowed.includes(value) ? value : fallback;
		} catch {
			return fallback;
		}
	}

	function readLocalStorageNumber(key, fallback, lo, hi) {
		try {
			const value = localStorage.getItem(key);
			if (value === null) return fallback;
			const parsed = Number(value);
			if (Number.isNaN(parsed)) return fallback;
			return Math.max(lo, Math.min(hi, parsed));
		} catch {
			return fallback;
		}
	}

	function writeLocalStorage(key, value) {
		try {
			localStorage.setItem(key, value);
		} catch {
			// ignore - e.g. private browsing / storage disabled
		}
	}

	function clamp(value, lo, hi) {
		return Math.max(lo, Math.min(hi, value));
	}

	// The one function that applies the shared {scale, x, y} view state to a
	// single zoomable layer. Both panes' zoom-layer elements go through this,
	// so a future overlay layer (task 5c) just needs to be included in the
	// `.comparison-pane .zoom-layer` selector to stay in sync.
	//
	// `instant`, when true, suppresses the CSS transition (see .zoom-layer in
	// review-html.js) for this one application: an inline `transition: none`
	// is set, the new transform is applied, a reflow is forced so the browser
	// commits it without animating, and only then is the inline override
	// cleared - restoring the normal ~0.3s transition for the *next* change.
	// Used for cursor-centred zoom-follow (handleMouseMove below), so
	// tracking the mouse never lags a transition; deliberately not used for
	// zoom-level steps or arrow-key panning, which should animate.
	function applyViewTransform(layer, instant) {
		if (!layer) return;
		if (instant) layer.style.transition = "none";
		const { active, scale, x, y } = state.zoom;
		if (active) {
			layer.style.transformOrigin = `${x}% ${y}%`;
			layer.style.transform = `scale(${scale})`;
			layer.classList.toggle("pixelated", scale >= 4);
		} else {
			layer.style.transformOrigin = "";
			layer.style.transform = "";
			layer.classList.remove("pixelated");
		}
		if (instant) {
			// Force a reflow so the browser commits the change above before the
			// transition is restored, rather than animating it.
			void layer.offsetHeight;
			layer.style.transition = "";
		}
	}

	function applyZoomState(options) {
		const instant = !!options?.instant;
		document
			.querySelectorAll(".comparison-pane .zoom-layer")
			.forEach((layer) => {
				applyViewTransform(layer, instant);
			});
		document.querySelectorAll(".pane-image").forEach((pane) => {
			pane.classList.toggle("zoomed", state.zoom.active);
		});
		updateZoomBadge();
	}

	function updateZoomBadge() {
		const badge = document.getElementById("zoomBadge");
		if (!badge) return;
		if (state.zoom.active) {
			badge.textContent = `${state.zoom.scale}× · z to exit`;
			badge.hidden = false;
		} else {
			badge.hidden = true;
		}
	}

	function percentFromClient(paneEl, clientX, clientY) {
		const rect = paneEl.getBoundingClientRect();
		if (!rect.width || !rect.height) return { x: 50, y: 50 };
		return {
			x: clamp(((clientX - rect.left) / rect.width) * 100, 0, 100),
			y: clamp(((clientY - rect.top) / rect.height) * 100, 0, 100),
		};
	}

	function originFromLastMouse() {
		const pos = state.lastMouseClient;
		if (!pos) return null;
		const el = document.elementFromPoint(pos.x, pos.y);
		const pane = el?.closest(".pane-image");
		if (!pane) return null;
		return percentFromClient(pane, pos.x, pos.y);
	}

	// Persists the whole {active, scale, x, y} zoom/pan state to localStorage,
	// like the other view prefs (theme/diff/fade/...) - see the state.zoom
	// comment above. Called after every zoom/pan mutation below.
	function persistZoom() {
		writeLocalStorage("screenshot-review-zoom-active", state.zoom.active);
		writeLocalStorage("screenshot-review-zoom-scale", state.zoom.scale);
		writeLocalStorage("screenshot-review-zoom-x", state.zoom.x);
		writeLocalStorage("screenshot-review-zoom-y", state.zoom.y);
	}

	// Re-clamps the persisted pan position into [0, 100] after navigating to
	// a (possibly differently-sized) scenario. x/y are already percentages of
	// whichever screenshot is on screen rather than pixel offsets, so they're
	// inherently valid for any image size - this is a defensive re-clamp
	// (e.g. against a corrupted/out-of-range localStorage value) rather than
	// a correction expected to ever actually change anything in practice.
	function clampZoomToScenario() {
		state.zoom.x = clamp(state.zoom.x, 0, 100);
		state.zoom.y = clamp(state.zoom.y, 0, 100);
	}

	function activateZoom() {
		const origin = originFromLastMouse();
		state.zoom.active = true;
		state.zoom.scale = 2;
		state.zoom.x = origin ? origin.x : 50;
		state.zoom.y = origin ? origin.y : 50;
		applyZoomState();
		persistZoom();
	}

	function deactivateZoom() {
		state.zoom.active = false;
		state.zoom.scale = 2;
		state.zoom.x = 50;
		state.zoom.y = 50;
		applyZoomState();
		persistZoom();
	}

	function toggleZoom() {
		if (state.zoom.active) {
			deactivateZoom();
		} else {
			activateZoom();
		}
	}

	function panZoom(dx, dy) {
		state.zoom.x = clamp(state.zoom.x + dx, 0, 100);
		state.zoom.y = clamp(state.zoom.y + dy, 0, 100);
		applyZoomState();
		persistZoom();
	}

	function stepZoom(direction) {
		const idx = ZOOM_LEVELS.indexOf(state.zoom.scale);
		const nextIdx = clamp(
			(idx === -1 ? 0 : idx) + direction,
			0,
			ZOOM_LEVELS.length - 1
		);
		state.zoom.scale = ZOOM_LEVELS[nextIdx];
		applyZoomState();
		persistZoom();
	}

	function handleMouseMove(e) {
		state.lastMouseClient = { x: e.clientX, y: e.clientY };
		if (!state.zoom.active) return;
		const pane = e.target.closest?.(".pane-image");
		if (!pane) return;
		const { x, y } = percentFromClient(pane, e.clientX, e.clientY);
		state.zoom.x = x;
		state.zoom.y = y;
		applyZoomState({ instant: true });
		persistZoom();
	}

	function handleWheel(e) {
		if (!state.zoom.active) return;
		const pane = e.target.closest?.(".pane-image");
		if (!pane) return;
		e.preventDefault();
		stepZoom(e.deltaY < 0 ? 1 : -1);
	}

	// Timestamps show only the date, with the full ISO string on hover via a
	// <time datetime title> - kept in sync with the server-rendered duplicate
	// in review-html.js (same reasoning as changedPercentColor's duplicate
	// below: this script runs as a plain injected <script> body, not
	// require()'d).
	function formatDateOnly(iso) {
		if (!iso) return "";
		const match = String(iso).match(/^(\d{4}-\d{2}-\d{2})/);
		return match ? match[1] : String(iso);
	}

	function renderTimeHtml(iso) {
		if (!iso) return "";
		return `<time datetime="${escapeAttr(iso)}" title="${escapeAttr(iso)}">${escapeHtml(formatDateOnly(iso))}</time>`;
	}

	// Source path (folder/file, or <ref>:<path> for git `show`), then the date
	// (full timestamp on hover) and, for git baselines, the short commit.
	function sourceMetaHtml(source, date, commit) {
		const parts = [
			source ? `<code>${escapeHtml(source)}</code>` : null,
			date ? renderTimeHtml(date) : null,
			commit ? escapeHtml(commit) : null,
		].filter(Boolean);
		return parts.join(" · ");
	}

	function baselineMetaHtml(scenario) {
		return sourceMetaHtml(
			scenario.baseline_source,
			scenario.baseline_date,
			scenario.baseline_commit
		);
	}

	function currentMetaHtml(scenario) {
		return sourceMetaHtml(
			scenario.current_source,
			scenario.current_date || MANIFEST.current.generated_at,
			null
		);
	}

	function updateBaselineMeta(scenario) {
		const el = document.getElementById("baselineMeta");
		if (el) el.innerHTML = baselineMetaHtml(scenario);
		const cur = document.getElementById("currentMeta");
		if (cur) cur.innerHTML = currentMetaHtml(scenario);
	}

	// Disguises a "new" scenario as a "changed" one, pointed at its fallback
	// image/diff instead of the (nonexistent) real baseline, whenever fallback
	// mode is on and this particular scenario actually has a committed
	// fallback (see buildFallbackResult in cli.js). Every other
	// function here (currentPane/baselinePane/scenarioSupportsDiff/the diff %
	// badge/etc) already knows how to render a "changed" scenario, so routing
	// through this shim is all that's needed to make diff/blink/zoom/the %
	// badge all operate on the fallback - no separate fallback-rendering path.
	function effectiveScenario(scenario) {
		if (!scenario) return scenario;
		if (
			scenario.status !== "new" ||
			!state.fallbackActive ||
			!scenario.fallback_diff_path
		) {
			return scenario;
		}
		return Object.assign({}, scenario, {
			status: "changed",
			baseline_path: scenario.fallback_image,
			diff_path: scenario.fallback_diff_path,
			heatmap_path: scenario.fallback_heatmap_path,
			regions: scenario.fallback_regions,
			region_count: scenario.fallback_region_count,
			changed_percent: scenario.fallback_changed_percent,
			size_mismatch: scenario.fallback_size_mismatch,
			diff_error: scenario.fallback_error,
			diff_width: scenario.fallback_width,
			diff_height: scenario.fallback_height,
			current_width: scenario.fallback_current_width,
			current_height: scenario.fallback_current_height,
			baseline_width: scenario.fallback_baseline_width,
			baseline_height: scenario.fallback_baseline_height,
			baseline_commit: scenario.fallback_commit,
			baseline_date: scenario.fallback_date,
		});
	}

	function anyScenarioHasFallback() {
		return MANIFEST.scenarios.some((scenario) => !!scenario.fallback_diff_path);
	}

	// The real baseline label/version line is never replaced (task: keep it as
	// the real baseline) - a purple tag is added alongside it, styled like the
	// DIRTY/NEW badges, only while fallback mode is on AND this scenario
	// actually has one, so it's never mistaken for the real baseline.
	function updateBaselineFallbackTag(scenario) {
		const tag = document.getElementById("baselineFallbackTag");
		if (!tag) return;
		const useFallback = !!(
			scenario &&
			scenario.status === "new" &&
			state.fallbackActive &&
			scenario.fallback_diff_path
		);
		if (useFallback) {
			// .status-badge (which this tag also is, for the DIRTY/NEW-matching
			// styling) applies text-transform: uppercase to the whole element -
			// fine for the literal word "FALLBACK", but it also visually mangled
			// the git describe label (e.g. "-gcf41910e" read as "-GCF41910E").
			// .fallback-badge-detail opts back out so only "FALLBACK" itself is
			// uppercase.
			tag.innerHTML = `FALLBACK <span class="fallback-badge-detail">${escapeHtml(scenario.fallback_label)} · ${renderTimeHtml(scenario.fallback_date)}</span>`;
			tag.hidden = false;
		} else {
			tag.innerHTML = "";
			tag.hidden = true;
		}
	}

	function baselinePane(scenario) {
		if (scenario.status === "new") {
			const firstSeen = scenario.first_seen;
			const firstSeenText = firstSeen
				? `first appeared in ${escapeHtml(firstSeen.describe)} (${renderTimeHtml(firstSeen.date)})`
				: "first appeared in an uncommitted capture";
			// No .pane-label here - a normal (non-placeholder) pane below renders
			// none either (the "Baseline"/"Current" headings live in the static
			// .comparison-info blocks above both panels instead), so adding one
			// only here used to push this panel's image area lower than its
			// sibling, breaking the "both images start at the same y" alignment.
			return `
        <div class="pane-image">
          <div class="placeholder-pane">
            <p class="placeholder-main">Not in ${escapeHtml(MANIFEST.baseline.describe)}</p>
            <p class="placeholder-sub">${firstSeenText}</p>
          </div>
        </div>`;
		}

		const baselineImage = `<img src="${escapeAttr(scenario.baseline_path)}" alt="Baseline" loading="eager" />`;

		if (!scenarioSupportsDiff(scenario)) {
			// No shared canvas to scale against (e.g. a 'removed' scenario, where
			// there's no current image at all) - fall back to the simple "fill
			// the pane" rendering.
			return `
        <div class="pane-image">
          <div class="zoom-layer">
            ${baselineImage}
          </div>
        </div>`;
		}

		// Mirrors the current pane's canvas-relative scaling (see currentPane()
		// below): .canvas-frame is a non-zooming sizing box at the shared
		// padded-canvas aspect ratio (full pane width), and the baseline image
		// sits inside it, absolutely positioned at its own width as a fraction
		// of the canvas width. That way the same page element renders at the
		// same size in both the baseline and current panels, whichever one is
		// the smaller image.
		const canvasWidth = scenario.diff_width;
		const canvasHeight = scenario.diff_height;
		const baselineWidthPercent = (scenario.baseline_width / canvasWidth) * 100;

		return `
      <div class="pane-image">
        <div class="canvas-frame" style="aspect-ratio: ${canvasWidth} / ${canvasHeight};">
          <div class="zoom-layer overlay-zoom-layer" style="width: ${baselineWidthPercent}%;">
            ${baselineImage}
          </div>
        </div>
      </div>`;
	}

	function currentPane(scenario) {
		if (scenario.status === "removed") {
			// See the matching comment in baselinePane() above - no .pane-label
			// here either, for the same alignment reason.
			return `
        <div class="pane-image">
          <div class="placeholder-pane">
            <p class="placeholder-main">Removed since ${escapeHtml(MANIFEST.baseline.describe)}</p>
          </div>
        </div>`;
		}

		const supportsDiff = scenarioSupportsDiff(scenario);

		if (!supportsDiff) {
			const currentImage = `<img src="${escapeAttr(scenario.current_path)}" alt="Current" loading="eager" class="current-img" />`;
			return `
        <div class="pane-image current-pane-image">
          <div class="zoom-layer">
            ${currentImage}
          </div>
        </div>`;
		}

		// The diff PNG is sized to the padded canvas - max(width) x max(height)
		// of the current/baseline pair (see tools/screenshot/pixel-diff.js) -
		// which is usually bigger than either actual screenshot when they're
		// different sizes. To keep pixels corresponding 1:1 between the overlay
		// and the image underneath it, .diff-zoom-layer is the one in-flow
		// layer that establishes the pane's box (full pane width, height from
		// aspect-ratio), and the current image layer is absolutely positioned on
		// top of it at its own width as a fraction of the canvas width - i.e.
		// every layer renders at the same canvas-pixels-per-CSS-pixel scale,
		// anchored top-left like the padding itself.
		const canvasWidth = scenario.diff_width;
		const canvasHeight = scenario.diff_height;
		const currentWidthPercent = (scenario.current_width / canvasWidth) * 100;

		const currentImage = `<img src="${escapeAttr(scenario.current_path)}" alt="Current" loading="eager" class="current-img" />`;

		// Both layers share the .zoom-layer class so they go through the same
		// shared {scale, x, y} zoom/pan transform (see
		// applyViewTransform/applyZoomState above) - zoom and pan move the
		// overlay too. The diff layer is last in the markup so it paints on top
		// of the (also positioned, via .overlay-zoom-layer) current layer
		// beneath it. Blink (see toggleBlinkMode below) flashes this same diff
		// overlay via a CSS animation rather than swapping in a baseline image.
		// In Regions mode there's no overlay image at all - just outlined boxes
		// (see renderRegionBoxesLayer below) - so the diff <img> underneath it
		// is only rendered for the pixels/heatmap modes. Both layers share
		// `.diff-zoom-layer`'s canvas-relative sizing (aspect-ratio + full pane
		// width) so boxes/pixels line up with the current image the same way
		// regardless of which one is showing.
		const overlayLayer =
			state.diffViewMode === "regions"
				? renderRegionBoxesLayer(scenario, canvasWidth, canvasHeight)
				: `
        <div class="zoom-layer diff-zoom-layer" style="aspect-ratio: ${canvasWidth} / ${canvasHeight};">
          <img src="${escapeAttr(diffOverlaySrc(scenario))}" alt="Diff" loading="eager" class="diff-overlay${state.showDiff ? "" : " hidden"}" />
        </div>`;

		// .fade-layer is a plain sibling of the image inside the same
		// (possibly absolutely-positioned) .overlay-zoom-layer box, so it
		// automatically covers exactly the screenshot's box - never more,
		// never less - and rides along with it under zoom/pan (the shared
		// {scale, x, y} transform is applied to .overlay-zoom-layer itself,
		// which carries this child along for free; no separate .zoom-layer
		// class needed here). It paints between the screenshot image and
		// ${overlayLayer} (the diff-zoom-layer below it in the DOM) - see the
		// stacking comment on .fade-layer/.diff-zoom-layer isolation in
		// review-html.js for why the diff overlay stays unaffected by it.
		return `
      <div class="pane-image current-pane-image">
        <div class="zoom-layer overlay-zoom-layer" style="width: ${currentWidthPercent}%;">
          ${currentImage}
          <div class="fade-layer"></div>
        </div>
        ${overlayLayer}
      </div>`;
	}

	// Picks the overlay image for the current view mode - the classic red
	// pixel diff, or the heatmap PNG generated alongside it (see
	// tools/screenshot/heatmap.js) - falling back to the pixel diff if a
	// scenario has no heatmap_path for some reason (e.g. an older manifest).
	function diffOverlaySrc(scenario) {
		if (state.diffViewMode === "heatmap" && scenario.heatmap_path) {
			return scenario.heatmap_path;
		}
		return scenario.diff_path;
	}

	// Renders one outlined box + always-visible label per manifest region
	// (see tools/screenshot/regions.js), positioned as percentages of the
	// shared padded canvas so they land on the same `.diff-zoom-layer`-style
	// sizing box as the pixel/heatmap overlay - zoom and pan (the shared
	// `.zoom-layer` transform) move them exactly like any other layer.
	// Deliberately no click/keyboard handling here - regions are look-only,
	// per the task ("no navigation between regions").
	function renderRegionBoxesLayer(scenario, canvasWidth, canvasHeight) {
		const regions = scenario.regions || [];
		const boxesHtml = regions
			.map((region) => renderRegionBox(region, canvasWidth, canvasHeight))
			.join("");
		return `
      <div class="zoom-layer diff-zoom-layer regions-layer${state.showDiff ? "" : " hidden"}" style="aspect-ratio: ${canvasWidth} / ${canvasHeight};">
        ${boxesHtml}
      </div>`;
	}

	// A region box is near the top/left edge of the canvas when its own
	// position is within roughly a label's height/width of that edge -
	// that's when the default "label floats just above/left of the box"
	// placement would run off the canvas, so the label flips inside the box
	// instead. These thresholds are in canvas percentage, not pixels, since
	// that's the space the box itself is positioned in.
	const REGION_LABEL_FLIP_Y_PERCENT = 4;
	const REGION_LABEL_FLIP_X_PERCENT = 3;

	function renderRegionBox(region, canvasWidth, canvasHeight) {
		const leftPercent = (region.x / canvasWidth) * 100;
		const topPercent = (region.y / canvasHeight) * 100;
		const widthPercent = (region.w / canvasWidth) * 100;
		const heightPercent = (region.h / canvasHeight) * 100;

		const color = changedPercentColor(region.changed_percent);
		const borderColor = color ? color.background : "#d9534f";
		const labelColor = color ? color.color : "#ffffff";

		const flipY = topPercent < REGION_LABEL_FLIP_Y_PERCENT;
		// Anchored from the right (rather than flipped left/right) once the box
		// sits close enough to the canvas' right edge that a left-anchored
		// label could run past it - a plain left/right swap (mirroring the
		// vertical flip) would still overflow the *opposite* edge for a
		// wide/short box, whereas right-anchoring the label just keeps its
		// right edge pinned to the box's right edge either way.
		const flipX =
			leftPercent + widthPercent > 100 - REGION_LABEL_FLIP_X_PERCENT;

		const labelClass = [
			"region-label",
			flipY ? "region-label-inside-y" : "",
			flipX ? "region-label-flip-x" : "",
		]
			.filter(Boolean)
			.join(" ");

		const dimensionsText = `${Math.round(region.w)}×${Math.round(region.h)}`;
		const labelText = `#${region.id} · ${Math.round(region.changed_percent)}% · ${dimensionsText}`;

		return `
      <div class="region-box" style="left: ${leftPercent}%; top: ${topPercent}%; width: ${widthPercent}%; height: ${heightPercent}%; border-color: ${borderColor};">
        <span class="${labelClass}" style="background: ${borderColor}; color: ${labelColor};">${escapeHtml(labelText)}</span>
      </div>`;
	}

	function renderComparisonView(scenario) {
		if (!scenario) {
			return `<div class="empty-state"><p>👈 Select a screenshot from the list to begin</p></div>`;
		}

		return `
      <div class="comparison-container">
        <div class="comparison-pane">
          ${baselinePane(scenario)}
        </div>
        <div class="comparison-pane">
          ${currentPane(scenario)}
        </div>
      </div>`;
	}

	// The one place that reconciles every view-state intent onto the freshly
	// rendered DOM. Called after every navigation and after every intent
	// change, so nothing resets a setting by omission - if a control isn't
	// re-applied here, that's a bug, not a deliberate reset.
	function applyViewState() {
		const effective = effectiveScenario(state.currentScenario);
		updateDiffToggleButton(effective);
		applyFadeState();
		applyBlinkState();
		updateDiffViewModeButtons();
		updateFallbackButton();
		applyZoomState();
	}

	function updateView() {
		const effective = effectiveScenario(state.currentScenario);
		const content = document.getElementById("viewerContent");
		content.innerHTML = renderComparisonView(effective);
		updateDiffPercentBadge(effective);
		updateBaselineFallbackTag(state.currentScenario);
		clampZoomToScenario();
		applyViewState();
	}

	function selectScenario(scenario, index, options) {
		const opts = options || {};
		state.currentScenario = scenario;
		state.currentIndex = index;

		document.querySelectorAll(".scenario-card").forEach((card) => {
			card.classList.remove("active");
			card.removeAttribute("aria-current");
		});

		const selectedCard = document.querySelector(
			`[data-file="${escapeAttr(scenario.file)}"]`
		);
		if (selectedCard) {
			selectedCard.classList.add("active");
			selectedCard.setAttribute("aria-current", "true");
			selectedCard.scrollIntoView({ block: "nearest", inline: "nearest" });
		}

		document.getElementById("selectedFile").textContent = escapeHtml(
			scenario.file
		);
		updateBaselineMeta(effectiveScenario(scenario));
		updateView();

		if (!opts.skipHashUpdate) {
			history.replaceState(null, "", `#${encodeURIComponent(scenario.file)}`);
		}
	}

	function findScenarioIndexByFile(file) {
		return MANIFEST.scenarios.findIndex((scenario) => scenario.file === file);
	}

	function selectFromHash() {
		const file = decodeURIComponent(location.hash.replace(/^#/, ""));
		const index = file ? findScenarioIndexByFile(file) : -1;

		if (index >= 0) {
			selectScenario(MANIFEST.scenarios[index], index, {
				skipHashUpdate: true,
			});
		} else {
			selectScenario(MANIFEST.scenarios[0], 0);
		}
	}

	function selectNextScenario() {
		if (!MANIFEST.scenarios.length) return;
		const nextIndex = (state.currentIndex + 1) % MANIFEST.scenarios.length;
		selectScenario(MANIFEST.scenarios[nextIndex], nextIndex);
	}

	function selectPreviousScenario() {
		if (!MANIFEST.scenarios.length) return;
		const prevIndex =
			(state.currentIndex - 1 + MANIFEST.scenarios.length) %
			MANIFEST.scenarios.length;
		selectScenario(MANIFEST.scenarios[prevIndex], prevIndex);
	}

	function selectByIndex(index) {
		if (index >= 0 && index < MANIFEST.scenarios.length) {
			selectScenario(MANIFEST.scenarios[index], index);
		}
	}

	function escapeHtml(str) {
		if (str === null || str === undefined) return "";
		const map = {
			"&": "&amp;",
			"<": "&lt;",
			">": "&gt;",
			'"': "&quot;",
			"'": "&#039;",
		};
		return String(str).replace(/[&<>"']/g, (m) => map[m]);
	}

	function escapeAttr(str) {
		if (str === null || str === undefined) return "";
		return String(str).replace(/"/g, "&quot;");
	}

	// A size mismatch no longer disables the overlay - pixel-diff.js pads both
	// images onto a shared canvas and still produces a diff PNG and a
	// changed_percent for them (see tools/screenshot/pixel-diff.js). All that's
	// required here is a diff image to show and real before/after images to
	// compare it against.
	function scenarioSupportsDiff(scenario) {
		return !!(
			scenario?.diff_path &&
			scenario.status !== "new" &&
			scenario.status !== "removed"
		);
	}

	// Small duplicate of tools/screenshot/changed-percent-color.js's pure
	// function (see the comment there, and the one on changedBadgeText in
	// review-html.js, for why this script - injected as a plain <script> body
	// rather than require()'d - keeps its own copy instead of sharing a
	// module). Maps changed_percent to a Grafana-gauge-style green-to-red
	// color; kept in sync with the canonical version, which is unit-tested in
	// test/changed-percent-color.test.js.
	function changedPercentColor(percent) {
		if (typeof percent !== "number" || Number.isNaN(percent)) return null;

		const hslToRgb = (h, s, l) => {
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
		};

		const relativeLuminance = ([r, g, b]) => {
			const channel = (c) => {
				const cs = c / 255;
				return cs <= 0.03928 ? cs / 12.92 : ((cs + 0.055) / 1.055) ** 2.4;
			};
			const [rl, gl, bl] = [channel(r), channel(g), channel(b)];
			return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl;
		};

		const colorForHsl = (hue, saturation, lightness) => {
			const rgb = hslToRgb(hue, saturation, lightness);
			const color = relativeLuminance(rgb) > 0.42 ? "#111111" : "#ffffff";
			return {
				hue,
				background: `hsl(${hue.toFixed(1)}, ${saturation}%, ${lightness}%)`,
				color,
			};
		};

		if (percent <= 0) return colorForHsl(120, 35, 38);

		const clamped = clamp(percent, 0, 30);
		const t = Math.sqrt(clamped / 30);
		return colorForHsl(120 - 120 * t, 70, 45);
	}

	function formatChangedPercent(scenario) {
		if (!scenario || scenario.status === "new" || scenario.status === "removed")
			return "";
		if (scenario.diff_error) return scenario.diff_error;
		if (
			scenario.changed_percent === null ||
			scenario.changed_percent === undefined
		) {
			return scenario.size_mismatch || "";
		}
		const percentText =
			scenario.changed_percent === 0
				? "identical"
				: `${scenario.changed_percent.toFixed(2)}% changed`;
		const base = scenario.size_mismatch
			? `${percentText} — ${scenario.size_mismatch}`
			: percentText;
		// In Regions mode the header % badge also gets "· N regions" appended,
		// so switching to that mode shows the region count without needing a
		// second badge - only when there's a numeric region_count to show (e.g.
		// an older manifest without regions still gets the plain percent text).
		if (
			state.diffViewMode === "regions" &&
			typeof scenario.region_count === "number"
		) {
			const regionWord = scenario.region_count === 1 ? "region" : "regions";
			return `${base} · ${scenario.region_count} ${regionWord}`;
		}
		return base;
	}

	function updateDiffPercentBadge(scenario) {
		const badge = document.getElementById("diffPercentBadge");
		if (!badge) return;
		const text = formatChangedPercent(scenario);
		const sizeMismatch = !!scenario?.size_mismatch;
		badge.classList.toggle("size-mismatch", sizeMismatch);
		badge.classList.toggle("diff-error", !!scenario?.diff_error);

		// A size mismatch still keeps the "size differs" note (and the
		// .size-mismatch class as a fallback styling when there's no numeric
		// percent), but the color itself now follows the same green-to-red
		// changed_percent gauge as a plain percentage badge.
		if (scenario && typeof scenario.changed_percent === "number") {
			const color = changedPercentColor(scenario.changed_percent);
			badge.style.background = color ? color.background : "";
			badge.style.color = color ? color.color : "";
		} else {
			badge.style.background = "";
			badge.style.color = "";
		}

		if (text) {
			badge.textContent = text;
			badge.title = text;
			badge.hidden = false;
		} else {
			badge.title = "";
			badge.hidden = true;
		}
	}

	function updateDiffToggleButton(scenario) {
		const btn = document.getElementById("diffToggleBtn");
		const applicable = scenarioSupportsDiff(scenario);
		// The label/pressed-state always reflects the stored intent
		// (state.showDiff), never whether it currently applies - so "Diff On"
		// stays visible (just dimmed, via :disabled) on a scenario that can't
		// show one (e.g. NEW with no fallback, or REMOVED), instead of silently
		// reading as "Off". Always present (never hidden/removed) - hiding it
		// entirely for a scenario with nothing to diff used to shift every
		// button after it in the top bar depending on which scenario happened
		// to be selected.
		btn.disabled = !applicable;
		btn.innerHTML = `<span>Diff</span> ${state.showDiff ? "On" : "Off"}<span class="shortcut">[d]</span>`;
		btn.setAttribute("aria-pressed", String(state.showDiff));
		btn.title = applicable
			? ""
			: "This scenario has nothing to diff against - Diff stays on for when you reach one that does";
		updateDiffControls(scenario);
	}

	function updateDiffControls(scenario) {
		const controls = document.getElementById("diffControls");
		const active = scenarioSupportsDiff(scenario) && state.showDiff;
		if (controls) controls.hidden = !active;
		updateFadeButton();
		updateBlinkButton();
		updateDiffViewModeButtons();
	}

	function toggleDiffOverlay() {
		state.showDiff = !state.showDiff;
		writeLocalStorage("screenshot-review-diff", state.showDiff);
		// Regions mode has no `.diff-overlay` <img> - its overlay is
		// `.regions-layer` (see renderRegionBoxesLayer), which is otherwise left
		// showing forever once rendered, since this used to only ever look for
		// `.diff-overlay`. Toggling either one (whichever is present) keeps the
		// regions overlay in sync with the diff toggle exactly like the pixel/
		// heatmap overlay always has been.
		const overlay = document.querySelector(".diff-overlay, .regions-layer");
		if (overlay) {
			overlay.classList.toggle("hidden", !state.showDiff);
		}
		if (!state.showDiff) {
			// Explicitly switching diff off is a deliberate action, not a
			// navigation - blink no longer has anything to flash, so its intent
			// goes off with it (same as it always has).
			stopBlink();
		}
		applyFadeState();
		updateDiffToggleButton(effectiveScenario(state.currentScenario));
	}

	// --- Diff overlay view mode: "Pixels" (red diff), "Heatmap" (change-
	// density PNG), or "Regions" (outlined change-region boxes, see
	// tools/screenshot/regions.js) - a compact dropdown toggle in
	// .diff-controls (button + menu, see #diffViewMode in review-html.js).
	// Pixels<->Heatmap only swaps the overlay <img>'s src in place, so
	// blink/zoom/fade (all of which act on ".diff-overlay"
	// generically) keep working unchanged and blink doesn't get interrupted
	// by the swap. ---

	const DIFF_VIEW_MODES = ["pixels", "heatmap", "regions"];
	const DIFF_VIEW_MODE_LABELS = {
		pixels: "Pixels",
		heatmap: "Heatmap",
		regions: "Regions",
	};

	function setDiffViewMode(mode) {
		if (!DIFF_VIEW_MODES.includes(mode)) return;
		const previousMode = state.diffViewMode;
		state.diffViewMode = mode;
		writeLocalStorage("screenshot-review-diff-view", mode);
		closeDiffViewMenu();

		// Pixels <-> Heatmap is just an <img> src swap in place (see
		// diffOverlaySrc) so blink/zoom/fade keep working
		// unchanged and blink doesn't get interrupted by the swap. Regions
		// mode renders a structurally different layer (boxes, not an image),
		// so switching into or out of it re-renders the comparison view
		// instead - applyViewState() below still re-applies every other
		// intent (blink/fade/zoom) onto the new DOM afterwards.
		if (mode === "regions" || previousMode === "regions") {
			updateView();
			return;
		}

		const overlay = document.querySelector(".diff-overlay");
		const scenario = effectiveScenario(state.currentScenario);
		if (overlay && scenario) {
			overlay.src = diffOverlaySrc(scenario);
			// Heatmap overlay gets full opacity (1), Pixels stays at default (0.7).
			overlay.classList.toggle("heatmap-overlay", mode === "heatmap");
		}
		updateDiffViewModeButtons();
	}

	// v cycles Pixels -> Heatmap -> Regions -> Pixels, without opening the menu.
	function cycleDiffViewMode() {
		const nextIndex =
			(DIFF_VIEW_MODES.indexOf(state.diffViewMode) + 1) %
			DIFF_VIEW_MODES.length;
		setDiffViewMode(DIFF_VIEW_MODES[nextIndex]);
	}

	function updateDiffViewModeButtons() {
		const pixelsBtn = document.getElementById("diffViewPixelsBtn");
		const heatmapBtn = document.getElementById("diffViewHeatmapBtn");
		const regionsBtn = document.getElementById("diffViewRegionsBtn");
		if (pixelsBtn)
			pixelsBtn.setAttribute(
				"aria-checked",
				String(state.diffViewMode === "pixels")
			);
		if (heatmapBtn)
			heatmapBtn.setAttribute(
				"aria-checked",
				String(state.diffViewMode === "heatmap")
			);
		if (regionsBtn)
			regionsBtn.setAttribute(
				"aria-checked",
				String(state.diffViewMode === "regions")
			);

		const label = document.getElementById("diffViewModeLabel");
		if (label)
			label.textContent = DIFF_VIEW_MODE_LABELS[state.diffViewMode] || "Pixels";
	}

	// --- Diff view mode dropdown menu open/close/keyboard nav ---

	function diffViewModeMenuItems() {
		return Array.from(
			document.querySelectorAll("#diffViewModeMenu .diff-view-mode-item")
		);
	}

	function openDiffViewMenu() {
		if (state.diffViewMenuOpen) return;
		state.diffViewMenuOpen = true;
		const btn = document.getElementById("diffViewModeBtn");
		const menu = document.getElementById("diffViewModeMenu");
		if (btn) btn.setAttribute("aria-expanded", "true");
		if (menu) menu.hidden = false;

		const items = diffViewModeMenuItems();
		const activeItem =
			items.find((item) => item.dataset.mode === state.diffViewMode) ||
			items[0];
		if (activeItem) activeItem.focus();
	}

	// Closing never resets zoom on its own - Escape's priority between the two
	// is handled explicitly in handleKeydown.
	function closeDiffViewMenu(options) {
		const opts = options || {};
		if (!state.diffViewMenuOpen) return;
		state.diffViewMenuOpen = false;
		const btn = document.getElementById("diffViewModeBtn");
		const menu = document.getElementById("diffViewModeMenu");
		if (btn) btn.setAttribute("aria-expanded", "false");
		if (menu) menu.hidden = true;
		if (opts.focusButton && btn) btn.focus();
	}

	function toggleDiffViewMenu() {
		if (state.diffViewMenuOpen) {
			closeDiffViewMenu({ focusButton: true });
		} else {
			openDiffViewMenu();
		}
	}

	function handleDiffViewMenuKeydown(e) {
		const items = diffViewModeMenuItems();
		const currentIndex = items.indexOf(document.activeElement);

		// Stop every key handled here from also reaching the document-level
		// handleKeydown - otherwise e.g. ArrowDown/ArrowUp would both move focus
		// inside the menu *and* be reinterpreted there as next/previous-
		// scenario navigation (j/k's arrow-key aliases).
		if (e.key === "ArrowDown") {
			e.preventDefault();
			e.stopPropagation();
			const next = items[(currentIndex + 1 + items.length) % items.length];
			if (next) next.focus();
		} else if (e.key === "ArrowUp") {
			e.preventDefault();
			e.stopPropagation();
			const prev = items[(currentIndex - 1 + items.length) % items.length];
			if (prev) prev.focus();
		} else if (e.key === "Enter" || e.key === " ") {
			e.preventDefault();
			e.stopPropagation();
			const item = items[currentIndex];
			if (item) setDiffViewMode(item.dataset.mode);
		} else if (e.key === "Escape") {
			e.preventDefault();
			e.stopPropagation();
			closeDiffViewMenu({ focusButton: true });
		} else if (e.key === "Tab") {
			closeDiffViewMenu();
		}
	}

	// --- "Fade" toggle: fades the current screenshot under the overlay,
	// cycling dark overlay -> white overlay -> none (replacing the old
	// dim-base boolean). There's no user-facing opacity slider any more - the
	// overlay itself (pixels/heatmap <img> or the regions-layer box
	// container) just keeps its CSS default opacity (0.7, the slider's old
	// default - see .diff-overlay/.regions-layer in review-html.js). ---

	const FADE_MODES = ["dark", "white", "none"];
	const FADE_MODE_LABELS = { dark: "Dark", white: "White", none: "Off" };

	function applyFadeState() {
		const paneImg = document.querySelector(".current-pane-image");
		if (!paneImg) return;
		const active = state.showDiff ? state.fadeMode : "none";
		paneImg.classList.toggle("fade-dark", active === "dark");
		paneImg.classList.toggle("fade-white", active === "white");
	}

	function updateFadeButton() {
		const btn = document.getElementById("diffFadeBtn");
		if (!btn) return;
		btn.setAttribute("aria-pressed", String(state.fadeMode !== "none"));
		btn.innerHTML = `<span>Fade</span> ${FADE_MODE_LABELS[state.fadeMode]}<span class="shortcut">[f]</span>`;
	}

	function cycleFade() {
		if (
			!scenarioSupportsDiff(effectiveScenario(state.currentScenario)) ||
			!state.showDiff
		)
			return;
		const nextIndex =
			(FADE_MODES.indexOf(state.fadeMode) + 1) % FADE_MODES.length;
		state.fadeMode = FADE_MODES[nextIndex];
		writeLocalStorage("screenshot-review-diff-fade", state.fadeMode);
		applyFadeState();
		updateFadeButton();
	}

	// --- Blink mode: flashes the diff overlay itself via the CSS
	// `diff-blink-pulse` animation (see .diff-overlay.blinking in
	// review-html.js) - a 1.5s cycle that rises to full opacity over 0.1s and
	// fades back over 0.4s, resting at 0 the rest of the time - so subtle
	// differences pop out without swapping the images underneath it. ---

	function prefersReducedMotion() {
		return (
			typeof matchMedia === "function" &&
			matchMedia("(prefers-reduced-motion: reduce)").matches
		);
	}

	function applyBlinkState() {
		// Blink pulses whichever overlay is currently showing - the
		// pixels/heatmap `<img>.diff-overlay`, or Regions mode's
		// `.regions-layer` box container - via the same `blinking` CSS class.
		const overlay = document.querySelector(".diff-overlay, .regions-layer");
		if (overlay) {
			const blinking = state.blinkMode && state.showDiff;
			overlay.classList.toggle("blinking", blinking);
			if (!blinking) {
				// The blink animation (when it was running) drove opacity itself;
				// clearing any inline value lets the overlay's CSS default opacity
				// (0.7 - see .diff-overlay/.regions-layer in review-html.js) take
				// over again, with no flash of a stale inline value.
				overlay.style.opacity = "";
			}
		}
		updateBlinkButton();
	}

	function startBlink() {
		state.blinkMode = true;
		writeLocalStorage("screenshot-review-blink", state.blinkMode);
		applyBlinkState();
	}

	// Stops blinking and resets state, without assuming the current-pane DOM
	// still exists (safe to call after a scenario/view change).
	function stopBlink() {
		state.blinkMode = false;
		writeLocalStorage("screenshot-review-blink", state.blinkMode);
		applyBlinkState();
	}

	function toggleBlinkMode() {
		if (
			!scenarioSupportsDiff(effectiveScenario(state.currentScenario)) ||
			!state.showDiff
		)
			return;
		if (state.blinkMode) {
			stopBlink();
		} else {
			startBlink();
		}
	}

	function updateBlinkButton() {
		const btn = document.getElementById("diffBlinkBtn");
		if (!btn) return;
		btn.setAttribute("aria-pressed", state.blinkMode);
		btn.title = prefersReducedMotion()
			? "Reduced motion is on, so Blink shows the overlay steadily instead of flashing it"
			: "";
	}

	// --- "Show fallback": a global toggle (like the theme) applying to every
	// "new" scenario that has a committed fallback image (see
	// buildFallbackResult in cli.js) - see effectiveScenario above for
	// how it's actually wired into rendering. Disabled entirely when nothing
	// in the manifest could use it. ---

	function toggleFallback() {
		if (!anyScenarioHasFallback()) return;
		state.fallbackActive = !state.fallbackActive;
		writeLocalStorage("screenshot-review-fallback", state.fallbackActive);
		updateView();
	}

	function updateFallbackButton() {
		const btn = document.getElementById("fallbackToggleBtn");
		if (!btn) return;
		const manifestHasFallbacks = anyScenarioHasFallback();
		btn.disabled = !manifestHasFallbacks;
		btn.setAttribute(
			"aria-pressed",
			String(manifestHasFallbacks && state.fallbackActive)
		);
		btn.innerHTML = `<span>Fallback</span> ${manifestHasFallbacks && state.fallbackActive ? "On" : "Off"}<span class="shortcut">[s]</span>`;
		btn.title = manifestHasFallbacks
			? ""
			: "No new scenario in this review has a committed fallback";
	}

	function toggleSidebar() {
		state.sidebarVisible = !state.sidebarVisible;
		document.documentElement.setAttribute(
			"data-sidebar-visible",
			state.sidebarVisible
		);
		localStorage.setItem("screenshot-review-sidebar", state.sidebarVisible);
		updateMenuToggleButton();
	}

	function updateMenuToggleButton() {
		const btn = document.getElementById("menuToggleBtn");
		if (btn) {
			btn.textContent = state.sidebarVisible ? "☰ Hide" : "☰ Show";
			btn.setAttribute("aria-pressed", state.sidebarVisible);
		}
	}

	function applyTheme(themeName) {
		state.theme = themeName;
		document.documentElement.setAttribute("data-theme", themeName);
		localStorage.setItem("screenshot-review-theme", themeName);
		const selector = document.getElementById("themeSelector");
		if (selector) {
			selector.value = themeName;
		}
	}

	function toggleTheme() {
		const lightThemes = ["light-default", "light-soft", "light-cool"];
		const darkThemes = ["dark-default", "dark-warm", "dark-cool"];

		const isLight = lightThemes.includes(state.theme);
		const nextThemes = isLight ? darkThemes : lightThemes;
		const randomTheme =
			nextThemes[Math.floor(Math.random() * nextThemes.length)];

		applyTheme(randomTheme);
	}

	function showHelp() {
		if (state.helpVisible) return;
		state.helpVisible = true;

		const helpHtml = `
      <div class="help-modal" id="helpModal">
        <div class="help-content">
          <div class="help-header">
            <h2>Keyboard Shortcuts</h2>
            <button class="help-close" aria-label="Close help">✕</button>
          </div>
          <div class="help-body">
            <table class="shortcut-table">
              <tr><td><kbd>?</kbd></td><td>Show/hide this help</td></tr>
              <tr><td><kbd>j</kbd> or <kbd>↓</kbd></td><td>Next screenshot</td></tr>
              <tr><td><kbd>k</kbd> or <kbd>↑</kbd></td><td>Previous screenshot</td></tr>
              <tr><td><kbd>Space</kbd> or <kbd>d</kbd></td><td>Toggle diff overlay</td></tr>
              <tr><td><kbd>b</kbd></td><td>Toggle blink (flash the diff overlay), while diff is on</td></tr>
              <tr><td><kbd>f</kbd></td><td>Cycle "fade" (dark overlay / white overlay / off) under the diff overlay, while diff is on</td></tr>
              <tr><td><kbd>v</kbd></td><td>Cycle diff view mode (Pixels/Heatmap/Regions), while diff is on</td></tr>
              <tr><td><kbd>s</kbd></td><td>Toggle fallback images (extracted from a "new" scenario's first-seen commit) for scenarios that have one</td></tr>
              <tr><td><kbd>t</kbd></td><td>Toggle theme (light/dark)</td></tr>
              <tr><td><kbd>m</kbd></td><td>Toggle sidebar menu</td></tr>
              <tr><td><kbd>1</kbd>–<kbd>9</kbd></td><td>Jump to screenshot</td></tr>
              <tr><td><kbd>z</kbd></td><td>Toggle zoom (2×), centred on cursor</td></tr>
              <tr><td><kbd>+</kbd> / <kbd>-</kbd></td><td>Zoom step: 2× / 4× / 8×</td></tr>
              <tr><td><kbd>↑</kbd><kbd>↓</kbd><kbd>←</kbd><kbd>→</kbd></td><td>Pan while zoomed (Shift = bigger step)</td></tr>
              <tr><td><kbd>0</kbd> or <kbd>Esc</kbd></td><td>Reset zoom</td></tr>
              <tr><td><kbd>Esc</kbd></td><td>Close this help</td></tr>
            </table>
          </div>
        </div>
      </div>
    `;

		document.body.insertAdjacentHTML("beforeend", helpHtml);
		document
			.getElementById("helpModal")
			.querySelector(".help-close")
			.addEventListener("click", hideHelp);
	}

	function hideHelp() {
		const modal = document.getElementById("helpModal");
		if (modal) {
			modal.remove();
			state.helpVisible = false;
		}
	}

	function handleKeydown(e) {
		if (state.helpVisible && e.key === "Escape") {
			hideHelp();
			return;
		}

		// Esc priority: close the diff view mode menu first if it's open,
		// without also resetting zoom in the same keypress - a second Esc is
		// then free to reset zoom, same as when the menu was never opened.
		if (!state.helpVisible && state.diffViewMenuOpen && e.key === "Escape") {
			e.preventDefault();
			closeDiffViewMenu({ focusButton: true });
			return;
		}

		if (!state.helpVisible && state.zoom.active && e.key === "Escape") {
			e.preventDefault();
			deactivateZoom();
			return;
		}

		if (e.key === "?" || e.key === "h") {
			e.preventDefault();
			if (state.helpVisible) {
				hideHelp();
			} else {
				showHelp();
			}
		} else if (!state.helpVisible && e.key === "z") {
			e.preventDefault();
			toggleZoom();
		} else if (
			!state.helpVisible &&
			state.zoom.active &&
			(e.key === "+" || e.key === "=")
		) {
			e.preventDefault();
			stepZoom(1);
		} else if (!state.helpVisible && state.zoom.active && e.key === "-") {
			e.preventDefault();
			stepZoom(-1);
		} else if (!state.helpVisible && state.zoom.active && e.key === "0") {
			e.preventDefault();
			deactivateZoom();
		} else if (
			!state.helpVisible &&
			state.zoom.active &&
			(e.key === "ArrowUp" ||
				e.key === "ArrowDown" ||
				e.key === "ArrowLeft" ||
				e.key === "ArrowRight")
		) {
			e.preventDefault();
			const step = e.shiftKey ? ZOOM_STEP_LARGE : ZOOM_STEP;
			if (e.key === "ArrowUp") panZoom(0, -step);
			else if (e.key === "ArrowDown") panZoom(0, step);
			else if (e.key === "ArrowLeft") panZoom(-step, 0);
			else panZoom(step, 0);
		} else if (e.key === "j" || e.key === "ArrowDown") {
			if (!state.helpVisible) {
				e.preventDefault();
				selectNextScenario();
			}
		} else if (e.key === "k" || e.key === "ArrowUp") {
			if (!state.helpVisible) {
				e.preventDefault();
				selectPreviousScenario();
			}
		} else if (e.code === "Space" || e.key === "d") {
			if (
				!state.helpVisible &&
				scenarioSupportsDiff(effectiveScenario(state.currentScenario))
			) {
				e.preventDefault();
				toggleDiffOverlay();
			}
		} else if (e.key === "b") {
			if (
				!state.helpVisible &&
				state.showDiff &&
				scenarioSupportsDiff(effectiveScenario(state.currentScenario))
			) {
				e.preventDefault();
				toggleBlinkMode();
			}
		} else if (e.key === "f") {
			if (
				!state.helpVisible &&
				state.showDiff &&
				scenarioSupportsDiff(effectiveScenario(state.currentScenario))
			) {
				e.preventDefault();
				cycleFade();
			}
		} else if (e.key === "s") {
			if (!state.helpVisible) {
				e.preventDefault();
				toggleFallback();
			}
		} else if (e.key === "v") {
			if (
				!state.helpVisible &&
				state.showDiff &&
				scenarioSupportsDiff(effectiveScenario(state.currentScenario))
			) {
				e.preventDefault();
				cycleDiffViewMode();
			}
		} else if (e.key === "t") {
			if (!state.helpVisible) {
				e.preventDefault();
				toggleTheme();
			}
		} else if (e.key === "m") {
			if (!state.helpVisible) {
				e.preventDefault();
				toggleSidebar();
			}
		} else if (e.key >= "1" && e.key <= "9") {
			if (!state.helpVisible) {
				const index = parseInt(e.key, 10) - 1;
				selectByIndex(index);
			}
		}
	}

	function initializeEventListeners() {
		document.documentElement.setAttribute(
			"data-sidebar-visible",
			state.sidebarVisible
		);
		applyTheme(state.theme);

		document.getElementById("scenariosList").addEventListener("click", (e) => {
			const card = e.target.closest(".scenario-card");
			if (card) {
				const index = Array.from(
					document.querySelectorAll(".scenario-card")
				).indexOf(card);
				const scenario = MANIFEST.scenarios[index];
				if (scenario) {
					selectScenario(scenario, index);
				}
			}
		});

		document
			.getElementById("diffToggleBtn")
			.addEventListener("click", toggleDiffOverlay);
		document.getElementById("diffFadeBtn").addEventListener("click", cycleFade);
		document
			.getElementById("diffBlinkBtn")
			.addEventListener("click", toggleBlinkMode);
		const diffViewModeBtn = document.getElementById("diffViewModeBtn");
		const diffViewModeMenu = document.getElementById("diffViewModeMenu");
		if (diffViewModeBtn) {
			diffViewModeBtn.addEventListener("click", toggleDiffViewMenu);
		}
		if (diffViewModeMenu) {
			diffViewModeMenu.addEventListener("click", (e) => {
				const item = e.target.closest(".diff-view-mode-item");
				if (item) setDiffViewMode(item.dataset.mode);
			});
			diffViewModeMenu.addEventListener("keydown", handleDiffViewMenuKeydown);
		}
		document.addEventListener("click", (e) => {
			if (!state.diffViewMenuOpen) return;
			if (!e.target.closest("#diffViewMode")) closeDiffViewMenu();
		});
		updateDiffViewModeButtons();
		const fallbackBtn = document.getElementById("fallbackToggleBtn");
		if (fallbackBtn) {
			fallbackBtn.addEventListener("click", toggleFallback);
			updateFallbackButton();
		}

		document
			.getElementById("menuToggleBtn")
			.addEventListener("click", toggleSidebar);
		document
			.getElementById("gutterToggleBtn")
			.addEventListener("click", toggleSidebar);
		document
			.getElementById("prevBtn")
			.addEventListener("click", selectPreviousScenario);
		document
			.getElementById("nextBtn")
			.addEventListener("click", selectNextScenario);

		const themeSelector = document.getElementById("themeSelector");
		if (themeSelector) {
			themeSelector.addEventListener("change", (e) => {
				applyTheme(e.target.value);
			});
		}

		document.addEventListener("keydown", handleKeydown);
		document.addEventListener("mousemove", handleMouseMove);
		document
			.getElementById("viewerContent")
			.addEventListener("wheel", handleWheel, { passive: false });
		window.addEventListener("hashchange", selectFromHash);

		if (MANIFEST.scenarios.length > 0) {
			selectFromHash();
		} else {
			document.getElementById("viewerContent").innerHTML =
				'<div class="empty-state"><p>No screenshots available</p></div>';
		}
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", initializeEventListeners);
	} else {
		initializeEventListeners();
	}
})();
