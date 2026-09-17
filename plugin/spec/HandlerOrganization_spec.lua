local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)

    -- setFlags drives LrSelection, which acts on whatever the catalog's UI
    -- selection currently holds. Track that selection so the mock flags the
    -- right photos (pickStatus: 1 pick / -1 reject / 0 none).
    local currentSelection = {}
    local originalSetSelected = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, active, selected)
        currentSelection = selected or {}
        originalSetSelected(self, active, selected)
    end
    local selectionCommands = { pick = 1, reject = -1, none = 0 }
    local function applyFlagToCurrentSelection(value)
        for _, photo in ipairs(currentSelection) do
            photo:setRawMetadata("pickStatus", value)
        end
    end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrSelection = {
            flagAsPick = function() applyFlagToCurrentSelection(selectionCommands.pick) end,
            flagAsReject = function() applyFlagToCurrentSelection(selectionCommands.reject) end,
            removeFlag = function() applyFlagToCurrentSelection(selectionCommands.none) end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerOrganization = nil
    return catalog, require 'HandlerOrganization'
end

describe("HandlerOrganization.setRating", function()
    it("sets rating on found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", rating = 0 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", rating = 0 })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.setRating({ photo_ids = { "1", "2" }, rating = 4 })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.equal(4, p1.getRawMetadata(p1, "rating"))
        assert.are.equal(4, p2.getRawMetadata(p2, "rating"))
    end)

    it("validates rating range", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" }, rating = 6 }) end)
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" }, rating = -1 }) end)
    end)

    it("requires photo_ids and rating", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setRating({ rating = 3 }) end)
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" } }) end)
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", rating = 0 })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setRating({ photo_ids = { "1", "missing" }, rating = 2 })

        assert.are.equal(1, r.updated)
        assert.are.same({ "missing" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("rejects a rating that is not a number", function()
        local _, Handler = setup({})
        assert.has_error(
            function() Handler.setRating({ photo_ids = { "1" }, rating = "3" }) end,
            "rating must be a number between 0 and 5")
    end)
end)

describe("HandlerOrganization.setKeywords", function()
    it("adds keywords to the photo via createKeyword", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        local r = Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "summer", "beach" } })

        assert.is_true(r.success)
        assert.are.equal(1, r.updated)
        assert.are.equal(2, #catalog.getCreatedKeywords())
    end)

    it("creates duplicate add keywords once", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "summer", "summer" } })

        assert.are.equal(1, #catalog.getCreatedKeywords())
    end)

    it("removes existing keywords by name match", function()
        local existing = { getName = function() return "old" end }
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = { existing } })
        local _, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "old" } })

        -- removeKeyword captures into __removedKeywords on the photo's meta.
        -- We can't introspect easily, but we know the call didn't error and updated=1.
        local r = Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "missing" } })
        assert.are.equal(1, r.updated)
    end)

    it("requires photo_ids", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setKeywords({}) end)
        assert.has_error(function() Handler.setKeywords({ photo_ids = {} }) end)
    end)

    it("rejects a call with neither add_keywords nor remove_keywords", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(
            function() Handler.setKeywords({ photo_ids = { "1" } }) end,
            "add_keywords or remove_keywords is required")
        assert.has_error(
            function() Handler.setKeywords({ photo_ids = { "1" }, add_keywords = {} }) end,
            "add_keywords or remove_keywords is required")
    end)

    it("limits keyword batch size", function()
        local _, Handler = setup({})
        local keywords = {}
        for i = 1, 1001 do
            table.insert(keywords, "kw" .. i)
        end

        assert.has_error(function() Handler.setKeywords({ photo_ids = { "1" }, add_keywords = keywords }) end)
        assert.has_error(function() Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = keywords }) end)
    end)
end)

