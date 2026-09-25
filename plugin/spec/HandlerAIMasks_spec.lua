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
        -- createReturnsNil: createNewMask reports a clean nil and never
        -- yields a mask — Lightroom's "detection found nothing".
        createReturnsNil = opts.createReturnsNil,
        -- maskAfterPolls: createNewMask queues the mask (returns nil like
        -- the real API) and getAllMasks() only shows it after N polls,
        -- modelling slow inference that outlives the early warning shot.
        maskAfterPolls = opts.maskAfterPolls,
        queued = nil,
        queuedPolls = 0,
        overlayToggles = 0,
        resetMaskingCalls = 0,
        goToMaskingCalls = 0,
    }
    -- The correction that carries a new mask's sliders lands on the photo
    -- loaded in Develop — immediately for a normal creation, or when a
    -- queued mask finally arrives for the delayed variant.
    local function linkCorrection(maskId)
        local photo = getActivePhoto and getActivePhoto() or nil
        if not photo then return end
        local settings = photo.getDevelopSettings()
        settings.MaskGroupBasedCorrections = settings.MaskGroupBasedCorrections or {}
        table.insert(settings.MaskGroupBasedCorrections, {
            What = "Correction",
            CorrectionAmount = 1,
            CorrectionActive = true,
            CorrectionMasks = { { MaskID = maskId } },
        })
    end
    local controller = {
        getSelectedTool = function() return state.selectedTool end,
        goToMasking = function() state.goToMaskingCalls = state.goToMaskingCalls + 1 end,
        toggleOverlay = function() state.overlayToggles = state.overlayToggles + 1 end,
        resetMasking = function()
            state.resetMaskingCalls = state.resetMaskingCalls + 1
            state.masks = {}
            state.queued = nil
        end,
        selectTool = function(tool)
            table.insert(state.selectToolCalls, tool)
            state.selectedTool = tool
        end,
        createNewMask = function(maskType, subtype)
            if state.createError then error(state.createError) end
            local maskId = "mask-" .. (#state.createdMasks + 1)
            table.insert(state.createdMasks, { maskType = maskType, subtype = subtype, id = maskId })
            if state.createReturnsNil then
                return nil
            end
            if state.maskAfterPolls then
                state.queued = { id = maskId }
                state.queuedPolls = 0
                return nil
            end
            table.insert(state.masks, { id = maskId })
            linkCorrection(maskId)
            return maskId
        end,
        setValue = function(key, value)
            state.setValues[key] = value
        end,
        getAllMasks = function()
            if state.queued then
                state.queuedPolls = state.queuedPolls + 1
                if state.queuedPolls >= state.maskAfterPolls then
                    table.insert(state.masks, state.queued)
                    linkCorrection(state.queued.id)
                    state.queued = nil
                end
            end
            return state.masks
        end,
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

-- Real writable directory for the helper script/result file the warning-shot
-- capture writes next to LrTasks.execute (only specs that opt into winEnv
-- ever touch it; the others short-circuit before any filesystem access).
local tempDir = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "."

local function setup(opts)
    opts = opts or {}
    -- WIN_ENV decides whether captureWindowScreenshot drives the real
    -- PowerShell helper (true, against the mocks installed below) or takes
    -- the busted short-circuit (nil). Set on EVERY setup so the flag cannot
    -- leak between specs — HandlerAI_spec, which runs after this file,
    -- depends on WIN_ENV staying nil.
    _G.WIN_ENV = opts.winEnv or nil
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
    local executedCommands = {}
    local deletedFiles = {}
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        -- startAsyncTask runs its body immediately: the handler spawns a fresh
        -- task for the adjustment write (see HandlerAIMasks.lua:400) and then
        -- polls a done-flag with sleep, which is a no-op here.
        LrTasks = {
            sleep = function() end,
            startAsyncTask = function(fn) fn() end,
            -- The real capture runs `powershell -File ... -ResultPath "..."`
            -- and reads its verdict from that file (LrTasks.execute has no
            -- stdout). Parse the path out of the command and write the
            -- success marker the real script would, so the handler's poll
            -- sees 'ok'.
            execute = function(command)
                table.insert(executedCommands, command)
                local resultPath = command:match('%-ResultPath%s+"([^"]+)"')
                if resultPath then
                    local fh = io.open(resultPath, "w")
                    if fh then
                        fh:write("ok")
                        fh:close()
                    end
                end
                return 0
            end,
        },
        LrApplicationView = {
            switchToModule = function(name) table.insert(moduleSwitches, name) end,
        },
        LrDevelopController = controller,
        -- LrPathUtils/LrFileUtils are only reached by the warning-shot
        -- capture. The helper script and result file land in a real temp
        -- dir (written and removed for real); the previews folder stays a
        -- plain string because nothing here writes the JPEG that the
        -- mocked PowerShell would have produced.
        LrPathUtils = {
            child = function(dir, name) return dir .. "/" .. name end,
            getStandardFilePath = function(kind)
                if kind == "temp" then return tempDir end
                return os.getenv("USERPROFILE") or os.getenv("HOME") or tempDir
            end,
        },
        LrFileUtils = {
            createAllDirectories = function() return true end,
            delete = function(path)
                table.insert(deletedFiles, path)
                return os.remove(path)
            end,
            directoryEntries = function() return {} end,
        },
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
        executedCommands = executedCommands,
        deletedFiles = deletedFiles,
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
        -- An exception from createNewMask is labelled apart from a clean
        -- detection miss, and gets the fallback advice that fits it. Capture
        -- is impossible under busted, so the shot error must say so — there
        -- are no screenshots, hence no top-level warning either.
        assert.is_nil(r.warning)
        assert.is_nil(r.warning_screenshots)
        for _, entry in ipairs(r.results) do
            assert.is_not_nil(entry.error)
            assert.is_nil(entry.mask_id)
            assert.are.equal("sdk_error", entry.failure_kind)
            assert.is_not_nil(entry.suggested_action:find("createNewMask itself failed", 1, true))
            assert.are.equal("no OS automation in this environment (test)",
                entry.warning_capture_error)
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

describe("HandlerAIMasks warning capture", function()
    after_each(function()
        -- Belt and braces: WIN_ENV is process-global and HandlerAI_spec runs
        -- after this file relying on it staying nil. setup() also sets it on
        -- every call, but the file must end clean even so.
        _G.WIN_ENV = nil
    end)

    it("photographs the Lightroom window early and at failure when detection finds nothing", function()
        local ctx = setup({ createReturnsNil = true, winEnv = true })
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "subject",
        })

        assert.is_false(r.success)
        assert.are.equal(1, r.failed)
        local entry = r.results[1]
        assert.are.equal("detection_failed", entry.failure_kind)
        assert.is_not_nil(entry.suggested_action:find("no subject was detected", 1, true))
        assert.is_not_nil(entry.error:find("produced no mask after 8 attempts", 1, true))
        assert.is_not_nil(entry.error:find("banner was captured", 1, true))
        -- Two shots: one mid-retry (banner likely up), one at failure.
        assert.is_not_nil(entry.warning_screenshots)
        assert.are.equal(2, #entry.warning_screenshots)
        assert.are.equal(entry.warning_screenshots[1], entry.warning_screenshot)
        assert.is_not_nil(entry.warning_screenshots[1]:find("warn_wedding-001_early_", 1, true))
        assert.is_not_nil(entry.warning_screenshots[2]:find("warn_wedding-001_final_", 1, true))
        assert.is_nil(entry.warning_capture_error)
        -- Aggregated at the top level for the server's inline attachment.
        assert.are.equal(2, #r.warning_screenshots)
        assert.are.same(entry.warning_screenshots, r.warning_screenshots)
        assert.is_not_nil(r.warning:find("screenshot", 1, true))
        -- One PowerShell invocation per shot, paths passed as arguments.
        assert.are.equal(2, #ctx.executedCommands)
        assert.is_not_nil(ctx.executedCommands[1]:find('-ResultPath "', 1, true))
        assert.is_not_nil(ctx.executedCommands[1]:find('-OutPath "', 1, true))
        assert.is_not_nil(ctx.executedCommands[1]:find('-WindowTitle "Lightroom"', 1, true))
    end)

    it("labels an SDK failure as sdk_error with its own fallback advice", function()
        local ctx = setup({ createError = "ai masking unavailable", winEnv = true })
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "sky",
        })

        assert.is_false(r.success)
        local entry = r.results[1]
        assert.are.equal("sdk_error", entry.failure_kind)
        assert.is_not_nil(entry.suggested_action:find("createNewMask itself failed", 1, true))
        assert.is_not_nil(entry.error:find("createNewMask failed", 1, true))
        assert.is_not_nil(entry.error:find("ai masking unavailable", 1, true))
        assert.are.equal(2, #entry.warning_screenshots)
        assert.is_not_nil(r.warning)
    end)

    it("deletes the early shot once the photo eventually gets its mask", function()
        local ctx = setup({ maskAfterPolls = 4, winEnv = true })
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "subject",
        })

        assert.is_true(r.success)
        local entry = r.results[1]
        assert.are.equal("mask-1", entry.mask_id)
        assert.is_nil(entry.warning_screenshots)
        assert.is_nil(entry.warning_capture_error)
        assert.is_nil(entry.failure_kind)
        assert.is_nil(r.warning)
        assert.is_nil(r.warning_screenshots)
        -- Exactly one capture ran (the early shot) and its file was removed:
        -- the script/result files are named lightroom-mcp-warn-shot.*, so a
        -- plain "warn_" match isolates the JPEG.
        assert.are.equal(1, #ctx.executedCommands)
        local shotDeletes = {}
        for _, path in ipairs(ctx.deletedFiles) do
            if path:find("warn_", 1, true) then table.insert(shotDeletes, path) end
        end
        assert.are.equal(1, #shotDeletes)
        assert.is_not_nil(shotDeletes[1]:find("warn_wedding-001_early_", 1, true))
    end)

    it("says plainly when no banner screenshot can be captured", function()
        local ctx = setup({ createReturnsNil = true })
        local r = ctx.handler.addAIMask({
            photo_ids = { 914 },
            selection_type = "subject",
        })

        local entry = r.results[1]
        assert.are.equal("detection_failed", entry.failure_kind)
        assert.is_nil(entry.warning_screenshots)
        assert.is_nil(entry.warning_screenshot)
        assert.are.equal("no OS automation in this environment (test)",
            entry.warning_capture_error)
        assert.is_not_nil(entry.error:find("banner could not be captured", 1, true))
        assert.is_nil(r.warning)
        assert.is_nil(r.warning_screenshots)
        assert.are.equal(0, #ctx.executedCommands)
    end)

    it("leaves add_range_mask failures free of AI warning fields", function()
        local ctx = setup({ createReturnsNil = true })
        local r = ctx.handler.addRangeMask({
            photo_ids = { 914 },
            range_type = "luminance",
        })

        assert.is_false(r.success)
        local entry = r.results[1]
        assert.is_not_nil(entry.error)
        assert.is_not_nil(entry.error:find("no mask appeared in the Develop masking panel", 1, true))
        assert.is_nil(entry.error:find("banner", 1, true))
        assert.is_nil(entry.failure_kind)
        assert.is_nil(entry.suggested_action)
        assert.is_nil(entry.warning_screenshots)
        assert.is_nil(entry.warning_capture_error)
        assert.is_nil(r.warning)
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
