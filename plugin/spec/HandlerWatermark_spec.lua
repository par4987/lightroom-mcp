local helper = require 'spec_helper'

local function setup(dirContents)
    helper.installImport({
        LrPathUtils = {
            getStandardFilePath = function() return "C:/Users/z/AppData/Roaming/Adobe/Lightroom" end,
            child = function(dir, name) return dir .. "/" .. name end,
        },
        LrFileUtils = {
            directoryEntries = function()
                return dirContents
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerWatermark = nil
    return require 'HandlerWatermark'
end

describe("HandlerWatermark.listWatermarks", function()
    it("lists .watermark presets by file base name", function()
        local Handler = setup({
            "Copyright Juan.watermark",
            "Logo studio.watermark",
            "notes.txt",
            ".DS_Store",
        })

        local r = Handler.listWatermarks({})

        assert.is_true(r.success)
        assert.are.same({ "Copyright Juan", "Logo studio" }, r.watermarks)
        assert.are.equal(2, r.count)
    end)

    it("returns an empty list with guidance when no presets exist", function()
        local Handler = setup({})

        local r = Handler.listWatermarks({})

        assert.is_true(r.success)
        assert.are.equal(0, r.count)
        assert.is_not_nil(r.message:find("Edit Watermarks", 1, true))
    end)

    it("survives a missing presets folder", function()
        helper.installImport({
            LrPathUtils = {
                getStandardFilePath = function() return "C:/Users/z/AppData/Roaming/Adobe/Lightroom" end,
                child = function(dir, name) return dir .. "/" .. name end,
            },
            LrFileUtils = {
                directoryEntries = function() error("no such directory") end,
            },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.HandlerWatermark = nil
        local Handler = require 'HandlerWatermark'

        local r = Handler.listWatermarks({})
        assert.are.equal(0, r.count)
    end)
end)
