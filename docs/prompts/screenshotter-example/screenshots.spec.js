// Example screenshotter. Plain, sequential, one function per scenario.
// Replace the selectors/routes with the project's own; keep the structure and conventions.
const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');

const OUTPUT_DIR = process.env.SCREENSHOT_OUTPUT_DIR || 'docs/screenshots';
const EMAIL = process.env.SCREENSHOT_EMAIL || 'screenshots@example.com'; // from seed data
const PASSWORD = process.env.SCREENSHOT_PASSWORD || 'change-me'; // from seed data
const MOBILE = { width: 390, height: 844 };

// Numbered in the order a user explores the app. NNb- = variant of the same screen.
// `fullPage: false` for overlays/menus so the open state is in frame; `viewport` overrides size.
const scenarios = [
  { file: '01-login.png', capture: captureLogin },
  { file: '02-dashboard.png', capture: captureDashboard },
  { file: '03-nav-menu-open.png', capture: captureNavMenuOpen, fullPage: false },
  { file: '04-form-empty.png', capture: captureFormEmpty },
  { file: '04b-form-add-rows.png', capture: captureFormAddRows },
  { file: '04c-form-remove-row.png', capture: captureFormRemoveRow },
  { file: '04d-form-invalid.png', capture: captureFormInvalid },
  { file: '05-datepicker-open.png', capture: captureDatepickerOpen, fullPage: false },
  { file: '06-details-expanded.png', capture: captureDetailsExpanded },
  { file: '07-modal-open.png', capture: captureModalOpen, fullPage: false },
  { file: '08-search-results.png', capture: captureSearch },
  { file: '09-list-page-2.png', capture: capturePagination },
  { file: '10-dashboard-mobile.png', capture: captureDashboard, viewport: MOBILE },
  { file: '10b-mobile-menu-open.png', capture: captureMobileMenu, viewport: MOBILE, fullPage: false }
];

test.describe.configure({ mode: 'serial' });

test('captures the screenshot suite from seeded data', async ({ browser }) => {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const successes = [];
  const errors = [];

  for (const scenario of scenarios) {
    // Fresh context per scenario: no state leaks between scenarios, a crash can't cascade.
    const context = await browser.newContext({ viewport: scenario.viewport || undefined });
    const page = await context.newPage();
    try {
      console.log(`Capturing ${scenario.file}...`);
      await scenario.capture(page);
      await page.screenshot({
        path: path.join(OUTPUT_DIR, scenario.file),
        fullPage: scenario.fullPage !== false,
        animations: 'disabled',
        caret: 'hide'
      });
      successes.push(scenario.file);
      console.log(`✓ ${scenario.file}`);
    } catch (error) {
      const message = error.message.split('\n')[0];
      console.log(`✗ ${scenario.file}: ${message}`);
      errors.push({ file: scenario.file, message });
    } finally {
      await context.close();
    }
  }

  console.error(`\n=== Screenshot Capture Summary: ${successes.length}/${scenarios.length} ===`);
  errors.forEach(({ file, message }) => console.error(`  ✗ ${file}\n    ${message}`));
  expect(errors, 'All screenshot scenarios must capture successfully').toEqual([]);
});

// ---- helpers (keep tiny) ----

async function login(page) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(EMAIL);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: /log in|sign in/i }).click();
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
}

// ---- scenarios: wait on state (expect/waitFor), never on time ----

async function captureLogin(page) {
  await page.goto('/login');
  await expect(page.getByLabel('Email')).toBeVisible();
}

async function captureDashboard(page) {
  await login(page);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
}

async function captureNavMenuOpen(page) {
  await login(page);
  await page.getByRole('button', { name: /menu|account/i }).click();
  await expect(page.getByRole('menu')).toBeVisible();
}

async function captureFormEmpty(page) {
  await login(page);
  await page.goto('/items/new');
  await expect(page.locator('form')).toBeVisible();
}

async function captureFormAddRows(page) {
  await login(page);
  await page.goto('/items/new');
  const rows = page.locator('[data-row]');
  const before = await rows.count();
  for (let i = 0; i < 3; i++) await page.getByRole('button', { name: /add row/i }).click();
  await expect(rows).toHaveCount(before + 3);
  await rows.last().getByRole('textbox').first().fill('Example value');
}

async function captureFormRemoveRow(page) {
  await login(page);
  await page.goto('/items/new');
  await page.getByRole('button', { name: /add row/i }).click();
  await page.getByRole('button', { name: /add row/i }).click();
  const rows = page.locator('[data-row]');
  const before = await rows.count();
  await rows.last().getByRole('button', { name: /remove/i }).click();
  await expect(rows).toHaveCount(before - 1);
}

async function captureFormInvalid(page) {
  await login(page);
  await page.goto('/items/new');
  await page.getByRole('button', { name: /save|create/i }).click(); // submit empty; never saves
  await expect(page.locator('.error, [aria-invalid="true"]').first()).toBeVisible();
}

async function captureDatepickerOpen(page) {
  await login(page);
  await page.goto('/items/new');
  await page.getByLabel(/date/i).click();
  await expect(page.locator('.datepicker, [role="dialog"].calendar')).toBeVisible();
}

async function captureDetailsExpanded(page) {
  await login(page);
  await page.goto('/items/1');
  await page.locator('summary').first().click();
  await expect(page.locator('details[open]').first()).toBeVisible();
}

async function captureModalOpen(page) {
  await login(page);
  await page.goto('/items/1');
  await page.getByRole('button', { name: /edit status/i }).click();
  await expect(page.getByRole('dialog')).toBeVisible(); // open it; do NOT confirm destructive actions
}

async function captureSearch(page) {
  await login(page);
  await page.goto('/items');
  await page.getByRole('searchbox').fill('example');
  await page.getByRole('searchbox').press('Enter');
  await expect(page.locator('.result').first()).toBeVisible();
}

async function capturePagination(page) {
  await login(page);
  await page.goto('/items?page=2');
  await expect(page).toHaveURL(/page=2/);
  await expect(page.locator('.result').first()).toBeVisible();
}

async function captureMobileMenu(page) {
  await login(page);
  await page.getByRole('button', { name: /toggle navigation|menu/i }).click();
  await expect(page.getByRole('navigation')).toBeVisible();
}
