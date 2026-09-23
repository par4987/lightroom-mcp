#!/usr/bin/env python3
"""Run the plugin's busted-style specs under lupa without a busted install.

Implements the subset of busted the specs use (describe/it, assert.is_true,
assert.are.same/equal, assert.has_error, assert.is_nil/is_not_nil) directly in
Lua so the specs execute with real logic, catching regressions before the
project's own CI (which runs real busted) ever sees them.
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SPECS = sorted((ROOT / "plugin" / "spec").glob("*_spec.lua"))

SHIM = r"""
local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function fmt(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. fmt(val)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

-- Counters are GLOBALS so the Python driver can reset and read them between
-- spec files (chunk locals would be invisible across execute() calls).
passed = 0
failed = 0
failures = {}
ctx = ""
-- Stacks of before_each/after_each hooks collected across enclosing describes.
-- after_each MUST actually run: PluginInfoProvider_spec's io.open stub chains a
-- describe-scoped `realOpen` upvalue, and without the restore between tests the
-- stub re-captures itself into infinite tail recursion.
beforeStack = {}
afterStack = {}

function describe(name, fn)
    local prev = ctx
    local prevBeforeLen = #beforeStack
    local prevAfterLen = #afterStack
    ctx = (ctx == "" and name) or (ctx .. " " .. name)
    fn()
    -- Pop hooks this describe registered, like busted's scope.
    for i = #beforeStack, prevBeforeLen + 1, -1 do beforeStack[i] = nil end
    for i = #afterStack, prevAfterLen + 1, -1 do afterStack[i] = nil end
    ctx = prev
end

function before_each(fn)
    beforeStack[#beforeStack + 1] = fn
end

function after_each(fn)
    afterStack[#afterStack + 1] = fn
end

function it(name, fn)
    local ok, err = pcall(function()
        for _, hook in ipairs(beforeStack) do hook() end
        fn()
    end)
    -- Teardown runs even when the test body failed, mirroring busted.
    for i = #afterStack, 1, -1 do
        pcall(afterStack[i])
    end
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = ctx .. " :: " .. name .. " -> " .. tostring(err)
    end
end


assert = {}
function assert.is_true(v) assert_(v == true, "expected true, got " .. fmt(v)) end
function assert.is_false(v) assert_(v == false, "expected false, got " .. fmt(v)) end
function assert.is_nil(v) assert_(v == nil, "expected nil, got " .. fmt(v)) end
function assert.is_not_nil(v) assert_(v ~= nil, "expected non-nil value") end
function assert.is_not_true(v) assert_(v ~= true, "expected not true") end
function assert.is_not_false(v) assert_(v ~= false, "expected not false") end
function assert.is_truthy(v) assert_(v ~= nil and v ~= false, "expected truthy, got " .. fmt(v)) end
function assert.is_falsy(v) assert_(v == nil or v == false, "expected falsy, got " .. fmt(v)) end
function assert.is_table(v) assert_(type(v) == "table", "expected table, got " .. type(v)) end
function assert.is_function(v) assert_(type(v) == "function", "expected function, got " .. type(v)) end
function assert.is_string(v) assert_(type(v) == "string", "expected string, got " .. type(v)) end
function assert.is_number(v) assert_(type(v) == "number", "expected number, got " .. type(v)) end
function assert.equal(expected, actual)
    assert_(expected == actual, "expected " .. fmt(expected) .. ", got " .. fmt(actual))
end
function assert.same(expected, actual)
    assert_(deepEqual(expected, actual), "expected " .. fmt(expected) .. ", got " .. fmt(actual))
end

-- busted's has_error treats the expected message as a SUBSTRING of the
-- raised error (which carries a 'file:line:' prefix).
function assert.has_error(fn, expectedMsg)
    local ok, err = pcall(fn)
    assert_(not ok, "expected an error, none was raised")
    if expectedMsg ~= nil and err and not tostring(err):find(expectedMsg, 1, true) then
        error("expected error '" .. tostring(expectedMsg) .. "', got '" .. tostring(err) .. "'")
    end
end

function assert.has_no_errors(fn)
    local ok, err = pcall(fn)
    assert_(ok, "expected no error, got: " .. tostring(err))
end

-- busted's assert.matches uses Lua patterns.
function assert.matches(pattern, str)
    assert_(type(str) == "string" and str:find(pattern), "expected string matching " .. tostring(pattern))
end

-- busted's two-argument assertions live under assert.are.* / assert.is_* above.
assert.are = { equal = assert.equal, same = assert.same, not_equal = function(e, a) assert_(e ~= a) end }
assert.has_no = { errors = assert.has_no_errors }
"""

def main() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)

    # Expose a `pcall`-compatible assert with a Python-safe error raise.
    lua.execute(
        "function assert_(cond, msg) if not cond then error(msg or 'assertion failed', 2) end end"
    )
    lua.execute(SHIM)

    # Make the plugin + spec dirs requireable, mirroring .busted's lpath.
    lua.execute(
        f"package.path = '{ROOT.as_posix()}/plugin/?.lua;{ROOT.as_posix()}/plugin/spec/?.lua;"
        f"{ROOT.as_posix()}/plugin/LightroomMCP.lrplugin/?.lua;' .. package.path"
    )

    exit_code = 0
    for spec in SPECS:
        # Fresh per-file state: specs mutate package.loaded and _G.import.
        lua.execute("passed = 0; failed = 0; failures = {}; ctx = ''; beforeStack = {}; afterStack = {}")
        try:
            lua.execute(spec.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            print(f"ERR  {spec.name}: {exc}")
            exit_code = 1
            continue
        passed, failed = lua.eval("passed"), lua.eval("failed")
        status = "OK  " if not failed else "FAIL"
        print(f"{status} {spec.name}: {passed} passed, {failed} failed")
        if failed:
            # Assemble the message inside Lua; Python-side table iteration of
            # lupa tables yields key/value pairs, not the strings we want.
            joined = lua.execute("return table.concat(failures, '\\n')") or ""
            for line in str(joined).splitlines():
                print(f"       - {line}")
        if failed:
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
