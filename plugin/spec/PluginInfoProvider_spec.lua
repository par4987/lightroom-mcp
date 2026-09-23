local helper = require 'spec_helper'

-- Stub everything PluginInfoProvider / PluginInit pull in so requiring them
-- has no real side effects. The lifecycle logic under test lives in the
-- module body + resetForReload + PluginInit wiring; none of it binds a
-- socket at load time (binding happens only inside startServer).
local HANDLER_MODULES = {
    'JSON', 'HandlerSearch', 'HandlerCollections', 'HandlerMetadata',
    'HandlerOrganization', 'HandlerImport', 'HandlerExport',
    'HandlerSelection', 'HandlerDevelop',
    -- @pired/lightroom-mcp additions
    'HandlerAI', 'HandlerSpots', 'HandlerLocalAdjustments', 'HandlerWatermark',
    -- v2.0 additions
    'HandlerAIMasks',
}

-- opts (all optional) let a test drive the otherwise-async server task:
--   runTask        -- actually execute the postAsyncTaskWithContext body
--   cleanups       -- array; each registered cleanup handler is appended
--   socketOps      -- array; "close"/"reconnect" calls on bound sockets land here
--   stopLoopOnSleep -- flip running=false on the first LrTasks.sleep so the
--                      monitor loop exits after a single tick
--   capturedBinds  -- array; each LrSocket.bind opts table is appended, in
--                      bind order (request socket first, then response), so
--                      a test can invoke onConnected/onMessage/etc directly
--   onSleep        -- called with the shared state on each LrTasks.sleep, so a
--                      test can flip flags between monitor-loop ticks
--   sends          -- array; every line written to a bound socket lands here
local function installStubs(prefs, asyncTasks, opts)
    opts = opts or {}
    helper.installImport({
        LrTasks = {
            startAsyncTask = function(fn)
                if asyncTasks then
                    table.insert(asyncTasks, fn)
                else
                    fn()
                end
            end,
            sleep = function()
                if opts.stopLoopOnSleep and _G.LightroomMCP_State then
                    _G.LightroomMCP_State.running = false
                end
                if opts.onSleep then opts.onSleep(_G.LightroomMCP_State) end
            end,
            pcall = pcall,
        },
        LrLogger = helper.defaultLrLogger(),
        LrDialogs = { message = function() end },
        LrFunctionContext = {
            postAsyncTaskWithContext = function(name, fn)
                if opts.tasksStarted then table.insert(opts.tasksStarted, name) end
                if not opts.runTask then return end
                local context = {
                    addCleanupHandler = function(_, handler)
                        if opts.cleanups then table.insert(opts.cleanups, handler) end
                    end,
                }
                fn(context)
            end,
        },
        LrSocket = {
            bind = function(bindOpts)
                if opts.capturedBinds then table.insert(opts.capturedBinds, bindOpts) end
                return {
                    close = function()
                        if opts.socketOps then table.insert(opts.socketOps, "close") end
                    end,
                    reconnect = function()
                        if opts.socketOps then table.insert(opts.socketOps, "reconnect") end
                    end,
                    send = function(_, line)
                        if opts.sends then table.insert(opts.sends, line) end
                    end,
                }
            end,
        },
        LrPrefs = { prefsForPlugin = function() return prefs or {} end },
        LrView = { bind = function() end },
        LrUUID = { generateUUID = function() return "0000-0000" end },
        LrPathUtils = {
            child = function(a, b) return a .. "/" .. b end,
            getStandardFilePath = function() return "/home" end,
        },
        LrFileUtils = { createAllDirectories = function() end },
    })
    for _, name in ipairs(HANDLER_MODULES) do
        package.loaded[name] = {}
    end
end

-- Simulate Lightroom loading the InfoProvider file fresh (panel render) or
-- PluginInit requiring it: clear the module cache and re-run its body while
-- _G persists across the load (same Lua state).
local function loadInfoProvider()
    package.loaded.PluginInfoProvider = nil
    return require 'PluginInfoProvider'
end

local function loadPluginInit()
    package.loaded.PluginInfoProvider = nil
    package.loaded.PluginInit = nil
    require 'PluginInit'
end

