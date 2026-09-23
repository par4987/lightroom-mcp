local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local AIHandler = {}

-- =====================================================================
-- AI Denoise (hybrid)
-- =====================================================================
--
-- Adobe does not expose AI Denoise (Photo > Enhance) through the
-- Lightroom Classic SDK, so this handler drives it in a best-effort way:
--
--   1. select the target photo in the Lightroom UI (the Enhance menu
--      acts on the selection, not on an arbitrary catalog photo);
--   2. run a small PowerShell helper that activates the Lightroom
--      window and replays a configurable SendKeys sequence to open
--      Photo > Enhance... and confirm the dialog (defaults target the
--      English menu; every key is overridable per call);
--   3. poll the photo's folder for a brand-new DNG next to the source
--      file (that is where AI Denoise writes its result) and wait for
--      it to show up in the catalog;
--   4. if any of the above fails (shortcut mismatch, focus stolen,
--      dialog not confirmed, timeout), fall back to a smart manual
--      noise reduction via the official SDK and clearly report which
--      method was used.
--
-- The PowerShell helper communicates through a result file because
-- LrTasks.execute() does not capture child-process stdout.

local DEFAULT_WINDOW_TITLE = "Lightroom Classic"
local DEFAULT_MENU_KEYS = "%pe"          -- Alt+P (Photo menu), then E (Enhance...)
local DEFAULT_CONFIRM_KEYS = "{ENTER}"   -- confirm the dialog with defaults
local DEFAULT_KEY_DELAY_MS = 600
local DEFAULT_VERIFY_TIMEOUT_S = 90
local MIN_VERIFY_TIMEOUT_S = 10
local MAX_VERIFY_TIMEOUT_S = 240
local CATALOG_SETTLE_TIMEOUT_S = 30
local POLL_INTERVAL_S = 2
local MAX_SPOTS_PER_REQUEST = 50 -- shared cap style with other handlers

-- File formats AI Denoise accepts (as returned by getRawMetadata('fileFormat')).
local DENOISABLE_FORMATS = {
    RAW = true,
    DNG = true,
}

local MANUAL_NOISE_KEYS = {
    luminance = "LuminanceSmoothing",
    color = "ColorNoiseReduction",
    luminance_detail = "LuminanceNoiseReductionDetail",
    luminance_contrast = "LuminanceNoiseReductionContrast",
    color_detail = "ColorNoiseReductionDetail",
    color_smoothness = "ColorNoiseReductionSmoothness",
    sharpness = "Sharpness",
    sharpen_radius = "SharpenRadius",
    sharpen_detail = "SharpenDetail",
    sharpen_edge_masking = "SharpenEdgeMasking",
}

local function clampNumber(value, min, max, name)
    if type(value) ~= "number" then
        error(name .. " must be a number")
    end
    if value < min or value > max then
        error(string.format("%s must be between %s and %s", name, tostring(min), tostring(max)))
    end
    return value
end

local function clamp01(value)
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

-- ISO-aware manual noise reduction defaults. The LrC noise slider is 0-100;
-- these starting points are deliberately conservative.
local function smartManualDefaults(photo)
    local iso = tonumber(photo:getFormattedMetadata('isoSpeedRating')) or 0
    local luminance = 35
    if iso >= 12800 then
        luminance = 65
    elseif iso >= 6400 then
        luminance = 55
    elseif iso >= 3200 then
        luminance = 45
    end
    return {
        luminance = luminance,
        color = 25,
    }
end

local function buildManualSettings(photo, manualSettings)
    manualSettings = manualSettings or {}
    local defaults = smartManualDefaults(photo)
    local settings = {}

    for argName, sdkKey in pairs(MANUAL_NOISE_KEYS) do
        local value = manualSettings[argName]
        if value == nil and (argName == "luminance" or argName == "color") then
            value = defaults[argName]
        end
        if value ~= nil then
            if argName == "sharpen_radius" then
                settings[sdkKey] = clampNumber(value, 0.5, 3, argName)
            else
                settings[sdkKey] = clampNumber(value, 0, 100, argName)
            end
        end
    end

    if next(settings) == nil then
        settings.LuminanceSmoothing = defaults.luminance
        settings.ColorNoiseReduction = defaults.color
    end

    return settings
