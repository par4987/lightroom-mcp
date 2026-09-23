local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local SpotsHandler = {}

-- =====================================================================
-- Spot removal (the Develop module's spot heal/clone tool)
-- =====================================================================
--
-- Lightroom stores spot removal in the `RetouchInfo` develop setting. The
-- SDK returns it as a table that is a LIST of spot strings; each string is
-- the classic ACR flat format:
--
--   ( x, y ), ( type ), ( srcX, srcY ), ( radius ), ( f ), ( o ), ( flags )
--
-- where x/y/srcX/srcY are normalized coordinates (0..1), type is "heal" or
-- "clone", radius is normalized, and the trailing groups are preserved
-- verbatim when round-tripping. Because Adobe does not document this format,
-- this handler never rewrites existing entries (they are appended to
-- byte-identical) and verifies the write by reading the photo back.

local MAX_SPOTS_PER_REQUEST = 50

local function clamp01(v)
    if v == nil then return 0 end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

SpotsHandler.clamp01 = clamp01

local function requirePhotoId(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end
end

-- Extract every "( ... )" group from a flat spot string.
local function extractGroups(s)
    local groups = {}
    for group in s:gmatch("%b()") do
        table.insert(groups, group:sub(2, -2))
    end
    return groups
end

local function parseNumberList(group)
    local numbers = {}
    for token in group:gmatch("[-+]?%d+%.?%d*") do
        table.insert(numbers, tonumber(token))
    end
    return numbers
end

-- Parse one flat spot string into a descriptive table. Unknown/extra groups
-- are preserved raw so callers always see the original data.
function SpotsHandler.parseSpotString(s)
    if type(s) ~= "string" or s == "" then return nil end
    local groups = extractGroups(s)
    if #groups < 4 then return nil end

    local center = parseNumberList(groups[1])
    local kind = groups[2] and groups[2]:gsub("^%s+", ""):gsub("%s+$", "") or nil
    local source = parseNumberList(groups[3])
    local radius = tonumber(groups[4]:match("[-+]?%d+%.?%d*"))

    local rawTail = {}
    for i = 5, #groups do
        -- Trim so round-trips keep the canonical "( 1 ), ( 1 ), ( 0 )" spacing
        -- regardless of how much whitespace the source string carried.
        table.insert(rawTail, (groups[i]:gsub("^%s+", ""):gsub("%s+$", "")))
    end

    return {
        x = center[1],
        y = center[2],
        type = (kind == "clone") and "clone" or "heal",
        source_x = source[1],
        source_y = source[2],
        radius = radius,
        tail = rawTail,
        raw = s,
    }
end

-- Serialize one spot back into the flat format. The tail groups are kept
-- verbatim from the original entry when available.
local function buildSpotString(spot)
    local fmt = string.format
    local function num(v)
        return fmt("%.6f", v)
    end

    local x = clamp01(spot.x)
    local y = clamp01(spot.y)
    local radius = tonumber(spot.radius) or 0.05
    if radius < 0 then radius = 0.05 end
    if radius > 1 then radius = 1 end

    local kind = (spot.type == "clone") and "clone" or "heal"

    -- Source defaults to an offset left of the spot; Lightroom will usually
    -- recompute a better one automatically, but a deterministic fallback
    -- guarantees the heal never samples the spot itself.
    local srcX = tonumber(spot.source_x)
    local srcY = tonumber(spot.source_y)
    if srcX == nil or srcY == nil then
        srcX = x - (radius * 3)
        if srcX < 0 then srcX = x + (radius * 3) end
        if srcX > 1 then srcX = clamp01(x) end
        srcY = y
    end

    local tail
    if type(spot.tail) == "table" and #spot.tail >= 3 then
        tail = { spot.tail[1], spot.tail[2], spot.tail[3] }
    else
        tail = { "1", "1", "0" }
    end

    return "( " .. num(x) .. ", " .. num(y) .. " ), ( " .. kind .. " ), ( "
        .. num(srcX) .. ", " .. num(srcY) .. " ), ( " .. num(radius)
        .. " ), ( " .. tail[1] .. " ), ( " .. tail[2] .. " ), ( " .. tail[3] .. " )"
end

function SpotsHandler.clamp01(v)
    return clamp01(v)
end

-- Normalize whatever getDevelopSettings() returned into an array of strings.
-- Observed shapes: nil, {}, { "spot1" }, { "spot1", "spot2" }, or a single
-- string (defensive). Tables of tables (newer formats) are passed through
-- untouched so data is never corrupted by a guess.
local function retouchEntriesToTable(retouchInfo)
    if retouchInfo == nil then return {}, nil end
    if type(retouchInfo) == "string" then
        return { retouchInfo }, "string"
    end
    if type(retouchInfo) ~= "table" then
        return {}, nil
    end

    local strings = {}
    local others = {}
    for _, entry in ipairs(retouchInfo) do
        if type(entry) == "string" then
            table.insert(strings, entry)
        else
            table.insert(others, entry)
        end
    end
    return strings, (next(others) ~= nil) and others or nil
end

local function readRetouchInfo(photo)
    local settings = photo:getDevelopSettings()
    return retouchEntriesToTable(settings.RetouchInfo)
end

local function applyRetouchInfo(photo, entries, historyName)
    photo:applyDevelopSettings({
        EnableRetouch = (#entries > 0),
        RetouchInfo = entries,
    }, historyName)
end

local function resolveOnePhoto(catalog, photoId)
    local photo = nil
    catalog:withReadAccessDo(function()
        photo = PhotoLookup.resolveOne(catalog, photoId)
    end)
    if not photo then
        error("Photo not found: " .. tostring(photoId))
    end
    return photo
end

function SpotsHandler.getSpots(args)
    args = args or {}
    requirePhotoId(args)

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    local entries, others = readRetouchInfo(photo)
    local spots = {}
    for _, entry in ipairs(entries) do
        local parsed = SpotsHandler.parseSpotString(entry)
        if parsed then
            table.insert(spots, parsed)
        else
            -- Not the classic flat format; surface it raw instead of hiding it.
            table.insert(spots, { raw = entry, unparsed = true })
        end
    end

    Log.info(string.format("get_spots: %d spots on photo %s", #spots, tostring(args.photo_id)))

    return {
        success = true,
        photo_id = photo.localIdentifier,
        count = #spots,
        spots = spots,
        additional_raw_entries = others,
    }
end

function SpotsHandler.addSpots(args)
    args = args or {}
    requirePhotoId(args)

    local newSpots = args.spots
    if type(newSpots) ~= "table" or #newSpots == 0 then
        error("spots is required (array of {x, y, radius, type, source_x?, source_y?})")
    end
    if #newSpots > MAX_SPOTS_PER_REQUEST then
        error("spots must contain at most " .. MAX_SPOTS_PER_REQUEST .. " entries")
    end

    for i, spot in ipairs(newSpots) do
        if type(spot) ~= "table" or spot.x == nil or spot.y == nil then
            error("spots[" .. i .. "] must include numeric x and y (normalized 0..1)")
        end
        if spot.type ~= nil and spot.type ~= "heal" and spot.type ~= "clone" then
            error("spots[" .. i .. "].type must be 'heal' or 'clone'")
        end
    end

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    -- Existing entries are preserved byte-identical.
    local entries = readRetouchInfo(photo)
    local beforeCount = #entries

    for _, spot in ipairs(newSpots) do
        table.insert(entries, buildSpotString(spot))
    end

    local appliedSettings
    catalog:withWriteAccessDo("Add Spot Removal", function()
        applyRetouchInfo(photo, entries, "MCP Add Spots")
        appliedSettings = true
    end)

    -- Verify by reading back: if this Lightroom version refuses RetouchInfo
    -- writes, say so instead of reporting success.
    local afterEntries, _ = readRetouchInfo(photo)
    local verified = #afterEntries
    local took = verified > beforeCount

    Log.info(string.format("add_spots: %d before, %d after on photo %s",
        beforeCount, verified, tostring(args.photo_id)))

    if not took then
        return {
            success = false,
            photo_id = photo.localIdentifier,
            before_count = beforeCount,
            after_count = verified,
            applied = false,
            message = "Lightroom did not accept the RetouchInfo write on this version. "
                .. "Draw one spot manually on the photo, then retry: existing entries are "
                .. "used as a template and round-trip safely.",
        }
    end

    return {
        success = true,
        applied = true,
        photo_id = photo.localIdentifier,
        before_count = beforeCount,
        after_count = verified,
        added = #newSpots,
        message = string.format("Added %d spot(s); photo now has %d.", #newSpots, verified),
    }
end

function SpotsHandler.clearSpots(args)
    args = args or {}
    requirePhotoId(args)

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    local entries, _ = readRetouchInfo(photo)
    local beforeCount = #entries

    catalog:withWriteAccessDo("Clear Spot Removal", function()
        applyRetouchInfo(photo, {}, "MCP Clear Spots")
    end)

    local afterEntries, _ = readRetouchInfo(photo)
    local cleared = #afterEntries == 0

    Log.info(string.format("clear_spots: %d before, %d after on photo %s",
        beforeCount, #afterEntries, tostring(args.photo_id)))

    return {
        success = cleared,
        photo_id = photo.localIdentifier,
        before_count = beforeCount,
        after_count = #afterEntries,
        message = cleared
            and string.format("Removed all %d spot(s).", beforeCount)
            or string.format("Clear was not verified (%d spots still present); this Lightroom version may require removing them from the Develop panel.", #afterEntries),
    }
end

return SpotsHandler
