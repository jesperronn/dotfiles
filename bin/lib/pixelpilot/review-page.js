// Screenshot Review - Interactive Client Code

(function () {
  const state = {
    currentScenario: null,
    currentIndex: 0,
    showDiff: localStorage.getItem('screenshot-review-diff') === 'true',
    sidebarVisible: localStorage.getItem('screenshot-review-sidebar') !== 'false',
    theme: localStorage.getItem('screenshot-review-theme') || 'light-default',
    helpVisible: false
  };

  function renderComparisonView(scenario) {
    if (!scenario) {
      return `<div class="empty-state"><p>👈 Select a screenshot from the list to begin</p></div>`;
    }

    const baselineImage = `<img src="${escapeAttr(scenario.baseline_path)}" alt="Baseline" loading="eager" />`;
    const currentImage = `<img src="${escapeAttr(scenario.current_path)}" alt="Current" loading="eager" />`;
    const diffImage = scenario.diff_path ? `<img src="${escapeAttr(scenario.diff_path)}" alt="Diff" loading="eager" class="diff-overlay${state.showDiff ? '' : ' hidden'}" />` : '';

    return `
      <div class="comparison-container">
        <div class="comparison-pane">
          <div class="pane-label">Baseline</div>
          <div class="pane-image">
            ${baselineImage}
          </div>
        </div>
        <div class="comparison-pane">
          <div class="pane-label">Current</div>
          <div class="pane-image">
            ${currentImage}
            ${diffImage}
          </div>
        </div>
      </div>`;
  }

  function updateView() {
    const content = document.getElementById('viewerContent');
    content.innerHTML = renderComparisonView(state.currentScenario);
    updateDiffToggleButton();
  }

  function selectScenario(scenario, index, options) {
    const opts = options || {};
    state.currentScenario = scenario;
    state.currentIndex = index;

    document.querySelectorAll('.scenario-card').forEach((card) => {
      card.classList.remove('active');
    });

    const selectedCard = document.querySelector(`[data-file="${escapeAttr(scenario.file)}"]`);
    if (selectedCard) {
      selectedCard.classList.add('active');
      selectedCard.scrollIntoView({ block: 'nearest' });
    }

    // Scroll page to top when selecting new scenario
    window.scrollTo(0, 0);

    document.getElementById('selectedFile').textContent = escapeHtml(scenario.file);
    updateView();

    if (!opts.skipHashUpdate) {
      history.replaceState(null, '', '#' + encodeURIComponent(scenario.file));
    }
  }

  function findScenarioIndexByFile(file) {
    return MANIFEST.scenarios.findIndex((scenario) => scenario.file === file);
  }

  function selectFromHash() {
    const file = decodeURIComponent(location.hash.replace(/^#/, ''));
    const index = file ? findScenarioIndexByFile(file) : -1;

    if (index >= 0) {
      selectScenario(MANIFEST.scenarios[index], index, { skipHashUpdate: true });
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
    const prevIndex = (state.currentIndex - 1 + MANIFEST.scenarios.length) % MANIFEST.scenarios.length;
    selectScenario(MANIFEST.scenarios[prevIndex], prevIndex);
  }

  function selectByIndex(index) {
    if (index >= 0 && index < MANIFEST.scenarios.length) {
      selectScenario(MANIFEST.scenarios[index], index);
    }
  }

  function escapeHtml(str) {
    const map = {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#039;'
    };
    return str.replace(/[&<>"']/g, (m) => map[m]);
  }

  function escapeAttr(str) {
    return str.replace(/"/g, '&quot;');
  }

  function updateDiffToggleButton() {
    const btn = document.getElementById('diffToggleBtn');
    if (!state.currentScenario || !state.currentScenario.diff_path) {
      btn.style.display = 'none';
    } else {
      btn.style.display = 'flex';
      const text = state.showDiff ? '✓ Diff On' : 'Diff Off';
      btn.innerHTML = `<span>Diff</span> ${state.showDiff ? 'On' : 'Off'}<span class="shortcut">[d]</span>`;
      btn.setAttribute('aria-pressed', state.showDiff);
    }
  }

  function toggleDiffOverlay() {
    state.showDiff = !state.showDiff;
    localStorage.setItem('screenshot-review-diff', state.showDiff);
    const diffOverlay = document.querySelector('.diff-overlay');
    if (diffOverlay) {
      diffOverlay.classList.toggle('hidden', !state.showDiff);
    }
    updateDiffToggleButton();
  }

  function toggleSidebar() {
    state.sidebarVisible = !state.sidebarVisible;
    document.documentElement.setAttribute('data-sidebar-visible', state.sidebarVisible);
    localStorage.setItem('screenshot-review-sidebar', state.sidebarVisible);
    updateMenuToggleButton();
  }

  function updateMenuToggleButton() {
    const btn = document.getElementById('menuToggleBtn');
    if (btn) {
      btn.textContent = state.sidebarVisible ? '☰ Hide' : '☰ Show';
      btn.setAttribute('aria-pressed', state.sidebarVisible);
    }
  }

  function applyTheme(themeName) {
    state.theme = themeName;
    document.documentElement.setAttribute('data-theme', themeName);
    localStorage.setItem('screenshot-review-theme', themeName);
    const selector = document.getElementById('themeSelector');
    if (selector) {
      selector.value = themeName;
    }
  }

  function toggleTheme() {
    const lightThemes = ['light-default', 'light-soft', 'light-cool'];
    const darkThemes = ['dark-default', 'dark-warm', 'dark-cool'];

    const isLight = lightThemes.includes(state.theme);
    const nextThemes = isLight ? darkThemes : lightThemes;
    const randomTheme = nextThemes[Math.floor(Math.random() * nextThemes.length)];

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
              <tr><td><kbd>t</kbd></td><td>Toggle theme (light/dark)</td></tr>
              <tr><td><kbd>m</kbd></td><td>Toggle sidebar menu</td></tr>
              <tr><td><kbd>1</kbd>–<kbd>9</kbd></td><td>Jump to screenshot</td></tr>
              <tr><td><kbd>Esc</kbd></td><td>Close this help</td></tr>
            </table>
          </div>
        </div>
      </div>
    `;

    document.body.insertAdjacentHTML('beforeend', helpHtml);
    document.getElementById('helpModal').querySelector('.help-close').addEventListener('click', hideHelp);
  }

  function hideHelp() {
    const modal = document.getElementById('helpModal');
    if (modal) {
      modal.remove();
      state.helpVisible = false;
    }
  }

  function handleKeydown(e) {
    if (state.helpVisible && e.key === 'Escape') {
      hideHelp();
      return;
    }

    if (e.key === '?' || e.key === 'h') {
      e.preventDefault();
      if (state.helpVisible) {
        hideHelp();
      } else {
        showHelp();
      }
    } else if (e.key === 'j' || e.key === 'ArrowDown') {
      if (!state.helpVisible) {
        e.preventDefault();
        selectNextScenario();
      }
    } else if (e.key === 'k' || e.key === 'ArrowUp') {
      if (!state.helpVisible) {
        e.preventDefault();
        selectPreviousScenario();
      }
    } else if (e.code === 'Space' || e.key === 'd') {
      if (!state.helpVisible && state.currentScenario && state.currentScenario.diff_path) {
        e.preventDefault();
        toggleDiffOverlay();
      }
    } else if (e.key === 't') {
      if (!state.helpVisible) {
        e.preventDefault();
        toggleTheme();
      }
    } else if (e.key === 'm') {
      if (!state.helpVisible) {
        e.preventDefault();
        toggleSidebar();
      }
    } else if (e.key >= '1' && e.key <= '9') {
      if (!state.helpVisible) {
        const index = parseInt(e.key, 10) - 1;
        selectByIndex(index);
      }
    }
  }

  function initializeEventListeners() {
    document.documentElement.setAttribute('data-sidebar-visible', state.sidebarVisible);
    applyTheme(state.theme);

    document.getElementById('scenariosList').addEventListener('click', (e) => {
      const card = e.target.closest('.scenario-card');
      if (card) {
        const index = Array.from(document.querySelectorAll('.scenario-card')).indexOf(card);
        const scenario = MANIFEST.scenarios[index];
        if (scenario) {
          selectScenario(scenario, index);
        }
      }
    });

    document.getElementById('diffToggleBtn').addEventListener('click', toggleDiffOverlay);
    document.getElementById('menuToggleBtn').addEventListener('click', toggleSidebar);
    document.getElementById('gutterToggleBtn').addEventListener('click', toggleSidebar);
    document.getElementById('prevBtn').addEventListener('click', selectPreviousScenario);
    document.getElementById('nextBtn').addEventListener('click', selectNextScenario);

    const themeSelector = document.getElementById('themeSelector');
    if (themeSelector) {
      themeSelector.addEventListener('change', (e) => {
        applyTheme(e.target.value);
      });
    }

    document.addEventListener('keydown', handleKeydown);
    window.addEventListener('hashchange', selectFromHash);

    if (MANIFEST.scenarios.length > 0) {
      selectFromHash();
    } else {
      document.getElementById('viewerContent').innerHTML = '<div class="empty-state"><p>No screenshots available</p></div>';
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeEventListeners);
  } else {
    initializeEventListeners();
  }
})();
