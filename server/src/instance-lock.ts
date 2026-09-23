import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface InstanceLock {
  release: () => void;
}

export interface LockWaitInfo {
  /** Pid of the process currently holding the lock. */
  pid: number;
  /** Milliseconds since we started waiting. */
  elapsedMs: number;
}

export interface AcquireOptions {
  /** Directory holding the lock file. Defaults to ~/.config/lightroom-mcp. */
  baseDir?: string;
  /**
   * How long to wait for a conflicting holder to exit before failing.
   * MCP clients routinely spawn a short-lived probe process before the real
   * one (Claude Desktop does this on every restart); waiting lets the real
   * instance take over instead of dying on a lock held by a process that is
   * on its way out. Defaults to 15000, override via LIGHTROOM_MCP_LOCK_WAIT_MS.
   */
  waitMs?: number;
  /** Poll interval while waiting. Defaults to 250. */
  pollMs?: number;
  /** Liveness check override (tests). Defaults to process.kill(pid, 0). */
  isAlive?: (pid: number) => boolean;
  /** Progress callback while waiting for the holder to exit. */
  onWait?: (info: LockWaitInfo) => void;
  /**
   * Holder side: consulted when a waiting contender asks this bridge to
   * yield. Return true to exit and hand over the lock. Defaults to never
   * yielding (tests and simple embeds); index.ts wires the real policy
   * (idle client / never-used bridge).
   */
  shouldYield?: () => boolean;
  /** Holder side: called right before yielding to a contender. */
  onYield?: (contenderPid: number) => void;
  /** Holder side: called when another process took the lock from us. */
  onStolen?: (newHolderPid: number | null) => void;
  /**
   * A lock file whose mtime is older than this is considered abandoned
   * (pre-3.1.2 builds never refresh it, and a hung holder cannot either)
   * and gets taken over even when the recorded pid still matches some
   * living process — Windows reuses pids aggressively. Defaults to 60000.
   */
  staleMs?: number;
  /** How long a contender waits before asking the holder to yield. Defaults to 5000. */
  yieldRequestDelayMs?: number;
  /** Holder-side poll interval for yield requests. Defaults to 1000. */
  yieldCheckMs?: number;
  /** Holder-side lock refresh interval. Defaults to 5000. */
  refreshMs?: number;
  /** Injectable clock (tests). Defaults to Date.now. */
  now?: () => number;
  /** Injectable exit (tests). Defaults to process.exit. */
  exit?: (code: number) => void;
}

const DEFAULT_WAIT_MS = 15_000;
const DEFAULT_POLL_MS = 250;
const DEFAULT_STALE_MS = 60_000;
// tryCreate opens the file and writes the pid in two steps, so a contender
// polling in between sees an empty file. Anything younger than this is
// assumed to be that in-flight creation; older empties are corruption.
const EMPTY_GRACE_MS = 5_000;
const DEFAULT_YIELD_REQUEST_DELAY_MS = 5_000;
const DEFAULT_YIELD_CHECK_MS = 1_000;
const DEFAULT_REFRESH_MS = 5_000;

function pidIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

function readPid(pidFile: string): number | null {
  try {
    const raw = fs.readFileSync(pidFile, "utf8").trim();
    const parsed = Number(raw);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
}

function isEmptyFile(pidFile: string): boolean {
  try {
    return fs.readFileSync(pidFile, "utf8").trim() === "";
  } catch {
    return false;
  }
}

function mtimeMs(file: string): number | null {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return null;
  }
}

function envWaitMs(): number | undefined {
  const raw = process.env["LIGHTROOM_MCP_LOCK_WAIT_MS"];
  if (raw === undefined) return undefined;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
}

function tryCreate(lockFile: string): boolean {
  let fd: number | null = null;
  try {
    fd = fs.openSync(lockFile, "wx", 0o600);
    fs.writeFileSync(fd, `${process.pid}\n`, { encoding: "utf8" });
    return true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") {
      throw err;
    }
    return false;
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }
}

