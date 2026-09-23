#!/usr/bin/env node
// End-to-end lock behavior against the real dist build. Jest covers the
// lock module in isolation; these scenarios drive actual child processes so
// the wiring in index.ts (yield policy, sync logging, takeover cleanup) is
// what gets exercised.
//
//   A  fresh start            -> banner, lock holds the child pid, clean exit
//   B  pre-3.1.2 zombie       -> live pid + never-refreshed lock file: the
//                                new instance steals it without waiting 15s
//   C  abandoned bridge       -> handshaked holder with a silent client
//                                yields to a waiting contender
//   D  busy bridge            -> pinged holder refuses; contender times out
//                                with the actionable error; yield request
//                                gets garbage-collected
//
// Usage: node scripts/e2e_lock_takeover.mjs   (from server/, after `npm run build`)

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const entry = path.join(serverRoot, "dist", "index.js");

const REQ_PORT = "45999";
const RES_PORT = "46000";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-e2e-home-"));
const cfgDir = path.join(home, ".config", "lightroom-mcp");
fs.mkdirSync(cfgDir, { recursive: true });
const lockFile = path.join(cfgDir, `bridge-${REQ_PORT}-${RES_PORT}.lock`);
const yieldFile = lockFile + ".yield-request";

const results = [];
const children = new Set();
let failures = 0;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function baseEnv(extra = {}) {
  return {
    ...process.env,
    HOME: home,
    LIGHTROOM_MCP_REQUEST_PORT: REQ_PORT,
    LIGHTROOM_MCP_RESPONSE_PORT: RES_PORT,
    ...extra,
  };
}

function startBridge(label, extraEnv = {}) {
  const child = spawn(process.execPath, [entry], {
    env: baseEnv(extraEnv),
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.add(child);
  // NOTE: keep one mutable object; a spread at return time would snapshot the
  // (still empty) stderr/stdout strings and the assertions below would read
  // stale values forever.
  const bridge = { child, stderr: "", stdout: "", exited: null, code: null };
  child.stderr.on("data", (chunk) => (bridge.stderr += chunk));
  child.stdout.on("data", (chunk) => (bridge.stdout += chunk));
  child.on("exit", (code) => {
    bridge.exited = true;
    bridge.code = code;
    children.delete(child);
  });
  bridge.handshake = () => {
    child.stdin.write(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-06-18",
          capabilities: {},
          clientInfo: { name: `e2e-${label}`, version: "0.0.0" },
        },
      }) + "\n",
    );
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  };
  bridge.sendPing = () => {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method: "ping" }) + "\n");
  };
  return bridge;
}

async function waitFor(desc, predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(100);
  }
  throw new Error(`timeout waiting for: ${desc}`);
}

function check(scenario, description, ok, extra = "") {
  results.push({ scenario, description, ok });
  if (!ok) failures++;
  console.error(`${ok ? "PASS" : "FAIL"}  [${scenario}] ${description}${extra ? ` — ${extra}` : ""}`);
}

async function scenarioA() {
  const bridge = startBridge("A");
  await waitFor("banner", () => bridge.stderr.includes("running on stdio"), 20_000);
  bridge.handshake();
  await waitFor(
    "initialize response",
    () => bridge.stdout.includes('"serverInfo"') && bridge.stdout.includes("3.1.2"),
    10_000,
  );
  check("A", "fresh bridge starts and completes the MCP handshake", true);
  const holderPid = Number(fs.readFileSync(lockFile, "utf8").trim());
  check("A", "lock file records the running pid", holderPid === bridge.child.pid, `pid ${holderPid}`);
  bridge.child.kill("SIGTERM");
  await waitFor("exit", () => bridge.exited, 10_000);
  await waitFor("lock released", () => !fs.existsSync(lockFile), 5_000);
  check("A", "SIGTERM exits cleanly and releases the lock", bridge.code === 0);
}

async function scenarioB() {
  // A pre-3.1.2 zombie: pid still alive (ours), lock file never refreshed.
  fs.writeFileSync(lockFile, `${process.pid}\n`);
  const old = new Date(Date.now() - 120_000);
  fs.utimesSync(lockFile, old, old);

  const bridge = startBridge("B");
  const startedAt = Date.now();
  await waitFor("banner via stale takeover", () => bridge.stderr.includes("running on stdio"), 20_000);
  const tookMs = Date.now() - startedAt;
  check(
    "B",
    "live pid + stale lock is stolen without the 15s wait",
    tookMs < 10_000,
    `took ${(tookMs / 1000).toFixed(1)}s`,
  );
  check("B", "lock now belongs to the new bridge", Number(fs.readFileSync(lockFile, "utf8")) === bridge.child.pid);
  bridge.child.kill("SIGKILL");
  await waitFor("exit", () => bridge.exited, 5_000);
}

async function scenarioC() {
  const holder = startBridge("C-holder", { LIGHTROOM_MCP_PROBE_YIELD_MS: "3000" });
  await waitFor("holder banner", () => holder.stderr.includes("running on stdio"), 20_000);
  holder.handshake();
  // The client goes silent right after the handshake — the zombie flavor.

  const contender = startBridge("C-contender");
  await waitFor(
    "holder yields",
    () => holder.stderr.includes("Yielding the bridge to a newer instance"),
    30_000,
  );
  await waitFor("holder exit", () => holder.exited, 10_000);
  check("C", "abandoned holder yields to the contender", holder.code === 0);
  await waitFor("contender banner", () => contender.stderr.includes("running on stdio"), 20_000);
  check("C", "contender takes over and serves", Number(fs.readFileSync(lockFile, "utf8")) === contender.child.pid);
  check("C", "yield request cleaned up on takeover", !fs.existsSync(yieldFile));
  contender.child.kill("SIGKILL");
  await waitFor("exit", () => contender.exited, 5_000);
}

async function scenarioD() {
  const holder = startBridge("D-holder", { LIGHTROOM_MCP_PROBE_YIELD_MS: "60000" });
  await waitFor("holder banner", () => holder.stderr.includes("running on stdio"), 20_000);
  holder.handshake();
  const pinger = setInterval(() => holder.sendPing(), 2_000);

  const contender = startBridge("D-contender", { LIGHTROOM_MCP_LOCK_WAIT_MS: "8000" });
  await waitFor(
    "contender timeout error",
    () => contender.exited && contender.stderr.includes("did not exit within"),
    20_000,
  );
  check(
    "D",
    "busy holder is not stolen; contender gets the actionable error",
    contender.stderr.includes("Stop-Process"),
  );
  check("D", "holder survives the takeover attempt", !holder.exited);
  await waitFor("yield request garbage-collected", () => !fs.existsSync(yieldFile), 10_000);
  check("D", "dead contender's yield request is garbage-collected", true);

  clearInterval(pinger);
  holder.child.kill("SIGTERM");
  await waitFor("holder exit", () => holder.exited, 5_000);
  contender.child.kill("SIGKILL");
}

async function main() {
  if (!fs.existsSync(entry)) {
    console.error("dist/index.js missing — run `npm run build` first.");
    process.exit(2);
  }
  try {
    await scenarioA();
    await scenarioB();
    await scenarioC();
    await scenarioD();
  } finally {
    for (const child of [...children]) {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
    fs.rmSync(home, { recursive: true, force: true });
  }

  const passed = results.filter((r) => r.ok).length;
  console.error(`\n${passed}/${results.length} checks passed`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`e2e failed: ${err.message}`);
  for (const child of [...children]) {
    try {
      child.kill("SIGKILL");
    } catch {}
  }
  fs.rmSync(home, { recursive: true, force: true });
  process.exit(1);
});
