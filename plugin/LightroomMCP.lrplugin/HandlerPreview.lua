local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local PreviewHandler = {}

-- =====================================================================
-- get_photo_preview — let the AI actually SEE the photo
-- =====================================================================
--
-- The Lightroom SDK can render a JPEG of any catalog photo through
-- photo:requestJpegThumbnail(width, height, callback). The callback runs
-- asynchronously on a background render task, so we poll a completion
-- flag with LrTasks.sleep() instead of blocking.
--
-- The JPEG bytes are written to a file next to the MCP token
-- (<home>/.config/lightroom-mcp/previews/) so the MCP server can read
-- them back and attach the image inline to the tool response (Claude
-- Desktop renders image content blocks in the conversation). Writing to
-- disk keeps the large binary out of the line-delimited JSON socket
-- protocol entirely.
--
-- Old previews are pruned to bound disk usage: the folder keeps the
-- newest MAX_FILES_KEPT files (filenames embed a unix timestamp, so a
-- lexicographic sort on the timestamp field approximates mtime order
-- without a stat() API, which LrFileUtils does not expose).

local NAMED_SIZES = {
    small = 240,
    medium = 640,
    large = 1024,
}

local MIN_PIXELS = 32
local MAX_PIXELS = 2048
local RENDER_TIMEOUT_S = 60
-- Pause before the single retry. Long enough for Lightroom to get past a
-- momentary "loading" state, short enough not to double the wait on a photo
-- that genuinely cannot render.
local RENDER_RETRY_DELAY_S = 2.0
local POLL_INTERVAL_S = 0.1
local MAX_FILES_KEPT = 60
local FILE_PREFIX = "preview_"

-- Once a rendition has arrived, keep listening this long for a better one
-- before settling. requestJpegThumbnail delivers progressively improved
-- renditions for a single request (see the note above the render loop).
local RENDER_SETTLE_S = 1.0

-- How long to keep hoping for a correctly-sized rendition once a wrong-sized
-- one has arrived. Lightroom frequently has nothing better to offer, so this
-- stays short: the honest report is worth more than the wait.
local WRONG_SIZE_GRACE_S = 4.0

-- JPEG framing: SOI at the start, EOI at the end. A truncated or non-JPEG
-- buffer fails this, which is the difference between writing a broken file
-- and saying what actually came back.
local function isCompleteJpeg(data)
    if type(data) ~= "string" or #data < 4 then return false end
    return data:sub(1, 2) == "\255\216" and data:sub(-2) == "\255\217"
end

-- Real pixel dimensions, read from the JPEG's frame header (SOF0..SOF15,
-- excluding the non-frame markers C4/C8/CC).
--
-- This is not a nicety. requestJpegThumbnail does NOT honour the size it is
-- asked for in this Lightroom build: measured on one photo, a 240px request
-- came back as the full 6000x4000 original (705 KB), a 640px request as
-- 960x640, and — after any develop change — every request regardless of size
-- came back as the same cached 320x213 thumbnail. A caller that trusts
-- size_px is looking at something other than what it asked for, and after an
-- edit it is looking at the photo as it was BEFORE the edit. Measuring the
-- bytes is the only way to know.
local function jpegDimensions(data)
    local i = 3 -- skip SOI
    local len = #data
    while i < len - 8 do
        if data:byte(i) ~= 0xFF then
            i = i + 1
        else
            local marker = data:byte(i + 1)
            if marker == 0xD8 or marker == 0xD9
                or (marker >= 0xD0 and marker <= 0xD7) then
                i = i + 2
            elseif marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local height = data:byte(i + 5) * 256 + data:byte(i + 6)
                local width = data:byte(i + 7) * 256 + data:byte(i + 8)
                return width, height
            else
                local segment = data:byte(i + 2) * 256 + data:byte(i + 3)
                if segment < 2 then return nil end
                i = i + 2 + segment
            end
        end
    end
    return nil
end

