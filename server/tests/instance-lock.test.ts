import { describe, it, expect, afterEach } from "@jest/globals";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { acquireInstanceLock, type InstanceLock } from "../src/instance-lock.js";

const REQ = 58763;
const RES = 58764;

describe("instance lock", () => {
  let tmpDir: string | null = null;
  const locks: InstanceLock[] = [];
  const stopTimers: Array<() => void> = [];

  afterEach(() => {
    while (locks.length > 0) {
      locks.pop()?.release();
    }
    while (stopTimers.length > 0) {
      stopTimers.pop()?.();
    }
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = null;
    }
  });

  function baseDir(): string {
    tmpDir ??= fs.mkdtempSync(path.join(os.tmpdir(), "lightroom-mcp-lock-test-"));
    return tmpDir;
  }

  function lockPath(dir: string): string {
    return path.join(dir, `bridge-${REQ}-${RES}.lock`);
  }

  function yieldPath(dir: string): string {
    return path.join(dir, `bridge-${REQ}-${RES}.yield-request`);
  }

  function backdate(file: string, ms: number): void {
    const old = new Date(Date.now() - ms);
    fs.utimesSync(file, old, old);
  }

  const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

  it("rejects a second live bridge after waiting", async () => {
    locks.push(await acquireInstanceLock(REQ, RES, { baseDir: baseDir() }));

    await expect(
      acquireInstanceLock(REQ, RES, { baseDir: baseDir(), waitMs: 50, pollMs: 10 }),
    ).rejects.toThrow(/Another Lightroom MCP bridge is still running/);
  });

  it("names the holder pid and the stop command in the timeout error", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");

    await expect(
      acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 30,
        pollMs: 10,
        isAlive: () => true,
      }),
    ).rejects.toThrow(/Stop-Process -Id 424242 -Force/);
  });

  it("takes over a lock that a live holder stopped refreshing", async () => {
    // The pre-3.1.2 zombie: pid still alive, but the lock file went stale
    // because that build never refreshed it.
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");
    backdate(lockPath(dir), 120_000);

    locks.push(
      await acquireInstanceLock(REQ, RES, { baseDir: dir, isAlive: () => true }),
    );

    expect(fs.readFileSync(lockPath(dir), "utf8")).toBe(`${process.pid}\n`);
  });

  it("does not steal a live, freshly refreshed lock", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");

    await expect(
      acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 50,
        pollMs: 10,
        isAlive: () => true,
      }),
    ).rejects.toThrow(/still running/);
  });

  it("waits for a conflicting holder to exit and takes over", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    fs.writeFileSync(lockFile, "424242\n");

    let holderAlive = true;
    const lock = await acquireInstanceLock(REQ, RES, {
      baseDir: dir,
      waitMs: 5_000,
      pollMs: 10,
      isAlive: () => holderAlive,
      onWait: () => {
        // The holder dies right after the first wait notice is reported.
        holderAlive = false;
      },
    });
    locks.push(lock);

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("reports progress while waiting for the holder", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");

    const progress: number[] = [];
    let holderAlive = true;
    locks.push(
      await acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 5_000,
        pollMs: 10,
        isAlive: () => holderAlive,
        onWait: ({ pid, elapsedMs }) => {
          expect(pid).toBe(424242);
          progress.push(elapsedMs);
          if (progress.length >= 3) holderAlive = false;
        },
      }),
    );

    expect(progress.length).toBeGreaterThanOrEqual(3);
  });

  it("waits out an in-flight empty lock instead of stealing it", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "");

    await expect(
      acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 100,
        pollMs: 10,
        isAlive: () => true,
      }),
    ).rejects.toThrow(/unreadable/);
  });

  it("steals an empty lock that stayed empty past the grace window", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    fs.writeFileSync(lockFile, "");
    backdate(lockFile, 30_000);

    locks.push(await acquireInstanceLock(REQ, RES, { baseDir: dir }));

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("yields to a waiting contender when the policy approves", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    const yieldedTo: number[] = [];
    const exits: number[] = [];

    const lock = await acquireInstanceLock(REQ, RES, {
      baseDir: dir,
      shouldYield: () => true,
      onYield: (pid) => yieldedTo.push(pid),
      yieldCheckMs: 10,
      isAlive: () => true,
      exit: (code) => exits.push(code),
    });
    locks.push(lock);

    fs.writeFileSync(yieldPath(dir), "424242\n");
    await wait(60);

    expect(yieldedTo).toEqual([424242]);
    expect(exits).toEqual([0]);
    expect(fs.existsSync(lockFile)).toBe(false);
  });

  it("keeps the lock when the yield policy refuses", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    const exits: number[] = [];

    locks.push(
      await acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        shouldYield: () => false,
        yieldCheckMs: 10,
        isAlive: () => true,
        exit: (code) => exits.push(code),
      }),
    );

    fs.writeFileSync(yieldPath(dir), "424242\n");
    await wait(60);

    expect(exits).toEqual([]);
    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("garbage-collects a yield request from a dead contender", async () => {
    const dir = baseDir();
    const exits: number[] = [];

    locks.push(
      await acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        yieldCheckMs: 10,
        isAlive: (pid) => pid !== 424242,
        exit: (code) => exits.push(code),
      }),
    );

    fs.writeFileSync(yieldPath(dir), "424242\n");
    await wait(60);

    expect(fs.existsSync(yieldPath(dir))).toBe(false);
    expect(exits).toEqual([]);
  });

  it("exits when another process steals the lock", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    const stolenBy: Array<number | null> = [];
    const exits: number[] = [];

    locks.push(
      await acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        refreshMs: 10,
        onStolen: (pid) => stolenBy.push(pid),
        exit: (code) => exits.push(code),
      }),
    );

    fs.writeFileSync(lockFile, "777777\n");
    await wait(60);

    expect(stolenBy).toEqual([777777]);
    expect(exits).toEqual([0]);
    // release() must not delete the thief's lock file.
    expect(fs.readFileSync(lockFile, "utf8")).toBe("777777\n");
  });

  it("writes a yield request once a contender has waited past the delay", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");

    let holderAlive = true;
    locks.push(
      await acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 5_000,
        pollMs: 10,
        yieldRequestDelayMs: 30,
        isAlive: () => holderAlive,
        onWait: ({ elapsedMs }) => {
          if (elapsedMs >= 30) holderAlive = false;
        },
      }),
    );

    // The contender acquired the lock (holder died); the yield request it
    // wrote must have been cleaned up on takeover.
    expect(fs.existsSync(yieldPath(dir))).toBe(false);
  });

  it("mentions the ignored yield request in the timeout error", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), "424242\n");
    // Pre-existing yield request from a live contender that already lost.
    fs.writeFileSync(yieldPath(dir), "111111\n");

    await expect(
      acquireInstanceLock(REQ, RES, {
        baseDir: dir,
        waitMs: 60,
        pollMs: 10,
        yieldRequestDelayMs: 10,
        isAlive: () => true,
      }),
    ).rejects.toThrow(/asked to yield/);
  });

  it("honors LIGHTROOM_MCP_LOCK_WAIT_MS", async () => {
    const dir = baseDir();
    fs.writeFileSync(lockPath(dir), `${process.pid}\n`);
    process.env["LIGHTROOM_MCP_LOCK_WAIT_MS"] = "0";

    try {
      await expect(acquireInstanceLock(REQ, RES, { baseDir: dir })).rejects.toThrow(
        /Another Lightroom MCP bridge is still running/,
      );
    } finally {
      delete process.env["LIGHTROOM_MCP_LOCK_WAIT_MS"];
    }
  });

  it("allows different port pairs to run independently", async () => {
    locks.push(await acquireInstanceLock(REQ, RES, { baseDir: baseDir() }));
    locks.push(await acquireInstanceLock(58765, 58766, { baseDir: baseDir() }));
  });

  it("replaces a stale lock with a fully written live lock", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    fs.writeFileSync(lockFile, "999999999\n");

    locks.push(await acquireInstanceLock(REQ, RES, { baseDir: dir }));

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("replaces a malformed stale lock", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    fs.writeFileSync(lockFile, "not-a-pid\n");

    locks.push(await acquireInstanceLock(REQ, RES, { baseDir: dir }));

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("allows release after the lock file is already gone", async () => {
    const dir = baseDir();
    const lockFile = lockPath(dir);
    const lock = await acquireInstanceLock(REQ, RES, { baseDir: dir });
    fs.unlinkSync(lockFile);

    lock.release();
    lock.release();

    expect(fs.existsSync(lockFile)).toBe(false);
  });

  it("removes process handlers when released", async () => {
    const beforeExit = process.listenerCount("exit");
    const beforeSigint = process.listenerCount("SIGINT");
    const beforeSigterm = process.listenerCount("SIGTERM");

    const lock = await acquireInstanceLock(REQ, RES, { baseDir: baseDir() });
    expect(process.listenerCount("exit")).toBe(beforeExit + 1);
    expect(process.listenerCount("SIGINT")).toBe(beforeSigint + 1);
    expect(process.listenerCount("SIGTERM")).toBe(beforeSigterm + 1);

    lock.release();

    expect(process.listenerCount("exit")).toBe(beforeExit);
    expect(process.listenerCount("SIGINT")).toBe(beforeSigint);
    expect(process.listenerCount("SIGTERM")).toBe(beforeSigterm);
  });
});
