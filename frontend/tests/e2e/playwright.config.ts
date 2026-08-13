import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// This config lives at frontend/tests/e2e/, so the frontend package root
// (where `npm run dev` and package.json live) is two levels up.
const frontendRoot = path.resolve(__dirname, '../..');

export default defineConfig({
  // Config already lives inside frontend/tests/e2e/, so '.' is the
  // relative equivalent of pointing testDir at that directory.
  testDir: '.',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: 'npm run dev',
    cwd: frontendRoot,
    port: 5173,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
