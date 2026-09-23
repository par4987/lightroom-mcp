local helper = require 'spec_helper'

local function fakePreset(name, opts)
    opts = opts or {}
    return {
        getName = function() return name end,
        getUuid = function() return opts.uuid or ("uuid-" .. name) end,
        getFile = function() return opts.file end,
        getSetting = function() return opts.settings or {} end,
    }
end

local function fakeFolder(name, presets)
    return {
        getName = function() return name end,
        getDevelopPresets = function() return presets end,
    }
end

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {} })
    local pluginPresets = opts.pluginPresets or {}
    local files = opts.files or {}
    local copies = {}
    local function leafName(path)
        return path:match("([^/\\]+)$") or path
    end
    local function extension(path)
        return leafName(path):match("%.([^%.]+)$") or ""
    end
    _G._PLUGIN = opts.plugin or { id = "com.lightroom.mcp" }
    -- LrDevelopController drives the Develop module UI (tone curves' Auto
    -- commands). opts.controller lets applyAuto specs install side effects;
    -- the default is a harmless no-op controller.
    local controllerDefaults = {
        setAutoTone = function() end,
        setAutoWhiteBalance = function() end,
    }
    local controller = opts.controller or controllerDefaults
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            developPresetFolders = function() return opts.folders or {} end,
            getDevelopPresetsForPlugin = function() return pluginPresets end,
            addDevelopPresetForPlugin = function(_, name, settings)
                local preset = fakePreset(name, {
                    uuid = "plugin-" .. tostring(#pluginPresets + 1),
                    file = "/plugin/" .. name .. ".xmp",
                    settings = settings,
                })
                table.insert(pluginPresets, preset)
                files[preset:getFile()] = "file"
                return preset
            end,
        },
        LrFileUtils = {
            exists = function(path) return files[path] or false end,
            createAllDirectories = function(path) files[path] = "directory" return true end,
            copy = function(source, destination)
                if files[source] ~= "file" or files[destination] then return false, "copy refused" end
                files[destination] = "file"
                table.insert(copies, { source = source, destination = destination })
                return true
            end,
        },
        LrPathUtils = {
            leafName = leafName,
            extension = extension,
            child = function(parent, child) return parent .. "/" .. child end,
        },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { sleep = function() end },
        LrApplicationView = { switchToModule = function() end },
        LrDevelopController = controller,
    })
    package.loaded.HandlerDevelop = nil
    return catalog, require 'HandlerDevelop', {
        pluginPresets = pluginPresets,
        files = files,
        copies = copies,
    }
end