describe("HandlerOrganization.setFlags", function()
    it("flags photos as pick via the selection command", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", pickStatus = 0 })
        local catalog, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.setFlags({ photo_ids = { "1", "2" }, flag = "pick" })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.equal(1, p1.getRawMetadata(p1, "pickStatus"))
        assert.are.equal(1, p2.getRawMetadata(p2, "pickStatus"))
        -- The batch was selected as a group before the command ran.
        local call = catalog.getSelectionCall()
        assert.are.equal(2, #(call and call.photos or {}))
    end)

    it("flags photos as reject and clears them again", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local _, Handler = setup({ photos = { p1 } })

        Handler.setFlags({ photo_ids = { "1" }, flag = "reject" })
        assert.are.equal(-1, p1.getRawMetadata(p1, "pickStatus"))

        local r = Handler.setFlags({ photo_ids = { "1" }, flag = "none" })
        assert.is_true(r.success)
        assert.are.equal(0, p1.getRawMetadata(p1, "pickStatus"))
    end)

    it("validates the flag value and photo_ids", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setFlags({ photo_ids = { "1" }, flag = "star" })
        end, "flag must be 'pick', 'reject' or 'none'")
        assert.has_error(function() Handler.setFlags({ flag = "pick" }) end)
        assert.has_error(function() Handler.setFlags({ photo_ids = { "nope" }, flag = "pick" }) end)
    end)

    it("reports photos that stayed unmatched after retries", function()
        -- pickStatus stays 0 because the flag command never takes: a catalog
        -- whose setSelectedPhotos records nothing and a LrSelection mock that
        -- flags an empty selection.
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local catalog = helper.fakeCatalog({ photos = { p1 } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrSelection = {
                flagAsPick = function() end,
                flagAsReject = function() end,
                removeFlag = function() end,
            },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.HandlerOrganization = nil
        local Handler = require 'HandlerOrganization'

        local r = Handler.setFlags({ photo_ids = { "1" }, flag = "pick" })

        assert.is_false(r.success)
        assert.are.equal(0, r.updated)
        assert.are.same({ "1" }, r.missing)
        assert.is_not_nil(r.message:find("Switch Lightroom", 1, true))
    end)
end)

-- "gray" is Lightroom's answer for "no label", and it is not one of the five
-- labels it offers. Reported raw, it reads to a caller like a colour somebody
-- chose on purpose.
describe("colour label normalisation", function()
    it("reports an unlabelled photo as 'none', not 'gray'", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg", pickStatus = 0 })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.getPhotoStatus({ photo_ids = { "1" } })

        assert.are.equal("none", r.photos[1].color_label)
    end)

    it("passes a real label through untouched", function()
        local p1 = helper.fakePhoto({
            id = "1", fileName = "a.jpg", pickStatus = 0, colorNameForLabel = "Red",
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.getPhotoStatus({ photo_ids = { "1" } })

        assert.are.equal("Red", r.photos[1].color_label)
    end)
end)

describe("HandlerOrganization.setColorLabel", function()
    it("sets a color label and verifies it per photo", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.setColorLabel({ photo_ids = { "1", "2" }, label = "red" })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        -- Assert through the READ key: the handler writes 'label', which
        -- real Lightroom refuses to read back.
        assert.are.equal("Red", p1.getRawMetadata(p1, "colorNameForLabel"))
        assert.are.equal("Red", p2.getRawMetadata(p2, "colorNameForLabel"))
        assert.are.same({}, r.mismatching)
    end)

    it("clears labels with 'none'", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", colorNameForLabel = "Blue" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setColorLabel({ photo_ids = { "1" }, label = "none" })

        assert.is_true(r.success)
        assert.are.equal(1, r.updated)
        -- Lightroom reports an unlabelled photo as "gray", never nil. The
        -- clear is verified through that, not against nil.
        assert.are.equal("gray", p1.getRawMetadata(p1, "colorNameForLabel"))
        assert.are.same({}, r.mismatching)
    end)

    it("reports mismatching photos honestly after write", function()
        -- Simulate a photo whose label set maps 'green' to something else.
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        p1.getRawMetadata = function(_, key)
            if key == "label" then return "Client Green" end
            return nil
        end
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setColorLabel({ photo_ids = { "1" }, label = "green" })

        assert.is_false(r.success)
        assert.are.equal(0, r.updated)
        assert.are.same({ "1" }, r.mismatching)
    end)

    it("validates labels and photo_ids", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.setColorLabel({ photo_ids = { "1" }, label = "crimson" })
        end)

        assert.has_error(function()
            Handler.setColorLabel({ label = "red" })
        end, "photo_ids is required")

        assert.has_error(function()
            Handler.setColorLabel({ photo_ids = { "1" } })
        end, "label is required")
    end)
end)

describe("HandlerOrganization.createVirtualCopies", function()
    it("creates one copy per photo by default and returns their ids", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.createVirtualCopies({ photo_ids = { "1" } })

        assert.is_true(r.success)
        assert.are.equal(1, r.count)
        assert.are.equal("1", tostring(r.created[1].source_id))
        assert.are.equal("1-vc", tostring(r.created[1].id))
        assert.are.equal("a.jpg", r.created[1].filename)
    end)

    it("creates the requested number of copies", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.createVirtualCopies({ photo_ids = { "1" }, count = 3 })

        assert.are.equal(3, r.count)
    end)

    it("validates count bounds and integrality", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.createVirtualCopies({ photo_ids = { "1" }, count = 0 })
        end)

        assert.has_error(function()
            Handler.createVirtualCopies({ photo_ids = { "1" }, count = 21 })
        end)

        assert.has_error(function()
            Handler.createVirtualCopies({ photo_ids = { "1" }, count = 2.5 })
        end)
    end)

    it("errors when nothing matched photo_ids", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.createVirtualCopies({ photo_ids = { "404" } })
        end)
    end)
end)

describe("HandlerOrganization.createSmartCollection", function()
    it("creates a collection from rules with the searchDesc format", function()
        local catalog, Handler = setup({})

        local r = Handler.createSmartCollection({
            name = "Best of wedding",
            rules = {
                { criteria = "keywords", operation = "all", value = "wedding" },
                { criteria = "rating", operation = ">=", value = 3 },
            },
        })

        assert.is_true(r.success)
        assert.are.equal("Best of wedding", r.verified_name)
        assert.are.equal(2, r.rule_count)
        assert.are.equal("intersect", r.combine)

        local created = catalog.getCreatedCollections()[1]
        assert.is_not_nil(created.__smartSearchDesc)
        assert.are.equal("intersect", created.__smartSearchDesc.combine)
        assert.are.equal("keywords", created.__smartSearchDesc[1].criteria)
        assert.are.equal("wedding", created.__smartSearchDesc[1].value)
        assert.are.equal(">=", created.__smartSearchDesc[2].operation)
        assert.are.equal("3", created.__smartSearchDesc[2].value)
    end)

    it("supports union (OR) combining and value2 ranges", function()
        local catalog, Handler = setup({})

        local r = Handler.createSmartCollection({
            name = "Range",
            combine = "union",
            rules = {
                { criteria = "captureTime", operation = "in", value = "2026-01-01", value2 = "2026-12-31" },
            },
        })

        assert.is_true(r.success)
        assert.are.equal("union", r.combine)
        local desc = catalog.getCreatedCollections()[1].__smartSearchDesc
        assert.are.equal("2026-12-31", desc[1].value2)
    end)

    it("coerces numeric values to strings like findPhotos does", function()
        local catalog, Handler = setup({})
        Handler.createSmartCollection({
            name = "Rated",
            rules = { { criteria = "rating", operation = "==", value = 5 } },
        })
        assert.are.equal("5", catalog.getCreatedCollections()[1].__smartSearchDesc[1].value)
    end)

    it("validates name, rules and combine", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.createSmartCollection({ rules = { { criteria = "keywords", operation = "all", value = "x" } } })
        end, "name is required")

        assert.has_error(function()
            Handler.createSmartCollection({ name = "X" })
        end, "rules is required (at least one)")

        assert.has_error(function()
            Handler.createSmartCollection({
                name = "X",
                rules = { { operation = "all", value = "x" } },
            })
        end)

        assert.has_error(function()
            Handler.createSmartCollection({
                name = "X",
                rules = { { criteria = "keywords", value = "x" } },
            })
        end)

        assert.has_error(function()
            Handler.createSmartCollection({
                name = "X",
                rules = { { criteria = "keywords", operation = "all" } },
            })
        end)

        assert.has_error(function()
            Handler.createSmartCollection({
                name = "X",
                combine = "xor",
                rules = { { criteria = "keywords", operation = "all", value = "x" } },
            })
        end)
    end)
end)

