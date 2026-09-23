local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrSocket = import 'LrSocket'
local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local LrUUID = import 'LrUUID'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local JSON = require 'JSON'
local ServerLease = require 'ServerLease'
local HandlerSearch = require 'HandlerSearch'
local HandlerCollections = require 'HandlerCollections'
local HandlerMetadata = require 'HandlerMetadata'
local HandlerOrganization = require 'HandlerOrganization'
local HandlerImport = require 'HandlerImport'
local HandlerExport = require 'HandlerExport'
local HandlerSelection = require 'HandlerSelection'
local HandlerDevelop = require 'HandlerDevelop'
local HandlerAI = require 'HandlerAI'
local HandlerSpots = require 'HandlerSpots'
local HandlerLocalAdjustments = require 'HandlerLocalAdjustments'
local HandlerWatermark = require 'HandlerWatermark'
local HandlerAIMasks = require 'HandlerAIMasks'
local HandlerCatalog = require 'HandlerCatalog'
local HandlerPreview = require 'HandlerPreview'
local Log = require 'Log'

local DEFAULT_REQUEST_PORT = 58763
local DEFAULT_RESPONSE_PORT = 58764

-- LrSocket fires these on its accept-loop when no client is attached yet.
-- Both are benign listen-side states, not real failures.
local function isNoClientError(errStr)
    if errStr == "timeout" then return true end
    if errStr:find("failed to open", 1, true) then return true end
    return false
end

local function validPort(n)
    return type(n) == "number" and n == math.floor(n) and n >= 1 and n <= 65535
end

local function readPortPrefs()
    local prefs = LrPrefs.prefsForPlugin()
    local req = tonumber(prefs.requestPort)
    local res = tonumber(prefs.responsePort)
    if not validPort(req) then req = DEFAULT_REQUEST_PORT end
    if not validPort(res) then res = DEFAULT_RESPONSE_PORT end
    return req, res
end

-- State on _G so it survives across re-execution of this module body
-- within the same Lua state. This body runs BOTH when PluginInit requires
-- it AND every time Lightroom loads it as the InfoProvider to render the
-- Plug-in Manager panel. A render must NOT disturb a running server, so we
-- only ever CREATE state here (when absent) — never tear it down. Teardown
-- of a stale prior instance on Reload Plug-in is handled by resetForReload,
-- which PluginInit calls (PluginInit's LrInitPlugin runs on load/reload but
-- NOT on a plain panel render). Tearing down from this body — as earlier
-- versions did when running == true — killed the live server every time the
-- Plug-in Manager was opened (issues #121, #137).
if not _G.LightroomMCP_State then
    _G.LightroomMCP_State = {
        running = false,
        shuttingDown = false,
        requestSocket = nil,
        responseSocket = nil,
        sendConnected = false,
        receiveConnected = false,
        requestsProcessed = 0,
        lastEvent = nil,
        log = {},
        token = nil,
        lastRequestTime = nil,
        lastConnectedTime = nil,
        needsFullRestart = false,
        freshRestart = false,
        inFlightRequests = 0,
    }
end

local pluginState = _G.LightroomMCP_State

-- Nothing in the plugin raises this any more: the LrShutdownApp and
-- LrShutdownPlugin hooks were removed because they cost a second or more on
-- every quit and bought no teardown that Lightroom's own context cancellation
-- did not already do. The guards stay because shutdown() below is still the
-- programmatic stop, and re-registering a hook is a one-line change.
local function shutdownRequested()
    return pluginState.shuttingDown == true
end

local function tokenDir()
    return LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), ".config")
end

local function tokenFilePath()
    return LrPathUtils.child(LrPathUtils.child(tokenDir(), "lightroom-mcp"), "token")
end

local function addLog(msg)
    table.insert(pluginState.log, os.date("%H:%M:%S") .. " - " .. msg)
    if #pluginState.log > 100 then
        table.remove(pluginState.log, 1)
    end
    Log.info(msg)
end

local function generateToken()
    -- Two UUIDs (32 hex chars each after stripping dashes) → 256 bits of entropy.
    local u1 = LrUUID.generateUUID():gsub("-", "")
    local u2 = LrUUID.generateUUID():gsub("-", "")
    return (u1 .. u2):lower()
end

local function writeTokenFile(token)
    local dir = LrPathUtils.child(tokenDir(), "lightroom-mcp")
    LrFileUtils.createAllDirectories(dir)
    local path = tokenFilePath()
    local fh, openErr = io.open(path, "w")
    if not fh then
        addLog("Token write failed: " .. tostring(openErr))
        return false
    end
    fh:write(token)
    fh:close()
    -- Lightroom's Lua sandbox has no os.execute, so chmod is impossible here.
    -- On macOS single-user installs ~/.config/ inherits home-dir privacy (700).
    -- On Linux/multi-user systems run: chmod 700 ~/.config/lightroom-mcp
    -- See README "Security" section. Token gates localhost only; threat is
    -- local-user access on the same machine.
    return true
end

-- The token currently PUBLISHED on disk — which is the one the bridge sends,
-- because the bridge re-reads this file on every request.
local function readTokenFile()
    local fh = io.open(tokenFilePath(), "r")
    if not fh then return nil end
    local contents = fh:read("*a")
    fh:close()
    if type(contents) ~= "string" then return nil end
    contents = contents:gsub("%s+$", "")
    if contents == "" then return nil end
    return contents
end