end

-- Write the SendKeys helper script next to the plugin's temp area and run it
-- synchronously on this task. Returns a status table:
--   { ok = true }                    -- keys were sent
--   { ok = false, error = "..." }    -- activate/send failure
local function sendNativeDenoiseKeys(automation)
    if WIN_ENV == nil and MAC_ENV == nil then
        -- Test environment (busted): no OS to automate. Report failure so the
        -- hybrid path exercises its manual fallback.
        return { ok = false, error = "OS automation unavailable in this environment" }
    end

    local windowTitle = automation.window_title or DEFAULT_WINDOW_TITLE
    local menuKeys = automation.menu_keys or DEFAULT_MENU_KEYS
    local confirmKeys = automation.confirm_keys or DEFAULT_CONFIRM_KEYS
    local keyDelay = automation.key_delay_ms or DEFAULT_KEY_DELAY_MS
    local preDelay = automation.pre_delay_ms or 400

    local tempDir = LrPathUtils.getStandardFilePath("temp")
    local scriptPath = LrPathUtils.child(tempDir, "lightroom-mcp-ai-denoise.ps1")
    local resultPath = LrPathUtils.child(tempDir, "lightroom-mcp-ai-denoise.result")

    pcall(function() LrFileUtils.delete(resultPath) end)

    -- Escape single quotes for PowerShell single-quoted literals ('' is a
    -- single quote inside one). Key sequences themselves are SendKeys syntax
    -- (e.g. "%pe" = Alt+P then E) and must NOT be escaped further.
    local function psQuote(s)
        return (s:gsub("'", "''"))
    end

    local script = table.concat({
        "$ErrorActionPreference = 'Stop'",
        "Add-Type -AssemblyName System.Windows.Forms",
        "$shell = New-Object -ComObject WScript.Shell",
        "try {",
        "  $activated = $shell.AppActivate('" .. psQuote(windowTitle) .. "')",
        "  if (-not $activated) { 'activate-failed' | Out-File -Encoding ascii '" .. psQuote(resultPath) .. "'; exit 2 }",
        "  Start-Sleep -Milliseconds " .. tostring(math.floor(preDelay)),
        "  $shell.SendKeys('" .. psQuote(menuKeys) .. "')",
        "  Start-Sleep -Milliseconds " .. tostring(math.floor(keyDelay)),
        "  $shell.SendKeys('" .. psQuote(confirmKeys) .. "')",
        "  'keys-sent' | Out-File -Encoding ascii '" .. psQuote(resultPath) .. "'",
        "} catch {",
        "  ('error: ' + $_.Exception.Message) | Out-File -Encoding ascii '" .. psQuote(resultPath) .. "'",
        "}",
    }, "\r\n")

    local fh, openErr = io.open(scriptPath, "w")
    if not fh then
        return { ok = false, error = "failed to write helper script: " .. tostring(openErr) }
    end
    fh:write(script)
    fh:close()

    local command = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
        .. scriptPath .. '"'
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

    if resultContent == nil then
        return {
            ok = false,
            error = "SendKeys helper produced no result (execute ok="
                .. tostring(execOk) .. ", status " .. tostring(execResult) .. ")",
        }
    end

    resultContent = resultContent:gsub("^%s+", ""):gsub("%s+$", "")
    if resultContent == "keys-sent" then
        return { ok = true }
    end
    if resultContent == "activate-failed" then
        return { ok = false, error = "could not activate the Lightroom window (title: '" .. windowTitle .. "')" }
    end
    return { ok = false, error = "SendKeys helper failed: " .. resultContent }
end

-- Returns the names (not paths) of every file in `folder`, or nil on error.
local function listFolderNames(folder)
    local ok, names = pcall(function() return LrFileUtils.directoryEntries(folder) end)
    if not ok or type(names) ~= "table" then return nil end
    return names
end

