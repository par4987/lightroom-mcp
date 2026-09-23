#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";
import { createMcpServer } from "./create-server.js";
import { NOT_CONNECTED_MESSAGE } from "./tool-handler.js";
import { parseCli, helpText } from "./cli.js";
import { VERSION } from "./version.js";
import { startHeartbeat, probePlugin } from "./heartbeat.js";
import { PluginLiveness, SHADOW_BRIDGE_MESSAGE } from "./plugin-liveness.js";
import { waitUntil } from "./wait-until.js";
import { acquireInstanceLock } from "./instance-lock.js";
import { ClientActivityTracker } from "./client-activity.js";
import {
  ensurePluginInstalled,
  findBundledPlugin,
  installPlugin,
  lightroomModulesDir,
} from "./install-plugin.js";

const REQUEST_TIMEOUT_MS = 30_000;
// Batch export/import render files and can run for minutes; the default
// timeout would report a spurious failure mid-export. See issue #128.
const LONG_RUNNING_TIMEOUT_MS = 300_000;
// Keep this interval in sync with HEARTBEAT_INTERVAL_SECONDS in
// PluginInfoProvider.lua. See heartbeat.ts for what this drives.
const HEARTBEAT_INTERVAL_MS = 30_000;
const PING_TIMEOUT_MS = 10_000;
const RESPONSE_CONNECT_SETTLE_MS = 200;
// Short enough that a tool call waiting on the verdict is not left hanging,
// generous enough for a busy-but-healthy plugin: a ping is a no-op dispatch
// that answered in single-digit milliseconds even mid-export.
const PROBE_TIMEOUT_MS = 5_000;
const PROBE_RECOVERY_INTERVAL_MS = 5_000;
// A client that calls a tool immediately after initialize would otherwise be
// told "plugin not connected" while the sockets are still coming up, which is
// a lie about a perfectly healthy Lightroom. Wait out the connect instead.
const STARTUP_GRACE_MS = 3_000;
const CONNECT_POLL_MS = 50;
// How long a freshly started bridge tolerates having no MCP client handshake.
// Real clients send initialize within milliseconds of spawn; probe processes
// never do. Generous enough for slow client startup, short enough that the
// next real instance (waiting on the instance lock) takes over well inside
// the client's own connect timeout.
const HANDSHAKE_TIMEOUT_MS = 5_000;
// Once both plugin sockets have connected at least once, being down for this
// long means Lightroom is gone and this bridge is a useless process holding
// the instance lock (and, for the plugin, the client slot). Exit so the next
// spawn can take over cleanly. 0 disables. Env:
// LIGHTROOM_MCP_PLUGIN_DOWN_EXIT_MS.
const PLUGIN_DOWN_EXIT_MS = 600_000;
const PLUGIN_DOWN_CHECK_MS = 30_000;
// Progress lines while waiting for the previous bridge: once every 2s is
// plenty for a human reading the client log (Claude Desktop copies every
// stderr line into it — per-poll logging left 511-line floods there).
const LOCK_WAIT_LOG_INTERVAL_MS = 2_000;
// First ping failure is logged, then one line per 20 failures (~10 minutes at
// the 30s heartbeat) plus the recovery line — the failure flood of a dead
// plugin used to bury everything else in the client log.
const HEARTBEAT_QUIET_FAILURES = 20;
const ACTION_TIMEOUTS_MS: Record<string, number> = {
  export_photos: LONG_RUNNING_TIMEOUT_MS,
  import_photos: LONG_RUNNING_TIMEOUT_MS,
  ping: PING_TIMEOUT_MS,
  // AI Denoise must wait out SendKeys + the actual DNG render (which can run
  // minutes on high-resolution RAW files) before its verification window
  // closes and the manual fallback kicks in.
  ai_denoise: LONG_RUNNING_TIMEOUT_MS,
  // Flagging large batches selects photos through the UI and retries one by
  // one; the default 30s is too tight near the 1000-photo cap.
  set_flags: 120_000,
  // AI masking drives Lightroom's on-device AI per photo (subject/sky/
  // background detection takes seconds per image on most machines), plus
  // module switches and per-photo selection.
  add_ai_mask: 120_000,
  // Both of these now force a RECOMPUTE before verifying -- they render a
  // throwaway thumbnail, because Lightroom will serve a write back on an
  // immediate read and discard it at the next recompute. On a 24MP RAW with a
  // cold preview cache that pushed a successful removal past the 30s default:
  // the work completed, the answer never arrived.
  add_local_adjustment: 120_000,
  remove_mask: 120_000,
  // apply_auto drives the Develop module UI per photo with settle pauses
  // and before/after read-backs.
  apply_auto: 120_000,
  // The preview render inside the plugin polls for up to 60s (photos still
  // building standard previews can take that long), plus file I/O.
  get_photo_preview: 90_000,
  // reset_develop/set_process_version/add_range_mask drive the Develop
  // module UI with module switches, settle pauses and read-backs.
  reset_develop: 120_000,
  set_process_version: 120_000,
  add_range_mask: 120_000,
  toggle_mask_overlay: 60_000,
  // Batch metadata writes up to 1000 photos through one write gate plus a
  // full read-back verification pass.
  batch_metadata: 120_000,
  // Selection changes yield to the Lightroom UI thread; large batches with
  // verification need headroom.
  select_photos: 60_000,
  rotate_photo: 60_000,
  remove_from_catalog: 60_000,
};

