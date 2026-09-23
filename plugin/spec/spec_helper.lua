-- Common test helpers + LR SDK mock factory.
-- Usage from a spec file:
--   local helper = require 'spec.spec_helper'
--   local catalog, photos = helper.mockCatalog({...})
--   helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
--   local Handler = require 'HandlerSearch'

local M = {}

-- Make plugin sources requireable.
local lfs_ok = pcall(function() return require 'lfs' end)
local sep = package.config:sub(1, 1)
local pluginRoot = "plugin" .. sep .. "LightroomMCP.lrplugin" .. sep .. "?.lua"
if not package.path:find(pluginRoot, 1, true) then
    package.path = package.path .. ";" .. pluginRoot
end

-- Write-gate tracking — the counterpart of the insideReadAccess guard in
-- fakeCatalog, for the failure mode that has now bitten this codebase four
-- times: an LrDevelopController command invoked INSIDE catalog:withWriteAccessDo.
-- Those commands drive the Develop module's UI and open their own catalog
-- transaction, so nesting one inside our own write gate makes real Lightroom
-- reject it every single time with "blocked by another write access call".
-- The old mock was a bare passthrough, so the bug shipped green in
-- reset_develop, apply_auto (x2) and set_process_version. These guards throw
-- the way Lightroom does, which means a handler that nests fails its spec
-- without anyone having to remember to assert it.
--
-- Getters are exempt: only commands take a transaction. The "^get" test keeps
-- the guard correct for SDK functions nobody has written yet.
local writeGateDepth = 0
local developCommandInsideWriteAccess = false

local function blockedByWriteAccess(actionName)
    return "LrCatalog:withWriteAccessDo: could not execute action '"
        .. tostring(actionName) .. "'. It was blocked by another write access "
        .. "call, and no timeout parameters were provided."
end

local function enterWriteGate(actionName)
    if writeGateDepth > 0 then
        error(blockedByWriteAccess(actionName), 0)
    end
    writeGateDepth = writeGateDepth + 1
end

local function leaveWriteGate()
    writeGateDepth = writeGateDepth - 1
end

local function guardDevelopCommand(name)
    if writeGateDepth > 0 and not tostring(name):match("^get") then
        developCommandInsideWriteAccess = true
        error(blockedByWriteAccess(name), 0)
    end
end

-- True if any LrDevelopController command was called inside a write gate
-- during this test. Companion to getQueriedInsideReadAccess().
function M.getDevelopCommandInsideWriteAccess()
    return developCommandInsideWriteAccess
end

-- Wrap an LrDevelopController mock so the guard applies no matter which spec
-- supplied it. Done centrally here rather than per spec, so a future handler
-- cannot opt out by bringing its own controller.
--
-- This is a live proxy, not a snapshot: several specs swap a function in after
-- installImport has run (`ctx.controller.toggleOverlay = function() ... end`),
-- so both the lookup and the call must hit the underlying table at call time.
local function guardController(controller)
    return setmetatable({}, {
        __index = function(_, key)
            if type(controller[key]) ~= "function" then return controller[key] end
            return function(...)
                guardDevelopCommand(key)
                return controller[key](...)
            end
        end,
        __newindex = function(_, key, value) controller[key] = value end,
    })
end

-- Install a mock `import` global. Subsequent `import 'X'` calls return the mock for X.
function M.installImport(modules)
    writeGateDepth = 0
    developCommandInsideWriteAccess = false

    local resolved = {}
    for key, value in pairs(modules) do resolved[key] = value end
    if type(resolved.LrDevelopController) == "table" then
        resolved.LrDevelopController = guardController(resolved.LrDevelopController)
    end

    _G.import = function(name)
        local m = resolved[name]
        if m == nil then
            error("No mock installed for import('" .. tostring(name) .. "')", 2)
        end
        return m
    end
end

-- Default LrLogger stub used by every handler.
function M.defaultLrLogger()
    return setmetatable({}, {
        __call = function()
            return {
                info = function() end,
                warn = function() end,
                error = function() end,
                enable = function() end,
            }
        end,
    })
end