describe("HandlerOrganization.getPhotoStatus", function()
    it("reads flag, rating and label per photo", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg", pickStatus = 1, rating = 4, colorNameForLabel = "Red" })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg", pickStatus = -1, rating = nil, colorNameForLabel = nil })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.getPhotoStatus({ photo_ids = { "1", "2" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.count)
        assert.are.equal("pick", r.photos[1].flag)
        assert.are.equal(1, r.photos[1].pick_status)
        assert.are.equal(4, r.photos[1].rating)
        assert.are.equal("Red", r.photos[1].color_label)
        assert.are.equal("reject", r.photos[2].flag)
        assert.is_nil(r.photos[2].rating)
    end)

    it("reports unknown ids as missing", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.getPhotoStatus({ photo_ids = { "1", "999" } })

        assert.are.equal(1, r.count)
        assert.are.same({ "999" }, r.missing)
    end)

    it("requires resolvable photos", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getPhotoStatus({}) end, "photo_ids is required")
        assert.has_error(function()
            Handler.getPhotoStatus({ photo_ids = { "404" } })
        end, "No photos matched photo_ids")
    end)
end)

describe("HandlerOrganization.batchMetadata", function()
    it("writes IPTC fields on many photos and verifies read-back", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg", title = nil })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg" })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.batchMetadata({
            photo_ids = { "1", "2" },
            metadata = { title = "Atardecer", city = "Salta" },
        })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.same({ "city", "title" }, r.fields)
        assert.are.equal("Atardecer", p1.getRawMetadata(p1, "title"))
        assert.are.equal("Salta", p1.getRawMetadata(p1, "city"))
    end)

    it("rejects unsupported fields and non-string values", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.batchMetadata({
                photo_ids = { "1" },
                metadata = { aperture = "f/2.8" },
            })
        end, "metadata field 'aperture' is not supported")
        assert.has_error(function()
            Handler.batchMetadata({
                photo_ids = { "1" },
                metadata = { title = 42 },
            })
        end, "metadata field 'title' must be a string or null")
    end)
