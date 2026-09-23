local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerCollections = nil
    return catalog, require 'HandlerCollections'
end

describe("HandlerCollections.listCollections", function()
    it("lists top-level collections", function()
        local _, Handler = setup({
            collections = {
                helper.fakeCollection("Trip", { 1, 2, 3 }),
                helper.fakeCollection("Family", { 1 }),
            },
        })
        local r = Handler.listCollections({})
        assert.are.equal(2, r.count)
        assert.are.equal("Trip", r.collections[1].name)
        assert.are.equal(3, r.collections[1].photoCount)
        assert.is_false(r.has_more)
    end)

    it("caps and paginates", function()
        local cols = {}
        for i = 1, 150 do
            table.insert(cols, helper.fakeCollection("c" .. i, {}))
        end
        local _, Handler = setup({ collections = cols })

        local r1 = Handler.listCollections({})
        assert.are.equal(150, r1.count)
        assert.are.equal(100, #r1.collections)
        assert.is_true(r1.has_more)

        local r2 = Handler.listCollections({ limit = 50, offset = 100 })
        assert.are.equal(150, r2.count)
        assert.are.equal(50, #r2.collections)
        assert.are.equal("c101", r2.collections[1].name)
        assert.is_false(r2.has_more)
    end)

    it("descends into collection sets and prefixes names", function()
        local nested = helper.fakeCollection("Inside", {})
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ collectionSets = { outerSet } })
        local r = Handler.listCollections({})
        assert.are.equal(1, r.count)
        assert.are.equal("Outer / Inside", r.collections[1].name)
        assert.are.equal("Outer", r.collections[1].parent)
    end)
end)