-- Valid Lightroom SDK metadata keys. The real getRawMetadata/getFormattedMetadata
-- THROW on an unsupported key, taking down the enclosing withReadAccessDo. The
-- non-validating mock used to return a value for any key, so a typo'd/invalid key
-- (e.g. `copyrightStatus` for `copyrightState`) shipped green. Validate against
-- this allowlist so specs catch it. Add genuinely-new SDK keys here.
--
-- READ and WRITE vocabularies differ, and listing a write-only key here hides
-- a real bug: get_photo_status read 'label' (the setRawMetadata key for colour
-- labels) and shipped green because the mock accepted it, while real Lightroom
-- answers every call with "Unknown key: label". Reads go through
-- VALID_METADATA_KEYS; keys that are only valid to write belong in
-- WRITE_ONLY_METADATA_KEYS. Reading one of those throws here, exactly as it
-- does in Lightroom.
local VALID_METADATA_KEYS = {}
for _, key in ipairs({
    -- File / catalog
    "fileName", "fileSize", "fileFormat", "path", "dimensions",
    "rating", "colorNameForLabel", "pickStatus", "keywords",
    -- EXIF
    "dateTimeOriginal", "dateTimeDigitized", "cameraMake", "cameraModel",
    "cameraSerialNumber", "lens", "isoSpeedRating", "focalLength",
    "focalLength35mm", "aperture", "shutterSpeed", "exposureBias",
    "exposureProgram", "meteringMode", "flash", "artist", "software",
    "gps", "gpsAltitude",
    -- IPTC content / location / rights
    "title", "caption", "headline", "location", "city", "stateProvince",
    "country", "isoCountryCode", "creator", "copyright", "copyrightState",
    "rightsUsageTerms",
}) do
    VALID_METADATA_KEYS[key] = true
end
local WRITE_ONLY_METADATA_KEYS = { label = true }
M.WRITE_ONLY_METADATA_KEYS = WRITE_ONLY_METADATA_KEYS
M.VALID_METADATA_KEYS = VALID_METADATA_KEYS

local function readMetadata(meta, key)
    -- `__`-prefixed keys are test-internal sentinels (e.g. __appliedSettings)
    -- that specs read back to assert what a handler wrote; never SDK keys.
    if key:sub(1, 2) ~= "__" and WRITE_ONLY_METADATA_KEYS[key] then
        error("Unknown key: \"" .. tostring(key) .. "\"", 0)
    end
    -- An UNLABELLED photo does not read back as nil: Lightroom answers
    -- "gray". Handlers that compared against nil reported every successful
    -- label CLEAR as a mismatch, and passed specs only because this mock was
    -- kinder than the SDK.
    if key == "colorNameForLabel" and meta[key] == nil then
        return "gray"
    end
    if key:sub(1, 2) ~= "__" and not VALID_METADATA_KEYS[key] then
        error("unsupported metadata key '" .. tostring(key)
            .. "' (add it to spec_helper VALID_METADATA_KEYS if it is a real SDK key)", 2)
    end
    return meta[key]
end

-- Build a fake photo with the given metadata table.
-- meta keys correspond to keys passed to getRawMetadata / getFormattedMetadata / localIdentifier.
function M.fakePhoto(meta)
    return {
        -- Test-only window into the closed-over metadata table (e.g. to
        -- assert rotations/snapshots recorded by the SDK-method mocks).
        __meta = meta,
        localIdentifier = meta.localIdentifier or meta.id or "photo-id",
        getRawMetadata = function(_, key) return readMetadata(meta, key) end,
        getFormattedMetadata = function(_, key) return readMetadata(meta, key) end,
        getDevelopSettings = function() return meta.developSettings or {} end,
        addKeyword = function(_, kw)
            meta.__addedKeywords = meta.__addedKeywords or {}
            table.insert(meta.__addedKeywords, kw)
        end,
        removeKeyword = function(_, kw)
            meta.__removedKeywords = meta.__removedKeywords or {}
            table.insert(meta.__removedKeywords, kw)
        end,
        setRawMetadata = function(_, key, value)
            meta[key] = value
            -- Colour labels are written as 'label' and read as
            -- 'colorNameForLabel'. Mirror that here, or a handler's read-back
            -- verification passes in specs only because the mock let it read
            -- the write key back.
            if key == "label" then meta.colorNameForLabel = value end
        end,
        applyDevelopPreset = function(_, preset, plugin)
            meta.__appliedPreset = preset
            meta.__appliedPresetPlugin = plugin
        end,
        applyDevelopSettings = function(_, settings)
            meta.__appliedSettings = settings
        end,
        createVirtualCopy = function(_)
            local copy = M.fakePhoto({
                localIdentifier = (meta.localIdentifier or meta.id or "photo-id") .. "-vc",
                id = (meta.localIdentifier or meta.id or "photo-id") .. "-vc",
                path = meta.path,
                fileName = meta.fileName,
            })
            meta.__virtualCopies = meta.__virtualCopies or {}
            table.insert(meta.__virtualCopies, copy)
            return copy
        end,
        rotateLeft = function(_)
            meta.__rotations = (meta.__rotations or 0) - 1
        end,
        rotateRight = function(_)
            meta.__rotations = (meta.__rotations or 0) + 1
        end,
        createDevelopSnapshot = function(_, name)
            meta.__snapshots = meta.__snapshots or {}
            table.insert(meta.__snapshots, name)
        end,
    }
