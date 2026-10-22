// Offline build-time rendering of the initial, unpriced counter. No chain data is fabricated or cached.
// Regenerate after editing the shell: `node scripts/prerender.mjs && npm run build`.
import { createServer } from "vite";
import { renderToString } from "react-dom/server";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const server = await createServer({ root, server: { middlewareMode: true }, appType: "custom" });
try {
  const { root: element } = await server.ssrLoadModule("/src/main.tsx");
  const html = renderToString(element);
  const path = new URL("../index.html", import.meta.url);
  const source = readFileSync(path, "utf8");
  const shell = source.replace(/<div id="root">[\s\S]*?<\/div>\s*<noscript>/, `<div id="root">${html}</div>\n    <noscript>`);
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  const style = `<style id="counter-styles">\n${css}\n    </style>`;
  // Inline the canonical styles so the static shell can paint without waiting for app CSS/JS.
  // main also imports the source stylesheet, so ordinary Vite builds still apply later CSS edits.
  const next = shell.includes('<style id="counter-styles">')
    ? shell.replace(/<style id="counter-styles">[\s\S]*?<\/style>/, style)
    : shell.replace("</head>", `${style}\n  </head>`);
  if (source === next && !source.includes(html)) throw new Error("Counter shell marker missing");
  writeFileSync(path, next);
  console.log("Rendered the disconnected counter shell; live prices still come only from the RPC.");
} finally { await server.close(); }
