local helper = require 'spec_helper'

-- LrDevelopController mock: the AI masking surface. `masks` is the list
-- getAllMasks returns; deleteMask removes by id when the id matches.
local function makeControllerMock(opts, getActivePhoto)
    opts = opts or {}
    local state = {
        masks = opts.masks or {},
        createdMasks = {},
        deletedMasks = {},
        setValues = {},
        selectedTool = opts.selectedTool,
        selectToolCalls = {},
        createError = opts.createError,
        overlayToggles = 0,
        resetMaskingCalls = 0,
        goToMaskingCalls = 0,
    }
    local controller = {
        getSelectedTool = function() return state.selectedTool end,
        goToMasking = function() state.goToMaskingCalls = state.goToMaskingCalls + 1 end,
        toggleOverlay = function() state.overlayToggles = state.overlayToggles + 1 end,
        resetMasking = function()
            state.resetMaskingCalls = state.resetMaskingCalls + 1
            state.masks = {}
        end,
        selectTool = function(tool)
            table.insert(state.selectToolCalls, tool)
            state.selectedTool = tool
        end,
        createNewMask = function(maskType, subtype)
            if state.createError then error(state.createError) end
            local maskId = "mask-" .. (#state.createdMasks + 1)
            table.insert(state.createdMasks, { maskType = maskType, subtype = subtype, id = maskId })
            table.insert(state.masks, { id = maskId })
            -- Mirror Lightroom: the new mask arrives with a correction to hold
            -- its sliders, attached to the photo loaded in Develop.
            local photo = getActivePhoto and getActivePhoto() or nil
            if photo then
                local settings = photo.getDevelopSettings()
                settings.MaskGroupBasedCorrections = settings.MaskGroupBasedCorrections or {}
                table.insert(settings.MaskGroupBasedCorrections, {
                    What = "Correction",
                    CorrectionAmount = 1,
                    CorrectionActive = true,
                    CorrectionMasks = { { MaskID = maskId } },
                })
            end
            return maskId
        end,
        setValue = function(key, value)
            state.setValues[key] = value
        end,
        getAllMasks = function() return state.masks end,
        deleteMask = function(maskId)
            table.insert(state.deletedMasks, maskId)
            for i, m in ipairs(state.masks) do
                if m.id == maskId then table.remove(state.masks, i) return end
            end
        end,
    }
    return controller, state
end

-- A photo whose applyDevelopSettings lands in developSettings, so the
-- handler's read-modify-write of MaskGroupBasedCorrections round-trips the way
-- it does in Lightroom. fakePhoto persists too now; this wrapper keeps the
-- explicit seed-then-apply shape the read-modify-write tests depend on.
local function makePhoto(meta)
    meta.developSettings = meta.developSettings or {}
    local photo = helper.fakePhoto(meta)
    local rawApply = photo.applyDevelopSettings
    photo.applyDevelopSettings = function(selfRef, settings, ...)
        for k, v in pairs(settings) do meta.developSettings[k] = v end
        return rawApply(selfRef, settings, ...)
    end
    return photo
end

-- Seeds MaskGroupBasedCorrections directly: list_masks and remove_mask now read
-- and write the STORED table rather than LrDevelopController.getAllMasks(),
-- because getAllMasks() does not see corrections written through
-- applyDevelopSettings -- which made anything add_local_adjustment created
-- impossible to delete.
local function seedCorrections(ctx, corrections)
    ctx.photo.getDevelopSettings().MaskGroupBasedCorrections = corrections
    -- forceRecompute asks for a throwaway thumbnail.
    ctx.photo.requestJpegThumbnail = function(_, _w, _h, callback) callback("jpeg", nil) end
end

local function storedMask(id, name, what)
    return {
        MaskID = id, MaskName = name, What = what or "Mask/CircularGradient",
        MaskActive = true, MaskInverted = false, MaskValue = 1,
    }
end

local function storedCorrection(id, masks)
    return {
        What = "Correction", CorrectionID = id, CorrectionActive = true,
        CorrectionAmount = 1, CorrectionMasks = masks,
    }
end

-- Mask sliders live in the photo's correction, NOT in LrDevelopController
-- .setValue -- that call edits the photo-wide sliders instead of the mask (see
-- the ADJUSTMENTS note in HandlerAIMasks.lua). Assert where they really land.
local function correctionFor(photo, maskId)
    local corrections = photo.getDevelopSettings().MaskGroupBasedCorrections or {}
    for _, correction in ipairs(corrections) do
        for _, mask in ipairs(correction.CorrectionMasks or {}) do
            if mask.MaskID == maskId then return correction end
        end
    end
    return nil
end

local function setup(opts)
    opts = opts or {}
    local photo = makePhoto({
        localIdentifier = 914,
        id = 914,
        path = "C:/photos/wedding-001.cr2",
        fileName = "wedding-001.cr2",
    })
    local photo2 = makePhoto({
        localIdentifier = 915,
        id = 915,
        path = "C:/photos/wedding-002.cr2",
        fileName = "wedding-002.cr2",
    })
    local catalog = helper.fakeCatalog({ photos = { photo, photo2 } })

    -- Creating a mask in Lightroom also creates the correction that carries its
    -- sliders, on whichever photo is loaded in Develop. Without that link the
    -- handler's adjustment write has nothing to find, so the mock mirrors it.
    local controller, controllerState = makeControllerMock(opts, function()
        local call = catalog.getSelectionCall()
        return call and call.active or nil
    end)

    local moduleSwitches = {}
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        -- startAsyncTask runs its body immediately: the handler spawns a fresh
        -- task for the adjustment write (see HandlerAIMasks.lua:400) and then
        -- polls a done-flag with sleep, which is a no-op here.
        LrTasks = {
            sleep = function() end,
            startAsyncTask = function(fn) fn() end,
        },
        LrApplicationView = {
            switchToModule = function(name) table.insert(moduleSwitches, name) end,
        },
        LrDevelopController = controller,
    })
    package.loaded.HandlerAIMasks = nil
    local Handler = require 'HandlerAIMasks'
    return {
        handler = Handler,
        catalog = catalog,
        photo = photo,
        photo2 = photo2,
        controller = controller,
        controllerState = controllerState,
        moduleSwitches = moduleSwitches,
    }