end

-- Build a fake keyword (catalog:getKeywords() entries).
function M.fakeKeyword(name, photoCount)
    return {
        localIdentifier = "kw-" .. name,
        getName = function() return name end,
        getPhotos = function()
            local photos = {}
            for _ = 1, (photoCount or 0) do table.insert(photos, {}) end
            return photos
        end,
    }
end

-- Build a fake folder (catalog:getFolders() entries).
function M.fakeFolder(opts)
    opts = opts or {}
    local photos = opts.photos or {}
    local children = opts.children or {}
    return {
        getPath = function() return opts.path or "/photos" end,
        getName = function() return opts.name or "photos" end,
        type = function() return opts.folderType or "LrFolder" end,
        getPhotos = function(_, includeSubfolders)
            if not includeSubfolders then return photos end
            local all = {}
            for _, p in ipairs(photos) do table.insert(all, p) end
            local function collectFrom(folder)
                for _, child in ipairs(folder:getChildren() or {}) do
                    for _, p in ipairs(child:getPhotos(false)) do table.insert(all, p) end
                    collectFrom(child)
                end
            end
            collectFrom({ getChildren = function() return children end })
            return all
        end,
        getChildren = function() return children end,
        getParent = function() return opts.parent end,
    }
end

-- Build a fake collection.
function M.fakeCollection(name, photos)
    photos = photos or {}
    local addedPhotos = {}
    return {
        getName = function() return name end,
        type = function() return "LrCollection" end,
        getPhotos = function() return photos end,
        addPhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(addedPhotos, p)
                table.insert(photos, p)
            end
        end,
        getAddedPhotos = function() return addedPhotos end,
    }
end

-- Build a fake collection set for getChildCollectionSets fixtures.
function M.fakeCollectionSet(name, collections)
    collections = collections or {}
    return {
        getName = function() return name end,
        type = function() return "LrCollectionSet" end,
        getChildCollections = function() return collections end,
        getChildCollectionSets = function() return {} end,
    }
end

