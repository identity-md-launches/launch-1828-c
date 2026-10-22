import { defineConfig } from "@playwright/test";

// e2e against anvil: `npm run e2e` (needs anvil on PATH and `forge build` at the repo root).
export default defineConfig({
  testDir: "e2e",
  globalSetup: "./e2e/setup.mjs",
  timeout: 90_000,
  workers: 1,
  fullyParallel: false,
  use: { baseURL: "http://127.0.0.1:4318/app/", viewport: { width: 390, height: 844 } },
});
