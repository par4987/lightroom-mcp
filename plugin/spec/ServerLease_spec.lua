local helper = require 'spec_helper'

-- ServerLease is the only guard that works across Lua states. Everything it
-- replaces lived on _G, which Lightroom gives each state its own copy of, so
-- two servers could bind the same port while each believed it was alone.
--
-- The filesystem is faked here so time can be moved without sleeping and so a
-- test never touches the real lease of a running Lightroom.

local function setup()
    local files = {}
    local realOpen = io.open
    io.open = function(path, mode)
        if mode == "w" then
            files[path] = ""
            return {
                write = function(_, data) files[path] = files[path] .. data end,
                close = function() return true end,
            }
        end
        if mode == "r" then
            local content = files[path]
            if content == nil then return nil end
            return {
                read = function() return content end,
                close = function() return true end,
            }
        end
        return realOpen(path, mode)
    end

    helper.installImport({
        LrPathUtils = {
            child = function(parent, name) return parent .. "/" .. name end,
            getStandardFilePath = function() return "HOME" end,
        },
        LrFileUtils = {
            createAllDirectories = function() end,
            delete = function(path) files[path] = nil end,
        },
    })
    package.loaded.ServerLease = nil
    local ServerLease = require 'ServerLease'

    local clock = 1000
    ServerLease.now = function() return clock end

    return {
        lease = ServerLease,
        files = files,
        advance = function(seconds) clock = clock + seconds end,
        restore = function() io.open = realOpen end,
    }
end

describe("ServerLease", function()
    it("claims a free lease", function()
        local ctx = setup()
        local ok, holder = ctx.lease.claim("owner-a", 58763, 58764)
        local stored = ctx.lease.read()
        ctx.restore()
        assert.is_true(ok)
        assert.is_nil(holder)
        assert.are.equal("owner-a", stored.owner)
    end)

    it("refuses a second claimant while the holder is alive", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)

        local ok, holder = ctx.lease.claim("owner-b", 58763, 58764)
        ctx.restore()

        assert.is_false(ok)
        assert.are.equal("owner-a", holder.owner)
        -- The incumbent's ports travel with it so the loser can say what is
        -- already being served instead of guessing.
        assert.are.equal(58763, holder.request_port)
    end)

    it("lets a claimant in once the holder stops proving it is alive", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)

        ctx.advance(ctx.lease.STALE_S + 1)
        local ok = ctx.lease.claim("owner-b", 58763, 58764)
        local stored = ctx.lease.read()
        ctx.restore()

        assert.is_true(ok)
        assert.are.equal("owner-b", stored.owner)
    end)

    it("keeps a busy holder alive across a refresh", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)

        -- Just under the staleness window, then a refresh: the holder must not
        -- be evicted by its own slow tick, which is the failure this guards.
        ctx.advance(ctx.lease.STALE_S - 1)
        assert.is_true(ctx.lease.refresh("owner-a", 58763, 58764))
        ctx.advance(ctx.lease.STALE_S - 1)
        local ok = ctx.lease.claim("owner-b", 58763, 58764)
        ctx.restore()

        assert.is_false(ok)
    end)

    it("tells a superseded holder to stop", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)
        ctx.advance(ctx.lease.STALE_S + 1)
        ctx.lease.claim("owner-b", 58763, 58764)

        local stillOurs, taker = ctx.lease.refresh("owner-a", 58763, 58764)
        ctx.restore()

        assert.is_false(stillOurs)
        assert.are.equal("owner-b", taker.owner)
    end)

    it("reports no holder when the lease is absent or stale", function()
        local ctx = setup()
        assert.is_nil(ctx.lease.heldBy())
        ctx.lease.claim("owner-a", 58763, 58764)
        assert.is_not_nil(ctx.lease.heldBy())
        ctx.advance(ctx.lease.STALE_S + 1)
        local held = ctx.lease.heldBy()
        ctx.restore()
        assert.is_nil(held)
    end)

    it("releases only its own lease", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)

        -- A task torn down late must not evict the instance that replaced it.
        assert.is_false(ctx.lease.release("owner-b"))
        assert.are.equal("owner-a", ctx.lease.read().owner)  -- still faked here

        assert.is_true(ctx.lease.release("owner-a"))
        local afterRelease = ctx.lease.read()
        ctx.restore()
        assert.is_nil(afterRelease)
    end)

    it("hands the port over immediately after a release", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)
        ctx.lease.release("owner-a")

        -- No staleness wait: a clean stop should not cost the next instance
        -- fifteen seconds of downtime.
        local ok = ctx.lease.claim("owner-b", 58763, 58764)
        ctx.restore()
        assert.is_true(ok)
    end)

    it("survives an unreadable or corrupt lease file", function()
        local ctx = setup()
        ctx.files[ctx.lease.path()] = "this is not a lease\n"
        local held = ctx.lease.heldBy()
        local ok = ctx.lease.claim("owner-a", 58763, 58764)
        ctx.restore()
        -- Garbage is treated as "nobody is holding it": refusing to start
        -- because a file is malformed would be worse than the race.
        assert.is_nil(held)
        assert.is_true(ok)
    end)

    it("refreshes a lease that has gone missing rather than failing", function()
        local ctx = setup()
        ctx.lease.claim("owner-a", 58763, 58764)
        ctx.files[ctx.lease.path()] = nil

        local ok = ctx.lease.refresh("owner-a", 58763, 58764)
        local stored = ctx.lease.read()
        ctx.restore()
        assert.is_true(ok)
        assert.are.equal("owner-a", stored.owner)
    end)
end)