-- Build a fake catalog. opts:
--   photos: array of fake photos
--   collections: array of fake collections
--   collectionSets: array of fake collection sets
--   folders: array of fake folders
--   keywords: array of fake keywords
function M.fakeCatalog(opts)
    opts = opts or {}
    local photos = opts.photos or {}
    local collections = opts.collections or {}
    local collectionSets = opts.collectionSets or {}
    local createdCollections = {}
    local createdCollectionSets = {}
    local createdKeywords = {}
    local readAccessCount = 0
    local writeAccessCount = 0
    local currentViewFilter = nil
    local viewFilterCalls = 0
    local viewFilterHistory = {}
    local removedPhotos = 0
    -- Tracks whether a catalog query (getTargetPhotos/findPhotos/getAllPhotos)
    -- was invoked while a withReadAccessDo gate was open. The Windows deadlock
    -- (#134/#124) is exactly that nesting, so handlers must keep their query
    -- OUTSIDE the gate; specs assert getQueriedInsideReadAccess() == false.
    local insideReadAccess = false
    local queriedInsideReadAccess = false
    local selectionCall = nil
    local function markQuery()
        if insideReadAccess then queriedInsideReadAccess = true end
    end

    local function photoMatches(photo, criterion)
        local crit = criterion.criteria
        local op = criterion.operation
        if crit == "filename" and op == "any" then
            local name = photo:getFormattedMetadata('fileName')
            if not name then return false end
            return name:lower():find(criterion.value:lower(), 1, true) ~= nil
        elseif crit == "rating" and op == "==" then
            local r = photo:getRawMetadata('rating')
            -- Simplified filters pass numbers, searchDesc rules pass strings.
            local expected = tonumber(criterion.value)
            if expected ~= nil then return r == expected end
            return r == criterion.value
        elseif crit == "rating" and op == ">=" then
            local r = photo:getRawMetadata('rating')
            local bound = tonumber(criterion.value)
            if bound == nil then
                error("fakeCatalog.findPhotos: rating comparison needs a numeric value, got " .. tostring(criterion.value))
            end
            return r ~= nil and r >= bound
        elseif crit == "keywords" and op == "all" then
            local kws = photo:getRawMetadata('keywords') or {}
            local target = criterion.value:lower()
            for _, kw in ipairs(kws) do
                if kw:getName():lower() == target then return true end
            end
            return false
        elseif crit == "captureTime" then
            local t = photo:getRawMetadata('dateTimeOriginal')
            if not t then return false end
            if op == "in" then
                return t >= criterion.value and t <= criterion.value2
            elseif op == ">" then
                return t > criterion.value
            elseif op == "<" then
                return t < criterion.value
            end
        end
        error("fakeCatalog.findPhotos: unsupported criterion " .. tostring(crit) .. "/" .. tostring(op))
    end

    return {
        getAllPhotos = function() markQuery() return photos end,
        getTargetPhotos = function() markQuery() return opts.targetPhotos or photos end,
        findPhotos = function(_, opts)
            markQuery()
            local desc = opts and opts.searchDesc or {}
            local out = {}
            for _, photo in ipairs(photos) do
                local ok = true
                for _, criterion in ipairs(desc) do
                    if not photoMatches(photo, criterion) then
                        ok = false
                        break
                    end
                end
                if ok then table.insert(out, photo) end
            end
            return out
        end,
        getChildCollections = function() return collections end,
        getChildCollectionSets = function() return collectionSets end,
        getFolders = function() return opts.folders or {} end,
        getKeywords = function() return opts.keywords or {} end,
        getCurrentViewFilter = function() return currentViewFilter end,
        setViewFilter = function(_, filter)
            viewFilterCalls = viewFilterCalls + 1
            table.insert(viewFilterHistory, filter)
            currentViewFilter = filter
        end,
        getViewFilterCallCount = function() return viewFilterCalls end,
        getViewFilterHistory = function() return viewFilterHistory end,
        removePhoto = function(_, photo)
            removedPhotos = removedPhotos + 1
            for i, p in ipairs(photos) do
                if p == photo then table.remove(photos, i) return end
            end
        end,
        getRemovedPhotoCount = function() return removedPhotos end,
        withReadAccessDo = function(_, fn)
            readAccessCount = readAccessCount + 1
            insideReadAccess = true
            local ok, err = pcall(fn)
            insideReadAccess = false
            if not ok then error(err, 0) end
        end,
        getQueriedInsideReadAccess = function() return queriedInsideReadAccess end,
        setSelectedPhotos = function(_, activePhoto, selected)
            markQuery()
            selectionCall = { active = activePhoto, photos = selected }
        end,
        getSelectionCall = function() return selectionCall end,
        withWriteAccessDo = function(_, actionName, fn)
            writeAccessCount = writeAccessCount + 1
            enterWriteGate(actionName)
            local ok, err = pcall(fn)
            leaveWriteGate()
            if not ok then error(err, 0) end
        end,
        findPhotoByLocalIdentifier = function(_, id)
            local target = tostring(id)
            for _, p in ipairs(photos) do
                if tostring(p.localIdentifier) == target then return p end
            end
            return nil
        end,
        createCollection = function(_, name)
            local c = M.fakeCollection(name, {})
            table.insert(createdCollections, c)
            table.insert(collections, c)
            return c
        end,
        createCollectionSet = function(_, name, parentSet, position)
            local s = {
                getName = function() return name end,
                type = function() return "LrCollectionSet" end,
                getParent = function() return parentSet end,
                __position = position,
                getChildCollections = function() return {} end,
                getChildCollectionSets = function() return {} end,
            }
            table.insert(createdCollectionSets, s)
            table.insert(collectionSets, s)
            return s
        end,
        createSmartCollection = function(_, name, searchDesc, targetSet, position)
            local c = M.fakeCollection(name, {})
            c.__smartSearchDesc = searchDesc
            c.__smartTargetSet = targetSet
            c.__smartPosition = position
            table.insert(createdCollections, c)
            table.insert(collections, c)
            return c
        end,
        createKeyword = function(_, name)
            local kw = { getName = function() return name end }
            table.insert(createdKeywords, kw)
            return kw
        end,
        addPhoto = function(_, path)
            local p = M.fakePhoto({ path = path, id = path })
            table.insert(photos, p)
            return p
        end,
        getCreatedCollections = function() return createdCollections end,
        getCreatedCollectionSets = function() return createdCollectionSets end,
        getCreatedKeywords = function() return createdKeywords end,
        getReadAccessCount = function() return readAccessCount end,
        getWriteAccessCount = function() return writeAccessCount end,
    }
end

return M
