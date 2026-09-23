local LrApplication = import 'LrApplication'
local LrSelection = import 'LrSelection'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local SelectionHandler = {}

local function buildResult(photo)
    return {
        id = photo.localIdentifier,
        path = photo:getRawMetadata('path'),
        filename = photo:getFormattedMetadata('fileName'),
        rating = photo:getRawMetadata('rating'),
        dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
    }
end

function SelectionHandler.getSelectedPhotos(args)
    args = args or {}
    local catalog = LrApplication.activeCatalog()

    -- floor: the tool schema permits any number, and a fractional offset would
    -- make the page loop index matches[i] with a non-integer key (always nil)
    -- and crash buildResult(nil).
    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    -- Acquire the target set OUTSIDE withReadAccessDo. getTargetPhotos() reads
    -- the live view selection, which yields to the UI thread; called from
    -- inside the read gate on Windows it deadlocks -- the task never returns
    -- and never releases the gate, so the whole bridge wedges until the 30s
    -- server timeout (issues #134, #124). Only the per-photo metadata reads
    -- need the gate; getTargetPhotos() does not. This mirrors get_photo_metadata,
    -- which works because it only does a non-yielding getAllPhotos() pass.
    Log.info("getSelectedPhotos: requesting target photos")
    local matches = catalog:getTargetPhotos() or {}
    local total = #matches
    Log.info(string.format("getSelectedPhotos: getTargetPhotos returned %d", total))

    local last = math.min(offset + limit, total)
    local results = {}
    catalog:withReadAccessDo(function()
        for i = offset + 1, last do
            table.insert(results, buildResult(matches[i]))
        end
    end)

    Log.info(string.format("getSelectedPhotos: returning %d (offset=%d, limit=%d)",
        #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

-- Test-only: kept out of server/src/tool-contracts.ts so it is reachable from
-- the raw TCP probe but never from an MCP client, which must not be able to
-- reorder the user's filmstrip. Lets the e2e playbook stage the selection that
-- get_selected_photos reads back, instead of a human clicking in Lightroom.
function SelectionHandler.setSelection(args)
    args = args or {}
    local ids = args.photo_ids
    if type(ids) ~= "table" or ids[1] == nil then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, ids)

    local photos = {}
    local missing = {}
    local seen = {}
    local selectedCount = 0
    local missingCount = 0
    for _, entry in ipairs(resolved) do
        if entry.photo then
            if not seen[entry.photo] then
                seen[entry.photo] = true
                selectedCount = selectedCount + 1
                photos[selectedCount] = entry.photo
            end
        else
            missingCount = missingCount + 1
            missing[missingCount] = tostring(entry.id)
        end
    end

    if selectedCount == 0 then
        error("No photos matched photo_ids")
    end

    -- Yields to the UI thread, so it must stay OUTSIDE withReadAccessDo for the
    -- same reason getTargetPhotos does (#134/#124). First arg becomes active.
    Log.info(string.format("setSelection: selecting %d (missing %d)", selectedCount, missingCount))
    catalog:setSelectedPhotos(photos[1], photos)

    -- Lightroom ignores photos outside the current view source and leaves the
    -- old selection in place, reporting nothing. Read the selection back so a
    -- caller is never told a selection happened that did not.
    local requested = {}
    for _, photo in ipairs(photos) do
        requested[photo] = true
    end
    local actualCount = 0
    for _, photo in ipairs(catalog:getTargetPhotos() or {}) do
        if requested[photo] then
            actualCount = actualCount + 1
        end
    end

    local result = {
        selected = actualCount,
        requested = selectedCount,
        active = photos[1].localIdentifier,
        missing = missing,
    }
    if actualCount < selectedCount then
        result.warning = string.format(
            "Lightroom selected %d of %d photos: the rest are not in the current view source. "
            .. "Switch Lightroom to a source that contains them, such as All Photographs.",
            actualCount, selectedCount)
    end
    return result
end

-- =====================================================================
-- select_photos — set the Lightroom UI selection by photo ids or mode
-- =====================================================================
--
-- Ported from znznzna/lightroom-cli (MIT) setSelectedPhotos/SelectionModule
-- and exposed as a first-class tool: selecting photos drives every
-- LrSelection-based command (flags, rating, labels) and stages the photo
-- the Develop module loads. catalog:setSelectedPhotos yields to the UI
-- thread, so it runs OUTSIDE any catalog gate (#134/#124), like the
-- test-only setSelection above; the two share the read-back verification.

function SelectionHandler.selectPhotos(args)
    args = args or {}
    local ids = args.photo_ids
    local mode = args.mode

    if ids == nil and mode == nil then
        error("photo_ids or mode is required")
    end
    if ids ~= nil and mode ~= nil then
        error("pass either photo_ids or mode, not both")
    end

    local catalog = LrApplication.activeCatalog()

    if mode ~= nil then
        local MODE_COMMANDS = {
            all = LrSelection.selectAll,
            none = LrSelection.selectNone,
            inverse = LrSelection.selectInverse,
            deselect_others = LrSelection.deselectOthers,
        }
        local command = MODE_COMMANDS[mode]
        if not command then
            error("mode must be one of: all, none, inverse, deselect_others")
        end

        -- LrSelection commands act on the UI selection directly (no catalog
        -- gate involved — same family as the flag commands in set_flags).
        local ok, err = pcall(command)
        if not ok then
            error("LrSelection command for mode '" .. mode .. "' failed: " .. tostring(err))
        end

        Log.info("selectPhotos: mode=" .. mode)

        return {
            success = true,
            mode = mode,
            message = "Selection mode applied: " .. mode,
        }
    end

    if type(ids) ~= "table" or ids[1] == nil then
        error("photo_ids must be a non-empty array")
    end

    local resolved = PhotoLookup.resolveMany(catalog, ids)

    local photos = {}
    local missing = {}
    local seen = {}
    local selectedCount = 0
    local missingCount = 0
    for _, entry in ipairs(resolved) do
        if entry.photo then
            if not seen[entry.photo] then
                seen[entry.photo] = true
                selectedCount = selectedCount + 1
                photos[selectedCount] = entry.photo
            end
        else
            missingCount = missingCount + 1
            missing[missingCount] = tostring(entry.id)
        end
    end

    if selectedCount == 0 then
        error("No photos matched photo_ids")
    end

    -- Yields to the UI thread, so it must stay OUTSIDE withReadAccessDo for
    -- the same reason getTargetPhotos does (#134/#124). First arg becomes active.
    Log.info(string.format("selectPhotos: selecting %d (missing %d)", selectedCount, missingCount))
    catalog:setSelectedPhotos(photos[1], photos)

    -- Lightroom ignores photos outside the current view source and leaves the
    -- old selection in place, reporting nothing. Read the selection back so a
    -- caller is never told a selection happened that did not.
    local requested = {}
    for _, photo in ipairs(photos) do
        requested[photo] = true
    end
    local actualCount = 0
    for _, photo in ipairs(catalog:getTargetPhotos() or {}) do
        if requested[photo] then
            actualCount = actualCount + 1
        end
    end

    Log.info(string.format("selectPhotos: Lightroom reports %d of %d", actualCount, selectedCount))

    local result = {
        success = actualCount > 0,
        selected = actualCount,
        requested = selectedCount,
        active = photos[1].localIdentifier,
        missing = missing,
        message = string.format("Selected %d of %d photo(s)", actualCount, selectedCount),
    }
    if actualCount < selectedCount then
        result.warning = string.format(
            "Lightroom selected %d of %d photos: the rest are not in the current view source. "
            .. "Switch Lightroom to a source that contains them, such as All Photographs.",
            actualCount, selectedCount)
    end
    return result
end

-- =====================================================================
-- navigate_photo — filmstrip navigation (next / previous)
-- =====================================================================
--
-- LrSelection.nextPhoto()/previousPhoto() move the filmstrip the way the
-- arrow keys do; the loupe view follows. Outside any gate (LrSelection
-- family, cf. set_flags). Ported from lightroom-cli SelectionModule.

function SelectionHandler.navigatePhoto(args)
    args = args or {}
    local direction = args.direction or "next"
    if direction ~= "next" and direction ~= "previous" then
        error("direction must be 'next' or 'previous'")
    end

    local command = (direction == "next") and LrSelection.nextPhoto
        or LrSelection.previousPhoto
    if type(command) ~= "function" then
        error("LrSelection navigation is not available")
    end

    local ok, err = pcall(command)
    if not ok then
        error("could not navigate to " .. direction .. " photo: " .. tostring(err))
    end

    -- Report which photo is active after the move, so the caller can chain
    -- get_photo_preview / develop work without a second round-trip.
    local catalog = LrApplication.activeCatalog()
    local activeId, activePath = nil, nil
    pcall(function()
        local targets = catalog:getTargetPhotos() or {}
        local active = targets[1]
        if active then
            activeId = active.localIdentifier
            activePath = active:getRawMetadata('path')
        end
    end)

    Log.info("navigatePhoto: " .. direction)

    local result = {
        success = true,
        direction = direction,
        message = "Moved to " .. direction .. " photo",
    }
    if activeId ~= nil then
        result.active = { id = activeId, path = activePath }
    end
    return result
end

return SelectionHandler