describe("PluginInfoProvider lifecycle", function()
    before_each(function()
        _G.LightroomMCP_State = nil
        installStubs()
    end)

    it("creates fresh state on first load", function()
        loadInfoProvider()
        assert.is_not_nil(_G.LightroomMCP_State)
        assert.is_false(_G.LightroomMCP_State.running)
    end)

    it("preserves a running server across a Plug-in Manager render", function()
        loadInfoProvider()
        -- Simulate a live server, then a panel render that re-runs the body.
        _G.LightroomMCP_State.running = true
        local sock = { close = function() error("must not close on render") end }
        _G.LightroomMCP_State.requestSocket = sock
        local stateBefore = _G.LightroomMCP_State

        loadInfoProvider()

        assert.are.equal(stateBefore, _G.LightroomMCP_State)
        assert.is_true(_G.LightroomMCP_State.running)
        assert.are.equal(sock, _G.LightroomMCP_State.requestSocket)
    end)

    it("resetForReload stops a stale running instance", function()
        local mod = loadInfoProvider()
        local closed = { request = false, response = false }
        local s = _G.LightroomMCP_State
        s.running = true
        s.token = "tok"
        s.sendConnected = true
        s.receiveConnected = true
        s.requestSocket = { close = function() closed.request = true end }
        s.responseSocket = { close = function() closed.response = true end }

        mod.resetForReload()

        assert.is_false(s.running)
        assert.is_nil(s.requestSocket)
        assert.is_nil(s.responseSocket)
        assert.is_false(s.sendConnected)
        assert.is_false(s.receiveConnected)
        assert.is_nil(s.token)
        assert.is_true(closed.request)
        assert.is_true(closed.response)
    end)

    it("resetForReload is a no-op when nothing is running", function()
        local mod = loadInfoProvider()
        assert.has_no.errors(function() mod.resetForReload() end)
        assert.is_false(_G.LightroomMCP_State.running)
    end)
end)

