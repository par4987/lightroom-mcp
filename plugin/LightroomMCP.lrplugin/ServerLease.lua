local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

-- A single-server lease held on the FILESYSTEM.
--
-- Every guard this plugin had against running two servers at once lived on
-- `_G.LightroomMCP_State`: a `running` flag, then a monotonic `instanceId`.
-- None of them can work, for a reason no amount of tightening fixes: Lightroom
-- runs the plugin in more than one Lua state, and each state has its OWN _G.
-- Measured in the log as two monitor loops with generations 25 and 3 rebinding
-- the same port in the same second, neither able to see the other, every
-- response stalling because no listener survived long enough to deliver.
--
-- So the coordination has to live outside the Lua state. The bridge already
-- solves the same problem the same way (server/src/instance-lock.ts); this is
-- that design on the plugin side.
--
-- Freshness, not process identity: the Lua sandbox exposes no pid, so a holder
-- proves it is alive by touching the lease on a timer. A holder that dies stops
-- touching it and the lease goes stale on its own -- which also means a crashed
-- Lightroom never leaves a lock that needs clearing by hand.

local ServerLease = {}

-- The holder refreshes every REFRESH_S; a lease older than STALE_S is up for
-- grabs. The gap has to absorb a slow tick: the monitor loop sleeps up to half
-- a second normally, but a socket rebind inside it can block for a second or
-- more, so the margin is deliberately wide. Too tight and a busy holder gets
-- evicted by its own stall, which is the failure this module exists to stop.
ServerLease.REFRESH_S = 3
ServerLease.STALE_S = 15

-- Injectable so specs can move time without sleeping.
ServerLease.now = function() return os.time() end

function ServerLease.directory()
    return LrPathUtils.child(
        LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), ".config"),
        "lightroom-mcp")
end

function ServerLease.path()
    return LrPathUtils.child(ServerLease.directory(), "plugin-server.lease")
end

-- Plain `key=value` lines rather than JSON: this file is read and written on a
-- timer by code that must never throw, and there is nothing here worth a parser.
local function parse(text)
    local lease = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then lease[key] = value end
    end
    if not lease.owner or lease.owner == "" then return nil end
    lease.heartbeat = tonumber(lease.heartbeat) or 0
    lease.request_port = tonumber(lease.request_port)
    lease.response_port = tonumber(lease.response_port)
    return lease
end

function ServerLease.read()
    local ok, result = pcall(function()
        local handle = io.open(ServerLease.path(), "r")
        if not handle then return nil end
        local text = handle:read("*a")
        handle:close()
        return parse(text or "")
    end)
    if not ok then return nil end
    return result
end

local function write(owner, requestPort, responsePort)
    local ok = pcall(function()
        LrFileUtils.createAllDirectories(ServerLease.directory())
        local handle = io.open(ServerLease.path(), "w")
        if not handle then error("cannot open lease for writing") end
        handle:write(string.format(
            "owner=%s\nheartbeat=%d\nrequest_port=%s\nresponse_port=%s\n",
            tostring(owner), ServerLease.now(),
            tostring(requestPort or ""), tostring(responsePort or "")))
        handle:close()
    end)
    return ok
end

-- The live holder, or nil when the lease is absent or stale. Returns the whole
-- lease so a caller can report WHICH ports the incumbent is serving.
function ServerLease.heldBy()
    local lease = ServerLease.read()
    if not lease then return nil end
    if ServerLease.now() - lease.heartbeat >= ServerLease.STALE_S then
        return nil
    end
    return lease
end

-- Take the lease unless someone else holds a fresh one. Returns
-- true, or false plus the incumbent, so the caller can log who won.
function ServerLease.claim(owner, requestPort, responsePort)
    local holder = ServerLease.heldBy()
    if holder and holder.owner ~= tostring(owner) then
        return false, holder
    end
    return write(owner, requestPort, responsePort), holder
end

-- Touch the lease, but only while it is still ours. A false return means we
-- were superseded and the caller must stop serving: this is the cross-state
-- signal that `instanceId` could never deliver.
function ServerLease.refresh(owner, requestPort, responsePort)
    local lease = ServerLease.read()
    if lease and lease.owner ~= tostring(owner) then
        return false, lease
    end
    return write(owner, requestPort, responsePort), lease
end

function ServerLease.release(owner)
    local lease = ServerLease.read()
    -- Never delete someone else's lease: a task being torn down late must not
    -- evict the instance that replaced it.
    if lease and lease.owner ~= tostring(owner) then return false end
    local ok = pcall(function() LrFileUtils.delete(ServerLease.path()) end)
    return ok
end

return ServerLease
