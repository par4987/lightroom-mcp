local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerCatalog = nil
    local Handler = require 'HandlerCatalog'
    return Handler, catalog
end

describe("HandlerCatalog.listFolders", function()
    it("lists root folders with photo counts", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", fileName = "b.jpg" })
        local Handler, _ = setup({
            folders = {
                helper.fakeFolder({ name = "2025", path = "C:/fotos/2025", photos = { p1, p2 } }),
                helper.fakeFolder({ name = "2026", path = "C:/fotos/2026", photos = {} }),
            },
        })

        local r = Handler.listFolders({})

        assert.is_true(r.success)
        assert.are.equal(2, r.count)
        assert.are.equal("2025", r.folders[1].name)
        assert.are.equal("C:/fotos/2025", r.folders[1].id)
        assert.are.equal(2, r.folders[1].photo_count)
        assert.are.equal(0, r.folders[2].photo_count)
        assert.is_nil(r.folders[1].subfolders)
    end)

    it("walks subfolders when include_subfolders is set", function()
        local p1 = helper.fakePhoto({ id = "1", fileName = "a.jpg" })
        local child = helper.fakeFolder({
            name = "enero", path = "C:/fotos/2026/enero", photos = { p1 },
        })
        local Handler, _ = setup({
            folders = {
                helper.fakeFolder({
                    name = "2026", path = "C:/fotos/2026", photos = {},
                    children = { child },
                }),
            },
        })

        local r = Handler.listFolders({ include_subfolders = true })

        assert.is_true(r.success)
        assert.are.equal(1, r.folders[1].total_photo_count)
        assert.are.equal(1, #r.folders[1].subfolders)
        assert.are.equal("enero", r.folders[1].subfolders[1].name)
        assert.are.equal(1, r.folders[1].subfolders[1].depth)
    end)
end)

describe("HandlerCatalog.listKeywords", function()
    it("lists top-level keywords sorted by name with photo counts", function()
        local Handler, _ = setup({
            keywords = {
                helper.fakeKeyword("playa", 4),
                helper.fakeKeyword("montaña", 12),
                helper.fakeKeyword("atardecer", 0),
            },
        })

        local r = Handler.listKeywords({})

        assert.is_true(r.success)
        assert.are.equal(3, r.count)
        assert.are.equal("atardecer", r.keywords[1].name)
        assert.are.equal("montaña", r.keywords[2].name)
        assert.are.equal("playa", r.keywords[3].name)
        assert.are.equal(12, r.keywords[2].photo_count)
    end)
end)

describe("HandlerCatalog.manageViewFilter", function()
    it("reads the current filter", function()
        local Handler, catalog = setup({})
        catalog.setViewFilter(catalog, { combine = "intersect" })

        local r = Handler.manageViewFilter({})

        assert.is_true(r.success)
        assert.are.equal("get", r.action)
        assert.is_true(r.has_filter)
    end)

    it("reports no filter when none is active", function()
        local Handler, _ = setup({})

        local r = Handler.manageViewFilter({})

        assert.is_true(r.success)
        assert.is_false(r.has_filter)
    end)

    it("applies rules to the grid filter", function()
        local Handler, catalog = setup({})

        local r = Handler.manageViewFilter({
            action = "set",
            rules = {
                { criteria = "rating", operation = ">=", value = 3 },
                { criteria = "keywords", operation = "all", value = "boda" },
            },
        })

        assert.is_true(r.success)
        assert.are.equal(1, catalog.getViewFilterCallCount())
        local applied = catalog.getViewFilterHistory()[1]
        assert.are.equal("intersect", applied.combine)
        assert.are.equal("3", applied[1].value)
        assert.are.equal("boda", applied[2].value)
    end)

    it("clears the filter", function()
        local Handler, catalog = setup({})

        local r = Handler.manageViewFilter({ action = "clear" })

        assert.is_true(r.success)
        assert.are.equal(1, catalog.getViewFilterCallCount())
    end)

    it("validates action, rules shape and combine", function()
        local Handler, _ = setup({})

        assert.has_error(function() Handler.manageViewFilter({ action = "apply" }) end,
            "action must be 'get', 'set' or 'clear'")
        assert.has_error(function() Handler.manageViewFilter({ action = "set" }) end,
            "rules is required when action is 'set'")
        assert.has_error(function()
            Handler.manageViewFilter({
                action = "set",
                rules = { { criteria = "rating" } },
            })
        end, "rules[1].operation is required (e.g. 'all', 'any', '==', '>=', 'in', 'startsWith')")
        assert.has_error(function()
            Handler.manageViewFilter({
                action = "set",
                combine = "xor",
                rules = { { criteria = "rating", operation = ">=", value = 3 } },
            })
        end, "combine must be 'intersect' (AND, default) or 'union' (OR)")
    end)
end)