-- Poll `folder` for a DNG that did not exist in `before` and whose name starts
-- with the source file's base name. Returns the new file name or nil.
local function findNewDngName(folder, sourceBase, before)
    local names = listFolderNames(folder)
    if not names then return nil end
    local lowerBase = sourceBase:lower()
    for _, name in ipairs(names) do
        if not before[name] then
            local lowerName = name:lower()
            if lowerName:sub(1, #lowerBase) == lowerBase and lowerName:find("%.dng$") then
                return name
            end
        end
    end
    return nil
end

local function photoIsDenoisable(photo)
    local format = photo:getRawMetadata('fileFormat')
    return format ~= nil and DENOISABLE_FORMATS[format] == true
end

function AIHandler.aiDenoise(args)
    args = args or {}
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local fallback = args.fallback or "manual"
    if fallback ~= "manual" and fallback ~= "none" then
        error("fallback must be 'manual' or 'none'")
    end

    local automation = args.native_automation or {}
    local verifyTimeout = tonumber(automation.verify_timeout_s) or DEFAULT_VERIFY_TIMEOUT_S
    if verifyTimeout < MIN_VERIFY_TIMEOUT_S then verifyTimeout = MIN_VERIFY_TIMEOUT_S end
    if verifyTimeout > MAX_VERIFY_TIMEOUT_S then verifyTimeout = MAX_VERIFY_TIMEOUT_S end

    local catalog = LrApplication.activeCatalog()

    local photo, sourcePath, sourceFolder, sourceBase
    catalog:withReadAccessDo(function()
        photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. tostring(args.photo_id))
        end
        sourcePath = photo:getRawMetadata('path')
    end)

    if not sourcePath then
        error("Photo has no path on disk: " .. tostring(args.photo_id))
    end

    sourceFolder = LrPathUtils.parent(sourcePath)
    sourceBase = LrPathUtils.removeExtension(LrPathUtils.leafName(sourcePath))

    -- Photos the user did not pick must not silently degrade to sliders: if
    -- the source is not RAW/DNG the native path cannot work at all.
    if not photoIsDenoisable(photo) then
        local reason = "AI Denoise requires a RAW or DNG file (this photo is "
            .. tostring(photo:getRawMetadata('fileFormat')) .. ")"
        if fallback == "none" then
            error(reason)
        end
        local manualSettings = buildManualSettings(photo, args.manual_settings)
        catalog:withWriteAccessDo("AI Denoise Manual Fallback", function()
            photo:applyDevelopSettings(manualSettings, "MCP AI Denoise (manual fallback)")
        end)
        return {
            success = true,
            method = "manual_fallback",
            photo_id = photo.localIdentifier,
            reason = reason,
            applied_settings = manualSettings,
            message = reason
                .. ". Applied smart manual noise reduction instead. Convert/export to DNG first if you need the real AI Denoise.",
        }
    end

    -- Snapshot the folder so the new DNG can be told apart from older ones.
    local before = {}
    for _, name in ipairs(listFolderNames(sourceFolder) or {}) do
        before[name] = true
    end

    -- 1. Select the photo so the Photo > Enhance command targets it.
    --    Yields to the UI thread: MUST stay outside any catalog access gate.
    Log.info("ai_denoise: selecting photo " .. tostring(photo.localIdentifier))
    catalog:setSelectedPhotos(photo, { photo })

    -- 2. Fire the menu automation.
    local sendResult = sendNativeDenoiseKeys(automation)
    if not sendResult.ok then
        Log.warn("ai_denoise: native trigger failed: " .. tostring(sendResult.error))
    end

    -- 3. Poll for the new DNG regardless; a mis-reported SendKeys status can
    --    still have delivered the keys, and vice versa.
    local newPhoto = nil
    local newPhotoPath = nil
    do
        local waited = 0
        while waited < verifyTimeout do
            LrTasks.sleep(POLL_INTERVAL_S)
            waited = waited + POLL_INTERVAL_S

            local newName = findNewDngName(sourceFolder, sourceBase, before)
            if newName then
                newPhotoPath = LrPathUtils.child(sourceFolder, newName)
                -- The file exists; wait for the catalog to register it.
                local settleWaited = 0
                while settleWaited < CATALOG_SETTLE_TIMEOUT_S do
                    local resolved = nil
                    catalog:withReadAccessDo(function()
                        resolved = PhotoLookup.resolveOne(catalog, newPhotoPath)
                    end)
                    if resolved then
                        newPhoto = resolved
                        break
                    end
                    LrTasks.sleep(POLL_INTERVAL_S)
                    settleWaited = settleWaited + POLL_INTERVAL_S
                end
                if newPhoto then break end
            end
        end
    end

    if newPhoto and newPhotoPath then
        Log.info("ai_denoise: native Denoise produced " .. newPhotoPath)
        return {
            success = true,
            method = "native",
            photo_id = photo.localIdentifier,
            new_photo_id = newPhoto.localIdentifier,
            new_photo_path = newPhotoPath,
            message = "Adobe AI Denoise applied. A new DNG was created next to the original and stacked in the catalog.",
        }
    end

    local nativeError = sendResult.ok
        and ("no new DNG appeared within " .. verifyTimeout .. "s (check that the Enhance dialog opened and was confirmed)")
        or tostring(sendResult.error)

    if fallback == "none" then
        error("Native AI Denoise failed and fallback is disabled: " .. nativeError)
    end

    -- 4. Manual fallback with a clear report of what happened.
    local manualSettings = buildManualSettings(photo, args.manual_settings)
    catalog:withWriteAccessDo("AI Denoise Manual Fallback", function()
        photo:applyDevelopSettings(manualSettings, "MCP AI Denoise (manual fallback)")
    end)

    Log.warn("ai_denoise: falling back to manual noise reduction")

    return {
        success = true,
        method = "manual_fallback",
        photo_id = photo.localIdentifier,
        native_error = nativeError,
        applied_settings = manualSettings,
        message = "Native AI Denoise could not be verified (" .. nativeError
            .. "). Applied smart manual noise reduction instead. "
            .. "Verify the SendKeys sequence and the Lightroom window title, and keep Lightroom in the foreground.",
    }
