local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local exportSessionCalls = {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {} })
    -- In-memory destination tree (path -> "directory"). Lightroom does NOT
    -- create the destination folder, so the handler has to -- which means the
    -- specs need a filesystem where the folder starts missing.
    local fs = opts.fs or {}
    local mkdirCalls = {}
    -- Real SDK name/contract: LrFileUtils.createAllDirectories (SDK 1.3+)
    -- returns (made, detail); it does not raise.
    local fileUtils = opts.fileUtils or {
        exists = function(p) return fs[p] end,
        createAllDirectories = function(p)
            table.insert(mkdirCalls, p)
            fs[p] = "directory"
            return true
        end,
    }
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrFileUtils = fileUtils,
        LrPathUtils = {},
        LrExportSession = function(args)
            table.insert(exportSessionCalls, args)
            return {
                doExportOnCurrentTask = function() end,
            }
        end,
    })
    package.loaded.HandlerExport = nil
    return catalog, require 'HandlerExport', exportSessionCalls, mkdirCalls
end

describe("HandlerExport.exportPhotos", function()
    it("exports found photos with default JPEG settings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.is_true(r.success)
        assert.are.equal(1, r.exported)
        assert.are.equal("/out", r.destination)
        assert.are.equal("JPEG", calls[1].exportSettings.LR_format)
    end)

    it("never lets Lightroom prompt about existing files", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })
        assert.are.equal("rename", calls[1].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "overwrite" })
        assert.are.equal("overwrite", calls[2].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "skip" })
        assert.are.equal("skip", calls[3].exportSettings.LR_collisionHandling)
    end)

    it("rejects an unknown on_existing mode, including Lightroom's own ask", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "ask" })
        end, "on_existing must be one of: rename, overwrite, skip")
    end)

    it("rejects an unsupported format instead of silently exporting another", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = "bmp" })
        end, "format must be one of: jpeg, png, tiff, original")
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = 7 })
        end, "format must be one of: jpeg, png, tiff, original")
    end)

    it("applies width/height constraint", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", width = 2000 })

        local s = calls[1].exportSettings
        assert.is_true(s.LR_size_doConstrain)
        assert.are.equal(2000, s.LR_size_maxWidth)
    end)

    it("maps format strings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = "tiff" })
        assert.are.equal("TIFF", calls[1].exportSettings.LR_format)
    end)

    it("requires photo_ids and destination", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.exportPhotos({ destination = "/x" }) end)
        assert.has_error(function() Handler.exportPhotos({ photo_ids = { "1" } }) end)
    end)

    it("errors when no photos match", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "missing" }, destination = "/out" })
        end)
    end)

    it("runs the export after releasing catalog read access", function()
        -- Holding read access for the whole export wedged the bridge on
        -- macOS (issue #128). The lock must be released before
        -- doExportOnCurrentTask runs.
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local insideReadAccess = false
        local exportRanInsideReadAccess = nil
        local catalog = helper.fakeCatalog({ photos = { p } })
        local realWithRead = catalog.withReadAccessDo
        catalog.withReadAccessDo = function(self, fn)
            insideReadAccess = true
            realWithRead(self, fn)
            insideReadAccess = false
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = { exists = function() return "directory" end },
            LrPathUtils = {},
            LrExportSession = function()
                return {
                    doExportOnCurrentTask = function()
                        exportRanInsideReadAccess = insideReadAccess
                    end,
                }
            end,
        })
        package.loaded.HandlerExport = nil
        local Handler = require 'HandlerExport'

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.is_true(r.success)
        assert.are.equal(1, r.exported)
        assert.is_false(exportRanInsideReadAccess)
    end)

    it("creates the destination folder when it does not exist", function()
        -- Exporting into a missing folder fails with a Lightroom message in
        -- the UI's language; the handler creates it instead.
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls, mkdirs = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/tmp/new-dir" })

        assert.are.same({ "/tmp/new-dir" }, mkdirs)
        assert.is_true(r.created_directory)
        assert.is_true(r.success)
        assert.are.equal(1, #calls)
        assert.is_not_nil(r.message:find("destination folder created", 1, true))
    end)

    it("leaves an existing destination folder alone", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, _, mkdirs = setup({
            photos = { p },
            fs = { ["/out"] = "directory" },
        })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.are.same({}, mkdirs)
        assert.is_false(r.created_directory)
        assert.is_nil(r.message:find("destination folder created", 1, true))
    end)

    it("fails with the path when the folder cannot be created", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({
            photos = { p },
            fileUtils = {
                exists = function() return nil end,
                createAllDirectories = function() return nil end,
            },
        })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/nope" })
        end, "Destination folder does not exist and could not be created: /nope")
    end)
end)