describe("HandlerDevelop.listDevelopPresets", function()
    it("returns flat list with name + folder", function()
        local folders = {
            fakeFolder("User Presets", { fakePreset("Vibrant"), fakePreset("Moody") }),
            fakeFolder("Adobe Color", { fakePreset("Standard") }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.listDevelopPresets({})

        assert.is_true(r.success)
        assert.are.equal(3, r.count)
        assert.are.equal(3, #r.presets)
        assert.are.equal("Vibrant", r.presets[1].name)
        assert.are.equal("User Presets", r.presets[1].folder)
        assert.are.equal("Standard", r.presets[3].name)
        assert.are.equal("Adobe Color", r.presets[3].folder)
    end)

    it("returns empty list when no folders", function()
        local _, Handler = setup({ folders = {} })
        local r = Handler.listDevelopPresets({})
        assert.are.equal(0, r.count)
        assert.are.same({}, r.presets)
    end)

    it("includes UUID, scope, and plugin-managed checkpoints", function()
        local visible = fakePreset("Visible", { uuid = "visible-1", file = "/user/Visible.xmp" })
        local checkpoint = fakePreset("Look-v2", { uuid = "plugin-1", file = "/plugin/Look-v2.xmp" })
        local _, Handler = setup({
            folders = { fakeFolder("User Presets", { visible }) },
            pluginPresets = { checkpoint },
        })

        local r = Handler.listDevelopPresets({})

        assert.are.equal(2, r.count)
        assert.are.equal("lightroom", r.presets[1].scope)
        assert.are.equal("visible-1", r.presets[1].uuid)
        assert.are.equal("plugin", r.presets[2].scope)
        assert.are.equal("Plugin Develop Presets", r.presets[2].folder)
    end)
end)

describe("HandlerDevelop.getDevelopPreset", function()
    it("returns exact preset settings", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Exposure2012 = 0.25, ToneCurvePV2012 = { 0, 0, 255, 255 } },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { preset }) } })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.is_true(r.success)
        assert.are.equal("John Warm", r.name)
        assert.are.equal(2, r.setting_count)
        assert.are.same({ 0, 0, 255, 255 }, r.settings.ToneCurvePV2012)
    end)

    it("rejects ambiguous names", function()
        local folders = {
            fakeFolder("A", { fakePreset("Same", { uuid = "same-a" }) }),
            fakeFolder("B", { fakePreset("Same", { uuid = "same-b" }) }),
        }
        local _, Handler = setup({ folders = folders })

        assert.has_error(function()
            Handler.getDevelopPreset({ preset_name = "Same" })
        end, "Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end)

    it("accepts a name that resolves to one aliased preset", function()
        local shared = fakePreset("Portrait", {
            uuid = "portrait-1",
            settings = { Contrast2012 = 8 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_name = "Portrait" })

        assert.is_true(r.success)
        assert.are.equal("portrait-1", r.uuid)
    end)

    it("accepts duplicate Lightroom aliases selected by UUID", function()
        local shared = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Contrast2012 = 12 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.is_true(r.success)
        assert.are.equal("warm-1", r.uuid)
        assert.are.equal(12, r.settings.Contrast2012)
    end)
end)

describe("HandlerDevelop.compareDevelopPresets volatile ids", function()
    local function maskedPreset(name, uuid, correctionId, maskId, extra)
        return fakePreset(name, {
            uuid = uuid,
            settings = {
                Contrast2012 = extra or 10,
                MaskGroupBasedCorrections = {
                    {
                        CorrectionID = correctionId,
                        CorrectionActive = true,
                        CorrectionMasks = { { MaskID = maskId, MaskInverted = false } },
                    },
                },
            },
        })
    end

    it("ignores the per-read CorrectionID and MaskID Lightroom regenerates", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1")
        local candidate = maskedPreset("Masked B", "b", "correction-2", "mask-2")
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(0, r.changed_count)
        assert.are.same({}, r.changes)
    end)

    it("still reports a real difference inside a masked preset", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1", 10)
        local candidate = maskedPreset("Masked B", "b", "correction-2", "mask-2", 40)
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(40, r.changes[1].after)
    end)

    it("strips volatile ids from the reported diff values", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1")
        local candidate = fakePreset("Plain", {
            uuid = "b",
            settings = { Contrast2012 = 10 },
        })
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("MaskGroupBasedCorrections", r.changes[1].key)
        assert.is_true(r.changes[1].before_present)
        assert.is_false(r.changes[1].after_present)
        assert.is_nil(r.changes[1].before[1].CorrectionID)
        assert.is_nil(r.changes[1].before[1].CorrectionMasks[1].MaskID)
        assert.is_true(r.changes[1].before[1].CorrectionActive)
    end)
end)

describe("HandlerDevelop.compareDevelopPresets", function()
    it("returns deterministic setting differences", function()
        local base = fakePreset("Approved", {
            uuid = "base",
            settings = { Contrast2012 = 10, Vibrance = 5, Saturation = -2 },
        })
        local candidate = fakePreset("Candidate", {
            uuid = "candidate",
            settings = { Contrast2012 = 15, Vibrance = 5, Dehaze = 3 },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "base" },
            candidate = { preset_uuid = "candidate" },
        })

        assert.are.equal(3, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(15, r.changes[1].after)
        assert.are.equal("Dehaze", r.changes[2].key)
        assert.is_false(r.changes[2].before_present)
        assert.are.equal("Saturation", r.changes[3].key)
        assert.is_false(r.changes[3].after_present)
    end)
end)

describe("HandlerDevelop.createDevelopPreset", function()
    it("creates a versioned plugin checkpoint from explicit photo settings", function()
        local photo = helper.fakePhoto({
            id = "source",
            path = "/raw/source.nef",
            developSettings = {
                Exposure2012 = 0.5,
                Contrast2012 = 12,
                ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
                CropTop = 0.1,
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "source",
            preset_name = "John Warm v2",
            settings = { "Contrast2012", "ToneCurvePV2012" },
        })

        assert.is_true(r.success)
        assert.is_false(r.visible_in_develop)
        assert.are.equal("plugin", r.scope)
        assert.are.equal(1, #state.pluginPresets)
        assert.are.same({
            Contrast2012 = 12,
            ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
        }, state.pluginPresets[1]:getSetting())
    end)

    it("captures curves Lightroom stores off the 0-255 anchors", function()
        local photo = helper.fakePhoto({
            id = "source",
            path = "/raw/source.nef",
            developSettings = {
                ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 },
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "source",
            preset_name = "Clipped v1",
            settings = { "ToneCurvePV2012" },
        })

        assert.is_true(r.success)
        assert.are.same(
            { ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 } },
            state.pluginPresets[1]:getSetting()
        )
    end)

    it("refuses duplicate names and missing source settings", function()
        local existing = fakePreset("Existing")
        local photo = helper.fakePhoto({
            id = "source", path = "/raw/source.nef", developSettings = { Exposure2012 = 0.5 },
        })
        local _, Handler = setup({ photos = { photo }, pluginPresets = { existing } })

        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "source", preset_name = "Existing", settings = { "Exposure2012" },
            })
        end, "Plugin preset already exists; use a versioned preset_name")
        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "source", preset_name = "New", settings = { "Contrast2012" },
            })
        end, "Source photo has no develop setting: Contrast2012")
    end)
end)