end

describe("HandlerAIMasks.addAIMask", function()
    it("creates the AI mask per photo and applies adjustments to it", function()
        local ctx = setup()
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "subject",
            adjustments = { exposure = 0.5, clarity = 10 },
        })

        assert.is_true(r.success)
        assert.are.equal(1, r.succeeded)
        assert.are.equal(1, #ctx.controllerState.createdMasks)
        assert.are.equal("aiSelection", ctx.controllerState.createdMasks[1].maskType)
        assert.are.equal("subject", ctx.controllerState.createdMasks[1].subtype)
        -- Exposure is EV (unscaled); every other slider is stored as a
        -- fraction of its -100..100 UI range.
        local correction = correctionFor(ctx.photo, "mask-1")
        assert.is_not_nil(correction)
        assert.are.equal(0.5, correction.LocalExposure2012)
        assert.are.equal(0.1, correction.LocalClarity2012)
        assert.are.equal("mask-1", r.results[1].mask_id)
        assert.are.same({ exposure = 0.5, clarity = 10 }, r.results[1].applied)
        assert.is_nil(r.results[1].adjustment_errors)
        -- Switches to Develop once and selects the photo outside gates.
        assert.are.same({ "develop" }, ctx.moduleSwitches)
        assert.is_not_nil(ctx.catalog.getSelectionCall())
    end)

    it("processes every photo and reports per-photo failures honestly", function()
        local ctx = setup({ createError = "ai masking unavailable" })
        local r = ctx.handler.addAIMask({
            photo_ids = { 914, 915 },
            selection_type = "sky",
        })

        assert.is_false(r.success)
        assert.are.equal(0, r.succeeded)
        assert.are.equal(2, r.failed)
        for _, entry in ipairs(r.results) do
            assert.is_not_nil(entry.error)
            assert.is_nil(entry.mask_id)
        end
    end)

    it("engages the masking tool only when another tool is active", function()
        local ctx = setup({ selectedTool = "crop" })
        ctx.handler.addAIMask({ photo_ids = { 914 }, selection_type = "subject" })
        assert.are.same({ "masking" }, ctx.controllerState.selectToolCalls)
    end)

    it("does not re-engage masking when it is already active", function()
        local ctx = setup({ selectedTool = "masking" })
        ctx.handler.addAIMask({ photo_ids = { 914 }, selection_type = "subject" })
        assert.are.same({}, ctx.controllerState.selectToolCalls)
    end)

    it("rejects an invalid selection type", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({ photo_ids = { 914 }, selection_type = "volcano" })
        end)
    end)

    it("rejects missing photo_ids", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({ selection_type = "subject" })
        end, "photo_ids is required")
    end)

    it("rejects unknown adjustment names", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({
                photo_ids = { 914 },
                selection_type = "subject",
                adjustments = { glow = 5 },
            })
        end)
    end)

    it("rejects adjustments out of range", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({
                photo_ids = { 914 },
                selection_type = "subject",
                adjustments = { exposure = 12 },
            })
        end)
    end)

    it("no longer offers temperature/tint (ambiguous units in mask context)", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({
                photo_ids = { 914 },
                selection_type = "subject",
                adjustments = { temperature = 5500 },
            })
        end)
    end)
