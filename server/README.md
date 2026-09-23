# @pired/lightroom-mcp

MCP server bridging Claude / DeepSeek / Codex / Cursor to Adobe Lightroom Classic via a bundled Lua plugin — with hybrid AI Denoise, spot removal, local + AI + range masks, tone curves, Auto commands, scoped resets, process version, snapshots, inline JPEG previews, selection & navigation and batch IPTC.

Published on npm as **`@pired/lightroom-mcp`**. This is the `server/` half of the
**pired-lightroom-mcp** repository (a fork of
[Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) that keeps all
18 original tools and adds 37 more, 55 in total). The full documentation — installation,
tool reference and troubleshooting — lives in the repository's main `README.md`.
The npm tarball is self-contained: `dist/` carries the compiled server, the
`LightroomMCP.lrplugin` Lua plugin (so `install-plugin` works out of the box), the
zero-dependency DeepSeek harness (`dist/deepseek-harness/`) and ready-made client
configs (`dist/configs/`).

## Quick start (npm)

```bash
npm install -g @pired/lightroom-mcp
pired-lightroom-mcp install-plugin        # copies the .lrplugin into Lightroom's Modules folder
```

Then restart Lightroom Classic and click **Start Server** in
File → Plug-in Manager → Lightroom MCP AI.

Point your MCP client at the package (no global install needed):

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "npx",
      "args": ["-y", "@pired/lightroom-mcp"]
    }
  }
}
```

On Windows with Claude Desktop use the `cmd` wrapper (see `dist/configs/claude-desktop.json`).

## Quick start (from source)

```bash
cd server
npm install
npm run build
node dist/index.js install-plugin   # copies the .lrplugin into Lightroom's Modules folder
```

Then point your client at `server/dist/index.js` (absolute path).

## Commands

```
pired-lightroom-mcp [stdio]            Run MCP over stdio (default)
pired-lightroom-mcp install-plugin     Copy plugin into Lightroom Modules folder
pired-lightroom-mcp --help | --version
```

## Environment

| Var | Default | Purpose |
| --- | --- | --- |
| `LIGHTROOM_MCP_REQUEST_PORT` | `58763` | Plugin request port. |
| `LIGHTROOM_MCP_RESPONSE_PORT` | `58764` | Plugin response port. |
| `LIGHTROOM_MCP_TOKEN_PATH` | `~/.config/lightroom-mcp/token` | Auth token file. |
| `LIGHTROOM_MCP_TOOLS` | `all` | Comma-separated subset of tools to expose (token-constrained clients); unknown names warn on stderr, no-match falls back to all. |

## License

MIT
