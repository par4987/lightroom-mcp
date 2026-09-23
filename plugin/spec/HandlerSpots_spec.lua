local helper = require 'spec_helper'

-- fakePhoto persists applies into developSettings now. This wrapper adds a
-- deep copy of array settings (so a later mutation of the applied table does
-- not alias back into the stored one); the spots handlers verify their writes
-- by reading the settings back, so specs need applies to be observable.
local function makePhoto(meta)
    meta = meta or {}
    meta.developSettings = meta.developSettings or {}
    local photo = helper.fakePhoto(meta)
    local rawApply = photo.applyDevelopSettings
    photo.applyDevelopSettings = function(_, settings, history)
        for k, v in pairs(settings) do
            if type(v) == "table" then
                local copy = {}
                for i, entry in ipairs(v) do copy[i] = entry end
                meta.developSettings[k] = copy
            else
                meta.developSettings[k] = v
            end
        end
        rawApply(_, settings, history)
    end
    return photo
end

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerSpots = nil
    return catalog, require 'HandlerSpots'
end

describe("HandlerSpots.parseSpotString", function()
    local _, Handler = setup({})

    it("parses a classic flat heal spot", function()
        local spot = Handler.parseSpotString(
            "( 0.250000, 0.500000 ), ( heal ), ( 0.100000, 0.500000 ), ( 0.050000 ), ( 1 ), ( 1 ), ( 0 )")
        assert.are.equal(0.25, spot.x)
        assert.are.equal(0.5, spot.y)
        assert.are.equal("heal", spot.type)
        assert.are.equal(0.1, spot.source_x)
        assert.are.equal(0.05, spot.radius)
        assert.are.same({ "1", "1", "0" }, spot.tail)
    end)

    it("treats unknown types as heal", function()
        local spot = Handler.parseSpotString(
            "( 0.250000, 0.500000 ), ( clone ), ( 0.100000, 0.500000 ), ( 0.050000 )")
        assert.are.equal("clone", spot.type)
    end)

    it("returns nil for non-flat strings", function()
        assert.is_nil(Handler.parseSpotString("garbage"))
        assert.is_nil(Handler.parseSpotString(""))
        assert.is_nil(Handler.parseSpotString(nil))
    end)
end)

describe("HandlerSpots.getSpots", function()
    it("lists parsed spots", function()
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = {
                RetouchInfo = {
                    "( 0.250000, 0.500000 ), ( heal ), ( 0.100000, 0.500000 ), ( 0.050000 ), ( 1 ), ( 1 ), ( 0 )",
                },
            },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.getSpots({ photo_id = "1" })

        assert.is_true(r.success)
        assert.are.equal(1, r.count)
        assert.are.equal("heal", r.spots[1].type)
        assert.are.equal(0.05, r.spots[1].radius)
    end)

    it("returns zero spots when none exist", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.getSpots({ photo_id = "1" })

        assert.are.equal(0, r.count)
    end)

    it("requires photo_id", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getSpots({}) end)
    end)

    it("errors on unknown photos", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getSpots({ photo_id = "nope" }) end)
    end)
end)

describe("HandlerSpots.addSpots", function()
    it("appends spots and preserves existing entries verbatim", function()
        local existing = "( 0.250000, 0.500000 ), ( heal ), ( 0.100000, 0.500000 ), ( 0.050000 ), ( 1 ), ( 1 ), ( 0 )"
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = { RetouchInfo = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addSpots({
            photo_id = "1",
            spots = {
                { x = 0.8, y = 0.2, radius = 0.03 },
                { x = 0.1, y = 0.9, radius = 0.07, type = "clone" },
            },
        })

        assert.is_true(r.success)
        assert.is_true(r.applied)
        assert.are.equal(1, r.before_count)
        assert.are.equal(3, r.after_count)

        local stored = p1.getDevelopSettings().RetouchInfo
        assert.are.equal(existing, stored[1])
        assert.is_not_nil(stored[2]:find("0%.800000", 1, false))
        assert.is_not_nil(stored[3]:find("clone"))
    end)

    it("reports when the write was not accepted", function()
        -- This Lightroom version refuses the RetouchInfo write outright.
        -- fakePhoto persists applies by default (read-back verification
        -- depends on it), so the refusal has to be explicit here.
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        p1.applyDevelopSettings = function() end
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addSpots({
            photo_id = "1",
            spots = { { x = 0.5, y = 0.5 } },
        })

        assert.is_false(r.success)
        assert.is_false(r.applied)
        assert.is_not_nil(r.message:find("did not accept", 1, true))
    end)

    it("validates the spots array", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.addSpots({ photo_id = "1" }) end)
        assert.has_error(function() Handler.addSpots({ photo_id = "1", spots = {} }) end)
        assert.has_error(function()
            Handler.addSpots({ photo_id = "1", spots = { { x = 0.5 } } })
        end, "spots[1] must include numeric x and y (normalized 0..1)")
        assert.has_error(function()
            Handler.addSpots({ photo_id = "1", spots = { { x = 0.5, y = 0.5, type = "magic" } } })
        end)
    end)

    it("caps batch size at 50", function()
        local _, Handler = setup({})
        local spots = {}
        for _ = 1, 51 do table.insert(spots, { x = 0.5, y = 0.5 }) end
        assert.has_error(function() Handler.addSpots({ photo_id = "1", spots = spots }) end)
    end)
end)

describe("HandlerSpots.clearSpots", function()
    it("removes all spots", function()
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = {
                RetouchInfo = {
                    "( 0.250000, 0.500000 ), ( heal ), ( 0.100000, 0.500000 ), ( 0.050000 ), ( 1 ), ( 1 ), ( 0 )",
                },
            },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.clearSpots({ photo_id = "1" })

        assert.is_true(r.success)
        assert.are.equal(1, r.before_count)
        assert.are.equal(0, r.after_count)
        assert.are.equal(0, #p1.getDevelopSettings().RetouchInfo)
    end)

    it("requires photo_id", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.clearSpots({}) end)
    end)
end)