-- Lightroom does not render to the exact size asked for: it serves the nearest
-- level of its standard preview pyramid at or above it (measured on a 6000x4000
-- photo: 240 -> 320x213, 640 -> 960x640, 1024 -> 1920x1280). So an exact match
-- is the wrong test. What matters is staying inside a band:
--
--   * smaller than requested  -> a stale cached thumbnail. This is the
--     dangerous one: after a develop change Lightroom serves the rendition it
--     had BEFORE the edit, so the image silently does not show the edit.
--   * far larger than requested -> the full-resolution original (a 240px
--     request returning 6000x4000 at 705 KB is what broke this tool).
local OVERSIZE_FACTOR = 4

local function renditionFitness(data, pixelSize)
    local w, h = jpegDimensions(data)
    if not w then return "unknown", nil, nil end
    local longEdge = math.max(w, h)
    if longEdge < pixelSize then return "too_small", w, h end
    if longEdge > pixelSize * OVERSIZE_FACTOR then return "too_large", w, h end
    return "ok", w, h
end

local function previewsDir()
    local config = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("home"), ".config")
    local base = LrPathUtils.child(
        LrPathUtils.child(config, "lightroom-mcp"), "previews")
    LrFileUtils.createAllDirectories(base)
    return base
end

-- "DSC_0123 (cópia).NEF" -> "dsc_0123_cpa" : Windows-safe, ascii-ish.
local function sanitizeBase(filename)
    local base = filename or "photo"
    base = base:gsub("%.[^%.]*$", "") -- drop extension
    base = base:lower():gsub("[^%w%-_]", "")
    if #base > 40 then base = base:sub(1, 40) end
    if base == "" then base = "photo" end
    return base
end

-- Delete oldest generated previews past MAX_FILES_KEPT. Filenames are
-- preview_<id>_<size>px_<timestamp>.jpg; extracting the timestamp keeps
-- the sort stable across ids/sizes. Best-effort, never fatal.
local function pruneOldPreviews(dir)
    -- directoryEntries is the Lightroom SDK API: returns an array of file
    -- names in `dir`. (directoryContents does not exist in the SDK and used
    -- to crash the handler AFTER a successful preview write.)
    local ok, entries = pcall(function() return LrFileUtils.directoryEntries(dir) end)
    if not ok or type(entries) ~= "table" then return end
    local stamped = {}
    for _, name in ipairs(entries) do
        local ts = name:match("^" .. FILE_PREFIX .. ".-(%d+)%.jpg$")
        if ts then table.insert(stamped, { name = name, ts = ts }) end
    end
    if #stamped <= MAX_FILES_KEPT then return end
    table.sort(stamped, function(a, b) return a.ts < b.ts end)
    for i = 1, #stamped - MAX_FILES_KEPT do
        pcall(function() LrFileUtils.delete(LrPathUtils.child(dir, stamped[i].name)) end)
    end
end

