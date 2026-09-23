local LrApplication = import 'LrApplication'
local LrSelection = import 'LrSelection'

local PhotoLookup = require 'PhotoLookup'
local PhotoFields = require 'PhotoFields'
local Log = require 'Log'

local OrganizationHandler = {}
local MAX_KEYWORDS_PER_REQUEST = 1000

local function validateKeywordLimit(keywords, fieldName)
    if keywords and #keywords > MAX_KEYWORDS_PER_REQUEST then
        error(fieldName .. " must contain at most " .. MAX_KEYWORDS_PER_REQUEST .. " keywords")
    end
end

function OrganizationHandler.setKeywords(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end
    validateKeywordLimit(args.add_keywords, "add_keywords")
    validateKeywordLimit(args.remove_keywords, "remove_keywords")

    -- Neither list means there is nothing to do; reporting "Updated keywords
    -- for 1 photos" for that claimed work that never happened.
    local hasAdds = args.add_keywords ~= nil and args.add_keywords[1] ~= nil
    local hasRemoves = args.remove_keywords ~= nil and args.remove_keywords[1] ~= nil
    if not hasAdds and not hasRemoves then
        error("add_keywords or remove_keywords is required")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0

    local addKeywordNames = {}
    local addSet = {}
    if args.add_keywords then
        for _, kw in ipairs(args.add_keywords) do
            if not addSet[kw] then
                addSet[kw] = true
                table.insert(addKeywordNames, kw)
            end
        end
    end

    local removeSet = {}
    if args.remove_keywords then
        for _, kw in ipairs(args.remove_keywords) do
            removeSet[kw] = true
        end
    end

    catalog:withWriteAccessDo("Set Keywords", function()
        -- createKeyword is not idempotent within one write transaction.
        local keywordObjs = {}
        for _, kw in ipairs(addKeywordNames) do
            table.insert(keywordObjs, catalog:createKeyword(kw, {}, true, nil, true))
        end

        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                for _, kwObj in ipairs(keywordObjs) do
                    photo:addKeyword(kwObj)
                end

                if next(removeSet) then
                    local existingKeywords = photo:getRawMetadata('keywords')
                    if existingKeywords then
                        for _, kw in ipairs(existingKeywords) do
                            if removeSet[kw:getName()] then
                                photo:removeKeyword(kw)
                            end
                        end
                    end
                end

                updatedCount = updatedCount + 1
            end
        end
    end)

    Log.info(string.format("Updated keywords for %d photos", updatedCount))

    return {
        success = true,
        updated = updatedCount,
        message = string.format("Updated keywords for %d photos", updatedCount)
    }
end

function OrganizationHandler.setRating(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.rating then
        error("rating is required")
    end

    -- Comparing a string to a number raised a raw Lua type error that leaked
    -- the handler's file and line to the client.
    if type(args.rating) ~= "number" then
        error("rating must be a number between 0 and 5")
    end

    if args.rating < 0 or args.rating > 5 then
        error("rating must be between 0 and 5")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    -- LrSDK rejects literal 0 on the rating field; nil means "no rating".
    local ratingValue = args.rating
    if ratingValue == 0 then ratingValue = nil end

    catalog:withWriteAccessDo("Set Rating", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:setRawMetadata('rating', ratingValue)
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Set rating to %d for %d photos", args.rating, updatedCount))

    return {
        success = true,
        updated = updatedCount,
        rating = args.rating,
        missing = missingIds,
        message = string.format("Set rating to %d for %d photos (%d ids not found)",
            args.rating, updatedCount, missingCount)
    }
end

function OrganizationHandler.setFlags(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local flag = args.flag
    if flag ~= "pick" and flag ~= "reject" and flag ~= "none" then
        error("flag must be 'pick', 'reject' or 'none'")
    end

    local catalog = LrApplication.activeCatalog()

    -- LrSelection commands behave like the main-menu commands: they act on
    -- the UI selection (grid view: all selected; loupe: active photo only).
    -- We therefore select the target photos first, run the command, then
    -- verify per photo via pickStatus. Yields to the UI thread, so the
    -- selection must stay OUTSIDE any catalog access gate (issues #134/#124).
    local photos = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photos, entry.photo)
            end
        end
    end)

    if #photos == 0 then
        error("No photos matched photo_ids")
    end

    local command = (flag == "pick" and LrSelection.flagAsPick)
        or (flag == "reject" and LrSelection.flagAsReject)
        or LrSelection.removeFlag

    local function pickValueOf(photo)
        return photo:getRawMetadata('pickStatus')
    end

    local function applyCommandToSelection(target)
        catalog:setSelectedPhotos(target[1], target)
        command()
    end

    local function flagMatches(photo)
        local status = pickValueOf(photo)
        if flag == "pick" then return status == 1 end
        if flag == "reject" then return status == -1 end
        return status == 0 or status == nil
    end

    -- First pass: whole batch as one selection (fast path; works when the
    -- photos are visible in the current view source, e.g. All Photographs).
    pcall(applyCommandToSelection, photos)

    -- Verify and retry photo-by-photo where the batch command did not take
    -- (hidden photos, view-source mismatch, loupe view applying to the
    -- active photo only).
    local updated = 0
    local retried = 0
    local failed = {}
    for _, photo in ipairs(photos) do
        if not flagMatches(photo) then
            retried = retried + 1
            pcall(applyCommandToSelection, { photo })
        end
        if flagMatches(photo) then
            updated = updated + 1
        else
            table.insert(failed, tostring(photo.localIdentifier))
        end
    end

    Log.info(string.format("Set flag '%s' on %d/%d photos (%d single retries)",
        flag, updated, #photos, retried))

    local result = {
        success = #failed == 0,
        updated = updated,
        requested = #photos,
        single_retries = retried,
        missing = {},
        message = string.format("Set flag '%s' on %d of %d photos", flag, updated, #photos),
    }
    if #failed > 0 then
        result.missing = failed
        result.message = result.message
            .. ". Photos not updated: " .. table.concat(failed, ", ")
            .. ". Switch Lightroom to a source containing them (e.g. All Photographs) and retry."
    end
    return result
end

-- =====================================================================
-- Color labels
-- =====================================================================
--
-- Labels are stored as plain text via setRawMetadata('label', ...). The
-- five standard UI colors map to their capitalized names; matching against
-- the catalog's label set is done by Lightroom itself on read-back (a
-- custom label set can rename them, hence the case-insensitive compare).

local COLOR_LABELS = {
    red = "Red",
    yellow = "Yellow",
    green = "Green",
    blue = "Blue",
    purple = "Purple",
}

function OrganizationHandler.setColorLabel(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local label = args.label
    if label == nil then
        error("label is required")
    end

    local labelValue = nil
    if label ~= "none" then
        labelValue = COLOR_LABELS[label]
        if not labelValue then
            error("label must be one of: red, yellow, green, blue, purple, none")
        end
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Set Color Label", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                -- nil clears the label, exactly like the rating handler.
                entry.photo:setRawMetadata('label', labelValue)
            end
        end
    end)

    -- Verify per photo by reading back: 'none' expects an empty label, the
    -- colors compare case-insensitively to tolerate label-set variations.
    local updatedCount = 0
    local mismatchIds = {}
    local mismatchCount = 0

    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                -- PhotoFields handles both traps: the write key ('label')
                -- cannot be read back, and an unlabelled photo reads as
                -- "gray", not nil. Comparing against nil here reported every
                -- successful CLEAR as a mismatch.
                local current = PhotoFields.colorLabel(photo)
                local matches
                if label == "none" then
                    matches = current == PhotoFields.NO_LABEL
                else
                    matches = current:lower() == labelValue:lower()
                end
                if matches then
                    updatedCount = updatedCount + 1
                else
                    mismatchCount = mismatchCount + 1
                    table.insert(mismatchIds, tostring(photo.localIdentifier))
                end
            end
        end
    end)

    Log.info(string.format("Set color label '%s' on %d photos", label, updatedCount))

    local result = {
        success = mismatchCount == 0,
        label = label,
        updated = updatedCount,
        mismatching = mismatchIds,
        message = string.format("Set color label '%s' on %d photos (%d mismatched after write)",
            label, updatedCount, mismatchCount),
    }
    if mismatchCount > 0 then
        result.message = result.message
            .. ". Photos not verified: " .. table.concat(mismatchIds, ", ")
    end
    return result
end

-- =====================================================================
-- Virtual copies
-- =====================================================================
--
-- photo:createVirtualCopy() inside a write gate returns the new LrPhoto.
-- The copies are stacked with their source and share its develop settings.

function OrganizationHandler.createVirtualCopies(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local count = args.count or 1
    if type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > 20 then
        error("count must be an integer between 1 and 20")
    end

    local catalog = LrApplication.activeCatalog()
    local created = {}

    catalog:withWriteAccessDo("Create Virtual Copies", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                for _ = 1, count do
                    local newPhoto = photo:createVirtualCopy()
                    if newPhoto then
                        table.insert(created, {
                            source_id = photo.localIdentifier,
                            id = newPhoto.localIdentifier,
                            path = newPhoto:getRawMetadata('path'),
                            filename = newPhoto:getFormattedMetadata('fileName'),
                        })
                    end
                end
            end
        end
    end)

    if #created == 0 then
        error("No virtual copies were created (check that photo_ids matched photos)")
    end

    Log.info(string.format("Created %d virtual copies", #created))

    return {
        success = true,
        created = created,
        count = #created,
        message = string.format("Created %d virtual cop%s",
            #created, #created == 1 and "y" or "ies"),
    }
end

-- =====================================================================
-- Smart collections
-- =====================================================================
--
-- catalog:createSmartCollection(name, criteria, targetSet, position) uses
-- the same searchDesc shape as findPhotos: a combine field plus an array
-- of { criteria, operation, value, value2? } rules. Common criteria:
-- keywords, rating, filename, captureTime, copyName, cameraModel, lens,
-- isoSpeedRating, hasAdjustments, text; operations: all/any (containment),
-- ==/</>/>=/in (comparisons), startsWith/endsWith.

local MAX_SMART_COLLECTION_RULES = 20

function OrganizationHandler.createSmartCollection(args)
    local name = args.name
    if type(name) ~= "string" or name == "" then
        error("name is required")
    end
    if #name > 255 then
        error("name must be at most 255 characters")
    end

    local rules = args.rules
    if type(rules) ~= "table" or #rules == 0 then
        error("rules is required (at least one)")
    end
    if #rules > MAX_SMART_COLLECTION_RULES then
        error("rules must contain at most " .. MAX_SMART_COLLECTION_RULES .. " entries")
    end

    local combine = args.combine or "intersect"
    if combine ~= "intersect" and combine ~= "union" then
        error("combine must be 'intersect' (AND, default) or 'union' (OR)")
    end

    local searchDesc = { combine = combine }
    for i, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            error("rules[" .. i .. "] must be an object")
        end
        if type(rule.criteria) ~= "string" or rule.criteria == "" then
            error("rules[" .. i .. "].criteria is required (e.g. 'keywords', 'rating', 'filename', 'captureTime')")
        end
        if type(rule.operation) ~= "string" or rule.operation == "" then
            error("rules[" .. i .. "].operation is required (e.g. 'all', 'any', '==', '>=', 'in', 'startsWith')")
        end
        if rule.value == nil then
            error("rules[" .. i .. "].value is required")
        end
        local r = {
            criteria = rule.criteria,
            operation = rule.operation,
            value = tostring(rule.value),
        }
        if rule.value2 ~= nil then r.value2 = tostring(rule.value2) end
        table.insert(searchDesc, r)
    end

    local catalog = LrApplication.activeCatalog()
    local createdCollection = nil
    local createError = nil

    catalog:withWriteAccessDo("Create Smart Collection", function()
        local ok, result = pcall(function()
            return catalog:createSmartCollection(name, searchDesc, nil, true)
        end)
        if ok then
            createdCollection = result
        else
            createError = result
        end
    end)

    if createError ~= nil then
        error("createSmartCollection failed: " .. tostring(createError))
    end
    if not createdCollection then
        error("createSmartCollection returned no collection (duplicate name?)")
    end

    -- Read back the name through the returned collection object.
    local verifiedName = nil
    pcall(function() verifiedName = createdCollection:getName() end)

    Log.info(string.format("Created smart collection '%s' (%d rule(s))",
        name, #rules))

    local result = {
        success = true,
        name = name,
        verified_name = verifiedName,
        rule_count = #rules,
        combine = combine,
        message = string.format("Created smart collection '%s' with %d rule(s)",
            name, #rules),
    }
    if verifiedName == nil then
        result.warning = "Collection created but its name could not be read back."
    end
    return result
end

-- =====================================================================
-- get_photo_status — flag, rating and color label per photo
-- =====================================================================
--
-- Read-only counterpart of set_flags/set_rating/set_color_label: one
-- round-trip returns all three status fields for a batch. Ported from
-- lightroom-cli getFlag/getRating/getColorLabel (three commands there,
-- one here). pickStatus maps to flag names; label keeps the raw stored
-- text (custom label sets can rename colors, cf. setColorLabel).

local FLAG_NAMES = {
    [1] = "pick",
    [-1] = "reject",
    [0] = "none",
}

function OrganizationHandler.getPhotoStatus(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()

    local results = {}
    local missing = {}

    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                local pickStatus = photo:getRawMetadata('pickStatus')
                table.insert(results, {
                    id = photo.localIdentifier,
                    path = photo:getRawMetadata('path'),
                    filename = photo:getFormattedMetadata('fileName'),
                    flag = FLAG_NAMES[pickStatus] or ("unknown (" .. tostring(pickStatus) .. ")"),
                    pick_status = pickStatus,
                    rating = photo:getRawMetadata('rating'),
                    color_label = PhotoFields.colorLabel(photo),
                })
            else
                table.insert(missing, tostring(entry.id))
            end
        end
    end)

    if #results == 0 then
        error("No photos matched photo_ids")
    end

    Log.info(string.format("getPhotoStatus: %d photo(s)", #results))

    return {
        success = true,
        photos = results,
        count = #results,
        missing = missing,
        message = string.format("Read status for %d photo(s) (%d ids not found)",
            #results, #missing),
    }
end

-- =====================================================================
-- batch_metadata — IPTC text fields for many photos at once
-- =====================================================================
--
-- setRawMetadata over a whitelisted set of writable IPTC string fields
-- (title, caption, headline, location, city, stateProvince, country,
-- creator, copyright), then a read-back verification pass — nil clears a
-- field exactly like the rating/label handlers. Ported from lightroom-cli
-- batch-metadata/set-metadata.

local BATCH_METADATA_FIELDS = {
    title = true,
    caption = true,
    headline = true,
    location = true,
    city = true,
    stateProvince = true,
    country = true,
    isoCountryCode = true,
    creator = true,
    copyright = true,
}

function OrganizationHandler.batchMetadata(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local metadata = args.metadata
    if type(metadata) ~= "table" then
        error("metadata object is required")
    end

    local fields = {}
    for key, _ in pairs(metadata) do
        if not BATCH_METADATA_FIELDS[key] then
            error("metadata field '" .. tostring(key)
                .. "' is not supported (allowed: title, caption, headline, location, city, "
                .. "stateProvince, country, isoCountryCode, creator, copyright)")
        end
        if metadata[key] ~= nil and type(metadata[key]) ~= "string" then
            error("metadata field '" .. tostring(key) .. "' must be a string or null")
        end
        table.insert(fields, key)
    end

    if #fields == 0 then
        error("metadata must contain at least one field")
    end
    table.sort(fields)

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Batch Metadata", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                for _, key in ipairs(fields) do
                    entry.photo:setRawMetadata(key, metadata[key])
                end
            end
        end
    end)

    -- Verify by reading every field back; a mismatch is reported honestly
    -- rather than failing the whole batch (per-photo, like setColorLabel).
    local updatedCount = 0
    local mismatches = {}

    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                local badFields = {}
                for _, key in ipairs(fields) do
                    local current = photo:getRawMetadata(key)
                    local expected = metadata[key]
                    local matches
                    if expected == nil then
                        matches = current == nil or current == ""
                    else
                        matches = current == expected
                    end
                    if not matches then
                        table.insert(badFields, key)
                    end
                end
                if #badFields == 0 then
                    updatedCount = updatedCount + 1
                else
                    table.insert(mismatches, {
                        id = photo.localIdentifier,
                        fields = badFields,
                    })
                end
            end
        end
    end)

    Log.info(string.format("batchMetadata: %d photo(s) verified", updatedCount))

    local result = {
        success = #mismatches == 0,
        updated = updatedCount,
        fields = fields,
        mismatching = mismatches,
        message = string.format("Set %d metadata field(s) on %d photo(s) (%d mismatched after write)",
            #fields, updatedCount, #mismatches),
    }
    if #mismatches > 0 then
        result.message = result.message
            .. ". Check the 'mismatching' entries — the write may be pending or the field unsupported."
    end
    return result
end

-- =====================================================================
-- rotate_photo — 90-degree rotation, batch
-- =====================================================================
--
-- photo:rotateLeft()/rotateRight() inside one write gate; the rotation
-- is applied to the stored orientation, so previews/exports pick it up.
-- Ported from lightroom-cli rotateLeft/rotateRight (one tool here).

function OrganizationHandler.rotatePhoto(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local direction = args.direction or "right"
    if direction ~= "left" and direction ~= "right" then
        error("direction must be 'left' or 'right'")
    end

    local catalog = LrApplication.activeCatalog()

    local updatedCount = 0
    local missing = {}

    catalog:withWriteAccessDo("Rotate Photos", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                if direction == "left" then
                    entry.photo:rotateLeft()
                else
                    entry.photo:rotateRight()
                end
                updatedCount = updatedCount + 1
            else
                table.insert(missing, tostring(entry.id))
            end
        end
    end)

    if updatedCount == 0 then
        error("No photos matched photo_ids")
    end

    Log.info(string.format("Rotated %d photo(s) %s", updatedCount, direction))

    return {
        success = true,
        updated = updatedCount,
        direction = direction,
        missing = missing,
        message = string.format("Rotated %d photo(s) %s (%d ids not found)",
            updatedCount, direction, #missing),
    }
end

-- =====================================================================
-- remove_from_catalog — destructive, confirm-gated
-- =====================================================================
--
-- catalog:removePhoto(photo) removes the photo from the catalog (files on
-- disk are NOT deleted). Destructive and hard to undo, so the tool
-- contract demands confirm=true and the handler re-checks it: an
-- accidental call errors instead of removing anything. Verification: the
-- ids must no longer resolve afterwards.

function OrganizationHandler.removeFromCatalog(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if args.confirm ~= true then
        error("remove_from_catalog is destructive: pass confirm=true to proceed "
            .. "(files on disk are kept; only the catalog entries are removed)")
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Remove From Catalog", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                catalog:removePhoto(entry.photo)
            end
        end
    end)

    -- Verify: every id that resolved before must now be gone.
    local stillPresent = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(stillPresent, tostring(entry.id))
            end
        end
    end)

    Log.info(string.format("removeFromCatalog: %d removed, %d still present",
        #args.photo_ids - #stillPresent, #stillPresent))

    local result = {
        success = #stillPresent == 0,
        requested = #args.photo_ids,
        still_present = stillPresent,
        message = string.format("Removed %d photo(s) from the catalog",
            #args.photo_ids - #stillPresent),
    }
    if #stillPresent > 0 then
        result.warning = "Some photos are still in the catalog: "
            .. table.concat(stillPresent, ", ")
            .. ". Re-run for those ids."
    end
    return result
end

return OrganizationHandler
