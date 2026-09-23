local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local PhotoFields = require 'PhotoFields'
local Log = require 'Log'

local CollectionsHandler = {}

-- Every by-name lookup in this file used to compare against collection:getName()
-- alone, while listCollections DISPLAYS nested collections with their set path
-- prefixed ("Viajes / Catamarca"). The name an agent had just copied from
-- list_collections therefore failed with "Collection not found". Resolve what
-- list shows: the full path first (it disambiguates duplicates), then the bare
-- name, and refuse to guess when a bare name is ambiguous.
--
-- Must run inside a catalog access block: getName/getChildCollections need it.
local function findCollection(catalog, wanted)
    local entries = {}
    local function add(coll, path)
        table.insert(entries, { path = path, bare = coll:getName(), collection = coll })
    end

    for _, coll in ipairs(catalog:getChildCollections()) do
        add(coll, coll:getName())
    end

    local function walk(set, prefix)
        for _, coll in ipairs(set:getChildCollections()) do
            add(coll, prefix .. coll:getName())
        end
        for _, child in ipairs(set:getChildCollectionSets()) do
            walk(child, prefix .. child:getName() .. " / ")
        end
    end

    for _, set in ipairs(catalog:getChildCollectionSets()) do
        walk(set, set:getName() .. " / ")
    end

    for _, entry in ipairs(entries) do
        if entry.path == wanted then return entry.collection end
    end

    local ambiguous = {}
    for _, entry in ipairs(entries) do
        if entry.bare == wanted then table.insert(ambiguous, entry) end
    end
    if #ambiguous == 1 then return ambiguous[1].collection end
    if #ambiguous > 1 then
        local paths = {}
        for _, entry in ipairs(ambiguous) do table.insert(paths, entry.path) end
        error("Collection name is ambiguous: '" .. wanted .. "' matches "
            .. table.concat(paths, ", ")
            .. ". Use the full path as shown by list_collections.")
    end

    return nil
end