function PreviewHandler.getPhotoPreview(args)
    args = args or {}
    if not args.photo_id then
        error("photo_id is required")
    end

    local requested = args.size or "medium"
    local pixelSize
    if type(requested) == "string" then
        pixelSize = NAMED_SIZES[requested]
        if not pixelSize then
            error("size must be 'small', 'medium', 'large' or a number of pixels")
        end
    elseif type(requested) == "number" then
        pixelSize = math.floor(requested)
        if pixelSize < MIN_PIXELS or pixelSize > MAX_PIXELS then
            error(string.format("size must be between %d and %d pixels", MIN_PIXELS, MAX_PIXELS))
        end
    else
        error("size must be 'small', 'medium', 'large' or a number of pixels")
    end

    local catalog = LrApplication.activeCatalog()

    local photo, filename, dimensions
    catalog:withReadAccessDo(function()
        photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if photo then
            filename = photo:getFormattedMetadata('fileName')
            dimensions = photo:getRawMetadata('dimensions')
        end
    end)

    if not photo then
        error("No photo matched photo_id")
    end

    -- requestJpegThumbnail renders asynchronously and invokes its callback
    -- from a background task; both the render and the poll sleep yield, so
    -- they stay OUTSIDE any catalog access gate (issues #134/#124).
    --
    -- The callback fires MORE THAN ONCE for a single request. Lightroom
    -- delivers progressively better renditions — commonly a cached or
    -- placeholder frame first and the real render after — and while the
    -- render engine is still loading the file it can deliver a transient
    -- errorMsg in between. Treating the first callback as final is what made
    -- this tool hand back a blank image, and fail with "error loading thumb"
    -- on photos that render perfectly in the UI.
    --
    -- So: accept every rendition, keep the last COMPLETE JPEG (later ones are
    -- better), and treat an error as terminal only if nothing valid ever
    -- arrives. Every rendition is recorded so the response can say what
    -- Lightroom actually delivered instead of guessing.
    local best, lastError, bestFitness, renditions

    -- One render attempt, factored out so a failure can be retried once.
    -- "error loading thumb" is not always a photo that cannot render: it is
    -- also what Lightroom says while it is rebuilding previews, and asking
    -- again a moment later then succeeds. Measured on a photo whose preview
    -- cache had been invalidated by a develop change.
    local function attemptRender()
        best, lastError, bestFitness = nil, nil, "unknown"
        renditions = {}
        local settledFor = 0

        photo:requestJpegThumbnail(pixelSize, pixelSize, function(jpg, err)
        if err then
            lastError = tostring(err)
            table.insert(renditions, { error = tostring(err) })
            return
        end
        local size = (type(jpg) == "string") and #jpg or 0
        local complete = isCompleteJpeg(jpg)
        local fitness, w, h = "unknown", nil, nil
        if complete then
            fitness, w, h = renditionFitness(jpg, pixelSize)
        end
        table.insert(renditions, {
            bytes = size, complete_jpeg = complete,
            width = w, height = h, fitness = fitness,
        })
        if complete then
            -- A usable rendition wins outright; anything else is kept only as
            -- a fallback while we keep listening for a better one.
            if fitness == "ok" or best == nil then
                best = jpg
                bestFitness = fitness
            end
            settledFor = 0 -- a better rendition may still be on its way
        end
    end)

        local waited = 0
        while waited < RENDER_TIMEOUT_S do
            LrTasks.sleep(POLL_INTERVAL_S)
            waited = waited + POLL_INTERVAL_S
            if best ~= nil then
                settledFor = settledFor + POLL_INTERVAL_S
                if bestFitness == "ok" then
                    if settledFor >= RENDER_SETTLE_S then break end
                elseif settledFor >= WRONG_SIZE_GRACE_S then
                    -- Only a wrong-size rendition arrived. Lightroom often has
                    -- no better one to give (it serves its cache), so stop
                    -- waiting the full timeout and report what we got.
                    break
                end
            end
        end
    end

    attemptRender()
    local retried = false
    if best == nil and lastError ~= nil then
        LrTasks.sleep(RENDER_RETRY_DELAY_S)
        retried = true
        attemptRender()
    end

    if best == nil then
        local detail = string.format(" (%d callback(s) received", #renditions)
        for _, r in ipairs(renditions) do
            if r.error then
                detail = detail .. "; error: " .. r.error
            else
                detail = detail .. string.format("; %d bytes, complete_jpeg=%s",
                    r.bytes, tostring(r.complete_jpeg))
            end
        end
        detail = detail .. ")"

        if lastError then
            local hint = ""
            if lastError:find("thumb", 1, true) or lastError:find("loading", 1, true) then
                -- The message Lightroom gives is the same whether the file is
                -- unreadable or its preview cache is stale, so say which one is
                -- likely and how to clear it. A develop change -- masks
                -- especially -- can invalidate the pyramid for one photo while
                -- every other photo still renders.
                hint = ". This usually means this photo's preview cache is stale "
                    .. "rather than the file being unreadable, especially right "
                    .. "after a develop change. Rebuild it in Lightroom: Library "
                    .. "> Previews > Build Standard-Sized Previews, with the photo "
                    .. "selected. If other photos render fine, that is the cause"
            end
            if retried then
                hint = hint .. ". Already retried once after "
                    .. tostring(RENDER_RETRY_DELAY_S) .. "s"
            end
            error("Lightroom failed to render the preview: " .. lastError .. detail .. hint)
        end
        if #renditions == 0 then
            error(string.format(
                "Timed out after %ds waiting for Lightroom to render the preview. "
                .. "Lightroom was reachable -- it took the request and never "
                .. "answered -- so this is a slow or blocked render, NOT a dead "
                .. "plugin: a photo pending standard previews, or an import, "
                .. "export or preview rebuild running in the background. Retry "
                .. "once that finishes", RENDER_TIMEOUT_S))
        end
        error("Lightroom returned no complete JPEG for this photo" .. detail)
    end

    local jpegData = best

    local dir = previewsDir()
    local outName = string.format("%sp%d_%dpx_%d.jpg",
        FILE_PREFIX, photo.localIdentifier or 0, pixelSize, os.time())
    local outPath = LrPathUtils.child(dir, outName)

    local fh, openErr = io.open(outPath, "wb")
    if not fh then
        error("failed to write preview file: " .. tostring(openErr))
    end
    local wrote, writeErr = fh:write(jpegData)
    local closed, closeErr = fh:close()
    if not wrote then
        error("failed to write preview file: " .. tostring(writeErr))
    end
    if not closed then
        error("failed to flush preview file: " .. tostring(closeErr))
    end

    -- Report the size of the file on disk, not of the buffer we meant to
    -- write: a short write would otherwise be reported as a full one.
    local bytesOnDisk = #jpegData
    local verify = io.open(outPath, "rb")
    if verify then
        bytesOnDisk = verify:seek("end") or bytesOnDisk
        verify:close()
    end

    pcall(pruneOldPreviews, dir) -- never fail the response over pruning

    Log.info(string.format("getPhotoPreview: wrote %s (%d bytes, %dpx, %d rendition(s))",
        outPath, bytesOnDisk, pixelSize, #renditions))

    local result = {
        success = true,
        file_path = outPath,
        size_bytes = bytesOnDisk,
        mime_type = "image/jpeg",
        size_px = pixelSize,
        -- What Lightroom actually delivered for this one request. Diagnostic:
        -- more than one entry is the normal multi-rendition case.
        renditions_received = #renditions,
        photo = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
            filename = filename,
            width = dimensions and dimensions.width or nil,
            height = dimensions and dimensions.height or nil,
        },
        -- Marker consumed by the MCP server (tool-handler.ts): the JPEG is
        -- on disk and small enough to inline as an MCP image content block.
        image_attached_by_server = true,
        -- Says what the plugin did. Whether the image ends up attached is
        -- decided later by tool-handler.ts, which can still fall back to a
        -- warning, so this must not claim it.
        message = string.format("Preview written to %s (%d bytes, %dpx)",
            outPath, bytesOnDisk, pixelSize),
    }

    local renderedW, renderedH = jpegDimensions(jpegData)
    if renderedW then
        result.rendered_width = renderedW
        result.rendered_height = renderedH
    end

    local actual = renderedW and (renderedW .. "x" .. renderedH) or "an unreadable"
    result.size_usable = (bestFitness == "ok")
    if bestFitness == "too_small" then
        -- The dangerous one, and the one this tool used to hide.
        result.warning = string.format(
            "Lightroom returned a %s rendition for a %dpx request — SMALLER than "
            .. "asked for, which means it served a cached thumbnail. After a "
            .. "develop change that cache can predate the edit, so this image "
            .. "may show the photo as it was BEFORE it. Do not treat it as "
            .. "proof of an edit: re-check in Lightroom, or export the photo "
            .. "for an authoritative render.", actual, pixelSize)
    elseif bestFitness == "too_large" then
        result.warning = string.format(
            "Lightroom returned a %s rendition for a %dpx request — far larger "
            .. "than asked for (it fell back to the full-resolution original). "
            .. "The pixels are real, but the file is much bigger than intended "
            .. "and may be too large for a client to display.", actual, pixelSize)
    elseif bestFitness == "unknown" then
        result.warning = "Could not read the rendition's dimensions, so its "
            .. "size could not be checked against the request."
    end

    return result
end

return PreviewHandler
