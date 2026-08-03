/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    // Playwright owns tests/e2e/**; keep Vitest scoped to unit/component specs
    // so the two runners never race over the same *.spec.ts files.
    exclude: ['**/node_modules/**', '**/dist/**', 'tests/e2e/**'],
  },
});
