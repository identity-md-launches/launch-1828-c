import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative base so the export works at an IPFS gateway subpath or an ENS name.
// The export goes to dist/ at the repository root, which is what gets pinned.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: { outDir: process.env.CV_OUT_DIR || "../dist", emptyOutDir: true, chunkSizeWarningLimit: 1200 },
});