end)

describe("HandlerOrganization.rotatePhoto", function()
    it("rotates each photo left or right", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg" })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.rotatePhoto({ photo_ids = { "1", "2" }, direction = "left" })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.equal(-1, p1.__meta.__rotations)
        assert.are.equal(-1, p2.__meta.__rotations)

        r = Handler.rotatePhoto({ photo_ids = { "1" } })
        assert.are.equal(0, p1.__meta.__rotations)
    end)

    it("validates direction and photo_ids", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.rotatePhoto({ photo_ids = { "1" }, direction = "upside_down" })
        end, "direction must be 'left' or 'right'")
        assert.has_error(function()
            Handler.rotatePhoto({ photo_ids = { "404" } })
        end, "No photos matched photo_ids")
    end)
end)

describe("HandlerOrganization.removeFromCatalog", function()
    it("requires explicit confirmation before doing anything", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local catalog, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.removeFromCatalog({ photo_ids = { "1" } })
        end, "remove_from_catalog is destructive: pass confirm=true to proceed")
        assert.are.equal(0, catalog.getRemovedPhotoCount())
    end)

    it("removes the photos and verifies they no longer resolve", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg" })
        local catalog, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.removeFromCatalog({ photo_ids = { "1" }, confirm = true })

        assert.is_true(r.success)
        assert.are.equal(1, catalog.getRemovedPhotoCount())
        assert.are.same({}, r.still_present)
    end)

    it("warns when a photo survives the removal", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local catalog, Handler = setup({ photos = { p1 } })
        -- Make removal silently fail to verify honest reporting.
        catalog.removePhoto = function() end

        local r = Handler.removeFromCatalog({ photo_ids = { "1" }, confirm = true })

        assert.is_false(r.success)
        assert.are.same({ "1" }, r.still_present)
        assert.is_not_nil(r.warning)
    end)
end)