end)

describe("HandlerAIMasks.listMasks", function()
    it("lists the masks stored in MaskGroupBasedCorrections", function()
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1", "Subject 1") }),
            storedCorrection("corr-2", { storedMask("mask-2", "Sky 1", "Mask/Image") }),
        })

        local r = ctx.handler.listMasks({ photo_id = 914 })

        assert.is_true(r.success)
        assert.are.equal(2, r.count)
        assert.are.equal(2, r.corrections)
        assert.are.equal("mask-1", r.masks[1].mask_id)
        assert.are.equal("Sky 1", r.masks[2].name)
        -- The owning correction travels with the mask: remove_mask and
        -- set_mask_adjustments both need it.
        assert.are.equal("corr-2", r.masks[2].correction_id)
    end)

    it("sees masks that the Develop module does not", function()
        -- The whole reason for the rewrite. getAllMasks() is seeded empty here
        -- while the stored table holds a mask, which is exactly the live
        -- divergence measured on a real photo.
        local ctx = setup({ masks = {} })
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1", "Radial 1") }),
        })

        local r = ctx.handler.listMasks({ photo_id = 914 })

        assert.are.equal(1, r.count)
    end)

    it("does not switch modules or change the selection", function()
        local ctx = setup()
        seedCorrections(ctx, {})
        ctx.handler.listMasks({ photo_id = 914 })
        assert.are.same({}, ctx.moduleSwitches)
    end)

    it("returns an empty list when the photo has no masks", function()
        local ctx = setup()
        local r = ctx.handler.listMasks({ photo_id = 914 })
        assert.is_true(r.success)
        assert.are.equal(0, r.count)
    end)

    it("requires photo_id", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.listMasks({})
        end, "photo_id is required")
    end)

    it("errors when the photo does not exist", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.listMasks({ photo_id = 424242 })
        end, "No photo matched photo_id")
    end)
end)

describe("HandlerAIMasks.removeMask", function()
    it("removes the mask from the stored table and verifies after a recompute", function()
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1") }),
            storedCorrection("corr-2", { storedMask("mask-2") }),
        })

        local r = ctx.handler.removeMask({ photo_id = 914, mask_id = "mask-1" })

        assert.is_true(r.success)
        assert.are.equal(2, r.masks_before)
        assert.are.equal(1, r.masks_after)
        assert.is_true(r.verified)
        assert.is_true(r.verified_after_recompute)
    end)

    it("drops a correction left with no masks instead of keeping an empty one", function()
        -- An adjustment with no geometry is the shape that stopped a photo
        -- rendering previews, so removal must never create one.
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1") }),
        })

        ctx.handler.removeMask({ photo_id = 914, mask_id = "mask-1" })

        local stored = ctx.photo.getDevelopSettings().MaskGroupBasedCorrections
        assert.are.equal(0, #stored)
    end)

    it("keeps the other masks of a multi-mask correction", function()
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1"), storedMask("mask-2") }),
        })

        local r = ctx.handler.removeMask({ photo_id = 914, mask_id = "mask-1" })

        assert.is_true(r.success)
        local stored = ctx.photo.getDevelopSettings().MaskGroupBasedCorrections
        assert.are.equal(1, #stored)
        assert.are.equal("mask-2", stored[1].CorrectionMasks[1].MaskID)
    end)

    it("fails, rather than reporting a hollow success, when the id matches nothing", function()
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1") }),
        })

        local r = ctx.handler.removeMask({ photo_id = 914, mask_id = "ghost" })

        assert.is_false(r.success)
        assert.are.equal(0, r.removed)
        assert.are.equal(1, r.masks_after)
        assert.is_not_nil(r.message:find("No mask with id", 1, true))
    end)

    it("strips every mask with remove_all when confirmed", function()
        local ctx = setup()
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("mask-1") }),
            storedCorrection("corr-2", { storedMask("mask-2") }),
        })

        local r = ctx.handler.removeMask({
            photo_id = 914, remove_all = true, confirm = true,
        })

        assert.is_true(r.success)
        assert.are.equal(0, r.masks_after)
        assert.are.equal(0, #ctx.photo.getDevelopSettings().MaskGroupBasedCorrections)
    end)

    it("refuses remove_all without confirm", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.removeMask({ photo_id = 914, remove_all = true })
        end)
    end)

    it("requires photo_id and mask_id", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.removeMask({ mask_id = "mask-1" })
        end, "photo_id is required")
        assert.has_error(function()
            ctx.handler.removeMask({ photo_id = 914 })
        end, "mask_id is required (or pass remove_all=true to clear every mask)")
    end)
