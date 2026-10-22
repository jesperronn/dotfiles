const { changedPercentColor } = require("./changed-percent-color");

function renderReviewHtml({
	manifest,
	scriptSource,
	title = "Screenshot Review",
}) {
	// Fields like baseline_path/current_path/diff_path are null for new/removed
	// scenarios (there's genuinely nothing on that side to point at) - render
	// that as an empty attribute/text rather than crashing.
	const escapeHtml = (str) => {
		if (str === null || str === undefined) return "";
		const map = {
			"&": "&amp;",
			"<": "&lt;",
			">": "&gt;",
			'"': "&quot;",
			"'": "&#039;",
		};
		return String(str).replace(/[&<>"']/g, (m) => map[m]);
	};

	// Timestamps are shown as just the date (YYYY-MM-DD), with the full ISO
	// string available on hover via a native <time title="..."> - accessible
	// (assistive tech reads the datetime/title) without cluttering the UI with
	// full timestamps everywhere. Falls back to the raw string if it doesn't
	// look like an ISO timestamp. Kept in sync with the client-side duplicate
	// in review-page.js (same reasoning as changedPercentColor there).
	const formatDateOnly = (iso) => {
		if (!iso) return "";
		const match = String(iso).match(/^(\d{4}-\d{2}-\d{2})/);
		return match ? match[1] : String(iso);
	};

	const renderTime = (iso) => {
		if (!iso) return "";
		return `<time datetime="${escapeHtml(iso)}" title="${escapeHtml(iso)}">${escapeHtml(formatDateOnly(iso))}</time>`;
	};

	// Local time of the machine that generated the page, with its UTC offset
	// (e.g. "2026-10-22 00:35 +02:00"); the tooltip keeps the exact ISO value.
	const formatLocalMinutes = (iso) => {
		const date = new Date(iso);
		if (Number.isNaN(date.getTime())) return String(iso);
		const pad = (n) => String(n).padStart(2, "0");
		const offsetMinutes = -date.getTimezoneOffset();
		const sign = offsetMinutes < 0 ? "-" : "+";
		const abs = Math.abs(offsetMinutes);
		return (
			`${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
			`${pad(date.getHours())}:${pad(date.getMinutes())} ` +
			`${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
		);
	};
	const generatedIso = manifest.current && manifest.current.generated_at;
	const generatedAtHtml = generatedIso
		? `<span class="generated-at" title="${escapeHtml(generatedIso)}">generated: ${escapeHtml(
				formatLocalMinutes(generatedIso)
			)}</span>`
		: "";

	const statusBadge = (status) => {
		if (status === "new")
			return '<span class="status-badge status-badge-new">NEW</span>';
		if (status === "removed")
			return '<span class="status-badge status-badge-removed">REMOVED</span>';
		return "";
	};

	// Shared with the header badge rendered client-side in review-page.js
	// (kept as a small duplicate there rather than shared module, since the
	// sidebar is baked in at generation time here while the header re-renders
	// per selected scenario in the browser). New/removed scenarios have
	// nothing to compare, so they get no badge; a size mismatch reuses its
	// own descriptive label in place of a percentage.
	const changedBadgeText = (scenario) => {
		if (scenario.status === "new" || scenario.status === "removed") return "";
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
		return scenario.size_mismatch
			? `${percentText} — ${scenario.size_mismatch}`
			: percentText;
	};

	const scenariosList = manifest.scenarios
		.map((scenario) => {
			const diff_path = scenario.diff_path || scenario.current_path;
			const thumbSrc = scenario.current_path || scenario.baseline_path;
			const thumb = thumbSrc
				? `<img src="${escapeHtml(thumbSrc)}" alt="${escapeHtml(scenario.file)}" loading="lazy" />`
				: '<div class="scenario-preview-empty">No image</div>';
			const badgeText = changedBadgeText(scenario);
			// A size mismatch still keeps the "size differs" note, but the color
			// now follows the same green-to-red changed_percent gauge as a plain
			// percentage badge (rather than a fixed red) - .change-badge-size-mismatch
			// is only a fallback for when there's no numeric percent to gauge.
			let badgeStyle = "";
			if (typeof scenario.changed_percent === "number") {
				const color = changedPercentColor(scenario.changed_percent);
				if (color)
					badgeStyle = ` style="background: ${color.background}; color: ${color.color};"`;
			}
			const changeBadgeClass = scenario.diff_error
				? " change-badge-size-mismatch"
				: scenario.size_mismatch
					? " change-badge-size-mismatch"
					: "";
			const changeBadge = badgeText
				? `<span class="change-badge${changeBadgeClass}"${badgeStyle}>${escapeHtml(badgeText)}</span>`
				: "";
			return `
    <div class="scenario-card" data-file="${escapeHtml(scenario.file)}" data-status="${escapeHtml(scenario.status)}" data-baseline="${escapeHtml(scenario.baseline_path)}" data-current="${escapeHtml(scenario.current_path)}" data-diff="${escapeHtml(diff_path)}">
      <h3>${escapeHtml(scenario.file)} ${statusBadge(scenario.status)}</h3>
      <div class="scenario-preview">
        ${thumb}
      </div>
      ${changeBadge ? `<div class="scenario-change">${changeBadge}</div>` : ""}
    </div>`;
		})
		.join("\n");

	const html = `<!DOCTYPE html>
<html lang="en" data-sidebar-visible="true" data-theme="light-default">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)}</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    /* Theme Variables */
    :root {
      --color-bg-primary: #ffffff;
      --color-bg-secondary: #f5f5f5;
      --color-bg-tertiary: #fafafa;
      --color-text-primary: #333333;
      --color-text-secondary: #666666;
      --color-text-tertiary: #999999;
      --color-border: #dddddd;
      --color-accent: #2196f3;
      --color-accent-light: #e3f2fd;
      --thumb-focus: 35% 35%;
    }

    html[data-theme="light-soft"] {
      --color-bg-primary: #fffef9;
      --color-bg-secondary: #f9f7f2;
      --color-bg-tertiary: #f5f2ed;
      --color-text-primary: #3a3a3a;
      --color-text-secondary: #6b6b6b;
      --color-text-tertiary: #999999;
      --color-border: #e0dcd4;
      --color-accent: #d97706;
      --color-accent-light: #fef3c7;
    }

    html[data-theme="light-cool"] {
      --color-bg-primary: #ffffff;
      --color-bg-secondary: #f0f4f8;
      --color-bg-tertiary: #e8f0f8;
      --color-text-primary: #1e293b;
      --color-text-secondary: #475569;
      --color-text-tertiary: #94a3b8;
      --color-border: #cbd5e1;
      --color-accent: #0369a1;
      --color-accent-light: #e0f2fe;
    }

    html[data-theme="dark-default"] {
      --color-bg-primary: #1e1e1e;
      --color-bg-secondary: #2a2a2a;
      --color-bg-tertiary: #3a3a3a;
      --color-text-primary: #ffffff;
      --color-text-secondary: #bbbbbb;
      --color-text-tertiary: #888888;
      --color-border: #444444;
      --color-accent: #42a5f5;
      --color-accent-light: #1a3a52;
    }

    html[data-theme="dark-warm"] {
      --color-bg-primary: #1a1410;
      --color-bg-secondary: #2a2016;
      --color-bg-tertiary: #3a3020;
      --color-text-primary: #f5f1ed;
      --color-text-secondary: #d4ccc4;
      --color-text-tertiary: #998877;
      --color-border: #554433;
      --color-accent: #f59e0b;
      --color-accent-light: #4a3a2a;
    }

    html[data-theme="dark-cool"] {
      --color-bg-primary: #0f172a;
      --color-bg-secondary: #1e293b;
      --color-bg-tertiary: #334155;
      --color-text-primary: #f1f5f9;
      --color-text-secondary: #cbd5e1;
      --color-text-tertiary: #94a3b8;
      --color-border: #475569;
      --color-accent: #06b6d4;
      --color-accent-light: #164e63;
    }

    html, body {
      height: 100%;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: var(--color-bg-secondary);
      color: var(--color-text-primary);
      transition: background-color 0.7s, color 0.7s;
      height: 100vh;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }

    .header {
      background: var(--color-bg-primary);
      border-bottom: 1px solid var(--color-border);
      padding: 5px 20px;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
      flex: 0 0 auto;
      transition: background-color 0.7s, border-color 0.7s;
    }

    .header-top {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
    }

    .header h1 {
      font-size: 24px;
      margin: 0;
    }

    .header-title {
      display: flex;
      align-items: baseline;
      gap: 12px;
      min-width: 0;
    }

    .generated-at {
      font-size: 11px;
      color: var(--color-text-tertiary);
      white-space: nowrap;
    }

    @media (max-width: 1280px) {
      .generated-at {
        display: none;
      }
    }

    .header-controls {
      display: flex;
      gap: 16px;
      align-items: center;
    }

    .control-group {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .control-group label {
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      color: var(--color-text-tertiary);
      white-space: nowrap;
    }

    .control-btn {
      padding: 6px 12px;
      border: 1px solid var(--color-border);
      background: var(--color-bg-primary);
      color: var(--color-text-primary);
      border-radius: 4px;
      cursor: pointer;
      font-size: 13px;
      transition: all 0.2s;
      display: flex;
      align-items: center;
      gap: 6px;
      white-space: nowrap;
    }

    .control-btn:hover {
      background: var(--color-bg-tertiary);
      border-color: var(--color-text-secondary);
    }

    .control-btn:active {
      opacity: 0.7;
    }

    .control-btn[aria-pressed="true"] {
      background: var(--color-accent);
      color: white;
      border-color: var(--color-accent);
    }

    .shortcut {
      font-size: 11px;
      color: var(--color-text-tertiary);
      white-space: nowrap;
    }

    #themeSelector {
      padding: 4px 8px;
      border: 1px solid var(--color-border);
      background: var(--color-bg-primary);
      color: var(--color-text-primary);
      border-radius: 4px;
      font-size: 13px;
      cursor: pointer;
    }

    .header-info {
      display: none;
    }

    .info-block {
      font-size: 12px;
      color: var(--color-text-secondary);
      padding: 8px 12px;
      background: var(--color-bg-tertiary);
      border-bottom: 1px solid var(--color-border);
      transition: all 0.3s;
    }

    .info-block h3 {
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      color: var(--color-text-tertiary);
      margin-bottom: 4px;
    }

    .info-block p {
      margin: 2px 0;
      font-family: "Monaco", "Courier New", monospace;
      font-size: 11px;
      word-break: break-all;
      color: var(--color-text-secondary);
    }

    .baseline-images-note {
      color: var(--color-text-tertiary);
      font-size: 10px !important;
    }

    .dirty-badge,
    .status-badge {
      display: inline-block;
      padding: 1px 6px;
      border-radius: 3px;
      background: var(--color-danger, #d9534f);
      color: #fff;
      font-weight: 600;
      text-transform: uppercase;
      font-size: 10px;
    }

    /* Fixed (not theme-token) colours, same approach as .dirty-badge, chosen
       for readable contrast with white text in both light and dark themes. */
    .status-badge-new {
      background: #2e7d32;
    }

    .status-badge-removed {
      background: #b23c17;
    }

    /* Distinct from NEW/REMOVED/dirty so a fallback baseline is never
       mistaken for the real one. */
    .fallback-badge {
      background: #6a1b9a;
    }

    /* .status-badge sets display: inline-block unconditionally, which
       otherwise beats the browser's default [hidden] { display: none } UA
       rule (same specificity, author style wins) - same fix already used
       for #diffPercentBadge/#zoomBadge below. */
    .fallback-badge[hidden] {
      display: none;
    }

    /* Opts the label/date back out of .status-badge's text-transform:
       uppercase - only the literal word "FALLBACK" should be uppercase,
       not the git describe label or date next to it. */
    .fallback-badge-detail {
      text-transform: none;
    }

    .scenario-preview-empty {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      color: var(--color-text-tertiary);
      font-size: 11px;
    }

    .placeholder-pane {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      height: 100%;
      min-height: 200px;
      padding: 20px;
      text-align: center;
      color: var(--color-text-secondary);
      font-size: 13px;
    }

    /* The "not in baseline" / "removed since" headline: bold, noticeably
       larger than body text, and dimmed (muted colour, not full-strength
       text) rather than an attention-grabbing color - it's an absence, not
       an error. Works unmodified in light and dark themes since it's built
       entirely from theme tokens. */
    .placeholder-main {
      font-weight: 700;
      font-size: 1.75rem;
      color: var(--color-text-tertiary);
      opacity: 0.8;
      line-height: 1.3;
    }

    /* The "first appeared in ..." detail line: intentionally tiny, well
       below body size, since it's supporting detail rather than the main
       message. */
    .placeholder-sub {
      font-size: 0.7rem;
      color: var(--color-text-tertiary);
    }

    .container {
      max-width: 100%;
      margin: 0;
      padding: 0;
      display: grid;
      grid-template-columns: 300px 1fr;
      flex: 1 1 auto;
      min-height: 0;
      overflow: hidden;
    }

    html[data-sidebar-visible="false"] .container {
      grid-template-columns: 40px 1fr;
    }

    .sidebar-wrapper {
      display: flex;
      flex-direction: column;
      border-right: 1px solid var(--color-border);
      transition: all 0.3s;
      height: 100%;
      min-height: 0;
      overflow: hidden;
    }

    html[data-sidebar-visible="false"] .sidebar-wrapper {
      background: var(--color-bg-tertiary);
      padding: 8px 4px;
    }

    .sidebar-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 12px;
      background: var(--color-bg-tertiary);
      transition: all 0.3s;
      height: 53px;
    }

    html[data-sidebar-visible="false"] .sidebar-header {
      display: none;
    }

    .sidebar-header h3 {
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      color: var(--color-text-tertiary);
      margin: 0;
    }

    .menu-toggle-btn {
      padding: 4px 8px;
      border: 1px solid var(--color-border);
      background: var(--color-bg-primary);
      color: var(--color-text-primary);
      border-radius: 3px;
      cursor: pointer;
      font-size: 12px;
      transition: all 0.2s;
    }

    .menu-toggle-btn:hover {
      background: var(--color-bg-secondary);
    }

    .menu-toggle-gutter {
      display: none;
      width: 40px;
      padding: 8px 4px;
      background: var(--color-bg-tertiary);
      border-right: 1px solid var(--color-border);
      transition: all 0.3s;
    }

    html[data-sidebar-visible="false"] .menu-toggle-gutter {
      display: flex;
      align-items: flex-start;
      justify-content: center;
    }

    .gutter-toggle-btn {
      padding: 4px;
      border: none;
      background: transparent;
      color: var(--color-text-secondary);
      cursor: pointer;
      font-size: 20px;
      width: 28px;
      height: 28px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 3px;
      transition: all 0.2s;
    }

    .gutter-toggle-btn:hover {
      background: var(--color-border);
      color: var(--color-text-primary);
    }

    .scenarios-list {
      background: var(--color-bg-primary);
      overflow-y: auto;
      overflow-x: hidden;
      padding: 0;
      flex: 1 1 auto;
      min-height: 0;
      scrollbar-width: auto;
      scrollbar-color: var(--color-text-tertiary) var(--color-bg-primary);
    }

    .scenarios-list::-webkit-scrollbar {
      width: 10px;
    }

    .scenarios-list::-webkit-scrollbar-track {
      background: var(--color-bg-primary);
    }

    .scenarios-list::-webkit-scrollbar-thumb {
      background: var(--color-border);
      border-radius: 5px;
    }

    html[data-sidebar-visible="false"] .sidebar-wrapper {
      display: none;
    }

    .scenario-card {
      padding: 12px;
      border-bottom: 1px solid var(--color-border);
      cursor: pointer;
      transition: background 0.2s;
    }

    .scenario-card:hover {
      background: var(--color-bg-secondary);
    }

    .scenario-card.active {
      background: var(--color-accent-light);
      border-left: 4px solid var(--color-accent);
      padding-left: calc(12px - 4px);
    }

    .scenario-card h3 {
      font-size: 12px;
      margin-bottom: 8px;
      word-break: break-all;
      color: var(--color-text-primary);
    }

    .scenario-preview {
      width: 100%;
      height: 80px;
      overflow: hidden;
      border-radius: 4px;
      background: var(--color-bg-secondary);
      border: 1px solid var(--color-border);
    }

    .scenario-preview img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      object-position: var(--thumb-focus);
    }

    .viewer {
      background: var(--color-bg-primary);
      overflow: hidden;
      display: flex;
      flex-direction: column;
      min-height: 0;
      height: 100%;
    }

    /* flex-wrap: nowrap keeps the whole toolbar - filename plus every
       control - on a single row at any viewport width. #diffPercentBadge
       (inside .viewer-controls below) is the only item allowed to give up
       width; the filename and every control keep their natural width and
       never shrink or wrap - see the comment on .viewer-controls. */
    .viewer-header {
      background-color: var(--color-bg-tertiary);
      padding: 12px 16px;
      display: flex;
      justify-content: space-between;
      align-items: stretch;
      flex-wrap: nowrap;
      gap: 8px;
      min-width: 0;
    }

    .viewer-header h2 {
      font-size: 14px;
      color: var(--color-text-primary);
      flex: 0 0 auto;
      white-space: nowrap;
    }

    /* align-items: stretch (rather than the default center) makes every
       direct child - the % badge, .diff-controls, the zoom badge, and
       .nav-buttons - share this row's full height, which is however tall
       its tallest child needs to be. Combined with white-space: nowrap on
       the badges/buttons below (so a two-word label or a "[k]"-style
       shortcut never wraps onto a second line and inflates that child's
       own height), every item ends up the same height instead of the
       previous mix of one- and two-line controls.

       The row intentionally never wraps (flex-wrap: nowrap): #diffPercentBadge
       is the one flexible item (flex: 1 1 auto, min-width: 0 below) and
       absorbs any extra or missing width by growing or shrinking - down to
       ellipsis-truncating its own text - while every other item keeps its
       natural width (flex: 0 0 auto) and never shrinks or wraps, so the
       toolbar always stays a single row at any viewport width. */
    .viewer-controls {
      display: flex;
      align-items: stretch;
      flex: 1 1 auto;
      flex-wrap: nowrap;
      gap: 8px;
      min-width: 0;
    }

    .viewer-content {
      flex: 1;
      overflow: auto;
      background: var(--color-bg-secondary);
    }

    .comparison-info {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      padding: 0 20px 0;
      background-color: var(--color-bg-secondary);
    }

    .comparison-info .info-block {
      border-color: var(--color-border);
      border-style: solid;
      border-width: 1px 1px 0;
      padding: 12px;
    }

    .comparison-container {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      padding: 0 20px 20px;
      min-height: 100%;
    }

    .comparison-container .comparison-pane {
      padding-right: 0 10px;
    }


    .nav-buttons {
      display: flex;
      align-items: stretch;
      flex: 0 0 auto;
      gap: 6px;
      white-space: nowrap;
    }

    .nav-btn {
      padding: 6px 8px;
      border: 1px solid var(--color-border);
      background: var(--color-bg-primary);
      color: var(--color-text-primary);
      border-radius: 3px;
      cursor: pointer;
      font-size: 12px;
      transition: all 0.2s;
      display: flex;
      align-items: center;
      flex: 0 0 auto;
      gap: 4px;
      white-space: nowrap;
    }

    /* Both labels share one grid cell, so the button is always as wide as the
       longer one and swapping them on Shift never moves the layout. The
       hidden one keeps its width via visibility, not display. */
    .nav-label {
      display: inline-grid;
    }

    .nav-label > span {
      grid-area: 1 / 1;
      text-align: center;
    }

    .nav-label-shift,
    html[data-shift="true"] .nav-label-normal {
      visibility: hidden;
    }

    html[data-shift="true"] .nav-label-shift {
      visibility: visible;
    }

    .nav-btn:hover {
      background: var(--color-bg-secondary);
      border-color: var(--color-text-secondary);
    }

    .nav-btn:active {
      opacity: 0.7;
    }

    .comparison-pane {
      display: flex;
      flex-direction: column;
      background: var(--color-bg-primary);
      border-right: 1px solid var(--color-border);
      border-left: 1px solid var(--color-border);
      border-radius: 4px;
      overflow: hidden;
    }

    .comparison-pane, .info-block {
      border-width: 0 1px;
      border-style: solid;
      border-color: var(--color-border);
    }

    .pane-header {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 8px 12px;
      background: var(--color-bg-tertiary);
      border-bottom: 1px solid var(--color-border);
      min-height: 40px;
      transition: all 0.3s;
    }

    .pane-label {
      font-size: 11px;
      font-weight: 600;
      color: var(--color-text-tertiary);
      text-transform: uppercase;
      flex: 0 0 auto;
      width: 100%;
      padding-left: 12px;
      text-align: left;
      transition: all 0.3s;
    }

    .pane-meta {
      font-size: 10px;
      font-weight: 400;
      text-transform: none;
      color: var(--color-text-tertiary);
      font-family: "Monaco", "Courier New", monospace;
      display: block;
      margin-top: 2px;
    }

    .control-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    .control-btn:disabled:hover {
      background: var(--color-bg-primary);
      border-color: var(--color-border);
    }

    .pane-image {
      flex: 1;
      overflow: auto;
      position: relative;
      display: flex;
      align-items: flex-start;
      justify-content: flex-start;
    }

    .pane-image img {
      width: 100%;
      height: auto;
      display: block;
    }

    /* Zoom/pan: .zoom-layer wraps a pane's image layer(s) and is the sole
       target of the shared {scale, x, y} view state (see applyViewTransform
       in review-page.js). transform-origin is set to the x/y percentages so
       panels of different heights still zoom to the same relative point.
       The diff overlay/fade layer are plain children of this same element
       (or of its .overlay-zoom-layer sibling, itself a .zoom-layer), so
       they ride along with exactly this transform - nothing extra needed to
       keep them in lockstep.

       transform/transform-origin transition over ~0.3s ease so stepping
       between zoom levels (z, +/-, 0/Esc) and arrow-key panning animate
       smoothly, rather than jumping. Cursor-centred zoom-follow
       (mousemove while zoomed - see handleMouseMove in review-page.js)
       applies its transform-origin update with this transition suppressed
       (an inline transition override of "none", restored after a forced
       reflow) so tracking the cursor never lags behind it. */
    .zoom-layer {
      position: relative;
      width: 100%;
      transition: transform 0.3s ease, transform-origin 0.3s ease;
    }

    /* Respect reduced-motion: apply zoom/pan changes instantly. */
    @media (prefers-reduced-motion: reduce) {
      .zoom-layer {
        transition: none;
      }
    }

    .zoom-layer.pixelated img {
      image-rendering: pixelated;
    }

    .pane-image.zoomed {
      cursor: crosshair;
      overflow: hidden;
    }

    .zoom-badge {
      display: flex;
      align-items: center;
      flex: 0 0 auto;
      font-size: 11px;
      font-weight: 600;
      color: var(--color-text-primary);
      background: var(--color-accent-light);
      border: 1px solid var(--color-accent);
      border-radius: 4px;
      padding: 2px 8px;
      white-space: nowrap;
    }

    .zoom-badge[hidden] {
      display: none;
    }

    /* .diff-zoom-layer is the one in-flow layer inside .current-pane-image:
       it's sized to the full padded diff canvas (100% of the pane's width,
       height from aspect-ratio - see currentPane() in review-page.js) and
       so establishes the pane's box size. The current/blink image layers
       (.overlay-zoom-layer) are absolutely positioned on top of it, each at
       its own width as a fraction of the canvas width, so every layer ends
       up at the same canvas-pixels-per-CSS-pixel scale. It's last in the
       markup so it paints over those layers. It still goes through the
       same applyViewTransform() zoom/pan as everything else, via the shared
       .zoom-layer class - see review-page.js. Full definition with pointer-events
       and positioning rules is below, in the fade stacking section. */

    /* Positions the current/blink image layers over .diff-zoom-layer's box
       - see the comment there. */
    .overlay-zoom-layer {
      position: absolute;
      top: 0;
      left: 0;
    }

    /* Baseline-pane counterpart to .diff-zoom-layer: a non-zooming sizing
       box at the shared padded-canvas aspect ratio, so the baseline image
       (an .overlay-zoom-layer child, sized to its own fraction of the
       canvas width) renders at the same scale as the current pane's
       layers - see baselinePane() in review-page.js. It isn't itself a
       .zoom-layer (it holds no image directly), so it doesn't get the
       zoom/pan transform applied twice. */
    .canvas-frame {
      position: relative;
      width: 100%;
    }

    .diff-overlay {
      width: 100%;
      height: 100%;
      pointer-events: none;
      opacity: 0.7;
    }

    /* Heatmap overlay renders at full opacity (opacity 1) while Pixels mode
       stays at 0.7. The mode is tracked via a class on .diff-overlay. */
    .diff-overlay.heatmap-overlay {
      opacity: 1;
    }

    .diff-overlay.hidden {
      display: none;
    }

    .hidden {
      display: none;
    }

    /* Blink flashes the diff overlay itself (a pulse of its opacity) rather
       than swapping the baseline/current images underneath it. The blink
       animation pulse uses the per-mode base opacity: 0.7 for Pixels, 1 for
       Heatmap. Decay curve: instant-on at full opacity, fast drop to 35% over
       the first 8% of the 1.5s cycle (120ms, ease-out), then slow fade to
       zero over the next 42%, holding zero for the remainder. */
    @keyframes diff-blink-pulse {
      0% {
        opacity: 1;
      }
      8% {
        opacity: 0.35;
        animation-timing-function: ease-out;
      }
      50% {
        opacity: 0;
      }
      100% {
        opacity: 0;
      }
    }

    .diff-overlay.blinking,
    .regions-layer.blinking {
      animation: diff-blink-pulse 1.5s linear infinite;
    }

    /* Respect reduced-motion: show the overlay steadily at its default
       opacity instead of pulsing (applyBlinkState() in review-page.js clears
       the inline opacity once the animation is removed here, letting this
       CSS default take over). */
    @media (prefers-reduced-motion: reduce) {
      .diff-overlay.blinking,
      .regions-layer.blinking {
        animation: none;
      }
    }

    /* Regions mode: outlined boxes + always-visible labels, positioned as
       percentages of .diff-zoom-layer's canvas box (see the comment there)
       so they land in the same coordinate space as the pixel/heatmap
       overlay and move with it under zoom/pan. Deliberately inert - no
       click/hover affordance - regions are look-only (no click-to-zoom, no
       next/previous-region navigation). */
    .regions-layer {
      opacity: 0.7;
    }

    .region-box {
      position: absolute;
      box-sizing: border-box;
      border: 2px solid #d9534f;
      pointer-events: none;
    }

    .region-label {
      position: absolute;
      top: -20px;
      left: 0;
      padding: 1px 5px;
      font-size: 11px;
      font-weight: 600;
      line-height: 1.5;
      white-space: nowrap;
      border-radius: 3px;
      pointer-events: none;
    }

    /* Flips the label inside the box (instead of floating above it) when
       the box is close enough to the canvas' top edge that the default
       placement would run off it - see renderRegionBox() in
       review-page.js. */
    .region-label.region-label-inside-y {
      top: 2px;
    }

    /* Anchors the label to the box's right edge (instead of its left) when
       the box is close enough to the canvas' right edge that a
       left-anchored label could run past it. */
    .region-label.region-label-flip-x {
      left: auto;
      right: 0;
    }

    /* "Fade" fades the current screenshot underneath the diff overlay so the
       changed pixels stand out, cycling dark overlay -> white overlay -> off
       [f]. Only the current pane can carry these classes - see
       .current-pane-image in review-page.js.

       Stacking, bottom to top, inside .current-pane-image:
         1. .overlay-zoom-layer - the screenshot <img>, plus...
         2. ...its child .fade-layer - a plain, non-.zoom-layer sibling of
            the image that paints directly above it (see review-page.js) and
            is sized to exactly fill .overlay-zoom-layer's box, i.e. exactly
            the screenshot's own box, never more.
         3. .diff-zoom-layer (.diff-overlay / .regions-layer) - the diff
            visualization, last in the DOM so it paints on top of both.

       .fade-layer is a plain, unblended, opaque-color layer (background
       colour + opacity, no mix-blend-mode) so darkening/whitening the
       screenshot is just it painting over the image - no filter or opacity
       change on the image itself. */
    .diff-zoom-layer {
      position: relative;
      width: 100%;
      pointer-events: none;
    }

    .fade-layer {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.2s, background-color 0.2s;
    }

    .current-pane-image.fade-dark .fade-layer {
      background: #000;
      opacity: 0.65;
    }

    .current-pane-image.fade-white .fade-layer {
      background: #fff;
      opacity: 0.70;
    }

    .change-badge {
      display: inline-block;
      padding: 1px 6px;
      border-radius: 3px;
      background: var(--color-bg-tertiary);
      color: var(--color-text-secondary);
      font-size: 10px;
      font-weight: 600;
      border: 1px solid var(--color-border);
    }

    .change-badge-size-mismatch {
      background: var(--color-danger, #d9534f);
      color: #fff;
      border-color: transparent;
    }

    .scenario-change {
      margin-top: 6px;
    }

    /* The one flexible item in the toolbar row (see the comment on
       .viewer-controls): it grows to fill any leftover width and, unlike
       every other item, is also allowed to shrink - down to min-width below
       - instead of forcing the row to wrap or overflow. min-width: 0 lets it
       shrink past its content's natural width (the flex default is auto,
       which would otherwise never let it go below that); overflow/
       text-overflow then ellipsis-truncate the single-line text instead of
       wrapping or spilling out. The full text is always mirrored onto the
       title attribute in review-page.js so a truncated badge is still
       readable on hover. */
    #diffPercentBadge {
      display: flex;
      align-items: center;
      flex: 1 1 auto;
      min-width: 0;
      font-size: 11px;
      font-weight: 600;
      color: var(--color-text-primary);
      background: var(--color-bg-tertiary);
      border: 1px solid var(--color-border);
      border-radius: 4px;
      padding: 2px 8px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    #diffPercentBadge.size-mismatch {
      background: var(--color-danger, #d9534f);
      color: #fff;
      border-color: transparent;
    }

    #diffPercentBadge[hidden] {
      display: none;
    }

    /* align-items: stretch propagates the row's shared height (set by
       .viewer-controls above) down to Fade/Blink, so they end up the
       same height as the % badge and Prev/Next - see the comment on
       .viewer-controls. */
    .diff-controls {
      display: flex;
      align-items: stretch;
      flex: 0 0 auto;
      gap: 10px;
      background: var(--color-bg-tertiary);
      border-radius: 4px;
      white-space: nowrap;
    }

    /* Toggling #diffControls used to use the native [hidden] attribute's
       default display:none, which removes it from the flex layout
       entirely - since .viewer-header wraps, that changed the header's
       height depending on whether diff was on or off, and the comparison
       images below it jumped. Using visibility instead keeps the element
       (and the row height it occupies) in the layout at all times; only its
       painted content disappears. Combined with the padding/border removal
       above (which made this row no taller than its neighbours to begin
       with), showing/hiding it no longer changes the header's height at
       all. This ID selector intentionally beats both the browser's own
       [hidden] { display:none } UA rule and the plain .diff-controls[hidden]
       rule that used to live here. */
    #diffControls[hidden] {
      display: flex;
      visibility: hidden;
    }

    /* Fade / Blink keep their natural width inside .diff-controls,
       same as every other toolbar item - see the comment on
       .viewer-controls. */
    .diff-controls .control-btn {
      flex: 0 0 auto;
    }

    /* Compact dropdown toggle for the diff view mode (Pixels/Heatmap/
       Regions) - one button showing the current mode, a caret and the [v]
       shortcut hint, instead of a 3-button segmented control (which left too
       little room for #diffPercentBadge). position: relative anchors the
       menu below it; the menu is absolutely positioned so it overlays the
       viewer content rather than pushing it down. Shares the row's
       stretched height (align-items: stretch on .diff-controls above) like
       every other item there, so it doesn't upset the "toolbar items share
       a height" contract covered by the Playwright regression test. */
    .diff-view-mode {
      position: relative;
      display: flex;
      align-items: stretch;
      flex: 0 0 auto;
    }

    #diffViewModeBtn {
      flex: 0 0 auto;
    }

    .diff-view-mode-caret {
      font-size: 10px;
    }

    .diff-view-mode-menu {
      position: absolute;
      top: 100%;
      left: 0;
      margin-top: 4px;
      z-index: 20;
      display: flex;
      flex-direction: column;
      min-width: 100%;
      background: var(--color-bg-primary);
      border: 1px solid var(--color-border);
      border-radius: 4px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
      overflow: hidden;
      padding: 4px;
      gap: 2px;
    }

    .diff-view-mode-menu[hidden] {
      display: none;
    }

    .diff-view-mode-item {
      border: none;
      border-radius: 3px;
      background: transparent;
      color: var(--color-text-primary);
      padding: 6px 10px;
      font-size: 13px;
      text-align: left;
      white-space: nowrap;
      cursor: pointer;
    }

    .diff-view-mode-item:hover,
    .diff-view-mode-item:focus-visible {
      background: var(--color-bg-tertiary);
      outline: none;
    }

    .diff-view-mode-item[aria-checked="true"] {
      background: var(--color-accent, #4a90d9);
      color: #fff;
    }

    .empty-state {
      text-align: center;
      padding: 60px 40px;
      color: var(--color-text-secondary);
    }

    .empty-state p {
      margin: 10px 0;
      font-size: 16px;
    }

    .help-modal {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(0, 0, 0, 0.5);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
      padding: 20px;
    }

    .help-content {
      background: var(--color-bg-primary);
      border-radius: 8px;
      max-width: 500px;
      width: 100%;
      box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1);
      overflow: hidden;
    }

    .help-header {
      background: var(--color-bg-tertiary);
      border-bottom: 1px solid var(--color-border);
      padding: 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .help-header h2 {
      margin: 0;
      font-size: 18px;
      color: var(--color-text-primary);
    }

    .help-close {
      background: none;
      border: none;
      font-size: 24px;
      cursor: pointer;
      color: var(--color-text-secondary);
      padding: 0;
      width: 32px;
      height: 32px;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .help-close:hover {
      color: var(--color-text-primary);
    }

    .help-body {
      padding: 16px;
    }

    .shortcut-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }

    .shortcut-table tr {
      border-bottom: 1px solid var(--color-border);
    }

    .shortcut-table tr:last-child {
      border-bottom: none;
    }

    .shortcut-table td {
      padding: 8px;
      text-align: left;
      color: var(--color-text-primary);
    }

    .shortcut-table td:first-child {
      width: 90px;
      padding-right: 12px;
    }

    kbd {
      background: var(--color-bg-tertiary);
      border-radius: 3px;
      padding: 2px 6px;
      font-family: monospace;
      font-size: 12px;
      white-space: nowrap;
      display: inline-block;
      margin-right: 2px;
    }

    @media (max-width: 1024px) {
      .container {
        grid-template-columns: 1fr;
      }

      .scenarios-list {
        max-height: 200px;
        border-right: none;
        border-bottom: 1px solid var(--color-border);
      }

      .comparison-info {
        grid-template-columns: 1fr;
      }

      .comparison-container {
        grid-template-columns: 1fr;
      }
    }

    @media (max-width: 640px) {
      .header {
        padding: 12px;
      }

      .header h1 {
        font-size: 18px;
      }

      .header-controls {
        width: 100%;
        justify-content: flex-start;
        flex-wrap: wrap;
      }

      .header-info {
        gap: 12px;
      }

      .viewer-header h2 {
        font-size: 12px;
      }

      .control-btn {
        padding: 4px 8px;
        font-size: 12px;
      }
    }
  </style>
</head>
<body>
  <div class="header">
    <div class="header-top">
      <div class="header-title">
        <h1>${escapeHtml(title)}</h1>
        ${generatedAtHtml}
      </div>
      <div class="header-controls">
        <div class="control-group">
          <label for="themeSelector">Theme <span class="shortcut">[t]</span></label>
          <select id="themeSelector" aria-label="Select theme">
            <option value="dark-cool">Dark (Cool)</option>
            <option value="dark-default">Dark (Default)</option>
            <option value="dark-warm">Dark (Warm)</option>
            <option value="light-cool">Light (Cool)</option>
            <option value="light-default">Light (Default)</option>
            <option value="light-soft">Light (Soft)</option>
          </select>
        </div>
        <button class="control-btn" id="diffToggleBtn" aria-label="Toggle diff overlay">
          <span>Diff</span> Off
          <span class="shortcut">[d]</span>
        </button>
        <button class="control-btn" id="fallbackToggleBtn" aria-label="Toggle fallback images for new scenarios" aria-pressed="false">
          <span>Fallback</span> Off
          <span class="shortcut">[s]</span>
        </button>
      </div>
    </div>
  </div>

  <div class="container">
    <div class="menu-toggle-gutter">
      <button class="gutter-toggle-btn" id="gutterToggleBtn" aria-label="Toggle sidebar menu">☰</button>
    </div>
    <div class="sidebar-wrapper">
      <div class="sidebar-header">
        <h3>Screenshots</h3>
        <button class="menu-toggle-btn" id="menuToggleBtn" aria-label="Toggle sidebar menu">Hide <span class="shortcut">[m]</span></button>
      </div>
      <div class="scenarios-list" id="scenariosList">
${scenariosList}
      </div>
    </div>

    <div class="viewer">
      <div class="viewer-header">
        <h2 id="selectedFile">Select a screenshot</h2>
        <div class="viewer-controls">
          <span class="diff-percent-badge" id="diffPercentBadge" hidden></span>
          <div class="diff-controls" id="diffControls" hidden>
            <button class="control-btn" id="diffFadeBtn" aria-label="Cycle fade (dark overlay / white overlay / off) under the diff overlay" aria-pressed="false">
              <span>Fade</span> Off<span class="shortcut">[f]</span>
            </button>
            <button class="control-btn" id="diffBlinkBtn" aria-label="Blink the diff overlay" aria-pressed="false">
              Blink <span class="shortcut">[b]</span>
            </button>
            <div class="diff-view-mode" id="diffViewMode">
              <button
                class="control-btn"
                id="diffViewModeBtn"
                aria-haspopup="menu"
                aria-expanded="false"
                aria-controls="diffViewModeMenu"
              >
                <span id="diffViewModeLabel">Pixels</span> <span class="diff-view-mode-caret" aria-hidden="true">▾</span>
                <span class="shortcut">[v]</span>
              </button>
              <div class="diff-view-mode-menu" id="diffViewModeMenu" role="menu" aria-label="Diff overlay view mode" hidden>
                <button class="diff-view-mode-item" id="diffViewPixelsBtn" role="menuitemradio" aria-checked="true" data-mode="pixels">
                  Pixels
                </button>
                <button class="diff-view-mode-item" id="diffViewHeatmapBtn" role="menuitemradio" aria-checked="false" data-mode="heatmap">
                  Heatmap
                </button>
                <button class="diff-view-mode-item" id="diffViewRegionsBtn" role="menuitemradio" aria-checked="false" data-mode="regions">
                  Regions
                </button>
              </div>
            </div>
          </div>
          <span class="zoom-badge" id="zoomBadge" hidden></span>
          <div class="nav-buttons">
            <button class="nav-btn" id="prevBtn" aria-label="Previous screenshot (hold Shift to jump 10)"><span class="nav-label"><span class="nav-label-normal">← Prev</span><span class="nav-label-shift" aria-hidden="true">← Prev 10</span></span> <span class="shortcut">[k]</span></button>
            <button class="nav-btn" id="nextBtn" aria-label="Next screenshot (hold Shift to jump 10)"><span class="nav-label"><span class="nav-label-normal">Next →</span><span class="nav-label-shift" aria-hidden="true">Next 10 →</span></span> <span class="shortcut">[j]</span></button>
          </div>
        </div>
      </div>
      <div class="comparison-info">
        <div class="info-block">
          <h3>Baseline</h3>
          <p>${escapeHtml(manifest.baseline.describe)} <span class="status-badge fallback-badge" id="baselineFallbackTag" hidden></span></p>
          <p id="baselineMeta"></p>
        </div>
        <div class="info-block">
          <h3>Current</h3>
          <p>${escapeHtml(manifest.current.describe)}${manifest.current.dirty ? ' <span class="dirty-badge">dirty</span>' : ""}</p>
          <p id="currentMeta">${renderTime(manifest.current.generated_at)}</p>
        </div>
      </div>
      <div class="viewer-content" id="viewerContent">
        <div class="empty-state">
          <p>👈 Select a screenshot from the list to begin</p>
          <p style="font-size: 13px; color: var(--color-text-tertiary);">Press <kbd>?</kbd> for keyboard shortcuts</p>
        </div>
      </div>
    </div>
  </div>

  <script>
    const MANIFEST = ${JSON.stringify(manifest)};
    ${scriptSource}
  </script>
</body>
</html>`;

	return html;
}

module.exports = {
	renderReviewHtml,
};