describe("HandlerCollections.createCollection", function()
    it("creates a collection with the given name", function()
        local catalog, Handler = setup({})
        local r = Handler.createCollection({ name = "New Album" })
        assert.is_true(r.success)
        local created = catalog.getCreatedCollections()
        assert.are.equal(1, #created)
        assert.are.equal("New Album", created[1].getName())
    end)

    it("errors without name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.createCollection({}) end)
    end)

    it("rejects an empty or whitespace-only name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.createCollection({ name = "" }) end, "name is required")
        assert.has_error(function() Handler.createCollection({ name = "   " }) end, "name is required")
    end)

    it("rejects a duplicate name that would make lookup ambiguous", function()
        local existing = helper.fakeCollection("Album", {})
        local catalog, Handler = setup({ collections = { existing } })

        assert.has_error(
            function() Handler.createCollection({ name = "Album" }) end,
            "Collection already exists: Album")
        assert.is_nil(catalog.getCreatedCollections()[1])
    end)
end)

describe("HandlerCollections.addToCollection", function()
    it("adds matching photos to the named collection", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local target = helper.fakeCollection("Target", {})
        local _, Handler = setup({ photos = { p1, p2 }, collections = { target } })

        local r = Handler.addToCollection({
            collection_name = "Target",
            photo_ids = { "1", "2" },
        })

        assert.is_true(r.success)
        assert.are.equal(2, r.added)
        assert.are.equal(2, #target.getAddedPhotos())
    end)

    it("errors when collection not found", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.addToCollection({ collection_name = "Nope", photo_ids = { "1" } })
        end)
    end)

    it("reports ids that matched no photo", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local target = helper.fakeCollection("Target", {})
        local _, Handler = setup({ photos = { p1 }, collections = { target } })

        local r = Handler.addToCollection({
            collection_name = "Target",
            photo_ids = { "1", "ghost" },
        })

        assert.are.equal(1, r.added)
        assert.are.same({ "ghost" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("errors without required args", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.addToCollection({ photo_ids = { "1" } }) end)
        assert.has_error(function() Handler.addToCollection({ collection_name = "X" }) end)
    end)
end)

describe("HandlerCollections.createCollectionSet", function()
    it("creates a top-level set and verifies its name", function()
        local catalog, Handler = setup({})
        local r = Handler.createCollectionSet({ name = "Eventos 2026" })
        assert.is_true(r.success)
        assert.are.equal("Eventos 2026", r.verified_name)
        assert.is_nil(r.parent)
        assert.are.equal(1, #catalog.getCreatedCollectionSets())
    end)

    it("nests inside a parent set when given", function()
        local parent = helper.fakeCollectionSet("Por año", {})
        local catalog, Handler = setup({ collectionSets = { parent } })

        local r = Handler.createCollectionSet({ name = "2026", parent_set_name = "Por año" })

        assert.is_true(r.success)
        assert.are.equal("Por año", r.parent)
        local created = catalog.getCreatedCollectionSets()[1]
        assert.are.equal(parent, created.getParent())
    end)

    it("errors on missing name or unknown parent", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.createCollectionSet({}) end, "name is required")
        assert.has_error(function()
            Handler.createCollectionSet({ name = "2026", parent_set_name = "no existe" })
        end, "Parent collection set not found: no existe")
    end)
end)

describe("HandlerCollections.getCollectionPhotos", function()
    it("lists photos of a top-level collection with pagination", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg", rating = 4 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" })
        local _, Handler = setup({
            collections = { helper.fakeCollection("Boda", { p1, p2 }) },
        })

        local r = Handler.getCollectionPhotos({ collection_name = "Boda", limit = 1 })

        assert.is_true(r.success)
        assert.are.equal(2, r.count)
        assert.are.equal(1, #r.photos)
        assert.are.equal("1", r.photos[1].id)
        assert.is_true(r.has_more)
    end)

    it("finds collections nested in sets", function()
        local p1 = helper.fakePhoto({ id = "9", path = "/x.jpg", fileName = "x.jpg" })
        local nested = helper.fakeCollection("Seleccionadas", { p1 })
        local _, Handler = setup({
            collectionSets = { helper.fakeCollectionSet("Clientes", { nested }) },
        })

        local r = Handler.getCollectionPhotos({ collection_name = "Seleccionadas" })

        assert.is_true(r.success)
        assert.are.equal(1, r.count)
        assert.are.equal("9", r.photos[1].id)
    end)

    it("errors when the collection does not exist", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.getCollectionPhotos({ collection_name = "No está" })
        end, "Collection not found: No está")
        assert.has_error(function()
            Handler.getCollectionPhotos({})
        end, "collection_name is required")
    end)

    it("accepts the prefixed path list_collections displays", function()
        -- listCollections shows "Clientes / Seleccionadas"; the lookup used to
        -- compare bare getName() only, so the name the caller had just read
        -- from list_collections failed with "Collection not found".
        local p1 = helper.fakePhoto({ id = "9", path = "/x.jpg", fileName = "x.jpg" })
        local nested = helper.fakeCollection("Seleccionadas", { p1 })
        local _, Handler = setup({
            collectionSets = { helper.fakeCollectionSet("Clientes", { nested }) },
        })

        local listed = Handler.listCollections({})
        assert.are.equal("Clientes / Seleccionadas", listed.collections[1].name)

        local r = Handler.getCollectionPhotos({
            collection_name = "Clientes / Seleccionadas",
        })

        assert.is_true(r.success)
        assert.are.equal(1, r.count)
    end)

    it("refuses to guess when a bare name matches in two sets", function()
        local _, Handler = setup({
            collectionSets = {
                helper.fakeCollectionSet("Norte", { helper.fakeCollection("Viajes", {}) }),
                helper.fakeCollectionSet("Sur", { helper.fakeCollection("Viajes", {}) }),
            },
        })

        assert.has_error(function()
            Handler.getCollectionPhotos({ collection_name = "Viajes" })
        end, "Collection name is ambiguous: 'Viajes' matches Norte / Viajes, "
            .. "Sur / Viajes. Use the full path as shown by list_collections.")

        local r = Handler.getCollectionPhotos({ collection_name = "Sur / Viajes" })
        assert.is_true(r.success)
    end)
end)
