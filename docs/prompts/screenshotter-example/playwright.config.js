// Example config for a screenshot-only Playwright suite. Adapt baseURL default and testDir.
const { defineConfig } = require('@playwright/test');

const baseURL = process.env.SCREENSHOT_BASE_URL || process.env.PLAYWRIGHT_BASE_URL || 'http://127.0.0.1:3000';

module.exports = defineConfig({
  testDir: './playwright',
  fullyParallel: false, // scenarios are sequential by design
  workers: 1,
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: 'line',
  timeout: 120000, // one test runs the whole suite
  expect: { timeout: 5000 },
  use: {
    baseURL,
    headless: true,
    ignoreHTTPSErrors: process.env.SCREENSHOT_IGNORE_HTTPS_ERRORS === '1',
    screenshot: 'off', // we take our own
    video: 'off',
    trace: 'retain-on-failure',
    viewport: { width: 1440, height: 1200 }
  }
});
