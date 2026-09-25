local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local PhotoLookup = require 'PhotoLookup'
local MaskSummary = require 'MaskSummary'
local Corrections = require 'Corrections'
local Log = require 'Log'

local AIMaskHandler = {}

-- =====================================================================
-- add_ai_mask — AI subject/sky/background selection masks
-- =====================================================================
--
-- Lightroom Classic's AI masking (Select Subject / Select Sky / ...) is
-- exposed to the SDK through LrDevelopController:
--
--   maskId = LrDevelopController.createNewMask("aiSelection", subtype)
--
-- Unlike the catalog write APIs used by most handlers, LrDevelopController
-- drives the Develop module of the running Lightroom UI: the target photo
-- must be selected in the filmstrip and the Develop module active, and the
-- AI computation itself runs inside Lightroom (seconds on fast machines).
-- The handler therefore, per photo:
--
--   1. selects the photo (outside any catalog gate — it yields, #134/#124);
--   2. switches to the Develop module (once, before the batch);
--   3. engages the masking tool if another tool is active;
--   4. creates the AI selection mask;
--   5. applies the requested adjustment sliders to the new mask.
--
-- Everything is pcall-wrapped and reported honestly per photo: if a
-- particular subtype is unavailable in the installed Lightroom version,
-- or the photo has no detectable subject, the error surfaces in that
-- photo's entry instead of failing the whole call.
--
-- Best verified visually afterwards with get_photo_preview.

-- Subtypes accepted by createNewMask("aiSelection", ...). Availability of
-- people/objects/landscape depends on the Lightroom Classic version.
local SELECTION_TYPES = {
    subject = true,
    sky = true,
    background = true,
    objects = true,
    people = true,
    landscape = true,
}

-- Friendly arg name -> LOCAL slider key inside a correction (XMP name) and
-- the accepted UI range. The values are written straight into the mask's
-- MaskGroupBasedCorrections entry: LrDevelopController.setValue targets the
-- photo-wide sliders, so passing it these names silently edits the GLOBAL
-- develop settings instead of the mask (verified the hard way). Exposure is
-- in EV like its global counterpart; every other slider is stored as a
-- fraction of its -100..100 UI range. Temperature/Tint stay out of reach
-- here (local color work goes through add_local_adjustment, verified).
local ADJUSTMENTS = {
    exposure = { key = "LocalExposure2012", min = -5, max = 5, ev = true },
    contrast = { key = "LocalContrast2012", min = -100, max = 100 },
    highlights = { key = "LocalHighlights2012", min = -100, max = 100 },
    shadows = { key = "LocalShadows2012", min = -100, max = 100 },
    whites = { key = "LocalWhites2012", min = -100, max = 100 },
    blacks = { key = "LocalBlacks2012", min = -100, max = 100 },
    texture = { key = "LocalTexture", min = -100, max = 100 },
    clarity = { key = "LocalClarity2012", min = -100, max = 100 },
    dehaze = { key = "LocalDehaze", min = -100, max = 100 },
    vibrance = { key = "LocalVibrance", min = -100, max = 100 },
    saturation = { key = "LocalSaturation", min = -100, max = 100 },
    sharpness = { key = "LocalSharpness", min = 0, max = 150 },
}

local SUPPORTED_ADJUSTMENT_NAMES = (function()
    local names = {}
    for k in pairs(ADJUSTMENTS) do table.insert(names, k) end
    table.sort(names)
    return table.concat(names, ", ")
end)()

-- Named adjustment recipes for AI/range masks (ported from lightroom-cli's
-- presets.py, minus 'warm-skin': it relies on Temp/Tint, which this handler
-- deliberately does not expose — see the ADJUSTMENTS note above).
local ADJUSTMENT_PRESETS = {
    darken_sky = { exposure = -0.7, highlights = -30, saturation = 15 },
    brighten_subject = { exposure = 0.5, shadows = 20, clarity = 10 },
    blur_background = { sharpness = -80, clarity = -40 },
    enhance_landscape = { clarity = 30, vibrance = 25, dehaze = 15 },
}

local SETTLE_AFTER_MODULE_SWITCH_S = 0.5
local SETTLE_BETWEEN_PHOTOS_S = 0.3
-- AI selection (Select Subject/People/Sky/...) runs real inference over the
-- loaded photo — the same processing delay is visible when triggered from
-- the UI. createNewMask() does NOT throw while that inference is still
-- settling; it returns a clean nil, indistinguishable at the Lua level from
-- "no matching region found". Give it a beat after engaging the masking
-- tool, then retry a few times before reporting failure. An actual SDK
-- error (unsupported feature, no Develop context, etc.) still fails on the
-- first attempt — only a clean nil is retried.
local SETTLE_AFTER_TOOL_SELECT_S = 1.0
local MASK_CREATE_MAX_ATTEMPTS = 8
local MASK_CREATE_RETRY_DELAY_S = 1.5

-- When createNewMask produces no mask, Lightroom shows a transient
-- toast/banner explaining why (e.g. "Could not find subject in this
-- photo"). The SDK cannot read that text: LrDialogs has no message-text
-- API and the MCP log is ours, not Lightroom's. The only channel to the
-- caller is therefore a PHOTOGRAPH of the Lightroom window, taken while
-- the banner is still on screen — captureWindowScreenshot() below drives
-- a PowerShell helper (same temp-script/result-file protocol as
-- HandlerAI.sendNativeDenoiseKeys) because LrTasks.execute captures no
-- stdout. The file lands in the get_photo_preview previews folder and the
-- paths are returned per photo under `warning_screenshots` (first one
-- also under `warning_screenshot`).
--
-- Banners last a few seconds while the retry loop runs 10–30s, so the
-- shot is taken twice: once early (fast types: attempt 3 ≈ t=3s; slow
-- types: attempt 6 ≈ t=10s — the moment a detection failure's banner is
-- most likely up) and once at failure time (catches late failures). On a
-- photo that eventually succeeds the early file is deleted again.
local WARN_SHOT_KEEP = 40

local function buildAdjustments(input)
    if input == nil then return {} end
    if type(input) ~= "table" then
        error("adjustments must be an object")
    end
    local out = {}
    for name, value in pairs(input) do
        local spec = ADJUSTMENTS[name]
        if not spec then
            error("unknown adjustment '" .. tostring(name)
                .. "' (supported: " .. SUPPORTED_ADJUSTMENT_NAMES .. ")")
        end
        if type(value) ~= "number" then
            error("adjustment '" .. tostring(name) .. "' must be a number")
        end
        if value < spec.min or value > spec.max then
            error(string.format("adjustment '%s' must be between %s and %s",
                name, tostring(spec.min), tostring(spec.max)))
        end
        table.insert(out, { name = name, key = spec.key, value = value,
            ev = spec.ev, min = spec.min, max = spec.max })
    end
    return out
end

local function resolveAdjustments(args)
    if args.adjustments ~= nil and args.adjustment_preset ~= nil then
        error("pass either adjustments or adjustment_preset, not both")
    end
    if args.adjustment_preset ~= nil then
        local preset = ADJUSTMENT_PRESETS[args.adjustment_preset]
        if not preset then
            error("adjustment_preset must be one of: darken_sky, brighten_subject, blur_background, enhance_landscape")
        end
        return buildAdjustments(preset), args.adjustment_preset
    end
    return buildAdjustments(args.adjustments), nil
end

local function clampRange(v, min, max)
    if v == nil then return 0 end
    if v < min then return min end
    if v > max then return max end
    return v
end

-- "DSC_0123 (cópia).NEF" -> "dsc_0123_cpa" : Windows-safe, ascii-ish.
-- (HandlerPreview keeps the same helper local; it is not exported.)
local function sanitizeBase(filename)
    local base = filename or "photo"
    base = base:gsub("%.[^%.]*$", "") -- drop extension
    base = base:lower():gsub("[^%w%-_]", "")
    if #base > 40 then base = base:sub(1, 40) end
    if base == "" then base = "photo" end
    return base
end

-- The get_photo_preview previews folder; warn_*.jpg live alongside the
-- preview_*.jpg files. HandlerPreview's prune matches only preview_*, so
-- this module prunes its own warn_* files below.
local function warnShotsDir()
    local config = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("home"), ".config")
    local base = LrPathUtils.child(
        LrPathUtils.child(config, "lightroom-mcp"), "previews")
    LrFileUtils.createAllDirectories(base)
    return base
end

local warnShotSeq = 0

-- Delete the oldest warn_*.jpg past WARN_SHOT_KEEP. Filenames are
-- warn_<base>_<label>_<timestamp>_<seq>.jpg, so sorting on the timestamp
-- keeps them in creation order. Best-effort, never fatal.
local function pruneWarnShots(dir)
    local ok, entries = pcall(function()
        return LrFileUtils.directoryEntries(dir)
    end)
    if not ok or type(entries) ~= "table" then return end
    local stamped = {}
    for _, name in ipairs(entries) do
        local ts = name:match("^warn_.-(%d+)_(%d+)%.jpg$")
        if ts then table.insert(stamped, { name = name, ts = ts }) end
    end
    if #stamped <= WARN_SHOT_KEEP then return end
    table.sort(stamped, function(a, b) return a.ts < b.ts end)
    for i = 1, #stamped - WARN_SHOT_KEEP do
        pcall(function()
            LrFileUtils.delete(LrPathUtils.child(dir, stamped[i].name))
        end)
    end
end

local WARN_SHOT_WINDOW_TITLE = "Lightroom"

-- Photograph the Lightroom WINDOW (not the photo: requestJpegThumbnail
-- renders the image, which is exactly what the warning banner does NOT
-- contain) while the warning banner is on screen. Writes a temp
-- PowerShell helper — LrTasks.execute captures no stdout, hence the
-- result-file protocol shared with HandlerAI.sendNativeDenoiseKeys — and
-- runs it synchronously. The helper only copies the screen once
-- Lightroom owns the foreground: on a locked session (verified live:
-- AppActivate cannot move focus to the secure desktop) CopyFromScreen
-- would photograph the lock screen instead of the banner, so it refuses
-- with 'window-not-foreground' rather than lie to the vision client.
-- Returns (outPath, nil) or (nil, errmsg).
local function captureWindowScreenshot(filename, label)
    if WIN_ENV == nil and MAC_ENV == nil then
        -- Test environment (busted): no OS to automate.
        return nil, "no OS automation in this environment (test)"
    end
    if not WIN_ENV then
        return nil, "Lightroom window capture is Windows-only"
    end

    local dirOk, dirOrErr = pcall(warnShotsDir)
    if not dirOk then
        return nil, "could not create screenshot dir: " .. tostring(dirOrErr)
    end

    warnShotSeq = warnShotSeq + 1
    local outName = string.format("warn_%s_%s_%d_%d.jpg",
        sanitizeBase(filename), label or "shot", os.time(), warnShotSeq)
    local outPath = LrPathUtils.child(dirOrErr, outName)

    local tempDir = LrPathUtils.getStandardFilePath("temp")
    local scriptPath = LrPathUtils.child(tempDir, "lightroom-mcp-warn-shot.ps1")
    local resultPath = LrPathUtils.child(tempDir, "lightroom-mcp-warn-shot.result")
    pcall(function() LrFileUtils.delete(resultPath) end)

    -- No path is embedded inside the script body (they arrive as named
    -- parameters), so nothing needs PowerShell-quote escaping here.
    local script = table.concat({
        "param(",
        "    [string]$ResultPath,",
        "    [string]$OutPath,",
        "    [string]$WindowTitle",
        ")",
        "$ErrorActionPreference = 'Stop'",
        -- Status is a plain variable, written ONCE at the end: `exit` inside
        -- a try block is a catchable error in Windows PowerShell, which would
        -- overwrite 'no-window'/'bad-rect' from the catch below.
        "$status = 'ok'",
        "try {",
        "    Add-Type -AssemblyName System.Windows.Forms",
        "    Add-Type -AssemblyName System.Drawing",
        "    Add-Type @\"",
        "using System;",
        "using System.Runtime.InteropServices;",
        "public struct LrRECT {",
        "    public int Left;",
        "    public int Top;",
        "    public int Right;",
        "    public int Bottom;",
        "}",
        "public static class LrWin {",
        "    [DllImport(\"user32.dll\")] public static extern bool SetProcessDPIAware();",
        "    [DllImport(\"user32.dll\")] public static extern bool GetWindowRect(IntPtr hWnd, out LrRECT lpRect);",
        "    [DllImport(\"user32.dll\")] public static extern bool IsIconic(IntPtr hWnd);",
        "    [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);",
        "    [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();",
        "    [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd);",
        "    [DllImport(\"user32.dll\")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);",
        "}",
        "\"@",
        "    [void][LrWin]::SetProcessDPIAware()",
        "    $proc = $null",
        "    try { $proc = Get-Process -Name $WindowTitle -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 } catch {}",
        "    if (-not $proc) {",
        "        $proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like ('*' + $WindowTitle + '*') -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1",
        "    }",
        "    if (-not $proc) {",
        "        $status = 'no-window'",
        "    } else {",
        "        $hwnd = $proc.MainWindowHandle",
        "        if ([LrWin]::IsIconic($hwnd)) { [void][LrWin]::ShowWindow($hwnd, 9); Start-Sleep -Milliseconds 400 }",
        "        $shell = New-Object -ComObject WScript.Shell",
        "        [void]$shell.AppActivate($proc.Id)",
        "        [void][LrWin]::SetForegroundWindow($hwnd)",
        "        Start-Sleep -Milliseconds 400",
        "        $fg = [LrWin]::GetForegroundWindow()",
        "        $fgPid = 0",
        "        [void][LrWin]::GetWindowThreadProcessId($fg, [ref]$fgPid)",
        "        if ($fgPid -ne $proc.Id) {",
        "            $status = 'window-not-foreground (Lightroom could not be brought to the front - the session may be locked)'",
        "        } else {",
        "            $rect = New-Object LrRECT",
        "            [void][LrWin]::GetWindowRect($hwnd, [ref]$rect)",
        "            $w = $rect.Right - $rect.Left",
        "            $h = $rect.Bottom - $rect.Top",
        "            if ($w -le 0 -or $h -le 0) {",
        "                $status = 'bad-rect'",
        "            } else {",
        "                $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h",
        "                $g = [System.Drawing.Graphics]::FromImage($bmp)",
        "                $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size -ArgumentList $w, $h))",
        "                $g.Dispose()",
        "                $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)",
        "                $bmp.Dispose()",
        "            }",
        "        }",
        "    }",
        "} catch {",
        "    $status = 'error: ' + $_.Exception.Message",
        "}",
        "$status | Out-File -FilePath $ResultPath -Encoding ascii",
    }, "\r\n")

    local fh, openErr = io.open(scriptPath, "w")
    if not fh then
        return nil, "failed to write helper script: " .. tostring(openErr)
    end
    fh:write(script)
    fh:close()

    local command = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
        .. scriptPath
        .. '" -ResultPath "' .. resultPath
        .. '" -OutPath "' .. outPath
        .. '" -WindowTitle "' .. WARN_SHOT_WINDOW_TITLE .. '"'
    local execOk, execResult = pcall(function() return LrTasks.execute(command) end)

    -- Give the filesystem a beat to flush the result file before reading it.
    local resultContent = nil
    for _ = 1, 10 do
        local rf = io.open(resultPath, "r")
        if rf then
            resultContent = rf:read("*a") or ""
            rf:close()
            break
        end
        LrTasks.sleep(0.2)
    end

    pcall(function() LrFileUtils.delete(scriptPath) end)
    pcall(function() LrFileUtils.delete(resultPath) end)

    if resultContent == nil then
        return nil, "screenshot helper produced no result (execute ok="
            .. tostring(execOk) .. ", status " .. tostring(execResult) .. ")"
    end

    resultContent = resultContent:gsub("^%s+", ""):gsub("%s+$", "")
    if resultContent == "ok" then
        -- The helper writes the JPEG BEFORE it writes 'ok', so 'ok' means
        -- the file is on disk; prune neighbours best-effort.
        pcall(pruneWarnShots, dirOrErr)
        return outPath, nil
    end
    return nil, "screenshot helper failed: " .. resultContent
end

-- Heuristic fallback advice per selection_type when detection produced no
-- mask. It never claims to know Lightroom's exact banner text — that is
-- what the screenshot is for; the vision client reads it and decides.
local SUGGESTED_ACTIONS = {
    subject = "no subject was detected: try selection_type 'background' or 'objects', or cover the region with add_local_adjustment",
    sky = "no sky was detected: try selection_type 'subject' or 'background', or draw a linear gradient over the horizon with add_local_adjustment",
    background = "no background was detected: try selection_type 'subject', or mask the surroundings manually with add_local_adjustment",
    objects = "no objects were detected: try selection_type 'subject' or 'people', or use Select Objects in Lightroom's masking panel and then set_mask_adjustments with its mask_id",
    people = "no person was detected: the person/body-part pick is UI-only — select the person in Lightroom's masking panel, then use set_mask_adjustments with its mask_id",
    landscape = "no landscape regions were detected: try selection_type 'subject' or 'sky', or build the mask manually with add_local_adjustment",
}
local SUGGESTED_ACTION_SDK_ERROR = "createNewMask itself failed (see error): this Lightroom build may not support that selection type — create the mask in Lightroom's masking panel, or fall back to add_local_adjustment"
local SUGGESTED_ACTION_GENERIC = "AI detection produced no mask: retry with a different selection_type, or create it manually with add_local_adjustment / Lightroom's masking panel"

local function suggestedActionFor(selectionType, failureKind)
    if failureKind == "sdk_error" then return SUGGESTED_ACTION_SDK_ERROR end
    return SUGGESTED_ACTIONS[selectionType] or SUGGESTED_ACTION_GENERIC
end

-- MaskGroupBasedCorrections as a table; tolerates nil and odd shapes.
local function readCorrections(photo)
    local settings = photo:getDevelopSettings()
    local value = settings.MaskGroupBasedCorrections
    if type(value) == "table" then return value end
    return {}
end

local function findCorrectionByMaskId(corrections, maskId)
    local wanted = tostring(maskId)
    for _, correction in ipairs(corrections) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            for _, mask in ipairs(correction.CorrectionMasks) do
                if type(mask) == "table" and tostring(mask.MaskID) == wanted then
                    return correction
                end
            end
        end
    end
    return nil
end

-- createNewMask can return nil even when it successfully creates the mask
-- (this happens in the current Lightroom build for aiSelection), so success
-- is also verified through the mask count. getAllMasks() is queried directly
-- here because currentMaskCount() is declared further down in this file.
local function maskCountNow()
    local ok, masks = pcall(function()
        return LrDevelopController.getAllMasks()
    end)
    if not ok or type(masks) ~= "table" then return -1 end
    return #masks
end

local function isUsableMaskId(v)
    return v ~= nil and v ~= false
end

-- Derives the mask id of the newest mask from a getAllMasks() list. The
-- per-entry shape varies between Lightroom versions; the MaskID that
-- set_mask_adjustments expects is carried by Tools[1].ID.
local function latestMaskIdFromList(masks, beforeCount)
    if type(masks) ~= "table" then return nil end
    local n = #masks
    if n <= beforeCount then return nil end
    local entry = masks[n]
    if type(entry) ~= "table" then return nil end
    local tools = entry.Tools or entry.tools
    if type(tools) == "table" and type(tools[1]) == "table"
        and isUsableMaskId(tools[1].ID) then
        return tostring(tools[1].ID)
    end
    if isUsableMaskId(entry.ID) then return tostring(entry.ID) end
    if isUsableMaskId(entry.id) then return tostring(entry.id) end
    return nil
end

-- AI selection types whose detection runs a heavier model than
-- subject/sky/background. They get a longer poll window (the server allows
-- 120s for add_ai_mask), and their failure note points at the UI-only pick.
local SLOW_MASK_TYPES = { people = true, objects = true, landscape = true }
local SLOW_MASK_MAX_ATTEMPTS = 15
local SLOW_MASK_RETRY_DELAY_S = 2.0

-- Shared per-photo batch loop: selects each photo in Develop, engages the
-- masking tool if needed, creates the mask through `createMask()`, then
-- applies the requested adjustment sliders. Returns (results, succeeded).
local function runMaskCreationBatch(catalog, photos, createMask, opts)
    opts = opts or {}
    local results = {}
    local succeeded = 0
    local failed = 0

    for i, photo in ipairs(photos) do
        if i > 1 then LrTasks.sleep(SETTLE_BETWEEN_PHOTOS_S) end

        local entry = {
            photo = {
                id = photo.localIdentifier,
                path = photo:getRawMetadata('path'),
                filename = photo:getFormattedMetadata('fileName'),
            },
            photo_object = photo,
        }
        table.insert(results, entry)

        local ok = pcall(function()
            catalog:setSelectedPhotos(photo, { photo })
        end)
        if not ok then
            entry.error = "could not select the photo in Lightroom"
            failed = failed + 1
        else
            -- Open the Masking panel itself first — this is the call the UI's
            -- "Masking" icon makes to reveal the New Mask browser; it is
            -- distinct from selectTool("masking"), which only switches the
            -- active tool identifier and does not by itself open the panel
            -- that createNewMask("aiSelection", ...) draws its overlay into.
            -- Without it, createNewMask silently returns nil (no error) even
            -- though the same action works fine from a real UI click.
            pcall(function() LrDevelopController.goToMasking() end)

            local currentToolOk, currentTool = pcall(function()
                return LrDevelopController.getSelectedTool()
            end)
            if currentToolOk and currentTool ~= "masking" then
                pcall(function() LrDevelopController.selectTool("masking") end)
            end
            LrTasks.sleep(SETTLE_AFTER_TOOL_SELECT_S)

            local beforeCount = maskCountNow()
            local maskOk, maskOut = pcall(createMask)
            local maxAttempts = opts.retryMaxAttempts or MASK_CREATE_MAX_ATTEMPTS
            local retryDelay = opts.retryDelayS or MASK_CREATE_RETRY_DELAY_S
            -- Early banner shot: ~40% into the retry window, when a
            -- detection failure's banner is most likely still on screen
            -- (fast types: attempt 3 ≈ t=3s; slow types: attempt 6 ≈ t=10s).
            local captureAt = math.max(2, math.floor(maxAttempts * 0.4))
            local earlyShot, earlyShotErr
            local maskId = maskOk and isUsableMaskId(maskOut) and tostring(maskOut) or nil
            local created = maskId ~= nil or maskCountNow() > beforeCount
            -- A clean nil usually means the mask was QUEUED, not that it
            -- failed: this Lightroom build can create the mask and still
            -- return nil from createNewMask. Re-invoking it would queue
            -- duplicate masks, so for that case only the mask count is
            -- polled; createNewMask is retried after a real pcall error.
            for attempt = 2, maxAttempts do
                if created then break end
                LrTasks.sleep(retryDelay)
                if maskOk then
                    created = maskCountNow() > beforeCount
                else
                    maskOk, maskOut = pcall(createMask)
                    maskId = maskOk and isUsableMaskId(maskOut) and tostring(maskOut) or nil
                    created = maskId ~= nil or maskCountNow() > beforeCount
                end
                if not created and opts.captureWarningShot and attempt == captureAt then
                    earlyShot, earlyShotErr =
                        captureWindowScreenshot(entry.photo.filename, "early")
                end
            end
            if created and maskId == nil then
                local listOk, masks = pcall(function()
                    return LrDevelopController.getAllMasks()
                end)
                if listOk then
                    maskId = latestMaskIdFromList(masks, beforeCount)
                end
            end
            if not created then
                local shots = {}
                if opts.captureWarningShot then
                    -- Final shot at failure (catches banners that showed up
                    -- after the early one), then everything the caller needs
                    -- to choose a fallback.
                    local finalShot, finalShotErr =
                        captureWindowScreenshot(entry.photo.filename, "final")
                    if earlyShot then table.insert(shots, earlyShot) end
                    if finalShot then table.insert(shots, finalShot) end
                    if #shots > 0 then
                        entry.warning_screenshots = shots
                        entry.warning_screenshot = shots[1]
                    else
                        entry.warning_capture_error = finalShotErr or earlyShotErr
                            or "screenshot capture unavailable"
                    end
                    entry.failure_kind = maskOk and "detection_failed" or "sdk_error"
                    entry.suggested_action =
                        suggestedActionFor(opts.selectionType, entry.failure_kind)
                end

                if maskOk then
                    -- Clean nil: no exception, but no mask either. Say how
                    -- long we tried instead of the useless "failed: nil".
                    local bannerNote = ""
                    if opts.captureWarningShot then
                        if #shots > 0 then
                            bannerNote = "; the warning banner was captured (see warning_screenshots)"
                        elseif entry.warning_capture_error then
                            bannerNote = "; the warning banner could not be captured (see warning_capture_error)"
                        end
                    end
                    local elapsedS = math.floor((maxAttempts - 1) * retryDelay)
                    entry.error = string.format(
                        "createNewMask produced no mask after %d attempts over ~%ds: no mask appeared in the Develop masking panel%s",
                        maxAttempts, elapsedS, bannerNote)
                else
                    entry.error = "createNewMask failed: " .. tostring(maskOut)
                end
                if opts.errorNote then
                    entry.error = entry.error .. " - " .. opts.errorNote
                end
                failed = failed + 1
            else
                if earlyShot then
                    -- The photo ended up with a mask: the early shot was a
                    -- bet on failure that did not pay off — drop it so no
                    -- stale warning file survives for a healthy photo.
                    pcall(function() LrFileUtils.delete(earlyShot) end)
                end
                entry.mask_id = maskId
                entry.applied = {}
                entry.adjustment_errors = {}
                succeeded = succeeded + 1
            end
        end
    end

    return results, succeeded, failed
end

local function resolveSinglePhoto(catalog, photoId)
    local photo = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { photoId })
        if resolved[1] and resolved[1].photo then
            photo = resolved[1].photo
        end
    end)
    return photo
