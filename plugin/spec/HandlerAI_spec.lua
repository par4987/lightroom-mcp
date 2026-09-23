local helper = require 'spec_helper'

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

-- Minimal path/task mocks so the denoise polling and fallback logic can run
-- without a Lightroom. WIN_ENV/MAC_ENV are nil under busted, so the SendKeys
-- helper always reports unavailable and the hybrid path exercises its manual
-- fallback — exactly what the specs assert.
-- NOTE: LrPathUtils is a namespace (dot calls), so mocks take NO self arg.
local function pathMocks()
    return {
        parent = function(p) return p:match("^(.*)[/\\][^/\\]+$") or "/" end,
        leafName = function(p) return p:match("[^/\\]+$") or p end,
        removeExtension = function(p) return (p:gsub("%.[^./\\]+$", "")) end,
        child = function(dir, name) return dir .. "/" .. name end,
        getStandardFilePath = function() return "/tmp" end,
    }
end

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrPathUtils = pathMocks(),
        LrFileUtils = {
            directoryEntries = function(dir)
                if opts.folderContents then return opts.folderContents end
                return {}
            end,
            delete = function() end,
        },
        LrTasks = {
            sleep = function() end,
            execute = function() return "" end,
        },
    })
    package.loaded.HandlerAI = nil
    return catalog, require 'HandlerAI'
end

describe("HandlerAI.setNoiseReduction", function()
    it("maps friendly names onto SDK keys", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg", isoSpeedRating = "3200" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setNoiseReduction({
            photo_ids = { "1" },
            luminance = 40,
            color = 30,
            sharpen_radius = 1.2,
        })

        assert.is_true(r.success)
        assert.are.equal(1, r.updated)
        local applied = p1.getDevelopSettings()
        assert.are.equal(40, applied.LuminanceSmoothing)
        assert.are.equal(30, applied.ColorNoiseReduction)
        assert.are.equal(1.2, applied.SharpenRadius)
    end)

    it("validates slider ranges", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setNoiseReduction({ photo_ids = { "1" }, luminance = 101 })
        end)
        assert.has_error(function()
            Handler.setNoiseReduction({ photo_ids = { "1" }, sharpen_radius = 4 })
        end, "sharpen_radius must be between 0.5 and 3")
    end)

    it("requires at least one slider", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setNoiseReduction({ photo_ids = { "1" } })
        end, "at least one noise reduction parameter is required")
    end)

    it("requires photo_ids", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setNoiseReduction({ luminance = 10 }) end)
    end)
end)

describe("HandlerAI.aiDenoise", function()
    it("falls back to smart manual reduction when the native path is unavailable", function()
        local p1 = makePhoto({ id = "1", path = "/photos/IMG_1.NEF", fileFormat = "RAW", isoSpeedRating = "6400" })
        local catalog, Handler = setup({ photos = { p1 } })

        local r = Handler.aiDenoise({
            photo_id = "1",
            native_automation = { verify_timeout_s = 10 },
        })

        assert.is_true(r.success)
        assert.are.equal("manual_fallback", r.method)
        assert.is_not_nil(r.native_error)
        -- ISO 6400 bumps the default luminance to 55.
        assert.are.equal(55, p1.getDevelopSettings().LuminanceSmoothing)
        assert.are.equal(25, p1.getDevelopSettings().ColorNoiseReduction)
        -- The photo was selected so a real Enhance command would target it.
        assert.is_not_nil(catalog.getSelectionCall())
    end)

    it("accepts manual_settings overrides for the fallback", function()
        local p1 = makePhoto({ id = "1", path = "/photos/IMG_1.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.aiDenoise({
            photo_id = "1",
            manual_settings = { luminance = 20, color = 10 },
            native_automation = { verify_timeout_s = 10 },
        })

        assert.are.equal("manual_fallback", r.method)
        assert.are.equal(20, p1.getDevelopSettings().LuminanceSmoothing)
        assert.are.equal(10, p1.getDevelopSettings().ColorNoiseReduction)
    end)

    it("detects the new DNG and reports a native success", function()
        local p1 = makePhoto({ id = "1", path = "/photos/IMG_1.NEF", fileFormat = "RAW" })
        local dng = makePhoto({ id = 2, path = "/photos/IMG_1 - Enhance.dng", fileFormat = "DNG" })

        -- Folder starts without the DNG; the poll later sees it appear.
        local contents = { "IMG_1.NEF" }
        local catalog = helper.fakeCatalog({ photos = { p1, dng } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrPathUtils = pathMocks(),
            LrFileUtils = {
                directoryEntries = function()
                    return contents
                end,
                delete = function() end,
            },
            LrTasks = {
                sleep = function()
                    -- The DNG materializes while the first poll sleeps.
                    table.insert(contents, "IMG_1 - Enhance.dng")
                end,
                execute = function() return "" end,
            },
        })
        package.loaded.HandlerAI = nil
        local Handler = require 'HandlerAI'

        local r = Handler.aiDenoise({
            photo_id = "1",
            native_automation = { verify_timeout_s = 10 },
        })

        assert.is_true(r.success)
        assert.are.equal("native", r.method)
        assert.are.equal(2, r.new_photo_id)
        assert.are.equal("/photos/IMG_1 - Enhance.dng", r.new_photo_path)
        -- No manual sliders were touched on the source photo.
        assert.is_nil(p1.getDevelopSettings().LuminanceSmoothing)
    end)

    it("degrades gracefully for non-raw photos", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg", fileFormat = "JPG" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.aiDenoise({ photo_id = "1" })

        assert.are.equal("manual_fallback", r.method)
        assert.is_not_nil(r.reason:find("RAW or DNG", 1, true))
    end)

    it("errors when fallback is disabled and the native path fails", function()
        local p1 = makePhoto({ id = "1", path = "/photos/IMG_1.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.aiDenoise({
                photo_id = "1",
                fallback = "none",
                native_automation = { verify_timeout_s = 10 },
            })
        end)
    end)

    it("validates the fallback argument", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.aiDenoise({ photo_id = "1", fallback = "maybe" })
        end)
    end)
end)