describe("HandlerDevelop.exportDevelopPreset", function()
    it("copies the backing file without overwriting", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
        })
        local _, Handler, state = setup({
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/John Warm.xmp"] = "file" },
        })

        local r = Handler.exportDevelopPreset({
            preset_uuid = "warm-1",
            destination_dir = "/exports",
            filename = "John-Warm-v2",
        })

        assert.is_true(r.success)
        assert.are.equal("/exports/John-Warm-v2.xmp", r.destination)
        assert.are.equal("/user/John Warm.xmp", state.copies[1].source)
        assert.are.equal("/exports/John-Warm-v2.xmp", state.copies[1].destination)
    end)

    it("refuses path traversal, extension changes, and existing files", function()
        local preset = fakePreset("John Warm", { uuid = "warm-1", file = "/user/Warm.xmp" })
        local base = {
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/Warm.xmp"] = "file", ["/exports"] = "directory" },
        }
        local _, Handler = setup(base)

        assert.has_error(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "../escape.xmp",
            })
        end, "filename must be a leaf filename without path separators")
        assert.has_error(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.lrtemplate",
            })
        end, "filename extension must match preset backing file: .xmp")

        base.files["/exports/Warm.xmp"] = "file"
        local _, ExistingHandler = setup(base)
        assert.has_error(function()
            ExistingHandler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.xmp",
            })
        end, "destination preset already exists; choose a new filename")
    end)
end)

describe("HandlerDevelop.applyDevelopPreset", function()
    it("applies preset to resolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local preset = fakePreset("Vibrant")
        local folders = { fakeFolder("User", { preset }) }
        local _, Handler = setup({ photos = { p1, p2 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Vibrant" })

        assert.is_true(r.success)
        assert.are.equal(2, r.applied)
        assert.are.equal("Vibrant", r.preset)
        assert.are.equal("User", r.folder)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(preset, p2.getRawMetadata(p2, "__appliedPreset"))
    end)

    it("skips unresolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local folders = { fakeFolder("User", { fakePreset("Moody") }) }
        local _, Handler = setup({ photos = { p1 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "missing" }, preset_name = "Moody" })

        assert.are.equal(1, r.applied)
    end)

    it("passes the plugin object when applying a plugin-managed checkpoint", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Checkpoint", { uuid = "plugin-1" })
        local _, Handler = setup({ photos = { p1 }, pluginPresets = { preset } })

        local r = Handler.applyDevelopPreset({
            photo_ids = { "1" }, preset_uuid = "plugin-1", preset_scope = "plugin",
        })

        assert.is_true(r.success)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(_G._PLUGIN, p1.getRawMetadata(p1, "__appliedPresetPlugin"))
    end)

    it("errors on unknown preset", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local folders = { fakeFolder("User", { fakePreset("Vibrant") }) }
        local _, Handler = setup({ photos = { p1 }, folders = folders })

        assert.has_error(function()
            Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Nope" })
        end)
    end)

    it("requires photo_ids and preset_name", function()
        local catalog, Handler = setup({ folders = { fakeFolder("U", { fakePreset("X") }) } })
        assert.has_error(function() Handler.applyDevelopPreset({ preset_name = "X" }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = { "1" } }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = {}, preset_name = "X" }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = { "" }, preset_name = "X" }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)
end)

describe("HandlerDevelop numeric photo ids", function()
    it("accepts the numeric ids the catalog hands out", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local set = Handler.setDevelopSettings({
            photo_id = 10,
            settings = { Exposure2012 = 0.25 },
        })
        assert.is_true(set.success)

        local copied = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11 } })
        assert.are.equal(1, copied.copied)
    end)

    it("reports target ids that matched no photo", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg", developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11, "ghost" } })

        assert.are.equal(1, r.copied)
        assert.are.same({ "ghost" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("still rejects ids that are neither a number nor a non-empty string", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setDevelopSettings({ photo_id = true, settings = { Exposure2012 = 0 } })
        end, "photo_id is required")
        assert.has_error(function()
            Handler.copyDevelopSettings({ source_id = "s", target_ids = { {} } })
        end, "target_ids[1] must be a photo id or file path")
    end)
end)

describe("HandlerDevelop.copyDevelopSettings", function()
    it("copies all settings from source to targets", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg" })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.copied)
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t1.getRawMetadata(t1, "__appliedSettings")
        )
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t2.getRawMetadata(t2, "__appliedSettings")
        )
    end)

    it("filters by settings whitelist", function()
        local source = helper.fakePhoto({
            id = "20", path = "/s.jpg",
            developSettings = { Exposure2012 = 0.5, Contrast2012 = 10, Saturation = 20 },
        })
        local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "20",
            target_ids = { "21" },
            settings = { "Exposure2012", "Saturation" },
        })

        local applied = target.getRawMetadata(target, "__appliedSettings")
        assert.are.equal(0.5, applied.Exposure2012)
        assert.are.equal(20, applied.Saturation)
        assert.is_nil(applied.Contrast2012)
    end)

    it("copies HSL settings by whitelist", function()
        local source = helper.fakePhoto({
            id = "22", path = "/s.jpg",
            developSettings = {
                Exposure2012 = 0.5,
                HueAdjustmentOrange = -12,
                SaturationAdjustmentOrange = 18,
                LuminanceAdjustmentOrange = 7,
            },
        })
        local target = helper.fakePhoto({ id = "23", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "22",
            target_ids = { "23" },
            settings = { "HueAdjustmentOrange", "SaturationAdjustmentOrange", "LuminanceAdjustmentOrange" },
        })

        assert.are.same({
            HueAdjustmentOrange = -12,
            SaturationAdjustmentOrange = 18,
            LuminanceAdjustmentOrange = 7,
        }, target.getRawMetadata(target, "__appliedSettings"))
    end)

    it("errors when source missing", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.copyDevelopSettings({ source_id = "missing", target_ids = { "t" } })
        end)
    end)

    it("requires source_id and target_ids", function()
        local catalog, Handler = setup({})
        assert.has_error(function() Handler.copyDevelopSettings({ target_ids = { "t" } }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s" }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s", target_ids = {} }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s", target_ids = { "" } }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("rejects invalid settings whitelist before catalog access", function()
        local source = helper.fakePhoto({
            id = "20", path = "/s.jpg",
            developSettings = { Exposure2012 = 0.5 },
        })
        local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
        local catalog, Handler = setup({ photos = { source, target } })

        assert.has_error(function()
            Handler.copyDevelopSettings({
                source_id = "20",
                target_ids = { "21" },
                settings = { "UnsupportedSetting" },
            })
        end)

        assert.are.equal(0, catalog.getReadAccessCount())
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)
end)

