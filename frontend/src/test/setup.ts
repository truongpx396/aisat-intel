/**
 * Vitest global setup file.
 *
 * Extends Vitest's `expect` with jest-dom matchers (e.g. `toBeInTheDocument`,
 * `toHaveValue`, `toBeVisible`) so component tests read naturally without
 * importing matchers in every file.
 *
 * Referenced by `vite.config.ts → test.setupFiles`.
 */
import '@testing-library/jest-dom/vitest';
