-- HandlerCatalog.lua
-- Catalog-level inventory tools: folders, keyword tree and the Library view
-- filter. Ported from znznzna/lightroom-cli (MIT) CatalogModule.lua and
-- adapted to this plugin's gate/verification conventions.

local LrApplication = import 'LrApplication'

local Paging = require 'Paging'
local Log = require 'Log'

local CatalogHandler = {}

-- =====================================================================
-- list_folders — folder tree with photo counts
-- =====================================================================
--
-- LrCatalog:getFolders() returns the root folders shown in the Folders
-- panel; each LrFolder exposes getPath()/getName()/getPhotos(false|true)/
-- getChildren()/getParent(). Folders have no localIdentifier, so the path
-- doubles as the id (same convention as lightroom-cli). The tree is walked
-- inside a read gate — these are plain catalog reads like the collection
-- enumeration in HandlerCollections (unlike getAllPhotos/findPhotos, they
-- do not yield, see issues #124/#134 for the calls that must stay outside).

function CatalogHandler.listFolders(args)
    args = args or {}
    local includeSubfolders = args.include_subfolders == true

    local catalog = LrApplication.activeCatalog()

    local folders = nil
    catalog:withReadAccessDo(function()
        folders = catalog:getFolders() or {}
    end)

    local function describeFolder(folder, depth)
        local path = folder:getPath()
        local entry = {
            id = path,
            name = folder:getName(),
            path = path,
            type = folder:type(),
            depth = depth,
            photo_count = #(folder:getPhotos(false) or {}),
            total_photo_count = #(folder:getPhotos(true) or {}),
        }

        local parent = folder:getParent()
        if parent then
            entry.parent = parent:getPath()
        end

        if includeSubfolders then
            entry.subfolders = {}
            local children = folder:getChildren() or {}
            for _, child in ipairs(children) do
                table.insert(entry.subfolders, describeFolder(child, depth + 1))
            end
        end

        return entry
    end

    local result = {}
    for _, folder in ipairs(folders) do
        table.insert(result, describeFolder(folder, 0))
    end

    -- Paging applies to ROOT folders. With include_subfolders each entry still
    -- carries its whole subtree, so a page is a page of trees, not of folders.
    local page, meta = Paging.slice(result, args)

    Log.info(string.format("listFolders: %d/%d root folder(s), subfolders=%s",
        meta.count, meta.total, tostring(includeSubfolders)))

    return {
        success = true,
        folders = page,
        count = meta.count,
        total = meta.total,
        offset = meta.offset,
        limit = meta.limit,
        has_more = meta.has_more,
        include_subfolders = includeSubfolders,
        message = string.format("Found %d root folder(s) (showing %d)",
            meta.total, meta.count),
    }
end

-- =====================================================================
-- list_keywords — keyword tree entries with photo counts
-- =====================================================================
--
-- LrCatalog:getKeywords() returns the top-level keyword objects; each one
-- exposes getName()/getPhotos(). The SDK does not expose a child-keyword
-- walk, so this lists the flat top-level set (same coverage as
-- lightroom-cli's `catalog keywords`). Use set_keywords to attach them.

function CatalogHandler.listKeywords(args)
    args = args or {}

    local catalog = LrApplication.activeCatalog()

    local keywords = nil
    catalog:withReadAccessDo(function()
        keywords = catalog:getKeywords() or {}
    end)

    local result = {}
    for _, keyword in ipairs(keywords) do
        local ok, name = pcall(function() return keyword:getName() end)
        local okCount, photos = pcall(function() return keyword:getPhotos() end)
        table.insert(result, {
            id = keyword.localIdentifier,
            name = ok and name or nil,
            photo_count = (okCount and type(photos) == "table") and #photos or 0,
        })
    end

    table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)

    local page, meta = Paging.slice(result, args)

    Log.info(string.format("listKeywords: %d/%d keyword(s)", meta.count, meta.total))

    return {
        success = true,
        keywords = page,
        count = meta.count,
        total = meta.total,
        offset = meta.offset,
        limit = meta.limit,
        has_more = meta.has_more,
        message = string.format("Found %d top-level keyword(s) (showing %d)",
            meta.total, meta.count),
    }
end

-- =====================================================================
-- manage_view_filter — Library grid filter (get / set / clear)
-- =====================================================================
--
-- catalog:setViewFilter(filterDesc) applies the Library filter bar; the
-- descriptor uses the same { combine, { criteria, operation, value } }
-- shape as findPhotos (documented for LrCatalog:setViewFilter in the SDK).
-- lightroom-cli calls it without a write gate (their tested
-- implementation, CatalogModule.lua:1637) — matched here, pcall-wrapped
-- so an LrC version that does gate it surfaces as an honest error instead
-- of wedging the bridge. `clear` passes an empty descriptor, which LrC
-- treats as "no filter" (the Filters Off state).

local MAX_VIEW_FILTER_RULES = 20

local function buildViewFilterDesc(rules, combine)
    local desc = { combine = combine or "intersect" }
    for i, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            error("rules[" .. i .. "] must be an object", 0)
        end
        if type(rule.criteria) ~= "string" or rule.criteria == "" then
            error("rules[" .. i .. "].criteria is required (e.g. 'keywords', 'rating', 'filename', 'cameraModel', 'copyName')", 0)
        end
        if type(rule.operation) ~= "string" or rule.operation == "" then
            error("rules[" .. i .. "].operation is required (e.g. 'all', 'any', '==', '>=', 'in', 'startsWith')", 0)
        end
        if rule.value == nil then
            error("rules[" .. i .. "].value is required", 0)
        end
        local r = {
            criteria = rule.criteria,
            operation = rule.operation,
            value = tostring(rule.value),
        }
        if rule.value2 ~= nil then r.value2 = tostring(rule.value2) end
        table.insert(desc, r)
    end
    return desc
end

function CatalogHandler.manageViewFilter(args)
    args = args or {}
    local action = args.action or "get"

    if action ~= "get" and action ~= "set" and action ~= "clear" then
        error("action must be 'get', 'set' or 'clear'", 0)
    end

    local catalog = LrApplication.activeCatalog()

    if action == "get" then
        local current = nil
        local ok, err = pcall(function()
            catalog:withReadAccessDo(function()
                current = catalog:getCurrentViewFilter()
            end)
        end)
        if not ok then
            -- Fall back to a bare call the way lightroom-cli reads it.
            local bareOk, bareErr = pcall(function()
                return catalog:getCurrentViewFilter()
            end)
            if not bareOk then
                error("getCurrentViewFilter failed: " .. tostring(err) .. " / " .. tostring(bareErr), 0)
            end
            current = bareErr
        end
        return {
            success = true,
            action = "get",
            filter = current,
            has_filter = type(current) == "table" and next(current) ~= nil,
            message = "Current Library view filter read"
                .. (type(current) == "table" and next(current) ~= nil and "" or " (no filter active)"),
        }
    end

    if action == "set" then
        local rules = args.rules
        if type(rules) ~= "table" or #rules == 0 then
            error("rules is required when action is 'set'", 0)
        end
        if #rules > MAX_VIEW_FILTER_RULES then
            error("rules must contain at most " .. MAX_VIEW_FILTER_RULES .. " entries", 0)
        end
        local combine = args.combine or "intersect"
        if combine ~= "intersect" and combine ~= "union" then
            error("combine must be 'intersect' (AND, default) or 'union' (OR)", 0)
        end

        local desc = buildViewFilterDesc(rules, combine)

        local ok, err = pcall(function()
            catalog:setViewFilter(desc)
        end)
        if not ok then
            error("setViewFilter failed: " .. tostring(err), 0)
        end

        Log.info(string.format("manageViewFilter: set %d rule(s)", #rules))

        return {
            success = true,
            action = "set",
            rule_count = #rules,
            combine = combine,
            message = string.format("Library view filter set (%d rule(s))", #rules),
        }
    end

    -- action == "clear"
    local ok, err = pcall(function()
        catalog:setViewFilter(nil)
    end)
    if not ok then
        -- Some LrC builds reject nil; an empty descriptor is the fallback.
        local emptyOk, emptyErr = pcall(function()
            catalog:setViewFilter({})
        end)
        if not emptyOk then
            error("could not clear the view filter: " .. tostring(err) .. " / " .. tostring(emptyErr), 0)
        end
    end

    Log.info("manageViewFilter: cleared")

    return {
        success = true,
        action = "clear",
        message = "Library view filter cleared",
    }
end

return CatalogHandler