describe("HandlerDevelop.setDevelopSettings", function()
    it("applies settings to the photo", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.75, Contrast2012 = 15 },
        })

        assert.is_true(r.success)
        assert.are.same(
            { Exposure2012 = 0.75, Contrast2012 = 15 },
            p.getRawMetadata(p, "__appliedSettings")
        )
    end)

    it("applies HSL settings to the photo", function()
        local p = helper.fakePhoto({ id = "2", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "2",
            settings = {
                HueAdjustmentRed = -5,
                SaturationAdjustmentOrange = -20,
                LuminanceAdjustmentYellow = 12,
            },
        })

        assert.is_true(r.success)
        assert.are.same({
            HueAdjustmentRed = -5,
            SaturationAdjustmentOrange = -20,
            LuminanceAdjustmentYellow = 12,
        }, p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("applies RGB composite and per-channel point curves", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local composite = { 0, 0, 64, 48, 192, 210, 255, 255 }
        local red = { 0, 4, 128, 132, 255, 250 }

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = {
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = composite,
                ToneCurvePV2012Red = red,
            },
        })

        assert.is_true(r.success)
        local applied = p.getRawMetadata(p, "__appliedSettings")
        assert.are.same(composite, applied.ToneCurvePV2012)
        assert.are.same(red, applied.ToneCurvePV2012Red)
    end)

    it("errors when photo not found", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.setDevelopSettings({ photo_id = "missing", settings = { Exposure2012 = 1 } })
        end)
    end)

    it("requires photo_id and settings table", function()
        local catalog, Handler = setup({})
        assert.has_error(function() Handler.setDevelopSettings({ settings = {} }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1" }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1", settings = "not-a-table" }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("rejects unsupported setting keys before catalog write", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.setDevelopSettings({
                photo_id = "1",
                settings = { UnsupportedSetting = 1 },
            })
        end)

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("rejects unsupported setting values before catalog write", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.setDevelopSettings({
                photo_id = "1",
                settings = { Exposure2012 = { nested = true } },
            })
        end)

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("rejects malformed point curves before catalog write", function()
        local invalidCurves = {
            { 0, 0, 128, 120, 255 },
            { 0, 0, 128, 120, 100, 150, 255, 255 },
            { 0, 0, 255, 300 },
            { 10, 0, 255, 255 },
            { 0, 0, 240, 255 },
            { 0, 0, 128.5, 120, 255, 255 },
        }

        for _, curve in ipairs(invalidCurves) do
            local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
            local catalog, Handler = setup({ photos = { p } })

            assert.has_error(function()
                Handler.setDevelopSettings({
                    photo_id = "1",
                    settings = { ToneCurvePV2012 = curve },
                })
            end)

            assert.are.equal(0, catalog.getWriteAccessCount())
            assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
        end
    end)

    it("reads the settings back and reports what Lightroom stored", function()
        -- The only writer in the server that used to return success on the
        -- strength of the write call alone; everything else verifies.
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.75, Contrast2012 = 15 },
        })

        assert.is_true(r.success)
        assert.are.same({ Exposure2012 = 0.75, Contrast2012 = 15 }, r.verified)
        assert.is_nil(r.not_applied)
        assert.is_nil(r.warning)
        -- the read-back must come from the photo's stored settings, not from
        -- the arguments it was handed
        assert.are.same(r.verified, p.getDevelopSettings(p))
    end)

    it("names the keys Lightroom refused to store", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        -- Model Lightroom dropping a key it will not store for this photo.
        local accept = p.applyDevelopSettings
        p.applyDevelopSettings = function(self, settings)
            local stored = {}
            for k, v in pairs(settings) do
                if k ~= "Contrast2012" then stored[k] = v end
            end
            accept(self, stored)
        end
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.5, Contrast2012 = 40 },
        })

        assert.is_true(r.success)
        assert.are.same({ "Contrast2012" }, r.not_applied)
        assert.is_nil(r.verified.Contrast2012)
        assert.are.equal(0.5, r.verified.Exposure2012)
        assert.is_not_nil(r.warning:find("Contrast2012", 1, true))
    end)

    it("does not fail a stored float that Lightroom normalised", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local accept = p.applyDevelopSettings
        p.applyDevelopSettings = function(self, settings)
            local stored = {}
            for k, v in pairs(settings) do stored[k] = v end
            stored.Exposure2012 = 0.7500001
            accept(self, stored)
        end
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.75 },
        })

        assert.is_nil(r.not_applied)
        assert.is_nil(r.warning)
    end)
