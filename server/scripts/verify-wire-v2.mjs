/**
 * Live check of the v2 server over stdio: the handshake, the 56 tools, and the
 * wire fidelity of an inputSchema that uses the JSON Schema constructs v2's
 * types push back on (oneOf, anyOf, not, if/then). Run against dist/index.js.
 */
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: ["dist/index.js"],
  cwd: process.cwd(),
  stderr: "pipe",
});

const client = new Client({ name: "wire-verify", version: "1.0.0" });
await client.connect(transport);

const serverVersion = client.getServerVersion();
console.log(`handshake ok; server version = ${serverVersion?.version}`);

const { tools } = await client.listTools();
console.log(`tools/list = ${tools.length} tools`);

// Fidelity: the constructs TypeScript refused must reach the client unchanged.
const checks = [
  ["get_photo_metadata", "photo_id", (s) => Array.isArray(s.oneOf) && s.oneOf.length === 2],
  ["get_photo_preview", "size", (s) => Boolean(s.oneOf)],
  ["add_ai_mask", "adjustments", (s) => typeof s.description === "string"],
];
for (const [tool, prop, ok] of checks) {
  const t = tools.find((x) => x.name === tool);
  const schema = t?.inputSchema.properties?.[prop];
  console.log(`  ${tool}.${prop}: oneOf=${Array.isArray(schema?.oneOf)} desc=${typeof schema?.description} -> ${ok(schema) ? "OK" : "PERDIDO"}`);
}

// A tool whose schema uses if/then must still be listed and describable.
for (const name of ["reset_develop", "manage_view_filter", "select_photos"]) {
  const t = tools.find((x) => x.name === name);
  const json = JSON.stringify(t?.inputSchema ?? {});
  console.log(`  ${name}: type=${t?.inputSchema?.type} not=${json.includes('"not"')} if=${json.includes('"if"')} -> ${json.length > 40 ? "schema presente" : "VACIA"}`);
}

// Annotations drive read vs destructive; they must survive.
const byName = new Map(tools.map((t) => [t.name, t]));
console.log(`  search_photos readOnlyHint=${byName.get("search_photos")?.annotations?.readOnlyHint}`);
console.log(`  remove_from_catalog destructiveHint=${byName.get("remove_from_catalog")?.annotations?.destructiveHint}`);

// Validation must still reject a bad call before it reaches Lightroom.
const bad = await client.callTool({ name: "search_photos", arguments: { not_a_real_filter: 1 } });
console.log(`  validacion: isError=${bad.isError} msg=${String(bad.content?.[0]?.text ?? "").slice(0, 110)}`);

await client.close();