end

local function switchToDevelopAndSelect(catalog, photo)
    -- switchToModule and setSelectedPhotos both yield to the UI thread, so
    -- they must run OUTSIDE any catalog access gate (#134/#124).
    local switchOk, switchErr = pcall(function()
        LrApplicationView.switchToModule("develop")
    end)
    if not switchOk then
        error("could not switch Lightroom to the Develop module: "
            .. tostring(switchErr))
    end
    LrTasks.sleep(SETTLE_AFTER_MODULE_SWITCH_S)

    local selectOk = pcall(function()
        catalog:setSelectedPhotos(photo, { photo })
    end)
    if not selectOk then
        error("could not select the photo in Lightroom")
    end
    LrTasks.sleep(SETTLE_BETWEEN_PHOTOS_S)
end

function AIMaskHandler.addAIMask(args)
    args = args or {}
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local selectionType = args.selection_type or "subject"
    if not SELECTION_TYPES[selectionType] then
        error("selection_type must be one of: subject, sky, background, objects, people, landscape")
    end

    local adjustments, presetName = resolveAdjustments(args)

    local catalog = LrApplication.activeCatalog()

    local photos = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then table.insert(photos, entry.photo) end
        end
    end)

    if #photos == 0 then
        error("No photos matched photo_ids")
    end

    -- switchToModule and setSelectedPhotos both yield to the UI thread, so
    -- they must run OUTSIDE any catalog access gate (#134/#124).
    local switchOk, switchErr = pcall(function()
        LrApplicationView.switchToModule("develop")
    end)
    if not switchOk then
        error("could not switch Lightroom to the Develop module: "
            .. tostring(switchErr))
    end
    LrTasks.sleep(SETTLE_AFTER_MODULE_SWITCH_S)

    local maskOpts = {
        captureWarningShot = true,
        selectionType = selectionType,
    }
    if SLOW_MASK_TYPES[selectionType] then
        maskOpts.retryMaxAttempts = SLOW_MASK_MAX_ATTEMPTS
        maskOpts.retryDelayS = SLOW_MASK_RETRY_DELAY_S
        maskOpts.errorNote = "people/objects/landscape detection is slower and "
            .. "the person/body-part pick is UI-only: if no mask was "
            .. "created, create it manually in Lightroom and use "
            .. "set_mask_adjustments with its mask_id"
    end

    local results, succeeded, failed = runMaskCreationBatch(catalog, photos, function()
        return LrDevelopController.createNewMask("aiSelection", selectionType)
    end, maskOpts)

    -- Phase 2: apply the local-slider adjustments. The creation batch has
    -- yielded many times (module switch, tool select, createNewMask retry
    -- loop), and in this Lightroom build a task that has slept that much no
    -- longer satisfies withWriteAccessDo's "must be called from within an
    -- LrTask" check. set_mask_adjustments works because it runs in a fresh
    -- task with no prior yields, so the same shape is used here: a new
    -- startAsyncTask spawned AFTER the batch finished.
    if #adjustments > 0 then
        for _, entry in ipairs(results) do
            if entry.mask_id then
                local adjDone = false
                local adjOk = false
                local adjErr = ""
                LrTasks.startAsyncTask(function()
                    adjOk, adjErr = pcall(function()
                        catalog:withWriteAccessDo("MCP AI Mask", function()
                            local corrections = readCorrections(entry.photo_object)
                            local target = findCorrectionByMaskId(corrections, entry.mask_id)
                            if not target then
                                error("mask " .. tostring(entry.mask_id)
                                    .. " is not among the photo's corrections")
                            end
                            for _, adj in ipairs(adjustments) do
                                local v = clampRange(adj.value, adj.min, adj.max)
                                target[adj.key] = adj.ev and v or (v / 100)
                            end
                            entry.photo_object:applyDevelopSettings({
                                EnableMaskGroupBasedCorrections = true,
                                MaskGroupBasedCorrections = corrections,
                            }, "MCP AI Mask")
                        end)
                    end)
                    adjDone = true
                end)
                for _ = 1, 100 do
                    if adjDone then break end
                    LrTasks.sleep(0.05)
                end
                if adjDone and adjOk then
                    for _, adj in ipairs(adjustments) do
                        entry.applied[adj.name] = adj.value
                    end
                else
                    local why = adjDone and tostring(adjErr)
                        or "adjustment write did not settle within 5s"
                    for _, adj in ipairs(adjustments) do
                        entry.adjustment_errors[adj.name] = why
                    end
                end
                if next(entry.adjustment_errors) == nil then
                    entry.adjustment_errors = nil
                end
            end
        end
    end

    Log.info(string.format("addAIMask('%s'): %d/%d photos",
        selectionType, succeeded, #photos))

    local result = {
        success = failed == 0,
        selection_type = selectionType,
        requested = #photos,
        succeeded = succeeded,
        failed = failed,
        results = results,
        method = "LrDevelopController.createNewMask('aiSelection')",
        message = string.format("AI '%s' mask applied to %d of %d photos",
            selectionType, succeeded, #photos),
    }
    if presetName then
        result.adjustment_preset = presetName
    end
    if failed > 0 then
        result.message = result.message
            .. ". Check each photo's 'error' entry; verify masks visually with get_photo_preview."
        -- Surface the warning screenshots at the top level so the MCP
        -- client can read Lightroom's own banner text and decide the
        -- fallback (different selection_type, manual mask, or stop).
        local shots = {}
        for _, entry in ipairs(results) do
            if type(entry.warning_screenshots) == "table" then
                for _, path in ipairs(entry.warning_screenshots) do
                    table.insert(shots, path)
                end
            end
        end
        if #shots > 0 then
            result.warning_screenshots = shots
            result.warning = string.format(
                "AI detection produced no mask on %d photo(s); Lightroom's warning banner was captured in %d screenshot(s) attached to this response. Read the banner text in the image(s) to confirm the exact message, then decide per photo: retry add_ai_mask with another selection_type, fall back to add_local_adjustment, or follow the photo's suggested_action.",
                failed, #shots)
        end
    end
    return result
end

-- =====================================================================
-- add_range_mask — luminance / color / depth range masks
-- =====================================================================
--
-- LrDevelopController.createNewMask("rangeMask", "luminance"|"color"|"depth")
-- creates a range mask on the photo loaded in Develop, then setValue
-- applies the adjustment sliders to it (same flow as the AI masks).
-- HONEST LIMITATION (also present in lightroom-cli): the SDK cannot set
-- the range bounds or sample points, so a fresh range mask covers the
-- full range — refine the bounds in the Lightroom UI afterwards, or use
-- the adjustment sliders from here. 'depth' requires a photo that has
-- depth data (iPhone portrait etc.).

local RANGE_TYPES = {
    luminance = true,
    color = true,
    depth = true,
}

function AIMaskHandler.addRangeMask(args)
    args = args or {}
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local rangeType = args.range_type or "luminance"
    if not RANGE_TYPES[rangeType] then
        error("range_type must be one of: luminance, color, depth")
    end

    local adjustments, presetName = resolveAdjustments(args)

    local catalog = LrApplication.activeCatalog()

    local photos = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then table.insert(photos, entry.photo) end
        end
    end)

    if #photos == 0 then
        error("No photos matched photo_ids")
    end

    local switchOk, switchErr = pcall(function()
        LrApplicationView.switchToModule("develop")
    end)
    if not switchOk then
        error("could not switch Lightroom to the Develop module: "
            .. tostring(switchErr))
    end
    LrTasks.sleep(SETTLE_AFTER_MODULE_SWITCH_S)

    local results, succeeded, failed = runMaskCreationBatch(catalog, photos, function()
        return LrDevelopController.createNewMask("rangeMask", rangeType)
    end)

    -- Phase 2: local-slider adjustments, in a fresh task (same reason as
    -- addAIMask: the creation batch has yielded too many times for
    -- withWriteAccessDo to accept the calling context).
    if #adjustments > 0 then
        for _, entry in ipairs(results) do
            if entry.mask_id then
                local adjDone = false
                local adjOk = false
                local adjErr = ""
                LrTasks.startAsyncTask(function()
                    adjOk, adjErr = pcall(function()
                        catalog:withWriteAccessDo("MCP Range Mask", function()
                            local corrections = readCorrections(entry.photo_object)
                            local target = findCorrectionByMaskId(corrections, entry.mask_id)
                            if not target then
                                error("mask " .. tostring(entry.mask_id)
                                    .. " is not among the photo's corrections")
                            end
                            for _, adj in ipairs(adjustments) do
                                local v = clampRange(adj.value, adj.min, adj.max)
                                target[adj.key] = adj.ev and v or (v / 100)
                            end
                            entry.photo_object:applyDevelopSettings({
                                EnableMaskGroupBasedCorrections = true,
                                MaskGroupBasedCorrections = corrections,
                            }, "MCP Range Mask")
                        end)
                    end)
                    adjDone = true
                end)
                for _ = 1, 100 do
                    if adjDone then break end
                    LrTasks.sleep(0.05)
                end
                if adjDone and adjOk then
                    for _, adj in ipairs(adjustments) do
                        entry.applied[adj.name] = adj.value
                    end
                else
                    local why = adjDone and tostring(adjErr)
                        or "adjustment write did not settle within 5s"
                    for _, adj in ipairs(adjustments) do
                        entry.adjustment_errors[adj.name] = why
                    end
                end
                if next(entry.adjustment_errors) == nil then
                    entry.adjustment_errors = nil
                end
            end
        end
    end

    Log.info(string.format("addRangeMask('%s'): %d/%d photos",
        rangeType, succeeded, #photos))

    local result = {
        success = failed == 0,
        range_type = rangeType,
        requested = #photos,
        succeeded = succeeded,
        failed = failed,
        results = results,
        method = "LrDevelopController.createNewMask('rangeMask')",
        message = string.format("Range '%s' mask applied to %d of %d photos",
            rangeType, succeeded, #photos),
        note = "The SDK cannot set range bounds or sample points: the mask "
            .. "covers the full range. Refine the bounds in Lightroom's UI, or "
            .. "drive the look through the adjustment sliders.",
    }
    if presetName then
        result.adjustment_preset = presetName
    end
    if failed > 0 then
        result.message = result.message
            .. ". Check each photo's 'error' entry."
    end
    return result
end

-- =====================================================================
-- toggle_mask_overlay — show/hide mask overlays in the Develop UI
-- =====================================================================
--
-- LrDevelopController.toggleOverlay() flips the red mask overlay in the
-- Develop module, the fastest way for a human to eyeball what add_ai_mask /
-- add_local_adjustment actually selected. Acts on the photo loaded in
-- Develop; this handler selects the requested photo first so the overlay
-- belongs to it deterministically.

function AIMaskHandler.toggleMaskOverlay(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local catalog = LrApplication.activeCatalog()
    local photo = resolveSinglePhoto(catalog, args.photo_id)
    if not photo then
        error("No photo matched photo_id")
    end

    switchToDevelopAndSelect(catalog, photo)

    local ok, err = pcall(function()
        LrDevelopController.toggleOverlay()
    end)
    if not ok then
        error("toggleOverlay failed: " .. tostring(err)
            .. " (requires the Develop module to be showing this photo)")
    end

    Log.info(string.format("toggleMaskOverlay: photo %s", tostring(photo.localIdentifier)))

    return {
        success = true,
        photo = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
        },
        message = "Mask overlay toggled — check the Lightroom Develop view "
            .. "(red overlay shows what is masked).",
    }
end

-- =====================================================================
-- list_masks / remove_mask -- mask inventory management
-- =====================================================================
--
-- These read and write MaskGroupBasedCorrections directly, NOT
-- LrDevelopController.getAllMasks(). getAllMasks() reflects the photo loaded
-- in the Develop module, and it does not see corrections written through
-- applyDevelopSettings: measured on a photo where read_local_adjustments
-- reported one mask, getAllMasks() reported zero and BOTH removal paths
-- (deleteMask by id, and resetMasking for remove_all) silently removed
-- nothing. Anything add_local_adjustment created was therefore impossible to
-- delete through the server.
--
-- Reading the stored table fixes that and costs less: no module switch, no
-- selection change, no UI side effects.

function AIMaskHandler.listMasks(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end
    local fields = MaskSummary.requireFields(args.fields)

    local catalog = LrApplication.activeCatalog()
    local photo = resolveSinglePhoto(catalog, args.photo_id)
    if not photo then
        error("No photo matched photo_id")
    end

    local corrections = Corrections.read(photo)
    local entries = Corrections.flatten(corrections)

    local masks = {}
    for _, entry in ipairs(entries) do
        if fields == "full" then
            table.insert(masks, entry.mask)
        else
            local summary = MaskSummary.summarizeMask(entry.mask)
            if type(summary) == "table" then
                -- The owning correction is what set_mask_adjustments and
                -- remove_mask need, so it travels with the mask.
                summary.correction_id = entry.correction.CorrectionID
                summary.correction_name = entry.correction.CorrectionName
            end
            table.insert(masks, summary)
        end
    end

    Log.info(string.format("listMasks: %d mask(s) in %d correction(s) (fields=%s)",
        #masks, #corrections, fields))

    return {
        success = true,
        photo = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
        },
        fields = fields,
        masks = masks,
        count = #masks,
        corrections = #corrections,
        message = string.format("Photo has %d mask(s) in %d correction(s)",
            #masks, #corrections),
        note = (fields == "full")
            and "Verbatim CorrectionMasks entries as stored in "
                .. "MaskGroupBasedCorrections."
            or "Summary view: digest/version bookkeeping omitted. Each mask "
                .. "carries the correction_id that owns it, for "
                .. "set_mask_adjustments and remove_mask.",
    }
end

function AIMaskHandler.removeMask(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local removeAll = args.remove_all == true

    if not removeAll and args.mask_id == nil then
        error("mask_id is required (or pass remove_all=true to clear every mask)")
    end
    if removeAll and args.confirm ~= true then
        error("remove_all strips every mask from the photo: pass confirm=true to proceed")
    end

    local catalog = LrApplication.activeCatalog()
    local photo = resolveSinglePhoto(catalog, args.photo_id)
    if not photo then
        error("No photo matched photo_id")
    end

    local before = Corrections.read(photo)
    local beforeCount = Corrections.countMasks(before)

    local remaining, removed
    if removeAll then
        remaining, removed = {}, beforeCount
    else
        remaining, removed = Corrections.withoutMask(before, args.mask_id)
    end

    if removed == 0 then
        -- Nothing matched. Saying so beats writing the table back unchanged and
        -- reporting a success that removed nothing.
        return {
            success = false,
            removed = 0,
            remove_all = removeAll,
            masks_before = beforeCount,
            masks_after = beforeCount,
            verified = false,
            message = string.format(
                "No mask with id '%s' on this photo (it has %d). Run list_masks "
                .. "to see the ids actually stored.",
                tostring(args.mask_id), beforeCount),
        }
    end

    Corrections.write(catalog, photo, remaining, "MCP Remove Mask")

    -- Same discipline as add_local_adjustment: Lightroom can serve a write back
    -- on an immediate read and drop it at the next recompute, so force one.
    local recomputed = Corrections.forceRecompute(photo)
    local afterCount = Corrections.countMasks(Corrections.read(photo))
    local verified = afterCount < beforeCount

    Log.info(string.format("removeMask(%s): %d -> %d mask(s), recomputed=%s",
        removeAll and "all" or tostring(args.mask_id),
        beforeCount, afterCount, tostring(recomputed)))

    local result = {
        success = verified,
        removed = removed,
        remove_all = removeAll,
        masks_before = beforeCount,
        masks_after = afterCount,
        verified = verified,
        verified_after_recompute = recomputed,
        message = string.format("%s (masks %d -> %d)",
            removeAll and "Removed all masks"
                or ("Removed mask '" .. tostring(args.mask_id) .. "'"),
            beforeCount, afterCount),
    }
    if not verified then
        result.warning = "The write did not survive: Lightroom rejected the "
            .. "updated MaskGroupBasedCorrections. The photo still has its masks."
    end
    return result
end

return AIMaskHandler