end)

describe("HandlerDevelop.setWhiteBalance", function()
    local function makePhoto(meta)
        meta = meta or {}
        meta.developSettings = meta.developSettings or {}
        local photo = helper.fakePhoto(meta)
        local rawApply = photo.applyDevelopSettings
        photo.applyDevelopSettings = function(_, settings, history)
            for k, v in pairs(settings) do
                meta.developSettings[k] = v
            end
            rawApply(_, settings, history)
        end
        return photo
    end

    it("applies a WB preset with the flattenAuto flag", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setWhiteBalance({ photo_ids = { "1" }, preset = "Auto" })

        assert.is_true(r.success)
        assert.are.equal(1, r.updated)
        local applied = p.getRawMetadata(p, "__appliedSettings")
        assert.are.equal("Auto", applied.WhiteBalance)
        -- optFlattenAutoNow was requested (3rd argument of applyDevelopSettings).
        assert.is_nil(r.warning)
    end)

    it("applies custom Kelvin temperature and tint", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setWhiteBalance({ photo_ids = { "1" }, temperature = 5600, tint = 8 })

        assert.is_true(r.success)
        local applied = p.getRawMetadata(p, "__appliedSettings")
        assert.are.equal("Custom", applied.WhiteBalance)
        assert.are.equal(5600, applied.Temperature)
        assert.are.equal(8, applied.Tint)
    end)

    it("warns when photos are not RAW/DNG", function()
        local p = makePhoto({ id = "1", path = "/a.jpg", fileFormat = "JPG" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setWhiteBalance({ photo_ids = { "1" }, preset = "Daylight" })

        assert.is_true(r.success)
        assert.is_not_nil(r.warning)
    end)

    it("validates presets and ranges", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.setWhiteBalance({ photo_ids = { "1" }, preset = "Sunny" })
        end, "preset must be one of: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash")

        assert.has_error(function()
            Handler.setWhiteBalance({ photo_ids = { "1" }, temperature = 100 })
        end)

        assert.has_error(function()
            Handler.setWhiteBalance({ photo_ids = { "1" }, tint = 999 })
        end)

        assert.has_error(function()
            Handler.setWhiteBalance({ photo_ids = { "1" } })
        end, "provide a preset, or temperature and/or tint")

        assert.has_error(function()
            Handler.setWhiteBalance({ preset = "Auto" })
        end)
    end)
end)

describe("HandlerDevelop.setToneCurve", function()
    local function makePhoto(meta)
        meta = meta or {}
        meta.developSettings = meta.developSettings or {}
        local photo = helper.fakePhoto(meta)
        local rawApply = photo.applyDevelopSettings
        photo.applyDevelopSettings = function(_, settings, history)
            for k, v in pairs(settings) do
                meta.developSettings[k] = v
            end
            rawApply(_, settings, history)
        end
        return photo
    end

    it("sets a custom main curve and reads it back", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setToneCurve({
            photo_id = "1",
            channel = "main",
            points = { { 0, 0 }, { 64, 56 }, { 192, 202 }, { 255, 255 } },
        })

        assert.is_true(r.success)
        assert.are.equal("main", r.channel)
        assert.are.equal("Custom", r.curve_name)
        assert.are.same({ 0, 0, 64, 56, 192, 202, 255, 255 }, r.verified.raw)
        assert.are.same(
            { { 0, 0 }, { 64, 56 }, { 192, 202 }, { 255, 255 } },
            r.verified.points
        )
        assert.is_nil(r.endpoints_added)
    end)

    it("targets RGB channels and stores the flat SDK array", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setToneCurve({
            photo_id = "1",
            channel = "blue",
            points = { { 0, 0 }, { 128, 128 }, { 255, 255 } },
        })

        assert.is_true(r.success)
        assert.are.same({ 0, 0, 128, 128, 255, 255 }, p.getRawMetadata(p, "__appliedSettings").ToneCurvePV2012Blue)
    end)

    it("adds missing endpoints automatically and reports it", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setToneCurve({
            photo_id = "1",
            points = { { 128, 140 } },
        })

        assert.is_true(r.success)
        assert.is_true(r.endpoints_added)
        assert.are.same(
            { 0, 0, 128, 140, 255, 255 },
            r.verified.raw
        )
    end)

    it("applies built-in curve presets with their UI names", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileFormat = "RAW" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setToneCurve({ photo_id = "1", preset = "medium_contrast" })

        assert.is_true(r.success)
        assert.are.equal("Medium Contrast", r.curve_name)
        assert.are.same({ 0, 0, 64, 56, 128, 128, 192, 202, 255, 255 }, r.verified.raw)
    end)

    it("validates channels, points, and monotonic x", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.setToneCurve({ photo_id = "1", channel = "cyan", points = { { 0, 0 }, { 255, 255 } } })
        end)

        assert.has_error(function()
            Handler.setToneCurve({ photo_id = "1", points = {} })
        end)

        assert.has_error(function()
            Handler.setToneCurve({
                photo_id = "1",
                points = { { 0, 0 }, { 128, 128 }, { 100, 90 }, { 255, 255 } },
            })
        end)

        assert.has_error(function()
            Handler.setToneCurve({
                photo_id = "1",
                points = { { 0, 0 }, { 128, 300 }, { 255, 255 } },
            })
        end)

        assert.has_error(function()
            Handler.setToneCurve({ photo_id = "1", preset = "s-curve" })
        end)

        -- No points and no preset surfaces the friendly points validation
        -- (the anyOf gate lives in the MCP schema, validated TS-side).
        assert.has_error(function()
            Handler.setToneCurve({ photo_id = "1" })
        end, "points must be an array of at least 1 [x, y] pair")
    end)

    it("errors when the photo does not exist", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setToneCurve({ photo_id = "404", points = { { 0, 0 }, { 255, 255 } } })
        end, "No photo matched photo_id")
    end)