const here = path.dirname(fileURLToPath(import.meta.url));

// stderr as console.error is asynchronous; anything logged right before a
// process.exit() can be truncated in a Windows pipe (exactly where these
// diagnostics matter most). One-shot shutdown messages go through fd 2
// synchronously instead.
const logSync = (msg: string) => {
  try {
    fs.writeSync(2, msg + "\n");
  } catch {
    // stderr closed — nothing left to report to.
  }
};

async function main() {
  let cli;
  try {
    cli = parseCli(process.argv);
  } catch (err) {
    console.error((err as Error).message);
    process.exit(2);
  }

  if (cli.command === "help") {
    process.stdout.write(helpText());
    return;
  }
  if (cli.command === "version") {
    process.stdout.write(VERSION + "\n");
    return;
  }
  if (cli.command === "install-plugin") {
    runInstallPlugin();
    return;
  }

  let REQUEST_PORT: number;
  let RESPONSE_PORT: number;
  try {
    REQUEST_PORT = requestPort();
    RESPONSE_PORT = responsePort();
  } catch (err) {
    console.error((err as Error).message);
    process.exit(1);
  }

  // Tracks MCP client interest so an abandoned bridge can yield its lock to
  // a waiting contender. Created before the lock: the lock's yield policy
  // consults it, and the transport hook below feeds it once connected.
  const clientActivity = new ClientActivityTracker();

  let lockWaitLastLogMs = 0;
  try {
    const lock = await acquireInstanceLock(REQUEST_PORT, RESPONSE_PORT, {
      shouldYield: () => clientActivity.shouldYieldToContender(),
      onYield: (pid) =>
        logSync(`[lock] Yielding the bridge to a newer instance (pid ${pid}) — this one's client is idle.`),
      onStolen: () => logSync("[lock] A newer bridge took over the lock; exiting."),
      onWait: ({ pid, elapsedMs }) => {
        if (elapsedMs - lockWaitLastLogMs < LOCK_WAIT_LOG_INTERVAL_MS) return;
        lockWaitLastLogMs = elapsedMs;
        console.error(
          `[lock] Waiting for the previous Lightroom MCP bridge (pid ${pid}) to exit... ${(
            elapsedMs / 1000
          ).toFixed(1)}s`,
        );
      },
    });
    // The lock releases itself through the process exit/signal handlers it
    // registered; keep a reference so the intent is visible.
    void lock;
  } catch (err) {
    console.error((err as Error).message);
    process.exit(1);
  }

  ensurePluginInstalled(here, (m) => console.error(m));

  let requestSocket: PluginSocket;
  let responseSocket: PluginSocket | null = null;
  let responseConnectTimer: NodeJS.Timeout | null = null;
  const dispatcher = new Dispatcher({
    send: (line) => requestSocket.send(line),
    getToken: () => readToken(),
    timeoutMs: REQUEST_TIMEOUT_MS,
    actionTimeoutsMs: ACTION_TIMEOUTS_MS,
  });
  const liveness = new PluginLiveness();
  let recoveryTimer: NodeJS.Timeout | null = null;
  const probeOnConnect = () => {
    const token = liveness.beginProbe();
    if (token === null) return;
    void probePlugin(dispatcher, PROBE_TIMEOUT_MS).then((answered) => {
      if (!liveness.settleProbe(token, answered)) return;
      if (answered) {
        if (recoveryTimer) {
          clearInterval(recoveryTimer);
          recoveryTimer = null;
        }
        return;
      }
      console.error(`[plugin] ${SHADOW_BRIDGE_MESSAGE}`);
      // Re-probe faster than the 30s heartbeat so the bridge recovers promptly
      // once the process holding the plugin goes away.
      if (!recoveryTimer) {
        recoveryTimer = setInterval(() => probeOnConnect(), PROBE_RECOVERY_INTERVAL_MS);
      }
    });
  };
  const startResponseSocket = () => {
    if (responseSocket || !requestSocket.isConnected()) return;
    responseSocket = new PluginSocket({
      port: RESPONSE_PORT,
      label: "response",
      onLine: (line) => dispatcher.handleResponseLine(line),
      onConnect: () => probeOnConnect(),
    });
    responseSocket.connect();
  };
  const stopResponseSocket = () => {
    liveness.reset();
    if (responseConnectTimer) {
      clearTimeout(responseConnectTimer);
      responseConnectTimer = null;
    }
    responseSocket?.stop();
    responseSocket = null;
  };
  requestSocket = new PluginSocket({
    port: REQUEST_PORT,
    label: "request",
    onConnect: () => {
      if (responseConnectTimer) clearTimeout(responseConnectTimer);
      responseConnectTimer = setTimeout(() => {
        responseConnectTimer = null;
        startResponseSocket();
      }, RESPONSE_CONNECT_SETTLE_MS);
    },
    onDisconnect: () => {
      stopResponseSocket();
    },
  });
  requestSocket.connect();

  const socketsConnected = () =>
    requestSocket.isConnected() && (responseSocket?.isConnected() ?? false);

  let heartbeatFailures = 0;
  startHeartbeat(
    dispatcher,
    HEARTBEAT_INTERVAL_MS,
    (err) => {
      heartbeatFailures++;
      if (heartbeatFailures === 1 || heartbeatFailures % HEARTBEAT_QUIET_FAILURES === 0) {
        console.error(`[heartbeat] ping failed (${heartbeatFailures} in a row): ${err.message}`);
      }
      // A ping that fails because the socket is down is an ordinary disconnect,
      // not a second bridge holding the plugin. Only diagnose the latter while
      // the connection is actually up, or a stopped plugin gets blamed on a
      // process that does not exist.
      if (!socketsConnected()) {
        liveness.reset();
        return;
      }
      liveness.markUnresponsive();
      console.error(`[plugin] ${SHADOW_BRIDGE_MESSAGE}`);
    },
    () => {
      if (heartbeatFailures > 0) {
        console.error(`[heartbeat] ping recovered after ${heartbeatFailures} failure(s).`);
      }
      heartbeatFailures = 0;
      liveness.markResponsive();
    },
  );

  const server = createMcpServer({
    dispatcher,
    isReady: () => socketsConnected() && liveness.isUsable(),
    notReadyMessage: () => (socketsConnected() ? SHADOW_BRIDGE_MESSAGE : NOT_CONNECTED_MESSAGE),
    settleReadiness: async () => {
      await waitUntil(socketsConnected, STARTUP_GRACE_MS, CONNECT_POLL_MS);
      await liveness.settled();
    },
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Feed the yield policy with every incoming client message (idle tracking;
  // tools/call and friends mark the bridge as genuinely used).
  const transportOnMessage = transport.onmessage;
  transport.onmessage = (message) => {
    clientActivity.noteMessage((message as { method?: string }).method);
    transportOnMessage?.(message);
  };

  // Plugin-gone watchdog. Without a plugin connection the bridge cannot
  // serve a single tool, yet its sockets + heartbeat keep the process alive
  // forever — that is exactly the zombie that held the lock and the client
  // slot for hours while Lightroom was closed. A bridge that HAS connected
  // once and then stayed down for this long exits so a fresh spawn can take
  // over; a bridge that never connected keeps waiting (start Claude before
  // Lightroom is a legitimate startup order).
  const pluginDownExitMs = pluginDownExitMsFromEnv();
  if (pluginDownExitMs > 0) {
    let everConnected = false;
    let downSince: number | null = null;
    const downWatch = setInterval(() => {
      if (socketsConnected()) {
        everConnected = true;
        downSince = null;
        return;
      }
      if (!everConnected) return;
      downSince ??= Date.now();
      if (Date.now() - downSince >= pluginDownExitMs) {
        logSync(
          `[watchdog] Plugin connection down for over ${Math.round(pluginDownExitMs / 1000)}s; exiting so a fresh bridge can take over.`,
        );
        process.exit(0);
      }
    }, PLUGIN_DOWN_CHECK_MS);
    downWatch.unref?.();
  }

  // Exit when the MCP client goes away. Signal handlers never fire when the
  // parent dies without signaling (typical on Windows), and the live plugin
  // sockets plus the heartbeat interval keep the event loop alive — the
  // orphaned bridge then holds both the single-client plugin connection and
  // the instance lock, so every future bridge instance fails with "Another
  // Lightroom MCP bridge is already running". Stdin EOF is the one reliable
  // cross-platform signal that the client is gone.
  const exitOnClientGone = (reason: string) => () => {
    logSync(`Shutting down: ${reason}`);
    process.exit(0);
  };
  process.stdin.once("end", exitOnClientGone("stdin ended (client exited)"));
  process.stdin.once("close", exitOnClientGone("stdin closed (client exited)"));

  // Anti-probe watchdog. MCP clients (Claude Desktop above all) commonly
  // spawn a short-lived probe process before the real one. The probe grabs
  // the instance lock but never completes the MCP handshake, and — because
  // StdioServerTransport does not watch for stdin EOF and the client may
  // keep the pipe open — the probe can linger as a zombie that holds the
  // lock until the whole client app exits. A bridge that no client has
  // handshaked with within this window is, by definition, useless: exit and
  // release the lock so the next (real) instance can take over. Set
  // LIGHTROOM_MCP_HANDSHAKE_TIMEOUT_MS=0 to disable.
  let clientHandshaked = false;
  server.oninitialized = () => {
    clientHandshaked = true;
  };
  const handshakeTimeoutMs = handshakeTimeoutFromEnv();
  if (handshakeTimeoutMs > 0) {
    const watchdog = setTimeout(() => {
      if (!clientHandshaked) {
        console.error(
          "[watchdog] No MCP client completed the handshake; exiting so the next instance can take over the plugin.",
        );
        process.exit(0);
      }
    }, handshakeTimeoutMs);
    // Never keep the process alive just for the watchdog; sockets and the
    // heartbeat own the lifetime of a healthy bridge.
    watchdog.unref?.();
  }

  console.error(`Lightroom MCP server v${VERSION} running on stdio`);
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
  console.error(`Token file: ${tokenFilePath()}`);
}

function handshakeTimeoutFromEnv(): number {
  const raw = process.env["LIGHTROOM_MCP_HANDSHAKE_TIMEOUT_MS"];
  if (raw === undefined) return HANDSHAKE_TIMEOUT_MS;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : HANDSHAKE_TIMEOUT_MS;
}

function pluginDownExitMsFromEnv(): number {
  const raw = process.env["LIGHTROOM_MCP_PLUGIN_DOWN_EXIT_MS"];
  if (raw === undefined) return PLUGIN_DOWN_EXIT_MS;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : PLUGIN_DOWN_EXIT_MS;
}

function runInstallPlugin(): void {
  const source = findBundledPlugin(here);
  if (!source) {
    console.error("Could not locate bundled LightroomMCP.lrplugin folder near this binary.");
    console.error("If you cloned the repo, run from the repo root or pass a path explicitly.");
    process.exit(1);
  }
  const dest = lightroomModulesDir();
  try {
    const result = installPlugin({ source, destDir: dest });
    if (result.status === "installed") {
      console.error(`Installed plugin: ${result.destination}`);
      console.error(`Restart Lightroom Classic to load it.`);
    } else if (result.status === "already-present") {
      console.error(`Plugin already present at ${result.destination}`);
    } else {
      console.error(`Skipped: ${result.reason ?? "unknown reason"}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`Install failed: ${(err as Error).message}`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
