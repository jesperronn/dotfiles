function renderReviewHtml({ manifest, scriptSource }) {
  const escapeHtml = (str) => {
    const map = {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#039;'
    };
    return str.replace(/[&<>"']/g, (m) => map[m]);
  };

  const scenariosList = manifest.scenarios
    .map((scenario) => {
      const diff_path = scenario.diff_path || scenario.current_path;
      return `
    <div class="scenario-card" data-file="${escapeHtml(scenario.file)}" data-baseline="${escapeHtml(scenario.baseline_path)}" data-current="${escapeHtml(scenario.current_path)}" data-diff="${escapeHtml(diff_path)}">
      <h3>${escapeHtml(scenario.file)}</h3>
      <div class="scenario-preview">
        <img src="${escapeHtml(scenario.current_path)}" alt="${escapeHtml(scenario.file)}" loading="lazy" />
      </div>
    </div>`;
    })
    .join('\n');

  const html = `<!DOCTYPE html>
<html lang="en" data-sidebar-visible="true" data-theme="light-default">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Screenshot Review</title>
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

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: var(--color-bg-secondary);
      color: var(--color-text-primary);
      transition: background-color 0.7s, color 0.7s;
    }

    .header {
      background: var(--color-bg-primary);
      border-bottom: 1px solid var(--color-border);
      padding: 20px;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
      position: sticky;
      top: 0;
      z-index: 100;
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

    .container {
      max-width: 100%;
      margin: 0;
      padding: 0;
      display: grid;
      grid-template-columns: 300px 1fr;
      height: calc(100vh - 180px);
    }

    html[data-sidebar-visible="false"] .container {
      grid-template-columns: 40px 1fr;
    }

    .sidebar-wrapper {
      display: flex;
      flex-direction: column;
      border-right: 1px solid var(--color-border);
      transition: all 0.3s;
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
      padding: 0;
      flex: 1;
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
    }

    .viewer {
      background: var(--color-bg-primary);
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .viewer-header {
      background-color: var(--color-bg-tertiary);
      padding: 12px 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 8px;
    }

    .viewer-header h2 {
      font-size: 14px;
      color: var(--color-text-primary);
      flex: 1;
      min-width: 200px;
      word-break: break-all;
    }

    .viewer-controls {
      display: flex;
      gap: 8px;
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
      gap: 6px;
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

    .diff-overlay {
      position: absolute;
      top: 0;
      left: 0;
      mix-blend-mode: screen;
      pointer-events: none;
      opacity: 0.7;
    }

    .diff-overlay.hidden {
      display: none;
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

      .viewer-header {
        flex-direction: column;
        align-items: flex-start;
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
      <h1>Screenshot Review</h1>
      <div class="header-controls">
        <div class="control-group">
          <label for="themeSelector">Theme <span class="shortcut">[t]</span></label>
          <select id="themeSelector" aria-label="Select theme">
            <option value="light-default">Light (Default)</option>
            <option value="light-soft">Light (Soft)</option>
            <option value="light-cool">Light (Cool)</option>
            <option value="dark-default">Dark (Default)</option>
            <option value="dark-warm">Dark (Warm)</option>
            <option value="dark-cool">Dark (Cool)</option>
          </select>
        </div>
        <button class="control-btn" id="diffToggleBtn" aria-label="Toggle diff overlay">
          <span>Diff</span> Off
          <span class="shortcut">[d]</span>
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
          <div class="nav-buttons">
            <button class="nav-btn" id="prevBtn" aria-label="Previous screenshot">← Prev <span class="shortcut">[k]</span></button>
            <button class="nav-btn" id="nextBtn" aria-label="Next screenshot">Next → <span class="shortcut">[j]</span></button>
          </div>
        </div>
      </div>
      <div class="comparison-info">
        <div class="info-block">
          <h3>Baseline</h3>
          <p>${escapeHtml(manifest.baseline.ref)}</p>
          <p>${escapeHtml(manifest.baseline.describe)}</p>
          <p>${escapeHtml(manifest.baseline.generated_at)}</p>
        </div>
        <div class="info-block">
          <h3>Current</h3>
          <p>${escapeHtml(manifest.current.describe)}</p>
          <p>${escapeHtml(manifest.current.generated_at)}</p>
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
  renderReviewHtml
};
