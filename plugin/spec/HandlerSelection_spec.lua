local helper = require 'spec_helper'

-- Shared setup with LrSelection mocks (selectPhotos modes + navigatePhoto).
-- Returns a context table { handler, catalog, selectionCalls, navigationCalls }.
local function setupWithMocks(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)

    local selectionCalls = {}
    local navigationCalls = {}

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrSelection = {
            selectAll = function() table.insert(selectionCalls, "all") end,
            selectNone = function() table.insert(selectionCalls, "none") end,
            selectInverse = function() table.insert(selectionCalls, "inverse") end,
            deselectOthers = function() table.insert(selectionCalls, "deselect_others") end,
            nextPhoto = function() table.insert(navigationCalls, "next") end,
            previousPhoto = function() table.insert(navigationCalls, "previous") end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerSelection = nil
    local Handler = require 'HandlerSelection'
    return {
        handler = Handler,
        catalog = catalog,
        selectionCalls = selectionCalls,
        navigationCalls = navigationCalls,
    }
end

describe("HandlerSelection.getSelectedPhotos", function()
    local Handler
    local lastCatalog

    -- Back-compat wrapper for the pre-existing tests: assigns the describe-
    -- scoped locals the old setup maintained.
    local function setup(opts)
        local ctx = setupWithMocks(opts)
        Handler = ctx.handler
        lastCatalog = ctx.catalog
        return ctx
    end

    it("returns selected photos when selection is non-empty", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg", rating = 5 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg", rating = 3 })
        local p3 = helper.fakePhoto({ id = "3", path = "/c.jpg", fileName = "c.jpg", rating = 0 })
        setup({ photos = { p1, p2, p3 }, targetPhotos = { p1, p3 } })

        local r = Handler.getSelectedPhotos({})
        assert.are.equal(2, r.count)
        assert.are.equal("1", r.photos[1].id)
        assert.are.equal("3", r.photos[2].id)
        assert.is_false(r.has_more)
    end)

    it("falls back to filmstrip when no selection (targetPhotos defaults to all)", function()
        setup({
            photos = {
                helper.fakePhoto({ id = "1", fileName = "a.jpg" }),
                helper.fakePhoto({ id = "2", fileName = "b.jpg" }),
            },
        })
        local r = Handler.getSelectedPhotos({})
        assert.are.equal(2, r.count)
        assert.are.equal(2, #r.photos)
    end)

    it("returns serialized photo fields", function()
        setup({
            photos = { helper.fakePhoto({
                id = "42", path = "/x.jpg", fileName = "x.jpg",
                rating = 4, dateTimeOriginal = "2026-05-06",
            }) },
        })
        local r = Handler.getSelectedPhotos({})
        local p = r.photos[1]
        assert.are.equal("42", p.id)
        assert.are.equal("/x.jpg", p.path)
        assert.are.equal("x.jpg", p.filename)
        assert.are.equal(4, p.rating)
        assert.are.equal("2026-05-06", p.dateTimeOriginal)
    end)

    it("paginates via limit and offset", function()
        local photos = {}
        for i = 1, 250 do
            table.insert(photos, helper.fakePhoto({ id = tostring(i), fileName = "p" .. i .. ".jpg" }))
        end
        setup({ photos = photos })

        local r = Handler.getSelectedPhotos({ limit = 50, offset = 100 })
        assert.are.equal(250, r.count)
        assert.are.equal(50, #r.photos)
        assert.are.equal("101", r.photos[1].id)
        assert.is_true(r.has_more)
    end)

    it("caps to 100 by default", function()
        local photos = {}
        for i = 1, 150 do
            table.insert(photos, helper.fakePhoto({ id = tostring(i), fileName = "p.jpg" }))
        end
        setup({ photos = photos })

        local r = Handler.getSelectedPhotos({})
        assert.are.equal(150, r.count)
        assert.are.equal(100, #r.photos)
        assert.is_true(r.has_more)
    end)

    it("returns empty when nothing is targeted", function()
        setup({ photos = {}, targetPhotos = {} })
        local r = Handler.getSelectedPhotos({})
        assert.are.equal(0, r.count)
        assert.are.same({}, r.photos)
        assert.is_false(r.has_more)
    end)

    it("calls getTargetPhotos OUTSIDE the read-access gate (#134 deadlock guard)", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg", rating = 5 })
        setup({ photos = { p1 }, targetPhotos = { p1 } })
        Handler.getSelectedPhotos({})
        assert.is_false(lastCatalog.getQueriedInsideReadAccess())
    end)

    describe("setSelection", function()
        local function threePhotos()
            return
                helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" }),
                helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" }),
                helper.fakePhoto({ id = "3", path = "/c.jpg", fileName = "c.jpg" })
        end

        it("selects the resolved photos and makes the first one active", function()
            local p1, p2, p3 = threePhotos()
            setup({ photos = { p1, p2, p3 }, targetPhotos = { p3, p1 } })

            local r = Handler.setSelection({ photo_ids = { "3", "1" } })

            assert.are.equal(2, r.selected)
            assert.is_nil(r.warning)
            assert.are.equal("3", r.active)
            assert.are.same({}, r.missing)
            local call = lastCatalog.getSelectionCall()
            assert.are.equal(p3, call.active)
            assert.are.same({ p3, p1 }, call.photos)
        end)

        it("resolves by file path as well as local identifier", function()
            local p1, p2 = threePhotos()
            setup({ photos = { p1, p2 }, targetPhotos = { p2 } })

            local r = Handler.setSelection({ photo_ids = { "/b.jpg" } })

            assert.are.equal(1, r.selected)
            assert.are.equal(p2, lastCatalog.getSelectionCall().active)
        end)

        it("warns when Lightroom ignores photos outside the current view source", function()
            local p1, p2, p3 = threePhotos()
            setup({ photos = { p1, p2, p3 }, targetPhotos = { p2 } })

            local r = Handler.setSelection({ photo_ids = { "1", "3" } })

            assert.are.equal(0, r.selected)
            assert.are.equal(2, r.requested)
            assert.is_not_nil(r.warning)
            assert.is_not_nil(r.warning:find("current view source", 1, true))
        end)

        it("reports ids that matched no photo", function()
            local p1 = threePhotos()
            setup({ photos = { p1 } })

            local r = Handler.setSelection({ photo_ids = { "1", "999" } })

            assert.are.equal(1, r.selected)
            assert.are.same({ "999" }, r.missing)
        end)

        it("errors when photo_ids is missing or empty", function()
            setup({ photos = { threePhotos() } })
            assert.has_error(function() Handler.setSelection({}) end, "photo_ids is required")
            assert.has_error(function() Handler.setSelection({ photo_ids = {} }) end,
                "photo_ids is required")
        end)

        it("errors when no id resolves, leaving the selection untouched", function()
            setup({ photos = { threePhotos() } })

            assert.has_error(function() Handler.setSelection({ photo_ids = { "999" } }) end,
                "No photos matched photo_ids")
            assert.is_nil(lastCatalog.getSelectionCall())
        end)

        it("calls setSelectedPhotos OUTSIDE the read-access gate (#134 deadlock guard)", function()
            local p1 = threePhotos()
            setup({ photos = { p1 } })
            Handler.setSelection({ photo_ids = { "1" } })
            assert.is_false(lastCatalog.getQueriedInsideReadAccess())
        end)
    end)
end)

describe("HandlerSelection.selectPhotos", function()
    it("replaces the selection with the resolved photos (first active)", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" })
        local ctx = setupWithMocks({ photos = { p1, p2 }, targetPhotos = { p2, p1 } })

        local r = ctx.handler.selectPhotos({ photo_ids = { "2", "1" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.selected)
        assert.are.equal("2", r.active)
        local call = ctx.catalog.getSelectionCall()
        assert.are.equal(p2, call.active)
        assert.are.same({ p2, p1 }, call.photos)
    end)

    it("reports photos outside the current view source honestly", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg" })
        local ctx = setupWithMocks({ photos = { p1, p2 }, targetPhotos = { p2 } })

        local r = ctx.handler.selectPhotos({ photo_ids = { "1", "2" } })

        assert.are.equal(1, r.selected)
        assert.are.equal(2, r.requested)
        assert.is_not_nil(r.warning)
        assert.is_not_nil(r.warning:find("current view source", 1, true))
    end)

    it("applies UI modes through LrSelection", function()
        local ctx = setupWithMocks({ photos = {} })

        local r = ctx.handler.selectPhotos({ mode = "all" })
        assert.is_true(r.success)
        assert.are.same({ "all" }, ctx.selectionCalls)

        r = ctx.handler.selectPhotos({ mode = "none" })
        assert.are.same({ "all", "none" }, ctx.selectionCalls)

        r = ctx.handler.selectPhotos({ mode = "inverse" })
        assert.are.same({ "all", "none", "inverse" }, ctx.selectionCalls)
    end)

    it("rejects modes that do not exist, both or neither of ids/mode", function()
        local ctx = setupWithMocks({ photos = {} })
        assert.has_error(function() ctx.handler.selectPhotos({ mode = "some" }) end,
            "mode must be one of: all, none, inverse, deselect_others")
        assert.has_error(function() ctx.handler.selectPhotos({}) end,
            "photo_ids or mode is required")
        assert.has_error(function()
            ctx.handler.selectPhotos({ photo_ids = { "1" }, mode = "all" })
        end, "pass either photo_ids or mode, not both")
    end)
end)

describe("HandlerSelection.navigatePhoto", function()
    it("moves forward and back through LrSelection and reports the active photo", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" })
        local ctx = setupWithMocks({ photos = { p1, p2 }, targetPhotos = { p1, p2 } })

        local r = ctx.handler.navigatePhoto({ direction = "next" })
        assert.is_true(r.success)
        assert.are.same({ "next" }, ctx.navigationCalls)
        assert.are.equal("1", tostring(r.active.id))
        assert.are.equal("/a.jpg", r.active.path)

        r = ctx.handler.navigatePhoto({ direction = "previous" })
        assert.are.same({ "next", "previous" }, ctx.navigationCalls)
    end)

    it("defaults to next and rejects other directions", function()
        local ctx = setupWithMocks({ photos = {} })
        ctx.handler.navigatePhoto({})
        assert.are.same({ "next" }, ctx.navigationCalls)

        assert.has_error(function() ctx.handler.navigatePhoto({ direction = "sideways" }) end,
            "direction must be 'next' or 'previous'")
    end)
end)