-- Accept either our own in-memory token or the one published on disk.
--
-- `pluginState` lives in the module, and "Reload Plug-in" gives Lightroom a
-- FRESH module instance while the previous instance's LrSocket callbacks keep
-- serving. The old instance then authenticates against its own token while the
-- new one has already published a different token to the file, so every
-- request fails with a mismatch until Lightroom is restarted — measured on a
-- single reload: two contexts, two tokens, file written by the one that does
-- NOT own the socket. Trusting the published file makes the two sides agree by
-- construction, whichever instance happens to answer.
--
-- No security change: the file is already the shared secret, and anyone able
-- to write it can already read it.
local function isValidToken(candidate)
    if type(candidate) ~= "string" or candidate == "" then return false end
    if pluginState.token and candidate == pluginState.token then return true end
    local published = readTokenFile()
    return published ~= nil and candidate == published
end

local DISPATCH = {
    -- Heartbeat no-op. The MCP server pings on this action every
    -- HEARTBEAT_INTERVAL_SECONDS (server/src/index.ts) so the plugin can
    -- tell a healthy-but-idle session apart from a genuinely dead one
    -- without waiting out a long fixed timer. It travels through the same
    -- auth + dispatch path as any other action, so consumeMessage's
    -- lastRequestTime update (below) already treats it as liveness — no
    -- separate heartbeat bookkeeping needed. See STALE_RECONNECT_SECONDS.
    ping = function(_params) return { pong = true } end,
    search_photos = HandlerSearch.searchPhotos,
    list_collections = HandlerCollections.listCollections,
    create_collection = HandlerCollections.createCollection,
    add_to_collection = HandlerCollections.addToCollection,
    get_photo_metadata = HandlerMetadata.getPhotoMetadata,
    set_keywords = HandlerOrganization.setKeywords,
    set_rating = HandlerOrganization.setRating,
    import_photos = HandlerImport.importPhotos,
    export_photos = HandlerExport.exportPhotos,
    get_selected_photos = HandlerSelection.getSelectedPhotos,
    -- Test-only, no matching MCP tool contract: only the raw TCP probe
    -- (manual-test.mjs / the e2e playbook) can reach it. See HandlerSelection.
    set_selection = HandlerSelection.setSelection,
    list_develop_presets = HandlerDevelop.listDevelopPresets,
    get_develop_preset = HandlerDevelop.getDevelopPreset,
    compare_develop_presets = HandlerDevelop.compareDevelopPresets,
    create_develop_preset = HandlerDevelop.createDevelopPreset,
    export_develop_preset = HandlerDevelop.exportDevelopPreset,
    apply_develop_preset = HandlerDevelop.applyDevelopPreset,
    copy_develop_settings = HandlerDevelop.copyDevelopSettings,
    set_develop_settings = HandlerDevelop.setDevelopSettings,
    -- AI / smart adjustments (@pired/lightroom-mcp additions).
    -- NOTE: 'ai_denoise' is the only long-running action of this group and is
    -- covered by the server's LONG_RUNNING_TIMEOUT_MS (see index.ts).
    ai_denoise = HandlerAI.aiDenoise,
    set_noise_reduction = HandlerAI.setNoiseReduction,
    set_white_balance = HandlerDevelop.setWhiteBalance,
    set_flags = HandlerOrganization.setFlags,
    get_spots = HandlerSpots.getSpots,
    add_spots = HandlerSpots.addSpots,
    clear_spots = HandlerSpots.clearSpots,
    add_local_adjustment = HandlerLocalAdjustments.addLocalAdjustment,
    read_local_adjustments = HandlerLocalAdjustments.readLocalAdjustments,
    set_mask_adjustments = HandlerLocalAdjustments.setMaskAdjustments,
    list_watermarks = HandlerWatermark.listWatermarks,
    -- v2.0 — AI masking, tone curves, Auto commands, catalog extras
    -- (inspired by znznzna/lightroom-cli, MIT; adapted to this plugin's
    -- gate/verification conventions).
    -- NOTE: 'add_ai_mask' and 'apply_auto' drive the Develop module UI and
    -- can run long on batches; both are covered by ACTION_TIMEOUTS_MS.
    add_ai_mask = HandlerAIMasks.addAIMask,
    list_masks = HandlerAIMasks.listMasks,
    remove_mask = HandlerAIMasks.removeMask,
    set_tone_curve = HandlerDevelop.setToneCurve,
    get_tone_curve = HandlerDevelop.getToneCurve,
    apply_auto = HandlerDevelop.applyAuto,
    set_color_label = HandlerOrganization.setColorLabel,
    create_virtual_copies = HandlerOrganization.createVirtualCopies,
    create_smart_collection = HandlerOrganization.createSmartCollection,
    -- v3.0 — 100% functionality: preview gate, selection/navigation,
    -- catalog inventory, batch metadata, resets, process version,
    -- snapshots, range masks (lightroom-cli port, MIT).
    -- NOTE: 'get_photo_preview' renders asynchronously (up to 60s inside the
    -- handler); 'reset_develop'/'set_process_version'/'add_range_mask' drive
    -- the Develop module — all covered by ACTION_TIMEOUTS_MS.
    get_photo_preview = HandlerPreview.getPhotoPreview,
    get_develop_settings = HandlerDevelop.getDevelopSettings,
    reset_develop = HandlerDevelop.resetDevelop,
    set_process_version = HandlerDevelop.setProcessVersion,
    create_snapshot = HandlerDevelop.createSnapshot,
    select_photos = HandlerSelection.selectPhotos,
    navigate_photo = HandlerSelection.navigatePhoto,
    get_photo_status = HandlerOrganization.getPhotoStatus,
    batch_metadata = HandlerOrganization.batchMetadata,
    rotate_photo = HandlerOrganization.rotatePhoto,
    remove_from_catalog = HandlerOrganization.removeFromCatalog,
    list_folders = HandlerCatalog.listFolders,
    list_keywords = HandlerCatalog.listKeywords,
    manage_view_filter = HandlerCatalog.manageViewFilter,
    get_collection_photos = HandlerCollections.getCollectionPhotos,
    create_collection_set = HandlerCollections.createCollectionSet,
    add_range_mask = HandlerAIMasks.addRangeMask,
    toggle_mask_overlay = HandlerAIMasks.toggleMaskOverlay,
}

