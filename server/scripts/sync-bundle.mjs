#!/usr/bin/env node
// Bundle runtime assets into server/dist so the npm package is self-contained:
//   plugin/LightroomMCP.lrplugin -> dist/LightroomMCP.lrplugin  (install-plugin / auto-install)
//   examples/deepseek-harness   -> dist/deepseek-harness      (DeepSeek harness, zero deps)
//   examples/configs            -> dist/configs               (ready-made client configs)
//
// Runs as part of `npm run build` (and therefore of `prepare`/`prepublishOnly`),
// so `npm pack`/`npm publish` always ships a dist that can install the plugin
// and run the harness without cloning the repository.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(here, "..");
const repoRoot = path.resolve(serverDir, "..");
const dist = path.join(serverDir, "dist");

function copyDir(src, dest) {
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

const jobs = [
  ["plugin/LightroomMCP.lrplugin", "dist/LightroomMCP.lrplugin"],
  ["examples/deepseek-harness", "dist/deepseek-harness"],
  ["examples/configs", "dist/configs"],
];

for (const [srcRel, destRel] of jobs) {
  const src = path.join(repoRoot, srcRel);
  const dest = path.join(serverDir, destRel);
  if (!fs.existsSync(src)) {
    console.error(`[sync-bundle] missing source: ${src}`);
    process.exit(1);
  }
  copyDir(src, dest);
  console.log(`[sync-bundle] ${srcRel} -> ${destRel}`);
}
