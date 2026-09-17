#!/usr/bin/env python3
"""Syntax-check all LightroomMCP Lua plugin sources by compiling them with lupa.

Lightroom Classic runs Lua 5.1, but the handlers use plain portable Lua, so
compiling under the lupa runtime catches syntax errors without a Lightroom.
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugin" / "LightroomMCP.lrplugin"

def main() -> int:
    lua = LuaRuntime()
    files = sorted(PLUGIN_DIR.glob("*.lua"))
    failures = 0
    for f in files:
        try:
            src = f.read_text(encoding="utf-8")
            load = lua.eval("function(s) return load(s) end")
            if load(src) is None:
                load_with_name = lua.eval(
                    "function(s, n) local fn, err = load(s, n); return fn, err end"
                )
                _, err = load_with_name(src, str(f))
                print(f"FAIL {f.name}: {err}")
                failures += 1
            else:
                print(f"OK   {f.name}")
        except Exception as exc:  # noqa: BLE001
            print(f"ERR  {f.name}: {exc}")
            failures += 1
    print(f"\n{len(files)} files, {failures} failures")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
