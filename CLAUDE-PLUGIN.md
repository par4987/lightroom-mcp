# Claude Code plugin

This repository is also a Claude Code plugin. Installing it gives you the
`lightroom` MCP server and the `photo-edit-advisor` skill in one step, instead
of wiring the server into Claude Code by hand.

## Install

From a clone of this repository:

```bash
claude --plugin-dir /path/to/lightroom-mcp
```

Then `/mcp` should list `plugin:lightroom-classic-ai:lightroom`, and the skill
is available as `/lightroom-classic-ai:photo-edit-advisor`.

To keep it installed across sessions, add the repository as a marketplace or
commit the plugin folder to your own marketplace.

## How it launches the server

`.mcp.json` runs the server through `npx` against the published npm package,
pinned to an exact version:

```
npx -y @pired/lightroom-mcp@<version>
```

It does **not** point at `server/dist/index.js` in this repository. `dist/` is
build output and is gitignored, so a checkout — or a plugin installed from git —
has no server to run. Going through npm also means the version is a released,
tested one rather than whatever happens to be built on your machine.

On first run the server copies its bundled Lightroom plugin into Lightroom's
`Modules` folder and tells you to restart Lightroom once. After that, start the
server from Lightroom's Plug-in Manager.

## Releasing

The plugin version and the pinned npm version are kept in step by the same
script that already owns every other version in the repo:

```bash
node scripts/bump-version.mjs <version>
node scripts/bump-version.mjs --check     # fails on any drift
```

It now covers seven sources, including `.claude-plugin/plugin.json` and the
pinned specifier in `.mcp.json`. Publishing the npm package and releasing the
plugin have to happen in that order — the pin points at a version that has to
exist on npm.

## Known warnings

`claude plugin validate .` reports one warning:

```
root: CLAUDE.md at the plugin root is not loaded as project context
```

That is expected. `CLAUDE.md` and `AGENTS.md` are contributor guidance for
working *on* this repository; they are not instructions for using the plugin.
Context that should ship with the plugin belongs in `skills/<name>/SKILL.md`.

## Validate

```bash
claude plugin validate .
```