function unlinkQuiet(file: string): void {
  try {
    fs.unlinkSync(file);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Acquires the single-bridge lock for a port pair.
 *
 * The lock exists because the Lightroom plugin serves one bridge at a time.
 * Contender side: a dead holder (or one that stopped refreshing its lock
 * file — every release before 3.1.2) is taken over; a live, fresh holder is
 * first asked to yield (`.yield-request` sidecar file) and then waited out
 * up to `waitMs`. Holder side: the lock file is refreshed every few seconds
 * so future contenders can tell this bridge is alive, and a yield request
 * from a waiting contender makes this bridge exit when `shouldYield`
 * approves — that is what lets Claude Desktop's respawn cycle replace an
 * abandoned-but-not-closed bridge instead of dying on its lock.
 */
export async function acquireInstanceLock(
  requestPort: number,
  responsePort: number,
  options: AcquireOptions = {},
): Promise<InstanceLock> {
  const baseDir = options.baseDir ?? path.join(os.homedir(), ".config", "lightroom-mcp");
  const waitMs = options.waitMs ?? envWaitMs() ?? DEFAULT_WAIT_MS;
  const pollMs = options.pollMs ?? DEFAULT_POLL_MS;
  const staleMs = options.staleMs ?? DEFAULT_STALE_MS;
  const yieldRequestDelayMs = options.yieldRequestDelayMs ?? DEFAULT_YIELD_REQUEST_DELAY_MS;
  const isAlive = options.isAlive ?? pidIsAlive;
  const now = options.now ?? Date.now;
  const exitFn = options.exit ?? ((code: number) => process.exit(code));

  fs.mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const lockFile = path.join(baseDir, `bridge-${requestPort}-${responsePort}.lock`);
  const yieldFile = path.join(baseDir, `bridge-${requestPort}-${responsePort}.yield-request`);

  const startedAt = now();
  while (true) {
    if (tryCreate(lockFile)) break;

    const existingPid = readPid(lockFile);
    const age = now() - (mtimeMs(lockFile) ?? 0);
    const elapsedMs = now() - startedAt;

    if (elapsedMs >= waitMs) {
      throw new Error(
        existingPid !== null
          ? `Another Lightroom MCP bridge is still running for ports ${requestPort}/${responsePort} ` +
              `(pid ${existingPid}) and did not exit within ${Math.round(waitMs / 1000)}s. ` +
              (fs.existsSync(yieldFile)
                ? `It was asked to yield but appears to be actively serving another client. `
                : ``) +
              `If no other client is using it, stop that process and retry. ` +
              `PowerShell: Stop-Process -Id ${existingPid} -Force`
          : `Another Lightroom MCP bridge is still running for ports ${requestPort}/${responsePort}, ` +
              `but its lock file is unreadable; if this persists, delete it and retry: ${lockFile}`,
      );
    }

    if (existingPid === null) {
      // Empty or corrupt. An empty file that just appeared is the holder's
      // create/write window — give it a moment instead of stealing.
      if (isEmptyFile(lockFile) && age < EMPTY_GRACE_MS) {
        await sleep(Math.max(1, Math.min(pollMs, waitMs - elapsedMs)));
        continue;
      }
      unlinkQuiet(lockFile);
      continue;
    }

    if (age >= staleMs) {
      // Holder never refreshes the lock: every release before 3.1.2 (the
      // zombies that survive a 15s wait), a hung process, or a pid that
      // Windows already handed to an unrelated process. Take over.
      unlinkQuiet(lockFile);
      continue;
    }

    if (!isAlive(existingPid)) {
      // Stale lock: the holder crashed or was hard-killed (TerminateProcess
      // skips every Node hook, so this is the normal post-kill state).
      try {
        fs.unlinkSync(lockFile);
      } catch (unlinkErr) {
        if ((unlinkErr as NodeJS.ErrnoException).code !== "ENOENT") throw unlinkErr;
      }
      continue;
    }

    if (elapsedMs >= yieldRequestDelayMs && !fs.existsSync(yieldFile)) {
      // Ask the holder to yield — abandoned-but-open bridges (Claude
      // Desktop's probe cycle) only ever leave through this door.
      try {
        fs.writeFileSync(yieldFile, `${process.pid}\n`, { encoding: "utf8", mode: 0o600 });
      } catch {
        // Best effort: the plain wait still works.
      }
    }

    options.onWait?.({ pid: existingPid, elapsedMs });
    await sleep(Math.max(1, Math.min(pollMs, waitMs - elapsedMs)));
  }

  // We own the lock: clear any yield request we (or a late contender that
  // already lost) left behind so a fresh contender has to ask again.
  unlinkQuiet(yieldFile);

  let released = false;
  let refreshTimer: NodeJS.Timeout | null = null;
  let yieldTimer: NodeJS.Timeout | null = null;
  const stopSupervision = () => {
    if (refreshTimer) clearInterval(refreshTimer);
    if (yieldTimer) clearInterval(yieldTimer);
    refreshTimer = null;
    yieldTimer = null;
  };
  const release = () => {
    if (released) return;
    released = true;
    stopSupervision();
    process.off("exit", exitHandler);
    process.off("SIGINT", signalHandler);
    process.off("SIGTERM", signalHandler);
    if (process.platform === "win32") {
      process.off("SIGBREAK", signalHandler);
    }
    if (readPid(lockFile) === process.pid) {
      fs.unlinkSync(lockFile);
    }
  };
  const exitHandler = () => release();
  const signalHandler = () => {
    release();
    exitFn(0);
  };

  process.once("exit", exitHandler);
  process.once("SIGINT", signalHandler);
  process.once("SIGTERM", signalHandler);
  if (process.platform === "win32") {
    process.once("SIGBREAK", signalHandler);
  }

  // Keep the lock file's mtime fresh so contenders can tell a live v3.1.2
  // holder from an abandoned one, and notice (then exit) when somebody
  // takes the lock away from us.
  refreshTimer = setInterval(() => {
    try {
      if (readPid(lockFile) !== process.pid) {
        stopSupervision();
        options.onStolen?.(readPid(lockFile));
        release();
        exitFn(0);
      } else {
        fs.utimesSync(lockFile, new Date(now()), new Date(now()));
      }
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        stopSupervision();
        options.onStolen?.(null);
        release();
        exitFn(0);
      }
    }
  }, options.refreshMs ?? DEFAULT_REFRESH_MS);
  refreshTimer.unref?.();

  // A contender that has been waiting asks us to yield. Only exit when the
  // policy approves — an actively used bridge outlives the contender's
  // patience and the contender reports the actionable timeout error.
  yieldTimer = setInterval(() => {
    if (!fs.existsSync(yieldFile)) return;
    const contenderPid = readPid(yieldFile);
    if (contenderPid === null) return;
    if (!isAlive(contenderPid)) {
      unlinkQuiet(yieldFile);
      return;
    }
    if (options.shouldYield?.() ?? false) {
      stopSupervision();
      options.onYield?.(contenderPid);
      release();
      exitFn(0);
    }
  }, options.yieldCheckMs ?? DEFAULT_YIELD_CHECK_MS);
  yieldTimer.unref?.();

  return { release };
}
