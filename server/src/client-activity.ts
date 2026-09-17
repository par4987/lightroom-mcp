// Decides whether this bridge still has a live, interested MCP client.
//
// Claude Desktop's respawn cycle leaves two flavors of abandoned bridge
// behind: a probe process that completed the handshake but was never used,
// and a fully working bridge whose stdin pipe simply never got closed. Both
// survive every shutdown path that relies on stdin EOF, and both keep the
// instance lock, so every future spawn dies on it (issue: "Another Lightroom
// MCP bridge is already running").
//
// The signals we can trust, in order of strength:
//   1. A tools/call request — a client that runs tools is using the bridge.
//   2. Any JSON-RPC message — pings, tools/list, everything refreshes the
//      idle clock.
// A bridge that has never run a tool and went quiet is a probe; a bridge
// that ran tools and went quiet for a long while is abandoned. Both yield
// the lock to a waiting contender (see instance-lock.ts).

/** JSON-RPC methods that a client sends while merely probing. */
const PROBE_METHODS = new Set(["initialize", "notifications/initialized", "ping", "tools/list"]);

export interface ClientActivityOptions {
  /** Injectable clock (tests). Defaults to Date.now. */
  now?: () => number;
  /**
   * Idle time after which a bridge that HAS served tool calls agrees to
   * yield to a waiting contender. Defaults to 10 minutes, override via
   * LIGHTROOM_MCP_IDLE_YIELD_MS (0 disables yielding entirely).
   */
  idleYieldMs?: number;
  /**
   * Idle time after which a bridge that has NEVER served a tool call
   * agrees to yield — Claude's era probes answer their one handshake and
   * then go silent forever, so this is what unblocks the respawn cycle.
   * Defaults to 10 seconds, override via LIGHTROOM_MCP_PROBE_YIELD_MS.
   */
  probeYieldMs?: number;
}

export class ClientActivityTracker {
  private readonly now: () => number;
  private readonly idleYieldMs: number;
  private readonly probeYieldMs: number;
  private lastMessageAt: number;
  private sawToolCall = false;

  constructor(options: ClientActivityOptions = {}) {
    this.now = options.now ?? Date.now;
    this.idleYieldMs = options.idleYieldMs ?? envNumber("LIGHTROOM_MCP_IDLE_YIELD_MS") ?? 600_000;
    this.probeYieldMs = options.probeYieldMs ?? envNumber("LIGHTROOM_MCP_PROBE_YIELD_MS") ?? 10_000;
    this.lastMessageAt = this.now();
  }

  /** Records every JSON-RPC message received from the client. */
  noteMessage(method: string | undefined): void {
    this.lastMessageAt = this.now();
    if (method !== undefined && !PROBE_METHODS.has(method)) {
      this.sawToolCall = true;
    }
  }

  /** Milliseconds since the last client message. */
  idleMs(): number {
    return this.now() - this.lastMessageAt;
  }

  /** True once any request beyond the probe set arrived (tools/call et al.). */
  hasServedRealWork(): boolean {
    return this.sawToolCall;
  }

  /**
   * Whether this bridge should hand the lock to a waiting contender: it is
   * either a probe that nobody ever used, or a bridge whose client has been
   * silent long enough that it can only be an abandoned session.
   */
  shouldYieldToContender(): boolean {
    if (this.idleYieldMs <= 0) return false;
    if (!this.sawToolCall) return this.idleMs() >= this.probeYieldMs;
    return this.idleMs() >= this.idleYieldMs;
  }
}

function envNumber(name: string): number | undefined {
  const raw = process.env[name];
  if (raw === undefined) return undefined;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
}