-- Generous wait so the very first response after handshake doesn't get
-- dropped while LrSocket is still settling sendConnected on the response
-- side. Must stay below the server's dispatcher timeout (30s) so a real
-- send-side outage still surfaces as a server-side timeout, not silent
-- success.
local SEND_WAIT_SECONDS = 25
-- After this many seconds of waiting for sendConnected, request a fresh
-- response-side rebind. Recovers from states where the response listener
-- ended up bound-but-clientless without responseNeedsRebind being set —
-- observed on Windows in issue #110, where the post-rebind onConnected
-- fires but sendConnected is later false by the time sendResponse runs
-- and no event sets the rebind flag again.
local SEND_REBIND_TRIGGER_SECONDS = 5
-- The MCP server pings every HEARTBEAT_INTERVAL_SECONDS (server/src/index.ts).
-- Treat the connection as stale only after missing roughly three pings in a
-- row, rather than the old fixed 300s idle window. This is what lets a
-- healthy-but-quiet interactive session run indefinitely without tripping a
-- full restart (Automaat review, PR #151: "idle and stale connections are
-- indistinguishable") while still detecting a genuinely dead peer (Windows
-- onClosed unreliability, issue #134) in under two minutes.
local HEARTBEAT_INTERVAL_SECONDS = 30
local STALE_RECONNECT_SECONDS = HEARTBEAT_INTERVAL_SECONDS * 3
-- If a request is in flight when the soft threshold above is hit, give it a
-- chance to finish rather than yanking the socket out from under it — but
-- only up to this hard cap past the soft threshold. If the peer is truly
-- dead the in-flight request was already unrecoverable, so the hard cap
-- guarantees we still restart instead of waiting forever on a hung handler.
-- Bounds the blast radius of a stale-triggered restart (Automaat review,
-- PR #151: "a tool call landing in the restart window loses its response").
local STALE_RESTART_HARD_CAP_SECONDS = STALE_RECONNECT_SECONDS + 30

-- Pure decision extracted from the monitor loop so it can be unit tested
-- without driving the full async LrTasks loop (see PluginInfoProvider_spec.lua).
-- Returns whether to restart and, if so, a log-suffix noting whether the
-- hard cap (not just the soft threshold) is what triggered it.
local function shouldRestartForStaleConnection(idle, inFlightRequests, softSeconds, hardCapSeconds)
    local inFlight = (inFlightRequests or 0) > 0
    local pastSoft = idle > softSeconds
    local pastHard = idle > hardCapSeconds
    local restart = pastSoft and (not inFlight or pastHard)
    local suffix = (inFlight and pastHard) and " [hard cap, request still in flight]" or ""
    return restart, suffix
end

local function sendResponse(response)
    if shutdownRequested() then
        addLog("Drop response (shutting down) id=" .. tostring(response.id))
        return
    end
    local waited = 0
    local selfHealRequested = false
    while not pluginState.sendConnected and waited < SEND_WAIT_SECONDS do
        if shutdownRequested() then
            addLog("Drop response (shutting down) id=" .. tostring(response.id))
            return
        end
        if not selfHealRequested and waited >= SEND_REBIND_TRIGGER_SECONDS then
            addLog("sendResponse stalled " .. SEND_REBIND_TRIGGER_SECONDS .. "s, requesting rebind id=" .. tostring(response.id))
            pluginState.responseNeedsRebind = true
            selfHealRequested = true
        end
        LrTasks.sleep(0.1)
        waited = waited + 0.1
    end
    if not pluginState.responseSocket or not pluginState.sendConnected then
        addLog("Drop response (send socket disconnected after " .. SEND_WAIT_SECONDS .. "s) id=" .. tostring(response.id))
        return
    end
    local ok, payload = pcall(function() return JSON:encode(response) end)
    if not ok then
        addLog("JSON encode failed: " .. tostring(payload))
        return
    end
    pluginState.responseSocket:send(payload .. "\n")
    pluginState.requestsProcessed = pluginState.requestsProcessed + 1
end

local function dispatchAction(request)
    if shutdownRequested() then return end
    local id = request.id
    local action = request.action
    local params = request.params or {}

    if request.undecodable then
        addLog("Rejecting undecodable request id=" .. tostring(id))
        sendResponse({ id = id, error = "Malformed request: " .. request.undecodable })
        return
    end

    -- Heartbeat pings arrive every 30s and are pure liveness noise once the
    -- connection is healthy; skip them here so they don't dominate the
    -- 100-line ring buffer used by the status panel and drown out real
    -- request activity.
    local isHeartbeat = (action == "ping")
    if not isHeartbeat then
        addLog("Request id=" .. tostring(id) .. " action=" .. tostring(action))
    end

    -- Tracked so the stale-connection monitor can defer a restart while a
    -- real request is in flight. Held through sendResponse (not just the
    -- handler call) so the monitor can't yank the socket while a response
    -- is still queued waiting on sendConnected (see STALE_RESTART_HARD_CAP_SECONDS).
    pluginState.inFlightRequests = (pluginState.inFlightRequests or 0) + 1

    local handler = DISPATCH[action]
    if not handler then
        sendResponse({ id = id, error = "Unknown action: " .. tostring(action) })
        pluginState.inFlightRequests = math.max(0, pluginState.inFlightRequests - 1)
        return
    end

    -- xpcall, debug.traceback, and os.getenv aren't reliably exposed by
    -- Lightroom's Lua sandbox: using them in the dispatcher's error path
    -- turns a handler error into a silent nil-call that never reaches the
    -- client. Stick to LrTasks.pcall.
    local execOk, resultOrErr = LrTasks.pcall(function()
        return handler(params)
    end)
    if execOk then
        sendResponse({ id = id, result = resultOrErr })
    else
        addLog("Handler " .. action .. " error: " .. tostring(resultOrErr))
        sendResponse({ id = id, error = tostring(resultOrErr) })
    end
    pluginState.inFlightRequests = math.max(0, pluginState.inFlightRequests - 1)
end

-- Runs SYNCHRONOUSLY in onMessage. Every request must carry the current
-- token in `hello`; we authenticate per-message so connection-state
-- races (reload, dual-instance, reconnect) can't desync auth from the
-- live token.
local function consumeMessage(message)
    pluginState.lastEvent = os.date("%H:%M:%S")
    pluginState.lastRequestTime = os.time()  -- track for stale connection detection; a
                                              -- heartbeat ping counts as activity same as
                                              -- any other message.

    local parsedOk, request = pcall(function() return JSON:decode(message) end)
    if not parsedOk or type(request) ~= "table" then
        addLog("JSON decode failed: " .. tostring(message))
        -- A client that cannot be decoded still deserves an answer, or it sits
        -- there until its own 30s timeout with no clue why. Salvage id+token by
        -- pattern: only an authenticated caller gets the error back, so
        -- unauthenticated garbage stays silent as before.
        local salvagedToken = message:match('"hello"%s*:%s*"([^"]*)"')
        local salvagedId = message:match('"id"%s*:%s*"([^"]*)"')
        if salvagedId and isValidToken(salvagedToken) then
            return { id = salvagedId, undecodable = tostring(request) }
        end
        return nil
    end

    if not isValidToken(request.hello) then
        -- Drop silently. We CANNOT call sendResponse here: onMessage runs
        -- in a non-yielding context and sendResponse uses LrTasks.sleep.
        -- Server will time out, which is correct behaviour for auth fail.
        --
        -- That timeout is a known rough edge: the caller cannot tell an auth
        -- failure from a hung plugin, and the bridge eventually reports it as
        -- a different problem entirely. The log line below is the only place
        -- the truth is visible, so keep it.
        addLog("Auth failed (token mismatch) id=" .. tostring(request.id)
            .. " (in-memory=" .. tostring(pluginState.token)
            .. ", published=" .. tostring(readTokenFile())
            .. ", got=" .. tostring(request.hello) .. ")")
        return nil
    end

    return request
end

-- How long a stood-down instance keeps an eye on the incumbent. Without this,
-- the first instance to bind would be the only one that ever could, and if it
-- died Lightroom would sit there with no server until the user restarted it.
-- Bounded rather than forever: a superseded Lua state should not poll for the
-- rest of the session.
local LEASE_WATCH_POLL_S = 5
local LEASE_WATCH_TIMEOUT_S = 300

-- Forward declaration: the watcher restarts the server, and startServer starts
-- the watcher.
local startServer

local function watchForStaleLease()
    LrFunctionContext.postAsyncTaskWithContext("LightroomMCPLeaseWatch", function()
        local waited = 0
        while waited < LEASE_WATCH_TIMEOUT_S do
            LrTasks.sleep(LEASE_WATCH_POLL_S)
            waited = waited + LEASE_WATCH_POLL_S
            if shutdownRequested() then return end
            -- Something in THIS Lua state started serving; nothing to cover.
            if pluginState.running then return end
            if not ServerLease.heldBy() then
                addLog("Incumbent server lease went stale - taking over")
                -- noWatch: if this attempt is itself refused (another instance
                -- got there first), keep looping here instead of spawning a
                -- second watcher. Chaining watcher -> startServer -> watcher
                -- is unbounded, and a lost race would grow it without limit.
                startServer({ noWatch = true })
                if pluginState.running then return end
            end
        end
        addLog("Stopped watching for a stale server lease after "
            .. LEASE_WATCH_TIMEOUT_S .. "s")
    end)
end

startServer = function(opts)
    opts = opts or {}
    if shutdownRequested() then
        addLog("Start ignored (shutting down)")
        return
    end
    if pluginState.running then
        addLog("Already running")
        return
    end
    -- Set running immediately after the guard so check-and-set is atomic.
    -- generateToken/writeTokenFile/readPortPrefs below can yield the
    -- cooperative LrTasks scheduler (token file I/O), and a second caller
    -- waking in that window would otherwise pass the guard too and bind a
    -- second pair of LrSocket listeners on the same ports.
    pluginState.running = true
    -- Tag this invocation immediately in the synchronous prologue.
    -- generateToken/writeTokenFile/readPortPrefs below can yield the cooperative
    -- LrTasks scheduler (token file I/O). Bumping instanceId here ensures any
    -- prior instance's async context-cleanup handler (which may run during that
    -- yield) recognizes it has been superseded and skips wiping the new token
    -- or sockets (issues #121, #137).
    pluginState.instanceId = (pluginState.instanceId or 0) + 1
    local instanceId = pluginState.instanceId

    local requestPort, responsePort = readPortPrefs()

    -- The only guard that works across Lua states. instanceId above is still
    -- worth keeping -- it settles races WITHIN this state, where it is cheaper
    -- and exact -- but it cannot see an instance Lightroom is running in a
    -- different state, and that is the case that produced two servers fighting
    -- over one port. Claim BEFORE writing the token: standing down must not
    -- publish a token the incumbent does not know, which is what turned this
    -- into silent auth failures.
    local leaseOwner = LrUUID.generateUUID()
    local claimed, holder = ServerLease.claim(leaseOwner, requestPort, responsePort)
    if not claimed and holder then
        pluginState.running = false
        addLog(string.format(
            "Another plugin instance already holds the server lease (ports %s/%s) - standing down",
            tostring(holder.request_port), tostring(holder.response_port)))
        if not opts.noWatch then watchForStaleLease() end
        return
    end
    if not claimed then
        -- The lease file could not be written (permissions, full disk). Serving
        -- unguarded beats refusing to serve: the failure this protects against
        -- is rare, and a plugin that will not start is worse.
        addLog("Could not write the server lease - starting unguarded")
    end
    pluginState.leaseOwner = leaseOwner
    pluginState.leaseTouched = ServerLease.now()

    pluginState.token = generateToken()
    if writeTokenFile(pluginState.token) then
        addLog("Token written to " .. tokenFilePath())
    end

    pluginState.requestPort = requestPort
    pluginState.responsePort = responsePort

    addLog("Starting LrSocket servers")

    LrFunctionContext.postAsyncTaskWithContext("LightroomMCPServer", function(context)
        context:addCleanupHandler(function()
            if pluginState.instanceId ~= instanceId then
                -- A newer startServer superseded this instance; its sockets
                -- and token now own the shared state table. Tearing them down
                -- here would kill the live server, so leave them be.
                addLog("Stale cleanup skipped (instance " .. instanceId .. " superseded)")
                return
            end
            addLog("Server task context cleanup")
            if pluginState.requestSocket then
                pcall(function() pluginState.requestSocket:close() end)
            end
            if pluginState.responseSocket then
                pcall(function() pluginState.responseSocket:close() end)
            end
            pluginState.requestSocket = nil
            pluginState.responseSocket = nil
            pluginState.sendConnected = false
            pluginState.receiveConnected = false
            pluginState.token = nil
            pluginState.running = false
            -- Deliberately NOT releasing the lease here. Handing the port back
            -- the instant a task is torn down looks tidy and measured terribly:
            -- Lightroom spins up short-lived Lua states (15 module loads on one
            -- launch), and when one of them wins the lease and is then
            -- discarded, an immediate release let a watcher take over within
            -- five seconds -- onto another state that also died. Six servers
            -- started in ninety seconds.
            --
            -- Letting the lease go STALE instead costs one quiet staleness
            -- window and turns the cascade into a single calm takeover. That is
            -- what the freshness design is for. An explicit shutdown() still
            -- releases, because that is a real stop rather than a teardown.
        end)

        local function bindRequest()
            return LrSocket.bind {
                functionContext = context,
                plugin = _PLUGIN,
                port = requestPort,
                mode = "receive",
                onConnected = function()
                    pluginState.receiveConnected = true
                    pluginState.lastConnectedTime = os.time()
                    -- A stale lastRequestTime from a prior session (e.g. user
                    -- Stop/Start after the connection sat idle >90s) must not
                    -- leak into this connection's idle clock, or the monitor
                    -- loop sees a huge idle value on the very first tick and
                    -- restarts immediately. Idle now starts from
                    -- lastConnectedTime until the first real message arrives.
                    pluginState.lastRequestTime = nil
                    if pluginState.freshRestart then
                        -- Sockets were fully closed and rebound by the stale-detection
                        -- restart (issue #134 Windows workaround). The response listener
                        -- already accepted a fresh MCP client; no stale send-side
                        -- connection to flush. Skipping the rebind prevents the
                        -- request->response->request cycling that delays the first
                        -- post-restart response past the 30 s MCP timeout.
                        pluginState.freshRestart = false
                        addLog("REQUEST socket connected (post-restart)")
                    else
                        -- New request client on a live server = new MCP session. Force
                        -- a response-side rebind: LrSocket send-mode does not reliably
                        -- notice client disconnect on Windows, so sendConnected can stay
                        -- true pointing at a dead socket and :send() writes to the void.
                        pluginState.sendConnected = false
                        pluginState.responseNeedsRebind = true
                        addLog("REQUEST socket connected")
                    end
                end,
                onMessage = function(_, message)
                    if shutdownRequested() then return end
                    local request = consumeMessage(message)
                    if request then
                        LrTasks.startAsyncTask(function()
                            dispatchAction(request)
                        end)
                    end
                end,
                onClosed = function()
                    pluginState.receiveConnected = false
                    pluginState.requestNeedsReconnect = true
                    addLog("REQUEST socket closed (client disconnected)")
                end,
                onError = function(_, err)
                    local errStr = tostring(err)
                    if isNoClientError(errStr) then
                        if not pluginState.receiveConnected then
                            pluginState.requestNeedsReconnect = true
                        end
                    else
                        pluginState.receiveConnected = false
                        pluginState.requestNeedsReconnect = true
                        addLog("REQUEST socket error: " .. errStr)
                    end
                end,
            }
        end

        -- Each rebind bumps a generation. Old-listener callbacks compare
        -- their captured gen to the live one and ignore themselves if
        -- stale. Without this, an onError/onClosed from the just-closed
        -- listener can flag rebind AGAIN immediately after we just
        -- finished rebinding, looping us out of the new client.
        pluginState.responseGen = 0
        -- Clear loop-control flags so a reused state table (in-place
        -- resetForReload, or a panel Stop->Start) doesn't enter the monitor
        -- loop with a stale reconnect/rebind pending and churn the sockets we
        -- just bound on the first tick.
        pluginState.requestNeedsReconnect = false
        pluginState.responseNeedsRebind = false
        pluginState.responseNeedsReconnect = false

        -- bindResponse takes myGen explicitly so callers can pre-bump the
        -- generation BEFORE calling :close() on the prior listener. On
        -- platforms where LrSocket invokes onClosed synchronously during
        -- close (suspected on Windows, per issue #110), a stale callback
        -- would otherwise see isLive()==true and re-set responseNeedsRebind
        -- after we just cleared it.
        local function bindResponse(myGen)
            local function isLive() return pluginState.responseGen == myGen end
            return LrSocket.bind {
                functionContext = context,
                plugin = _PLUGIN,
                port = responsePort,
                mode = "send",
                onConnected = function()
                    if not isLive() then return end
                    pluginState.sendConnected = true
                    addLog("RESPONSE socket connected")
                end,
                onClosed = function()
                    if not isLive() then return end
                    pluginState.sendConnected = false
                    pluginState.responseNeedsRebind = true
                    addLog("RESPONSE socket closed (gen=" .. myGen .. ")")
                end,
                onError = function(_, err)
                    if not isLive() then return end
                    local errStr = tostring(err)
                    if isNoClientError(errStr) then
                        if not pluginState.sendConnected then
                            pluginState.responseNeedsReconnect = true
                        end
                    else
                        pluginState.sendConnected = false
                        pluginState.responseNeedsRebind = true
                        addLog("RESPONSE socket error: " .. errStr)
                    end
                end,
            }
        end

        -- Is this task still the server, or has a newer startServer taken over?
        --
        -- `running` alone cannot answer that. It is the only stop signal
        -- resetForReload has, but startServer sets it back to true immediately
        -- afterwards — and a surviving loop sleeps up to half a second per
        -- tick, so it wakes to find running == true again and keeps going.
        -- Two monitor loops then share one responseGen and one socket pair,
        -- each invalidating the other's listener on every rebind. Observed in
        -- the log as two generations rebinding the same port in the same
        -- second (gen=10 and gen=2), with every sendResponse stalling because
        -- no listener survives long enough to deliver: the plugin answers and
        -- the bridge never hears it.
        --
        -- instanceId is monotonic and deliberately never reset, so a restart
        -- cannot accidentally restore it. Comparing against it is the one
        -- check a superseded loop cannot miss.
        local function isCurrentInstance()
            return pluginState.instanceId == instanceId
        end

        -- The prologue yields (token I/O, prefs), so a newer startServer may
        -- already have taken over before this task ever binds.
        if not isCurrentInstance() then
            addLog("Server task superseded before binding (instance " .. instanceId .. ")")
            return
        end

        -- Bump first, then bind, so the initial listener owns gen=1 (any
        -- pre-existing stale callbacks from a Reload Plug-in cycle were
        -- bound against gen=0 and stay ignored).
        pluginState.responseGen = pluginState.responseGen + 1
        pluginState.requestSocket = bindRequest()
        addLog("REQUEST bound on " .. requestPort)
        pluginState.responseSocket = bindResponse(pluginState.responseGen)
        addLog("RESPONSE bound on " .. responsePort .. " gen=" .. pluginState.responseGen)

        while pluginState.running and isCurrentInstance() and not shutdownRequested() do
            -- Prove we are still alive, and find out whether we still own the
            -- port. A lease that another instance has taken is the one signal
            -- that crosses Lua states, so it is also the only one that can stop
            -- a loop this state cannot otherwise see is redundant.
            -- ServerLease.now, not os.time, so the clock is the one the lease
            -- itself uses and a test can move it.
            local tickNow = ServerLease.now()
            if tickNow - (pluginState.leaseTouched or 0) >= ServerLease.REFRESH_S then
                pluginState.leaseTouched = tickNow
                local stillOurs, taker = ServerLease.refresh(
                    leaseOwner, requestPort, responsePort)
                if not stillOurs and taker then
                    addLog("Server lease taken by another instance - stopping this loop")
                    -- Losing the lease must not be a death sentence. If the
                    -- instance that took it then dies, someone has to come
                    -- back; without a watcher an evicted server stays gone
                    -- until Lightroom is restarted, which is the exact failure
                    -- the lease exists to remove. Clear `running` first: the
                    -- watcher treats a running server as "nothing to cover".
                    pluginState.running = false
                    watchForStaleLease()
                    break
                end
            end

            if pluginState.requestNeedsReconnect and pluginState.requestSocket then
                pluginState.requestNeedsReconnect = false
                pluginState.requestSocket:reconnect()
            end
            -- Response socket has two recovery paths:
            -- - rebind: full close+rebind for true client disconnect
            -- - reconnect: cheap reconnect for listen-side timeouts
            if pluginState.responseNeedsRebind then
                -- Pre-bump gen BEFORE close so any synchronous onClosed
                -- callback fired during close() sees isLive()==false and
                -- ignores itself. Without this, the OLD listener's close
                -- callback re-sets responseNeedsRebind after we clear it
                -- below, looping the rebind on the next tick. Issue #110
                -- suspected Windows trigger.
                pluginState.responseGen = pluginState.responseGen + 1
                local newGen = pluginState.responseGen
                if pluginState.responseSocket then
                    pcall(function() pluginState.responseSocket:close() end)
                end
                pluginState.sendConnected = false
                -- Brief yield so any kernel cleanup of the just-closed
                -- listener completes before we try to bind the same port
                -- again. The actual server-side reconnect takes ~1s, so
                -- 100ms here doesn't meaningfully delay recovery.
                LrTasks.sleep(0.1)
                if shutdownRequested() then break end
                -- That sleep is long enough for a newer startServer to take
                -- over; rebinding here would steal the port back from it.
                if not isCurrentInstance() then break end
                pluginState.responseSocket = bindResponse(newGen)
                pluginState.responseNeedsRebind = false
                pluginState.responseNeedsReconnect = false
                addLog("RESPONSE rebound on " .. responsePort .. " gen=" .. newGen)
            elseif pluginState.responseNeedsReconnect and pluginState.responseSocket then
                pluginState.responseNeedsReconnect = false
                pluginState.responseSocket:reconnect()
            end
            -- Full restart requested by stale detection
            if pluginState.needsFullRestart then
                pluginState.needsFullRestart = false
                LrTasks.startAsyncTask(function()
                    addLog("Restarting server (stale connection recovery)")
                    -- stopServer() is declared after startServer() in this file
                    -- and is not an upvalue here; inline its effect directly.
                    pluginState.running = false
                    LrTasks.sleep(0.5)
                    startServer()
                end)
            end
            -- Stale connection detection: Windows LrSocket does not reliably
            -- fire onClosed when the remote MCP server process exits (issue #134).
            -- The MCP server pings every HEARTBEAT_INTERVAL_SECONDS, so as long as
            -- the connection is genuinely alive, lastRequestTime keeps advancing
            -- even with no real tool calls in flight. If receiveConnected is true
            -- but nothing (including a heartbeat) has arrived for
            -- STALE_RECONNECT_SECONDS, the peer is actually gone, not just idle.
            -- Defer past that soft threshold while a real request is in flight,
            -- up to STALE_RESTART_HARD_CAP_SECONDS, so we don't yank the socket
            -- out from under a response that's about to be sent.
            if pluginState.receiveConnected then
                local ref = pluginState.lastRequestTime or pluginState.lastConnectedTime
                if ref then
                    local idle = os.time() - ref
                    local restart, suffix = shouldRestartForStaleConnection(
                        idle, pluginState.inFlightRequests, STALE_RECONNECT_SECONDS, STALE_RESTART_HARD_CAP_SECONDS)
                    if restart then
                        addLog("Stale connection: " .. idle .. "s since last heartbeat, scheduling restart" .. suffix)
                        pluginState.lastRequestTime = nil
                        pluginState.lastConnectedTime = nil
                        pluginState.needsFullRestart = true
                        pluginState.freshRestart = true
                    end
                end
            end
            LrTasks.sleep(0.2)
        end

        addLog("Server loop exiting")
        -- Socket cleanup runs in context:addCleanupHandler above.
    end)
end

local function startServerFromPanel()
    pluginState.shuttingDown = false
    startServer()
end

local function stopServer()
    if not pluginState.running then
        addLog("Not running")
        return
    end
    addLog("Stopping LrSocket servers")
    pluginState.running = false
end

-- Called by PluginInit on plugin load/reload (never on a Plug-in Manager
-- render). Reload re-runs PluginInit while a prior instance's state may
-- still live on _G in the same Lua state, with `running` stale-true and
-- its task context already cancelled by Lightroom. Clear the flag so the
-- subsequent startServer() isn't blocked by its "Already running" guard,
-- and signal any surviving monitor loop to exit. Reset IN PLACE (not a new
-- table) so this module's pluginState and the old loop's closure keep
-- pointing at the same table — flipping running here is what stops it.
local function resetForReload()
    pluginState.shuttingDown = false
    if not pluginState.running then return end
    addLog("Reload detected - resetting previous server instance")
    pluginState.running = false
    if pluginState.requestSocket then
        pcall(function() pluginState.requestSocket:close() end)
    end
    if pluginState.responseSocket then
        pcall(function() pluginState.responseSocket:close() end)
    end
    pluginState.requestSocket = nil
    pluginState.responseSocket = nil
    pluginState.sendConnected = false
    pluginState.receiveConnected = false
    pluginState.token = nil
    -- Return the rest of the transient runtime state to fresh-state defaults
    -- so the Plug-in Manager reports honest status after a reload (no
    -- carried-over lastEvent / counters / ports) and the next startServer
    -- can't inherit a stale reconnect/rebind request. instanceId is
    -- deliberately NOT reset -- it must keep advancing so a superseded
    -- instance's cleanup handler stays a no-op (see startServer).
    pluginState.requestNeedsReconnect = false
    pluginState.responseNeedsRebind = false
    pluginState.responseNeedsReconnect = false
    pluginState.lastEvent = nil
    pluginState.requestsProcessed = 0
    pluginState.requestPort = nil
    pluginState.responsePort = nil
    pluginState.lastRequestTime = nil
    pluginState.lastConnectedTime = nil
    pluginState.needsFullRestart = false
    pluginState.freshRestart = false
    pluginState.inFlightRequests = 0
end

local function shutdown()
    pluginState.shuttingDown = true
    pluginState.running = false
    if pluginState.leaseOwner then
        ServerLease.release(pluginState.leaseOwner)
        pluginState.leaseOwner = nil
    end
    pluginState.requestNeedsReconnect = false
    pluginState.responseNeedsRebind = false
    pluginState.responseNeedsReconnect = false
    pluginState.needsFullRestart = false
    pluginState.freshRestart = false
    pluginState.sendConnected = false
    pluginState.receiveConnected = false
    pluginState.token = nil
end

addLog("PluginInfoProvider loaded")

local PluginInfoProvider = {
    startServer = startServer,
    startServerFromPanel = startServerFromPanel,
    stopServer = stopServer,
    shutdown = shutdown,
    resetForReload = resetForReload,
    -- Exposed for PluginInfoProvider_spec.lua only; not used elsewhere in the plugin.
    shouldRestartForStaleConnection = shouldRestartForStaleConnection,
    handlePing = DISPATCH.ping,
    HEARTBEAT_INTERVAL_SECONDS = HEARTBEAT_INTERVAL_SECONDS,
    STALE_RECONNECT_SECONDS = STALE_RECONNECT_SECONDS,
    STALE_RESTART_HARD_CAP_SECONDS = STALE_RESTART_HARD_CAP_SECONDS,
}

function PluginInfoProvider.sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    if prefs.autoStartServer == nil then
        prefs.autoStartServer = true
    end
    propertyTable.autoStartServer = prefs.autoStartServer
    propertyTable:addObserver('autoStartServer', function(_, _, value)
        prefs.autoStartServer = value
    end)

    local cfgRequestPort, cfgResponsePort = readPortPrefs()
    propertyTable.requestPort = cfgRequestPort
    propertyTable.responsePort = cfgResponsePort
    propertyTable:addObserver('requestPort', function(_, _, value)
        local n = tonumber(value)
        if validPort(n) then prefs.requestPort = n end
    end)
    propertyTable:addObserver('responsePort', function(_, _, value)
        local n = tonumber(value)
        if validPort(n) then prefs.responsePort = n end
    end)

    local activeRequest = pluginState.requestPort or cfgRequestPort
    local activeResponse = pluginState.responsePort or cfgResponsePort

    local statusText = "=== Lightroom MCP Status ===\n\n"
    statusText = statusText .. "Running: " .. tostring(pluginState.running) .. "\n"
    statusText = statusText .. "Request socket connected: " .. tostring(pluginState.receiveConnected) .. "\n"
    statusText = statusText .. "Response socket connected: " .. tostring(pluginState.sendConnected) .. "\n"
    statusText = statusText .. "Last event: " .. (pluginState.lastEvent or "Never") .. "\n"
    statusText = statusText .. "Requests processed: " .. pluginState.requestsProcessed .. "\n"
    statusText = statusText .. "Request port: " .. activeRequest .. " (mode=receive)\n"
    statusText = statusText .. "Response port: " .. activeResponse .. " (mode=send)\n"
    statusText = statusText .. "Log file: " .. (Log.filePath() or "(unavailable)") .. "\n"
    statusText = statusText .. "\nRecent logs:\n"
    local startIdx = math.max(1, #pluginState.log - 15)
    for i = startIdx, #pluginState.log do
        statusText = statusText .. "  " .. pluginState.log[i] .. "\n"
    end

    return {
        {
            title = "Lightroom MCP Server Status",
            f:static_text {
                title = statusText,
                fill_horizontal = 1,
                width_in_chars = 70,
                height_in_lines = 25,
            },
            f:checkbox {
                title = "Auto-start server on Lightroom launch",
                value = LrView.bind('autoStartServer'),
            },
            f:row {
                f:static_text { title = "Request port:", width = 110 },
                f:edit_field {
                    value = LrView.bind('requestPort'),
                    width_in_chars = 7,
                    precision = 0,
                    min = 1,
                    max = 65535,
                },
                f:static_text { title = "(default 58763)" },
            },
            f:row {
                f:static_text { title = "Response port:", width = 110 },
                f:edit_field {
                    value = LrView.bind('responsePort'),
                    width_in_chars = 7,
                    precision = 0,
                    min = 1,
                    max = 65535,
                },
                f:static_text { title = "(default 58764)" },
            },
            f:static_text {
                title = "Port changes apply on next Start. Server env vars must match: LIGHTROOM_MCP_REQUEST_PORT / LIGHTROOM_MCP_RESPONSE_PORT.",
                fill_horizontal = 1,
                width_in_chars = 70,
                height_in_lines = 2,
            },
            f:row {
                -- Two buttons rather than one toggle. The toggle's title was
                -- computed once at render, so after Stop it still read "Stop
                -- Server" and clicking it only logged "Not running" -- there was
                -- no way to start again without closing and reopening the
                -- dialog. A bound title does not work here: Lightroom ignores a
                -- binding on a push_button title.
                f:push_button {
                    title = "Start Server",
                    action = function()
                        if pluginState.running then
                            addLog("Start ignored (already running)")
                            return
                        end
                        startServerFromPanel()
                    end,
                },
                f:push_button {
                    title = "Stop Server",
                    action = function()
                        stopServer()
                    end,
                },
                f:push_button {
                    title = "Show Status",
                    action = function()
                        local lines = {
                            "Running: " .. tostring(pluginState.running),
                            "Request socket connected: " .. tostring(pluginState.receiveConnected),
                            "Response socket connected: " .. tostring(pluginState.sendConnected),
                            "Last event: " .. (pluginState.lastEvent or "Never"),
                            "Requests processed: " .. pluginState.requestsProcessed,
                            "Log file: " .. (Log.filePath() or "(unavailable)"),
                            "",
                            "Recent logs:",
                        }
                        local logStart = math.max(1, #pluginState.log - 30)
                        for i = logStart, #pluginState.log do
                            table.insert(lines, "  " .. pluginState.log[i])
                        end
                        LrDialogs.message("Lightroom MCP Status", table.concat(lines, "\n"), "info")
                    end,
                },
            },
        },
    }
end

return PluginInfoProvider