-- Auto-start scheduling itself is covered by PluginInit_spec.lua; here we
-- only assert that PluginInit wires the reload teardown into the real module.
describe("PluginInit reload reset", function()
    before_each(function()
        _G.LightroomMCP_State = nil
    end)

    it("resets a surviving running instance on reload", function()
        installStubs({ autoStartServer = false })
        local closed = false
        _G.LightroomMCP_State = {
            running = true,
            requestSocket = { close = function() closed = true end },
            responseSocket = nil,
            sendConnected = true,
            receiveConnected = false,
            requestsProcessed = 7,
            lastEvent = "12:00:00",
            requestPort = 12345,
            responseNeedsRebind = true,
            log = {},
            token = "tok",
        }

        loadPluginInit()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_true(closed)
        -- Transient state returns to fresh-state defaults (Copilot #141).
        assert.are.equal(0, _G.LightroomMCP_State.requestsProcessed)
        assert.is_nil(_G.LightroomMCP_State.lastEvent)
        assert.is_nil(_G.LightroomMCP_State.requestPort)
        assert.is_false(_G.LightroomMCP_State.responseNeedsRebind)
    end)
end)

-- Drives the real startServer task body (binds, cleanup handler, monitor
-- loop) to cover the concurrency-sensitive teardown that the in-place
-- resetForReload refactor put at risk.
-- The single-server lease is the only guard that crosses Lua states, so these
-- cover the WIRING: that startServer asks before binding, stands down when
-- refused, and does not publish a token it will not serve. A real lease is
-- swapped for a double -- what matters here is the order of operations, not the
-- file format (ServerLease_spec covers that).
describe("PluginInfoProvider single-server lease", function()
    local realOpen
    before_each(function()
        _G.LightroomMCP_State = nil
        realOpen = io.open
        io.open = function(path, mode, ...)
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
        package.loaded.ServerLease = nil
    end)

    local function withLease(lease, opts)
        package.loaded.ServerLease = lease
        local binds = {}
        installStubs(nil, nil, opts or { runTask = true, stopLoopOnSleep = true,
            cleanups = {}, capturedBinds = binds })
        local mod = loadInfoProvider()
        return mod, binds
    end

    local function fakeLease(overrides)
        local calls = { claims = {}, refreshes = {}, releases = {} }
        local lease = {
            REFRESH_S = 3, STALE_S = 15,
            now = function() return 1000 end,
            heldBy = function() return nil end,
            claim = function(owner, req, res)
                table.insert(calls.claims, { owner = owner, request = req, response = res })
                return true, nil
            end,
            refresh = function(owner)
                table.insert(calls.refreshes, owner)
                return true, nil
            end,
            release = function(owner) table.insert(calls.releases, owner) return true end,
        }
        for k, v in pairs(overrides or {}) do lease[k] = v end
        return lease, calls
    end

    it("stands down when another instance already holds the lease", function()
        local lease, calls = fakeLease({
            claim = function() return false, {
                owner = "someone-else", request_port = 58763, response_port = 58764,
            } end,
            -- The watcher polls this; a held lease means it keeps waiting
            -- rather than trying to take over.
            heldBy = function() return { owner = "someone-else" } end,
        })
        local mod, binds = withLease(lease)

        mod.startServer()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.are.equal(0, #binds, "a stood-down instance must not bind a port")
        assert.are.equal(0, #calls.refreshes)
    end)

    it("does not publish a token when it stands down", function()
        -- Ordering, and it is the whole point: the old code wrote a token
        -- before finding out whether it would serve, so the bridge sent a
        -- secret the live instance had never seen and every request failed
        -- authentication in silence.
        local lease = fakeLease({
            claim = function() return false, { owner = "someone-else" } end,
            heldBy = function() return { owner = "someone-else" } end,
        })
        local mod = withLease(lease)

        mod.startServer()

        assert.is_nil(_G.LightroomMCP_State.token)
    end)

    it("claims before binding, with the ports it is about to serve", function()
        local lease, calls = fakeLease()
        local mod, binds = withLease(lease)

        mod.startServer()

        assert.are.equal(1, #calls.claims)
        assert.are.equal(58763, calls.claims[1].request)
        assert.are.equal(58764, calls.claims[1].response)
        assert.is_true(#binds > 0)
    end)

    it("starts anyway when the lease file cannot be written", function()
        -- A plugin that refuses to start because of a disk problem is worse
        -- than one that serves unguarded: the race is rare, not starting is total.
        local lease = fakeLease({ claim = function() return false, nil end })
        local mod, binds = withLease(lease)

        mod.startServer()

        -- Asserting on binds, not on `running`: the harness stops the monitor
        -- loop at the first sleep, which clears `running` on its way out.
        assert.is_true(#binds > 0)
    end)

    it("stops serving, and keeps watching, when another instance takes the lease", function()
        local ticks = 0
        local clock = 1000
        local tasks = {}
        local evicted = false
        local lease = fakeLease({
            now = function() return clock end,
            refresh = function()
                evicted = true
                return false, { owner = "someone-else" }
            end,
            -- The winner is alive, so the watcher this spawns just waits.
            heldBy = function() return { owner = "someone-else" } end,
        })
        local mod = withLease(lease, {
            runTask = true,
            cleanups = {},
            capturedBinds = {},
            tasksStarted = tasks,
            onSleep = function(state)
                -- Count only the SERVER loop: once evicted, the sleeps come
                -- from the watcher, which the harness also runs inline.
                if not evicted then ticks = ticks + 1 end
                clock = clock + 10        -- past REFRESH_S, so the loop checks
                if ticks > 5 then state.running = false end   -- safety net
            end,
        })

        mod.startServer()

        -- It must break on the lost lease, not run into the safety net.
        assert.is_true(ticks <= 3, "loop kept going after losing the lease: " .. ticks)

        -- And it must leave a watcher behind. An evicted server that simply
        -- dies puts us back at "restart Lightroom" the moment the instance
        -- that evicted it goes away.
        local watching = false
        for _, name in ipairs(tasks) do
            if tostring(name):find("LeaseWatch", 1, true) then watching = true end
        end
        assert.is_true(watching, "an evicted server must keep watching the lease")
    end)

    it("does not release the lease when its task is torn down", function()
        -- Measured: Lightroom discards short-lived Lua states, and releasing on
        -- teardown handed the port to a watcher within five seconds -- onto
        -- another state that also died. Six servers in ninety seconds. Going
        -- stale costs one quiet window instead.
        local lease, calls = fakeLease()
        local cleanups = {}
        package.loaded.ServerLease = lease
        installStubs(nil, nil, {
            runTask = true, stopLoopOnSleep = true, cleanups = cleanups,
            capturedBinds = {},
        })
        local mod = loadInfoProvider()
        mod.startServer()

        assert.is_true(#cleanups > 0, "the server task registers a cleanup handler")
        for _, handler in ipairs(cleanups) do handler() end

        assert.are.equal(0, #calls.releases)
    end)

    it("releases the lease on shutdown", function()
        local lease, calls = fakeLease()
        local mod = withLease(lease)
        mod.startServer()

        mod.shutdown()

        assert.are.equal(1, #calls.releases)
    end)
end)

describe("PluginInfoProvider server task", function()
    local realOpen
    before_each(function()
        _G.LightroomMCP_State = nil
        -- startServer writes a token file; stub ONLY the write so it never
        -- touches disk. Delegate every other open to the real io.open --
        -- under CI's luarocks `require` loader, manifest reads call
        -- io.open(path):read(), and a fake handle there breaks module loading.
        realOpen = io.open
        io.open = function(path, mode, ...)
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
    end)

    describe("undecodable requests", function()
        local function startServerCapturing(sends)
            local binds = {}
            installStubs(nil, nil, {
                runTask = true, stopLoopOnSleep = true, cleanups = {},
                capturedBinds = binds, sends = sends,
            })
            package.loaded.JSON = nil
            local mod = loadInfoProvider()
            mod.startServer()
            _G.LightroomMCP_State.sendConnected = true
            return binds
        end

        local function malformed(token)
            return '{"hello":"' .. token .. '","id":"req_1","action":"ping","params":{"x":"\\q"}}'
        end

        it("answers an authenticated client instead of leaving it to time out", function()
            local sends = {}
            local binds = startServerCapturing(sends)

            binds[1].onMessage(nil, malformed(_G.LightroomMCP_State.token))

            assert.is_not_nil(sends[1])
            assert.is_nil(sends[2])
            assert.is_not_nil(sends[1]:find('"id":"req_1"', 1, true))
            assert.is_not_nil(sends[1]:find('Malformed request', 1, true))
        end)

        it("stays silent when the salvaged token does not match", function()
            local sends = {}
            local binds = startServerCapturing(sends)

            binds[1].onMessage(nil, malformed("not-the-token"))

            assert.is_nil(sends[1])
        end)

        it("stays silent when no id can be salvaged", function()
            local sends = {}
            local binds = startServerCapturing(sends)

            binds[1].onMessage(nil, '{"hello":"' .. _G.LightroomMCP_State.token .. '","action":"ping"')

            assert.is_nil(sends[1])
        end)

        -- "Reload Plug-in" hands Lightroom a FRESH module instance while the
        -- previous instance's LrSocket callbacks keep serving. The old instance
        -- authenticates against its own in-memory token; the new one has already
        -- published a different token to the file, which is what the bridge
        -- sends. Measured live: every request then failed as a mismatch, and
        -- because an auth failure is dropped silently the caller only saw a
        -- 90s timeout. Trusting the published token makes the two agree.
        local function withPublishedToken(published, fn)
            local prevOpen = io.open
            io.open = function(path, mode, ...)
                if mode and mode:find("w", 1, true) then
                    return { write = function() end, close = function() end }
                end
                if type(path) == "string" and path:find("token", 1, true) then
                    return { read = function() return published end, close = function() end }
                end
                return prevOpen(path, mode, ...)
            end
            local ok, err = pcall(fn)
            io.open = prevOpen
            if not ok then error(err, 0) end
        end

        it("accepts the token published on disk when its own is stale", function()
            local sends = {}
            local binds = startServerCapturing(sends)
            _G.LightroomMCP_State.token = "stale-from-a-previous-module-instance"

            withPublishedToken("the-live-token", function()
                binds[1].onMessage(nil, malformed("the-live-token"))
            end)

            assert.is_not_nil(sends[1])
            assert.is_not_nil(sends[1]:find('"id":"req_1"', 1, true))
        end)

        it("still rejects a token that matches neither memory nor the file", function()
            local sends = {}
            local binds = startServerCapturing(sends)
            _G.LightroomMCP_State.token = "in-memory"

            withPublishedToken("the-live-token", function()
                binds[1].onMessage(nil, malformed("neither-of-them"))
            end)

            assert.is_nil(sends[1])
        end)
    end)

    it("can start again after a stop, without a reload in between", function()
        installStubs(nil, nil, { runTask = false, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        assert.is_true(_G.LightroomMCP_State.running)

        mod.stopServer()
        assert.is_false(_G.LightroomMCP_State.running)

        mod.startServerFromPanel()
        assert.is_true(_G.LightroomMCP_State.running)
    end)

    it("bumps instanceId on every start", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        assert.are.equal(1, _G.LightroomMCP_State.instanceId)
        mod.startServer()
        assert.are.equal(2, _G.LightroomMCP_State.instanceId)
    end)

    -- The race that made every reload cost a manual process kill. resetForReload
    -- signals a surviving loop only through running=false, and startServer sets
    -- it straight back to true; a loop that was asleep never sees the false and
    -- keeps running. Two loops then share one responseGen and one socket pair
    -- and rebind the same port against each other forever (observed live as
    -- gen=10 and gen=2 in the same second), so every response stalls.
    it("stops a superseded monitor loop even while running stays true", function()
        local sleeps = 0
        installStubs(nil, nil, {
            runTask = true,
            cleanups = {},
            onSleep = function(state)
                sleeps = sleeps + 1
                if sleeps == 1 then
                    -- A newer startServer takes over. running stays TRUE --
                    -- that is precisely what used to keep this loop alive.
                    state.instanceId = state.instanceId + 1
                end
                -- Safety net so a regression fails the assertion instead of
                -- hanging the suite.
                if sleeps > 5 then state.running = false end
            end,
        })
        local mod = loadInfoProvider()
        mod.startServer()
        -- Give the loop work to do on its first tick.
        _G.LightroomMCP_State.responseNeedsRebind = true

        assert.is_true(sleeps <= 2)
        -- Proves the loop exited on the instance check, not on `running`.
        assert.is_true(_G.LightroomMCP_State.running)
    end)

    it("ignores a superseded instance's cleanup handler", function()
        local cleanups = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups })
        local mod = loadInfoProvider()

        mod.startServer() -- instance 1: binds, loop exits (stopLoopOnSleep)
        local staleCleanup = cleanups[1]

        mod.startServer() -- instance 2 supersedes
        local liveReq = _G.LightroomMCP_State.requestSocket
        local liveResp = _G.LightroomMCP_State.responseSocket
        local liveToken = _G.LightroomMCP_State.token

        -- Old context cleanup fires late (after the new instance rebound).
        staleCleanup()

        assert.are.equal(liveReq, _G.LightroomMCP_State.requestSocket)
        assert.are.equal(liveResp, _G.LightroomMCP_State.responseSocket)
        assert.are.equal(liveToken, _G.LightroomMCP_State.token)
    end)

    it("tears down its own sockets when not superseded", function()
        local cleanups = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups })
        local mod = loadInfoProvider()

        mod.startServer()
        cleanups[1]()

        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_nil(_G.LightroomMCP_State.responseSocket)
        assert.is_nil(_G.LightroomMCP_State.token)
    end)

    it("does not churn freshly bound sockets when recovery flags are stale", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()

        -- Simulate flags left true by a client disconnect just before reload.
        _G.LightroomMCP_State.requestNeedsReconnect = true
        _G.LightroomMCP_State.responseNeedsRebind = true
        _G.LightroomMCP_State.responseNeedsReconnect = true

        mod.startServer()

        assert.are.equal(0, #ops)
        assert.is_false(_G.LightroomMCP_State.requestNeedsReconnect)
        assert.is_false(_G.LightroomMCP_State.responseNeedsRebind)
        assert.is_false(_G.LightroomMCP_State.responseNeedsReconnect)
    end)
end)


describe("stale-connection follow-up fixes (PR #151 re-review)", function()
    local realOpen
    before_each(function()
        _G.LightroomMCP_State = nil
        realOpen = io.open
        io.open = function(path, mode, ...)
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
    end)

    it("clears a stale lastRequestTime on a fresh REQUEST connect so it doesn't leak into the new idle clock", function()
        local binds = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds })
        local mod = loadInfoProvider()

        mod.startServer()
        -- Simulate a prior session's activity timestamp surviving past a
        -- manual Stop/Start (or any reconnect) that happens long after it
        -- sat idle. Without clearing it here, the monitor loop's very next
        -- tick would see a huge idle value and restart immediately.
        _G.LightroomMCP_State.lastRequestTime = os.time() - 999
        binds[1].onConnected()

        assert.is_nil(_G.LightroomMCP_State.lastRequestTime)
        assert.is_not_nil(_G.LightroomMCP_State.lastConnectedTime)
    end)

    it("keeps a request counted in-flight until sendResponse actually completes, not just until the handler returns", function()
        package.loaded.JSON = nil -- exercise the real encoder/decoder, not the empty stub
        local binds = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds })
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = true
        state.responseSocket = {
            send = function()
                -- If inFlightRequests were decremented right after the
                -- handler returns (the pre-fix behavior), the monitor loop
                -- could see 0 in-flight and restart the server while this
                -- send is still happening — defeating the blast-radius fix.
                assert.are.equal(1, state.inFlightRequests)
            end,
        }

        binds[1].onMessage(nil, '{"id":1,"action":"ping","hello":"' .. state.token .. '"}')

        assert.are.equal(0, state.inFlightRequests)
    end)
end)

describe("heartbeat / stale-connection blast radius (PR #151 review)", function()
    before_each(function()
        _G.LightroomMCP_State = nil
        installStubs()
    end)

    it("ping handler is a pure liveness no-op returning pong=true", function()
        local mod = loadInfoProvider()
        assert.are.same({ pong = true }, mod.handlePing({}))
    end)

    it("derives the soft/hard thresholds from the heartbeat interval", function()
        local mod = loadInfoProvider()
        assert.are.equal(30, mod.HEARTBEAT_INTERVAL_SECONDS)
        assert.are.equal(90, mod.STALE_RECONNECT_SECONDS)
        assert.are.equal(120, mod.STALE_RESTART_HARD_CAP_SECONDS)
    end)

    describe("shouldRestartForStaleConnection", function()
        it("does not restart while idle is within the soft threshold", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                89, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it("restarts once idle passes the soft threshold with nothing in flight", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                91, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_true(restart)
            assert.are.equal("", suffix)
        end)

        it("defers the restart past the soft threshold while a request is genuinely in flight (blast radius fix)", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                91, 1, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it("still restarts past the hard cap even if a request is in flight, to bound the wait", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                121, 1, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_true(restart)
            assert.are.equal(" [hard cap, request still in flight]", suffix)
        end)

        it("treats exactly-at-threshold idle as not yet past it (strict greater-than)", function()
            local mod = loadInfoProvider()
            local restart = mod.shouldRestartForStaleConnection(
                90, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
        end)
    end)
end)

describe("cooperative shutdown at Lightroom quit (issue 195)", function()
    local realOpen
    local logOpens
    before_each(function()
        _G.LightroomMCP_State = nil
        logOpens = 0
        realOpen = io.open
        io.open = function(path, mode, ...)
            if path and path:find("LightroomMCP.log", 1, true) then
                logOpens = logOpens + 1
            end
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
        package.preload.PluginInfoProvider = nil
    end)

    local function requestFor(state, action)
        return '{"id":1,"action":"' .. action .. '","hello":"' .. state.token .. '"}'
    end

    it("clears connection state without blocking on sockets or the log file", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()

        mod.startServer()
        logOpens = 0
        mod.shutdown()

        local state = _G.LightroomMCP_State
        assert.is_true(state.shuttingDown)
        assert.is_false(state.running)
        assert.is_false(state.sendConnected)
        assert.is_false(state.receiveConnected)
        assert.is_nil(state.token)
        assert.are.same({}, ops)
        assert.are.equal(0, logOpens)
    end)

    it("leaves the sockets for the server task to release", function()
        local ops, cleanups = {}, {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups, socketOps = ops })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()

        assert.is_not_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_not_nil(_G.LightroomMCP_State.responseSocket)

        cleanups[1]()

        assert.are.same({ "close", "close" }, ops)
        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_nil(_G.LightroomMCP_State.responseSocket)
    end)

    it("is a cheap no-op when the server never started", function()
        local ops = {}
        installStubs(nil, nil, { socketOps = ops })
        local mod = loadInfoProvider()

        assert.has_no.errors(function() mod.shutdown() end)
        assert.are.same({}, ops)
        assert.is_true(_G.LightroomMCP_State.shuttingDown)
    end)

    it("leaves the monitor loop on the first tick after quit begins", function()
        local ticks = 0
        installStubs(nil, {}, {
            runTask = true,
            cleanups = {},
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.shuttingDown = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()

        assert.are.equal(1, ticks)
    end)

    it("does not bind a new response listener when quit lands inside the rebind yield", function()
        local binds = {}
        local ticks = 0
        installStubs(nil, {}, {
            runTask = true,
            cleanups = {},
            capturedBinds = binds,
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.responseNeedsRebind = true
                elseif ticks == 2 then
                    state.shuttingDown = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()

        assert.is_table(binds[2])
        assert.is_nil(binds[3])
    end)

    it("queues no dispatch task for a message that arrives during quit", function()
        local binds, asyncTasks = {}, {}
        installStubs(nil, asyncTasks, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.shuttingDown = true
        binds[1].onMessage(nil, requestFor(state, "ping"))

        assert.is_nil(asyncTasks[1])
    end)

    it("does not run a handler whose dispatch task was queued before quit", function()
        local binds, asyncTasks = {}, {}
        local handlerCalls = 0
        installStubs(nil, asyncTasks, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        package.loaded.HandlerSearch = {
            searchPhotos = function()
                handlerCalls = handlerCalls + 1
                return { photos = {} }
            end,
        }
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        binds[1].onMessage(nil, requestFor(state, "search_photos"))
        state.shuttingDown = true
        asyncTasks[1]()

        assert.are.equal(0, handlerCalls)
    end)

    it("drops the response of a handler that finished after quit began", function()
        local binds, sent = {}, {}
        installStubs(nil, nil, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        package.loaded.HandlerSearch = {
            searchPhotos = function()
                _G.LightroomMCP_State.shuttingDown = true
                return { photos = {} }
            end,
        }
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = true
        state.responseSocket = { send = function() table.insert(sent, true) end }

        binds[1].onMessage(nil, requestFor(state, "search_photos"))

        assert.are.same({}, sent)
    end)

    it("stops waiting for the send socket as soon as quit begins", function()
        local binds = {}
        local waitSleeps = 0
        local waiting = false
        installStubs(nil, nil, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
            onSleep = function(state)
                if not waiting then return end
                waitSleeps = waitSleeps + 1
                if waitSleeps == 2 then state.shuttingDown = true end
            end,
        })
        package.loaded.JSON = nil
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = false
        waiting = true

        binds[1].onMessage(nil, requestFor(state, "ping"))

        assert.are.equal(2, waitSleeps)
    end)

    it("abandons a pending stale-connection restart", function()
        local asyncTasks = {}
        local ticks = 0
        installStubs(nil, asyncTasks, {
            runTask = true,
            cleanups = {},
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.needsFullRestart = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()
        local instanceBefore = _G.LightroomMCP_State.instanceId
        _G.LightroomMCP_State.shuttingDown = true
        local pendingRestart = asyncTasks[1]
        assert.is_function(pendingRestart)
        pendingRestart()

        assert.are.equal(instanceBefore, _G.LightroomMCP_State.instanceId)
    end)

    it("refuses an auto-start that wakes after quit began", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.shutdown()
        mod.startServer()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.is_nil(_G.LightroomMCP_State.token)
    end)

    it("lets the Plug-in Manager Start button supersede an earlier shutdown", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()
        mod.startServerFromPanel()

        assert.is_false(_G.LightroomMCP_State.shuttingDown)
        assert.is_not_nil(_G.LightroomMCP_State.token)
    end)

    it("clears the shutdown flag on reload so the fresh instance can bind", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()
        mod.resetForReload()
        mod.startServer()

        assert.is_false(_G.LightroomMCP_State.shuttingDown)
        assert.is_not_nil(_G.LightroomMCP_State.token)
    end)

end)
