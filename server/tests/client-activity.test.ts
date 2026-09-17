import { describe, it, expect } from "@jest/globals";
import { ClientActivityTracker } from "../src/client-activity.js";

describe("ClientActivityTracker", () => {
  function trackerWith(clock: { now: number }) {
    return new ClientActivityTracker({
      now: () => clock.now,
      probeYieldMs: 10_000,
      idleYieldMs: 600_000,
    });
  }

  it("does not yield a bridge whose client just handshaked", () => {
    const clock = { now: 1_000 };
    const tracker = trackerWith(clock);
    tracker.noteMessage("initialize");
    tracker.noteMessage("notifications/initialized");

    clock.now += 5_000;

    expect(tracker.idleMs()).toBe(5_000);
    expect(tracker.hasServedRealWork()).toBe(false);
    expect(tracker.shouldYieldToContender()).toBe(false);
  });

  it("yields a never-used bridge once the probe idle window passes", () => {
    const clock = { now: 1_000 };
    const tracker = trackerWith(clock);
    tracker.noteMessage("initialize");

    clock.now += 11_000;

    expect(tracker.idleMs()).toBe(11_000);
    expect(tracker.shouldYieldToContender()).toBe(true);
  });

  it("treats ping and tools/list as activity but not as real work", () => {
    const clock = { now: 1_000 };
    const tracker = trackerWith(clock);
    tracker.noteMessage("initialize");
    clock.now += 5_000;
    tracker.noteMessage("ping");
    clock.now += 5_000;
    tracker.noteMessage("tools/list");

    expect(tracker.idleMs()).toBe(0);
    expect(tracker.hasServedRealWork()).toBe(false);
  });

  it("holds a tool-serving bridge until the long idle window passes", () => {
    const clock = { now: 1_000 };
    const tracker = trackerWith(clock);
    tracker.noteMessage("initialize");
    tracker.noteMessage("tools/call");

    clock.now += 599_000;
    expect(tracker.shouldYieldToContender()).toBe(false);

    clock.now += 2_000;
    expect(tracker.shouldYieldToContender()).toBe(true);
  });

  it("keeps counting tools/call traffic as interest", () => {
    const clock = { now: 1_000 };
    const tracker = trackerWith(clock);
    tracker.noteMessage("tools/call");

    clock.now += 700_000;
    tracker.noteMessage("tools/call");
    expect(tracker.idleMs()).toBe(0);

    clock.now += 599_000;
    expect(tracker.shouldYieldToContender()).toBe(false);
  });

  it("never yields when idleYieldMs is 0", () => {
    const clock = { now: 1_000 };
    const tracker = new ClientActivityTracker({ now: () => clock.now, idleYieldMs: 0 });
    tracker.noteMessage("initialize");

    clock.now += 3_600_000;

    expect(tracker.shouldYieldToContender()).toBe(false);
  });
});