function CollectionsHandler.listCollections(args)
    args = args or {}
    local catalog = LrApplication.activeCatalog()
    local all = {}

    local limit = tonumber(args.limit) or 100
    if limit < 0 then limit = 0 end
    local offset = tonumber(args.offset) or 0
    if offset < 0 then offset = 0 end

    catalog:withReadAccessDo(function()
        for _, collection in ipairs(catalog:getChildCollections()) do
            table.insert(all, {
                name = collection:getName(),
                type = collection:type(),
                photoCount = #collection:getPhotos(),
            })
        end

        local function addCollectionsFromSet(collSet, prefix)
            for _, coll in ipairs(collSet:getChildCollections()) do
                table.insert(all, {
                    name = prefix .. coll:getName(),
                    parent = collSet:getName(),
                    type = coll:type(),
                    photoCount = #coll:getPhotos(),
                })
            end
            for _, childSet in ipairs(collSet:getChildCollectionSets()) do
                addCollectionsFromSet(childSet, prefix .. childSet:getName() .. " / ")
            end
        end

        for _, set in ipairs(catalog:getChildCollectionSets()) do
            addCollectionsFromSet(set, set:getName() .. " / ")
        end
    end)

    local total = #all
    local last = math.min(offset + limit, total)
    local slice = {}
    for i = offset + 1, last do
        table.insert(slice, all[i])
    end

    Log.info(string.format("Found %d collections, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        collections = slice,
        has_more = (offset + #slice) < total,
    }
end

function CollectionsHandler.createCollection(args)
    if type(args.name) ~= "string" or args.name:match("^%s*$") then
        error("name is required")
    end

    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name

    -- add_to_collection addresses collections by name, so a second collection
    -- with the same name makes that lookup ambiguous: photos would silently
    -- land in whichever one enumerates first.
    for _, collection in ipairs(catalog:getChildCollections()) do
        if collection:getName() == collectionName then
            error("Collection already exists: " .. collectionName)
        end
    end

    catalog:withWriteAccessDo("Create Collection", function()
        catalog:createCollection(collectionName)
        Log.info("Created collection: " .. collectionName)
    end)

    return {
        success = true,
        message = "Collection created: " .. collectionName
    }
end

function CollectionsHandler.addToCollection(args)
    if not args.collection_name then
        error("collection_name is required")
    end

    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local addedCount = 0
    local missingIds = {}
    local missingCount = 0

    catalog:withWriteAccessDo("Add Photos to Collection", function()
        -- Find the collection, by the name list_collections displays.
        local targetCollection = findCollection(catalog, args.collection_name)

        if not targetCollection then
            error("Collection not found: " .. args.collection_name)
        end

        -- Find and add photos
        local photosToAdd = {}
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToAdd, entry.photo)
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end

        if #photosToAdd > 0 then
            targetCollection:addPhotos(photosToAdd)
            addedCount = #photosToAdd
        end
    end)

    Log.info(string.format("Added %d photos to collection: %s", addedCount, args.collection_name))

    -- Unresolvable ids used to vanish into a "success" with added=0, leaving the
    -- caller no way to tell a typo'd id from an empty add.
    return {
        success = true,
        added = addedCount,
        missing = missingIds,
        message = string.format("Added %d photos to collection (%d ids not found)",
            addedCount, missingCount)
    }
end

-- =====================================================================
-- create_collection_set — folder that groups collections
-- =====================================================================
--
-- catalog:createCollectionSet(name, targetSet, position) works like
-- createCollection. The parent is addressed by name like every other
-- collection tool here; an optional parent set keeps collections
-- organized in the Catalog panel.

function CollectionsHandler.createCollectionSet(args)
    if type(args.name) ~= "string" or args.name:match("^%s*$") then
        error("name is required")
    end

    local parentName = args.parent_set_name

    local catalog = LrApplication.activeCatalog()

    local parentSet = nil
    if parentName ~= nil and parentName ~= "" then
        catalog:withReadAccessDo(function()
            for _, set in ipairs(catalog:getChildCollectionSets()) do
                if set:getName() == parentName then
                    parentSet = set
                    break
                end
            end
        end)
        if not parentSet then
            error("Parent collection set not found: " .. parentName)
        end
    end

    local createdSet = nil
    catalog:withWriteAccessDo("Create Collection Set", function()
        createdSet = catalog:createCollectionSet(args.name, parentSet, true)
    end)

    if not createdSet then
        error("createCollectionSet returned no set (duplicate name?)")
    end

    local verifiedName = nil
    pcall(function() verifiedName = createdSet:getName() end)

    Log.info(string.format("Created collection set '%s'", args.name))

    local result = {
        success = true,
        name = args.name,
        verified_name = verifiedName,
        parent = parentName,
        message = string.format("Collection set created: %s", args.name),
    }
    if verifiedName == nil then
        result.warning = "Set created but its name could not be read back."
    end
    return result
end

-- =====================================================================
-- get_collection_photos — photos inside a named collection
-- =====================================================================
--
-- The same recursive by-name lookup addToCollection uses, then a paginated
-- listing with the fields harnesses need to keep working (id, path,
-- filename, rating, label). Ported from lightroom-cli getCollectionPhotos,
-- which addresses collections by localIdentifier; names fit this fork's
-- conventions better (list_collections exposes names).

function CollectionsHandler.getCollectionPhotos(args)
    if type(args.collection_name) ~= "string" or args.collection_name == "" then
        error("collection_name is required")
    end

    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    local catalog = LrApplication.activeCatalog()

    -- Find the collection by the name list_collections displays (path or bare),
    -- inside read access: getName/getChildCollections need it.
    local targetCollection = nil
    catalog:withReadAccessDo(function()
        targetCollection = findCollection(catalog, args.collection_name)
    end)

    if not targetCollection then
        error("Collection not found: " .. args.collection_name)
    end

    local allPhotos = nil
    catalog:withReadAccessDo(function()
        allPhotos = targetCollection:getPhotos() or {}
    end)

    local total = #allPhotos

    local results = {}
    local last = math.min(offset + limit, total)
    catalog:withReadAccessDo(function()
        for i = offset + 1, last do
            local photo = allPhotos[i]
            table.insert(results, {
                id = photo.localIdentifier,
                path = photo:getRawMetadata('path'),
                filename = photo:getFormattedMetadata('fileName'),
                rating = photo:getRawMetadata('rating'),
                color_label = PhotoFields.colorLabel(photo),
            })
        end
    end)

    Log.info(string.format("getCollectionPhotos('%s'): %d photo(s), returning %d",
        args.collection_name, total, #results))

    return {
        success = true,
        collection = args.collection_name,
        count = total,
        photos = results,
        returned = #results,
        offset = offset,
        has_more = (offset + #results) < total,
        message = string.format("Collection '%s' has %d photo(s)", args.collection_name, total),
    }
end

return CollectionsHandler