end

-- =====================================================================
-- Manual noise reduction (SDK-native sliders)
-- =====================================================================

function AIHandler.setNoiseReduction(args)
    args = args or {}
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end
    if #args.photo_ids > MAX_SPOTS_PER_REQUEST * 20 then
        error("photo_ids must contain at most 1000 photos")
    end

    local settings = {}
    for argName, sdkKey in pairs(MANUAL_NOISE_KEYS) do
        local value = args[argName]
        if value ~= nil then
            if argName == "sharpen_radius" then
                settings[sdkKey] = clampNumber(value, 0.5, 3, argName)
            else
                settings[sdkKey] = clampNumber(value, 0, 100, argName)
            end
        end
    end

    if next(settings) == nil then
        error("at least one noise reduction parameter is required")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}

    catalog:withWriteAccessDo("Set Noise Reduction", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopSettings(settings, "MCP Noise Reduction")
                updatedCount = updatedCount + 1
            else
                table.insert(missingIds, tostring(entry.id))
            end
        end
    end)

    -- Read back the effective noise settings of the first photo so the caller
    -- can confirm what Lightroom actually stored.
    local appliedSettings = nil
    if updatedCount > 0 then
        catalog:withReadAccessDo(function()
            local resolved = PhotoLookup.resolveMany(catalog, { args.photo_ids[1] })
            if resolved[1] and resolved[1].photo then
                local current = resolved[1].photo:getDevelopSettings()
                appliedSettings = {
                    LuminanceSmoothing = current.LuminanceSmoothing,
                    ColorNoiseReduction = current.ColorNoiseReduction,
                    Sharpness = current.Sharpness,
                }
            end
        end)
    end

    Log.info(string.format("Set noise reduction on %d photos", updatedCount))

    return {
        success = true,
        updated = updatedCount,
        missing = missingIds,
        applied = settings,
        verified = appliedSettings,
        message = string.format("Applied noise reduction to %d photos (%d ids not found)",
            updatedCount, #missingIds),
    }
end

return AIHandler
