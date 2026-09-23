import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { TOOL_CONTRACTS, annotationsFor, outputSchemaFor } from "./tool-contracts.js";

/**
 * `annotations` is what tells a client which tools merely read and which can
 * destroy work — the difference between an agent that can explore this
 * server's 56 tools safely and one that cannot. A contract may carry its own;
 * otherwise it is derived from the classification in tool-contracts.ts.
 */
export const TOOL_DEFINITIONS: Tool[] = TOOL_CONTRACTS.map(
  ({ name, description, inputSchema, annotations, outputSchema }) => {
    const resolvedOutput = outputSchema ?? outputSchemaFor(name);
    const tool: Tool = {
      name,
      description,
      inputSchema,
      annotations: annotations ?? annotationsFor(name),
    };
    // Only set the key when there is a schema: an explicit `undefined` would
    // serialise into the tool listing as a declared-but-empty output contract.
    if (resolvedOutput) tool.outputSchema = resolvedOutput;
    return tool;
  },
);

/**
 * Server-side tool filtering, primarily for token-constrained MCP clients
 * (e.g., a DeepSeek harness with function calling): set LIGHTROOM_MCP_TOOLS
 * to a comma-separated list of tool names to expose only those, or "all"
 * (the default) for the full set. Unknown names are reported on stderr and
 * skipped rather than failing the server — a typo should not take the
 * bridge down, and the mistake stays visible in the client's logs.
 */
export const TOOL_FILTER_ENV_VAR = "LIGHTROOM_MCP_TOOLS";

function parseToolFilter(raw: string | undefined): string[] | null {
  if (raw === undefined || raw.trim() === "" || raw.trim().toLowerCase() === "all") {
    return null;
  }
  return raw
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name !== "");
}

export function selectToolDefinitions(
  filterRaw: string | undefined,
  onWarning?: (message: string) => void,
): Tool[] {
  const filter = parseToolFilter(filterRaw);
  if (filter === null) return TOOL_DEFINITIONS;

  const byName = new Map(TOOL_DEFINITIONS.map((tool) => [tool.name, tool]));
  const selected: Tool[] = [];
  for (const name of filter) {
    const tool = byName.get(name);
    if (tool) {
      selected.push(tool);
    } else if (onWarning) {
      onWarning(
        `[tools] LIGHTROOM_MCP_TOOLS: unknown tool '${name}' (ignored); ` +
          `run the server with --help or list tools to see valid names`,
      );
    }
  }
  if (selected.length === 0 && onWarning) {
    onWarning(
      "[tools] LIGHTROOM_MCP_TOOLS matched no tools; exposing the full tool set instead",
    );
    return TOOL_DEFINITIONS;
  }
  return selected;
}

export function listToolsHandler(
  toolFilterRaw?: string,
  onWarning?: (message: string) => void,
): { tools: Tool[] } {
  return { tools: selectToolDefinitions(toolFilterRaw, onWarning) };
}