end)

describe("HandlerDevelop.getToneCurve", function()
    it("returns every channel as points plus the curve name", function()
        local p = helper.fakePhoto({
            id = "1",
            path = "/a.NEF",
            developSettings = {
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = { 0, 0, 128, 140, 255, 255 },
                ToneCurvePV2012Red = { 0, 0, 255, 255 },
            },
        })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.getToneCurve({ photo_id = "1" })

        assert.is_true(r.success)
        assert.are.equal("Custom", r.curve_name)
        assert.are.same({ { 0, 0 }, { 128, 140 }, { 255, 255 } }, r.channels.main.points)
        assert.are.same({ { 0, 0 }, { 255, 255 } }, r.channels.red.points)
        assert.are.same({}, r.channels.green.points)
        assert.is_nil(r.channels.green.raw)
    end)

    it("validates photo_id and unknown photos", function()
        local _, Handler = setup({})

        assert.has_error(function()
            Handler.getToneCurve({})
        end, "photo_id is required")

        assert.has_error(function()
            Handler.getToneCurve({ photo_id = "404" })
        end, "No photo matched photo_id")
    end)
end)

describe("HandlerDevelop.applyAuto", function()
    -- getDevelopSettings must return a fresh copy per call: the handler
    -- diffs before/after, and the controller mocks mutate the source table.
    local function makePhoto(meta)
        meta = meta or {}
        meta.developSettings = meta.developSettings or {}
        local photo = helper.fakePhoto(meta)
        photo.getDevelopSettings = function()
            local copy = {}
            for k, v in pairs(meta.developSettings) do copy[k] = v end
            return copy
        end
        return photo, meta
    end

    it("runs both Auto commands and reports what changed per photo", function()
        local p, meta = makePhoto({
            id = "1",
            path = "/a.NEF",
            fileName = "a.NEF",
        })
        meta.developSettings = {
            Exposure2012 = 0,
            Temperature = 5500,
        }
        -- The controller's side effects simulate Lightroom's Auto analysis.
        local _, Handler = setup({
            photos = { p },
            controller = {
                setAutoTone = function()
                    meta.developSettings.Exposure2012 = 0.35
                end,
                setAutoWhiteBalance = function()
                    meta.developSettings.Temperature = 6100
                end,
            },
        })

        local r = Handler.applyAuto({ photo_ids = { "1" } })

        assert.is_true(r.success)
        assert.are.equal(1, r.succeeded)
        assert.are.same({ "tone", "white_balance" }, r.operations)
        local entry = r.results[1]
        assert.is_true(entry.applied.tone)
        assert.is_true(entry.applied.white_balance)
        assert.are.equal(0, entry.changed.Exposure2012.before)
        assert.are.equal(0.35, entry.changed.Exposure2012.after)
        assert.are.equal(5500, entry.changed.Temperature.before)
        assert.are.equal(6100, entry.changed.Temperature.after)
    end)

    it("runs a single operation when asked", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileName = "a.NEF" })
        local calls = {}
        local _, Handler = setup({
            photos = { p },
            controller = {
                setAutoTone = function() calls.tone = true end,
                setAutoWhiteBalance = function() calls.wb = true end,
            },
        })

        local r = Handler.applyAuto({ photo_ids = { "1" }, operations = { "white_balance" } })

        assert.is_true(r.success)
        assert.is_nil(calls.tone)
        assert.is_true(calls.wb)
        assert.are.same({ "white_balance" }, r.operations)
        assert.is_nil(r.results[1].applied.tone)
    end)

    it("notes honestly when Auto changes no sliders", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileName = "a.NEF" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.applyAuto({ photo_ids = { "1" } })

        assert.is_true(r.success)
        assert.is_nil(r.results[1].changed)
        assert.is_not_nil(r.results[1].note)
    end)

    it("reports command failures per photo instead of failing the batch", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileName = "a.NEF" })
        local _, Handler = setup({
            photos = { p },
            controller = {
                setAutoTone = function() error("auto tone unavailable") end,
                setAutoWhiteBalance = function() end,
            },
        })

        local r = Handler.applyAuto({ photo_ids = { "1" } })

        assert.is_false(r.success)
        assert.are.equal(0, r.succeeded)
        assert.is_false(r.results[1].applied.tone)
        assert.are.equal("auto tone unavailable", (r.results[1].tone_error:gsub("^.*: ", "")))
    end)

    it("validates operations and photo_ids", function()
        local p = makePhoto({ id = "1", path = "/a.NEF", fileName = "a.NEF" })
        local _, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.applyAuto({ photo_ids = { "1" }, operations = { "denoise" } })
        end)

        assert.has_error(function()
            Handler.applyAuto({})
        end, "photo_ids is required")
    end)