end)

describe("HandlerAIMasks.addRangeMask", function()
    it("creates range masks per photo and applies adjustments", function()
        local ctx = setup()
        local r = ctx.handler.addRangeMask({
            photo_ids = { 914, 915 },
            range_type = "luminance",
            adjustments = { exposure = -0.5 },
        })

        assert.is_true(r.success)
        assert.are.equal(2, r.succeeded)
        assert.are.equal("rangeMask", ctx.controllerState.createdMasks[1].maskType)
        assert.are.equal("luminance", ctx.controllerState.createdMasks[1].subtype)
        assert.are.equal(-0.5, correctionFor(ctx.photo, "mask-1").LocalExposure2012)
        assert.is_not_nil(r.note)
    end)

    it("validates range_type", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addRangeMask({ photo_ids = { 914 }, range_type = "vibration" })
        end, "range_type must be one of: luminance, color, depth")
    end)
end)

describe("HandlerAIMasks adjustment presets", function()
    it("addAIMask resolves adjustment_preset into sliders", function()
        local ctx = setup()
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "sky",
            adjustment_preset = "darken_sky",
        })

        assert.is_true(r.success)
        assert.are.equal("darken_sky", r.adjustment_preset)
        local correction = correctionFor(ctx.photo, "mask-1")
        assert.are.equal(-0.7, correction.LocalExposure2012)
        assert.are.equal(-0.3, correction.LocalHighlights2012)
        assert.are.equal(0.15, correction.LocalSaturation)
    end)

    it("rejects unknown presets and the adjustments+preset combination", function()
        local ctx = setup()
        assert.has_error(function()
            ctx.handler.addAIMask({
                photo_ids = { 914 },
                selection_type = "sky",
                adjustment_preset = "vivid_sky",
            })
        end, "adjustment_preset must be one of: darken_sky, brighten_subject, blur_background, enhance_landscape")
        assert.has_error(function()
            ctx.handler.addAIMask({
                photo_ids = { 914 },
                selection_type = "sky",
                adjustments = { exposure = 0.1 },
                adjustment_preset = "darken_sky",
            })
        end, "pass either adjustments or adjustment_preset, not both")
    end)
end)

describe("HandlerAIMasks.toggleMaskOverlay", function()
    it("selects the photo in Develop and toggles the overlay", function()
        local ctx = setup({ masks = { { id = "mask-1" } } })
        ctx.controller.toggleOverlay = function() ctx.overlayToggled = true end

        local r = ctx.handler.toggleMaskOverlay({ photo_id = 914 })

        assert.is_true(r.success)
        assert.is_true(ctx.overlayToggled)
        assert.are.same({ "develop" }, ctx.moduleSwitches)
        local call = ctx.catalog.getSelectionCall()
        assert.are.equal(914, call.active.localIdentifier)
    end)

    it("surfaces toggle failures honestly", function()
        local ctx = setup()
        ctx.controller.toggleOverlay = function() error("not in develop") end

        assert.has_error(function()
            ctx.handler.toggleMaskOverlay({ photo_id = 914 })
        end, "toggleOverlay failed")
    end)
end)

describe("HandlerAIMasks.removeMask remove_all", function()
    -- No longer routed through LrDevelopController.resetMasking(): that call
    -- reported success while removing nothing, because the Develop module does
    -- not see corrections written into MaskGroupBasedCorrections.
    it("clears the stored corrections when confirmed", function()
        local ctx = setup({ masks = { { id = "m1" }, { id = "m2" } } })
        seedCorrections(ctx, {
            storedCorrection("corr-1", { storedMask("m1") }),
            storedCorrection("corr-2", { storedMask("m2") }),
        })

        local r = ctx.handler.removeMask({ photo_id = 914, remove_all = true, confirm = true })

        assert.is_true(r.success)
        assert.is_true(r.remove_all)
        assert.are.equal(2, r.masks_before)
        assert.are.equal(0, r.masks_after)
        assert.is_true(r.verified)
        assert.is_nil(ctx.masksReset)
    end)

    it("requires confirmation before stripping everything", function()
        local ctx = setup({ masks = { { id = "m1" } } })

        assert.has_error(function()
            ctx.handler.removeMask({ photo_id = 914, remove_all = true })
        end, "remove_all strips every mask from the photo: pass confirm=true to proceed")
    end)
end)