end)

describe("HandlerDevelop.getDevelopSettings", function()
    it("returns the whitelisted basic fields by default", function()
        local photo = helper.fakePhoto({
            id = "914", path = "/a.jpg", fileName = "a.jpg",
            developSettings = {
                Exposure2012 = 0.5, Contrast2012 = 10, Temperature = 5500,
                MaskGroupBasedCorrections = { { deep = true } },
                SomethingExotic = "value",
            },
        })
        local _, Handler = setup({ photos = { photo } })

        local r = Handler.getDevelopSettings({ photo_id = "914" })

        assert.is_true(r.success)
        assert.are.equal("basic", r.fields)
        assert.are.equal(0.5, r.settings.Exposure2012)
        assert.are.equal(10, r.settings.Contrast2012)
        assert.are.equal(5500, r.settings.Temperature)
        assert.is_nil(r.settings.MaskGroupBasedCorrections)
        assert.is_nil(r.settings.SomethingExotic)
    end)

    it("fields='all' passes everything serializable through", function()
        local photo = helper.fakePhoto({
            id = "914",
            developSettings = {
                Exposure2012 = -0.3,
                ToneCurvePV2012 = { 0, 0, 255, 255 },
                RetouchInfo = { "( x, y )", "( heal )" },
            },
        })
        local _, Handler = setup({ photos = { photo } })

        local r = Handler.getDevelopSettings({ photo_id = "914", fields = "all" })

        assert.are.equal("all", r.fields)
        assert.are.equal(-0.3, r.settings.Exposure2012)
        assert.are.same({ 0, 0, 255, 255 }, r.settings.ToneCurvePV2012)
        assert.are.same({ "( x, y )", "( heal )" }, r.settings.RetouchInfo)
    end)

    it("skips non-serializable fields honestly instead of failing", function()
        local photo = helper.fakePhoto({
            id = "914",
            developSettings = {
                Exposure2012 = 1,
                Recursive = nil, -- placeholder; real case is deep tables
            },
        })
        -- Build a >6-level-deep value that cloneSerializable must skip.
        local deep = {}
        local cursor = deep
        for _ = 1, 10 do
            cursor.child = {}
            cursor = cursor.child
        end
        photo.__meta.developSettings.TooDeep = deep

        local _, Handler = setup({ photos = { photo } })

        local r = Handler.getDevelopSettings({ photo_id = "914", fields = "all" })

        assert.is_true(r.success)
        assert.is_nil(r.settings.TooDeep)
        assert.are.same({ "TooDeep" }, r.skipped_fields)
    end)

    it("validates photo_id and fields", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getDevelopSettings({}) end,
            "photo_id is required")
        assert.has_error(function()
            Handler.getDevelopSettings({ photo_id = "914", fields = "everything" })
        end, "fields must be 'basic' (default) or 'all'")
        assert.has_error(function()
            Handler.getDevelopSettings({ photo_id = "404" })
        end, "No photo matched photo_id")
    end)
end)

describe("HandlerDevelop.resetDevelop", function()
    local function resetController()
        return {
            resetAllDevelopAdjustments = function() end,
            resetCrop = function() end,
            resetTransforms = function() end,
            resetSpotRemoval = function() end,
            resetRedeye = function() end,
            resetHealing = function() end,
            resetMasking = function() end,
            resetGradient = function() end,
            resetCircularGradient = function() end,
            resetBrushing = function() end,
            resetToDefault = function() end,
        }
    end

    local function photoWithSettings()
        return helper.fakePhoto({
            id = "914", path = "/a.jpg", fileName = "a.jpg",
            developSettings = { Exposure2012 = 2, Contrast2012 = 40 },
        })
    end

    it("scope=all calls resetAllDevelopAdjustments as a bare command (no write gate)", function()
        local called = {}
        local controller = resetController()
        controller.resetAllDevelopAdjustments = function() called.all = true end
        local photo = photoWithSettings()
        local catalog, Handler = setup({ photos = { photo }, controller = controller })

        local r = Handler.resetDevelop({ photo_id = "914" })

        assert.is_true(r.success)
        assert.is_true(called.all)
        assert.is_true(r.applied.all)
        -- LrDevelopController.resetAllDevelopAdjustments() is a UI-command
        -- call that manages its own catalog transaction; wrapping it in our
        -- own withWriteAccessDo nests a second write request that real
        -- Lightroom always rejects ("blocked by another write access
        -- call"). Assert it stays bare, unlike the withReadAccessDo calls
        -- used to resolve the photo and read back settings.
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("scope=tools resets only the requested tools", function()
        local controller = resetController()
        local resetCalls = {}
        controller.resetCrop = function() table.insert(resetCalls, "crop") end
        controller.resetTransforms = function() table.insert(resetCalls, "transforms") end
        local _, Handler = setup({ photos = { photoWithSettings() }, controller = controller })

        local r = Handler.resetDevelop({ photo_id = "914", scope = "tools", tools = { "crop" } })

        assert.is_true(r.success)
        assert.are.same({ "crop" }, resetCalls)
        assert.is_true(r.applied.crop)
    end)

    it("scope=params resets allowlisted parameters", function()
        local controller = resetController()
        local paramsReset = {}
        controller.resetToDefault = function(key) table.insert(paramsReset, key) end
        local _, Handler = setup({ photos = { photoWithSettings() }, controller = controller })

        local r = Handler.resetDevelop({
            photo_id = "914",
            scope = "params",
            params = { "Exposure2012", "Contrast2012" },
        })

        assert.is_true(r.success)
        assert.are.same({ "Exposure2012", "Contrast2012" }, paramsReset)
    end)

    it("reports per-reset errors honestly", function()
        local controller = resetController()
        controller.resetCrop = function() error("no crop to reset") end
        local _, Handler = setup({ photos = { photoWithSettings() }, controller = controller })

        local r = Handler.resetDevelop({ photo_id = "914", scope = "tools", tools = { "crop" } })

        assert.is_false(r.success)
        assert.is_not_nil(r.errors.crop)
    end)

    it("validates scope, tools and params", function()
        local _, Handler = setup({ photos = { photoWithSettings() } })
        assert.has_error(function()
            Handler.resetDevelop({ photo_id = "914", scope = "everything" })
        end, "scope must be 'all' (default), 'tools' or 'params'")
        assert.has_error(function()
            Handler.resetDevelop({ photo_id = "914", scope = "tools" })
        end, "tools array is required when scope is 'tools'")
        assert.has_error(function()
            Handler.resetDevelop({ photo_id = "914", scope = "tools", tools = { "lens" } })
        end, "tools[1] 'lens' is not a resettable tool")
        assert.has_error(function()
            Handler.resetDevelop({ photo_id = "914", scope = "params", params = { "Nope" } })
        end, "Unsupported develop setting key: Nope")
        assert.has_error(function() Handler.resetDevelop({}) end, "photo_id is required")
    end)
end)

describe("HandlerDevelop.setProcessVersion", function()
    it("switches the process version and verifies via read-back", function()
        local reads = 0
        local currentVersion = "Version 3"
        local controller = {
            getProcessVersion = function()
                reads = reads + 1
                return currentVersion
            end,
            setProcessVersion = function(v)
                currentVersion = v
            end,
        }
        local photo = helper.fakePhoto({ id = "914", path = "/a.jpg", fileName = "a.jpg" })
        local _, Handler = setup({ photos = { photo }, controller = controller })

        local r = Handler.setProcessVersion({ photo_id = "914", version = "Version 6" })

        assert.is_true(r.success)
        assert.are.equal("Version 3", r.before)
        assert.are.equal("Version 6", r.after)
        assert.is_true(r.verified)
        assert.are.equal("Version 6", currentVersion)
    end)

    it("warns when Lightroom reports a different version afterwards", function()
        local controller = {
            getProcessVersion = function() return "Version 3" end,
            setProcessVersion = function() end,
        }
        local photo = helper.fakePhoto({ id = "914" })
        local _, Handler = setup({ photos = { photo }, controller = controller })

        local r = Handler.setProcessVersion({ photo_id = "914", version = "Version 6" })

        assert.is_true(r.success)
        assert.is_false(r.verified)
        assert.is_not_nil(r.warning)
    end)

    it("surfaces setProcessVersion failures", function()
        local controller = {
            getProcessVersion = function() return "Version 3" end,
            setProcessVersion = function() error("unsupported on this file") end,
        }
        local photo = helper.fakePhoto({ id = "914" })
        local _, Handler = setup({ photos = { photo }, controller = controller })

        assert.has_error(function()
            Handler.setProcessVersion({ photo_id = "914", version = "Version 6" })
        end, "setProcessVersion failed")
    end)
end)

describe("HandlerDevelop.createSnapshot", function()
    it("creates the snapshot inside a write gate and reports honestly", function()
        local photo = helper.fakePhoto({ id = "914", path = "/a.jpg", fileName = "a.jpg" })
        local catalog, Handler = setup({ photos = { photo } })

        local r = Handler.createSnapshot({ photo_id = "914", name = "antes del lote" })

        assert.is_true(r.success)
        assert.are.same({ "antes del lote" }, photo.__meta.__snapshots)
        assert.are.equal(1, catalog.getWriteAccessCount())
        assert.is_not_nil(r.note)
    end)

    it("validates name and photo_id", function()
        local photo = helper.fakePhoto({ id = "914" })
        local _, Handler = setup({ photos = { photo } })
        assert.has_error(function() Handler.createSnapshot({ photo_id = "914" }) end,
            "name is required")
        assert.has_error(function() Handler.createSnapshot({ name = "x" }) end,
            "photo_id is required")
    end)
end)
