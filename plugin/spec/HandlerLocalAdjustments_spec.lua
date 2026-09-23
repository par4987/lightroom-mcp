local helper = require 'spec_helper'

local function makePhoto(meta)
    meta = meta or {}
    meta.developSettings = meta.developSettings or {}
    local photo = helper.fakePhoto(meta)
    photo.requestJpegThumbnail = function(_, _w, _h, callback) callback("jpeg", nil) end
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
    -- Deterministic but distinct ids, so a test can assert that a clone did NOT
    -- inherit the template's identifiers.
    local seq = 0
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { sleep = function() end },
        LrUUID = {
            generateUUID = function()
                seq = seq + 1
                return string.format("00000000-0000-0000-0000-%012d", seq)
            end,
        },
    })
    package.loaded.HandlerLocalAdjustments = nil
    return catalog, require 'HandlerLocalAdjustments'
end

-- A photo that stores what it is given but drops CorrectionMasks, reproducing
-- what LrC 15.4 does with a mask entry that is missing per-version fields: the
-- correction survives, its mask does not.
-- forceRecompute asks for a throwaway thumbnail; every fake photo needs it.
local function withThumbnail(photo, onRequest)
    photo.requestJpegThumbnail = function(_, _w, _h, callback)
        if onRequest then onRequest() end
        callback("jpeg", nil)
    end
    return photo
end

local function makeMaskEatingPhoto(meta)
    meta.developSettings = meta.developSettings or {}
    local photo = withThumbnail(helper.fakePhoto(meta))
    photo.applyDevelopSettings = function(_, settings)
        for k, v in pairs(settings) do
            if k == "MaskGroupBasedCorrections" and type(v) == "table" then
                local stripped = {}
                for i, correction in ipairs(v) do
                    local copy = {}
                    for ck, cv in pairs(correction) do copy[ck] = cv end
                    copy.CorrectionMasks = {}
                    stripped[i] = copy
                end
                meta.developSettings[k] = stripped
            else
                meta.developSettings[k] = v
            end
        end
    end
    return photo
end

-- A realistic Lightroom-written correction, as observed in .xmp sidecars.
local function sampleCorrection()
    return {
        What = "Correction",
        CorrectionAmount = 1.0,
        CorrectionActive = true,
        LocalExposure2012 = -0.075,
        LocalContrast2012 = 0,
        LocalHighlights2012 = 0,
        LocalShadows2012 = 0,
        LocalWhites2012 = 0,
        LocalBlacks2012 = 0,
        LocalClarity2012 = 0,
        LocalDehaze = 0,
        LocalLuminanceNoise = 0,
        LocalMoire = 0,
        LocalDefringe = 0,
        LocalSaturation = 0,
        LocalSharpness = 0,
        LocalTemperature = 0,
        LocalTint = 0,
        LocalToningHue = 240,
        LocalToningSaturation = 0,
        CorrectionMasks = {
            {
                What = "Mask/Gradient",
                MaskValue = 1.0,
                ZeroX = 0.4,
                ZeroY = 0.25,
                FullX = 0.26,
                FullY = 0.30,
            },
        },
        CorrectionRangeMask = {
            ColorAmount = 0.5,
            DepthFeather = 0.5,
            DepthMax = 1.0,
            DepthMin = 0.0,
            LumFeather = 0.5,
            LumMax = 1.0,
            LumMin = 0.0,
            Type = 0,
            Version = "+2",
        },
    }
end

describe("HandlerLocalAdjustments.readLocalAdjustments", function()
    it("returns the stored corrections untouched with fields='full'", function()
        local existing = sampleCorrection()
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = {
                MaskGroupBasedCorrections = { existing },
            },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.readLocalAdjustments({ photo_id = "1", fields = "full" })

        assert.is_true(r.success)
        assert.are.equal(1, r.count)
        assert.are.same({ existing }, r.corrections)
    end)

    -- The default is the compact view: a correction carries ~30 Local* sliders
    -- plus digest/sync bookkeeping, and an edit->look->refine loop pays for all
    -- of it on every turn.
    it("summarises by default, keeping ids and only the sliders actually set", function()
        local existing = sampleCorrection()
        existing.CorrectionID = "corr-1"
        existing.CorrectionName = "Máscara 1"
        existing.CorrectionMasks[1].MaskID = "mask-1"
        existing.CorrectionMasks[1].MaskName = "Gente"
        existing.CorrectionMasks[1].MaskDigest = "NOISE"
        existing.CorrectionMasks[1].ModelVersion = 234881976
        existing.LocalShadows2012 = 0.2
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.readLocalAdjustments({ photo_id = "1" })

        assert.are.equal("summary", r.fields)
        local c = r.corrections[1]
        -- Ids survive: set_mask_adjustments needs the mask_id.
        assert.are.equal("corr-1", c.correction_id)
        assert.are.equal("mask-1", c.masks[1].mask_id)
        assert.are.equal("Gente", c.masks[1].name)
        -- Only what was set, and LocalToningHue=240 is a default, not an edit.
        assert.are.same({ LocalExposure2012 = -0.075, LocalShadows2012 = 0.2 }, c.adjustments)
        -- Bookkeeping is gone.
        assert.is_nil(c.masks[1].MaskDigest)
        assert.is_nil(c.masks[1].ModelVersion)
    end)

    it("reports no adjustments for a mask nobody has edited", function()
        local untouched = sampleCorrection()
        untouched.LocalExposure2012 = 0
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { untouched } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.readLocalAdjustments({ photo_id = "1" })

        assert.is_nil(r.corrections[1].adjustments)
    end)

    -- Two origins, two "untouched" values for the same slider: the structure
    -- this plugin writes seeds LocalToningHue at 240, while corrections made by
    -- Lightroom itself (measured on a real catalog) carry 0. Treating only one
    -- as the default puts a phantom adjustment on every mask.
    it("treats both stored defaults of LocalToningHue as untouched", function()
        for _, hue in ipairs({ 0, 240 }) do
            local correction = sampleCorrection()
            correction.LocalExposure2012 = 0
            correction.LocalToningHue = hue
            correction.LocalCurveRefineSaturation = 100
            local p = makePhoto({
                id = "1", path = "/a.jpg",
                developSettings = { MaskGroupBasedCorrections = { correction } },
            })
            local _, Handler = setup({ photos = { p } })

            local r = Handler.readLocalAdjustments({ photo_id = "1" })

            assert.is_nil(r.corrections[1].adjustments)
        end
    end)

    it("rejects an unknown fields value", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.readLocalAdjustments({ photo_id = "1", fields = "everything" })
        end, "fields must be 'summary' (default) or 'full'")
    end)

    it("returns zero corrections for a clean photo", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.readLocalAdjustments({ photo_id = "1" })
        assert.are.equal(0, r.count)
    end)

    it("requires photo_id and errors on unknown photos", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.readLocalAdjustments({}) end)
        assert.has_error(function() Handler.readLocalAdjustments({ photo_id = "nope" }) end)
    end)
end)

describe("HandlerLocalAdjustments.addLocalAdjustment", function()
    it("appends a linear gradient with correct geometry", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1",
            mask_type = "linear",
            center_x = 0.5,
            center_y = 0.5,
            angle = 90,
            span = 0.4,
            exposure = 1.5,
            saturation = -20,
        })

        assert.is_true(r.success)
        assert.is_true(r.applied)
        assert.are.equal(0, r.before_count)
        assert.are.equal(1, r.after_count)

        local stored = p1.getDevelopSettings().MaskGroupBasedCorrections
        assert.are.equal(1, #stored)
        assert.are.equal("Correction", stored[1].What)
        assert.are.equal(1.5, stored[1].LocalExposure2012)
        assert.are.equal(-0.2, stored[1].LocalSaturation)

        local mask = stored[1].CorrectionMasks[1]
        assert.are.equal("Mask/Gradient", mask.What)
        assert.are.equal(1.0, mask.MaskValue)
        -- Angle 90 points right: Full is to the right of Zero on the X axis.
        assert.is_true(mask.FullX > mask.ZeroX)
        assert.are.equal(0.5, mask.FullY)
        assert.are.equal(0.5, mask.ZeroY)
    end)

    it("appends a radial mask with bounding-box geometry", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1",
            mask_type = "radial",
            center_x = 0.25,
            center_y = 0.75,
            radius_x = 0.1,
            radius_y = 0.2,
            feather = 80,
            invert = true,
            exposure = -0.5,
        })

        assert.is_true(r.success)

        local mask = p1.getDevelopSettings().MaskGroupBasedCorrections[1].CorrectionMasks[1]
        assert.are.equal("Mask/CircularGradient", mask.What)
        assert.are.equal(0.15, mask.Left)
        assert.are.equal(0.35, mask.Right)
        assert.are.equal(0.55, mask.Top)
        assert.are.equal(0.95, mask.Bottom)
        assert.are.equal(80, mask.Feather)
        assert.is_true(mask.Flipped)
    end)

    it("clones unknown per-version fields from an existing correction", function()
        local existing = sampleCorrection()
        existing.SomeFutureField = "keep-me"
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1",
            mask_type = "linear",
            exposure = 0.3,
        })

        assert.is_true(r.applied)
        assert.are.equal(1, r.before_count)
        assert.are.equal(2, r.after_count)

        local corrections = p1.getDevelopSettings().MaskGroupBasedCorrections
        -- The existing correction is untouched.
        assert.are.same({ existing }, { corrections[1] })
        -- The new one inherited the structure of the template.
        assert.are.equal("keep-me", corrections[2].SomeFutureField)
        assert.are.equal(0.3, corrections[2].LocalExposure2012)
    end)

    -- A mask that arrives without a name shows up blank in Lightroom's Masks
    -- panel. An earlier fix here set the names to nil to stop a cloned template
    -- producing two corrections both called "Máscara 1"; that traded duplicate
    -- names for none at all.
    it("names the mask, and lets the caller choose the name", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "radial", exposure = 0.3, name = "Personas",
        })

        local correction = p1.getDevelopSettings().MaskGroupBasedCorrections[1]
        assert.are.equal("Personas", correction.CorrectionName)
        assert.are.equal("Personas", correction.CorrectionMasks[1].MaskName)
    end)

    it("falls back to a numbered name describing the mask type", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        Handler.addLocalAdjustment({ photo_id = "1", mask_type = "linear", exposure = 0.3 })

        local mask = p1.getDevelopSettings().MaskGroupBasedCorrections[1].CorrectionMasks[1]
        assert.are.equal("Linear gradient 1", mask.MaskName)
    end)

    it("does not inherit the template's name when cloning", function()
        local existing = sampleCorrection()
        existing.CorrectionName = "Máscara 1"
        existing.CorrectionMasks[1].MaskName = "Degradado radial 1"
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        Handler.addLocalAdjustment({ photo_id = "1", mask_type = "linear", exposure = 0.3 })

        local added = p1.getDevelopSettings().MaskGroupBasedCorrections[2]
        -- Two entries under one name is what the user sees in the panel.
        assert.is_true(added.CorrectionName ~= "Máscara 1")
        assert.is_true(added.CorrectionMasks[1].MaskName ~= "Degradado radial 1")
        assert.is_true(#tostring(added.CorrectionMasks[1].MaskName) > 0)
    end)

    it("clones per-version fields from the template's MASK, not just its wrapper", function()
        -- The fields Lightroom requires live on the mask entry. Cloning only the
        -- correction and building a fresh mask is what made LrC 15.4 accept the
        -- correction and throw the mask away.
        local existing = sampleCorrection()
        existing.CorrectionMasks[1].Version = 2
        existing.CorrectionMasks[1].MaskBlendMode = 0
        existing.CorrectionMasks[1].Midpoint = 50
        existing.CorrectionMasks[1].SomeFutureMaskField = "keep-me-too"
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "linear", exposure = 0.3,
        })

        assert.is_true(r.applied)
        assert.is_true(r.used_template)
        local newMask = p1.getDevelopSettings().MaskGroupBasedCorrections[2].CorrectionMasks[1]
        assert.are.equal(2, newMask.Version)
        assert.are.equal(0, newMask.MaskBlendMode)
        assert.are.equal(50, newMask.Midpoint)
        assert.are.equal("keep-me-too", newMask.SomeFutureMaskField)
        -- Geometry is the new one, not the template's.
        assert.is_true(newMask.ZeroX ~= existing.CorrectionMasks[1].ZeroX)
    end)

    it("gives the clone its own identifiers", function()
        local existing = sampleCorrection()
        existing.CorrectionID = "TEMPLATE-CORRECTION"
        existing.CorrectionSyncID = "TEMPLATESYNC"
        existing.CorrectionName = "Máscara 1"
        existing.CorrectionMasks[1].MaskID = "TEMPLATE-MASK"
        existing.CorrectionMasks[1].MaskSyncID = "TEMPLATEMASKSYNC"
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        Handler.addLocalAdjustment({ photo_id = "1", mask_type = "linear", exposure = 0.3 })

        local added = p1.getDevelopSettings().MaskGroupBasedCorrections[2]
        assert.is_true(added.CorrectionID ~= "TEMPLATE-CORRECTION")
        assert.is_true(added.CorrectionSyncID ~= "TEMPLATESYNC")
        assert.is_true(added.CorrectionMasks[1].MaskID ~= "TEMPLATE-MASK")
        assert.is_true(added.CorrectionMasks[1].MaskSyncID ~= "TEMPLATEMASKSYNC")
        -- Two corrections sharing one name is what the user sees in the panel --
        -- but nil is not the answer either: Lightroom then shows it blank.
        assert.is_true(added.CorrectionName ~= "Máscara 1")
        assert.is_true(#tostring(added.CorrectionName) > 0)
    end)

    it("carries the canonical mask fields when there is no template", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "radial", exposure = 0.3,
        })

        assert.is_true(r.applied)
        assert.is_false(r.used_template)
        local mask = p1.getDevelopSettings().MaskGroupBasedCorrections[1].CorrectionMasks[1]
        assert.are.equal(2, mask.Version)
        assert.are.equal(0, mask.MaskBlendMode)
        assert.are.equal(50, mask.Midpoint)
        assert.is_true(mask.MaskActive)
    end)

    -- Pins the structure to what LrC 15.4 stores for a correction it wrote
    -- itself, established by diffing a hand-drawn mask against this path's
    -- output. Getting this wrong is not a visible failure: Lightroom accepts
    -- the write, serves it back once, and drops it at the next recompute.
    it("writes the same correction shape Lightroom writes, with no template", function()
        local p1 = makePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "radial", exposure = 0.3,
            center_x = 0.4, center_y = 0.6,
        })

        local correction = p1.getDevelopSettings().MaskGroupBasedCorrections[1]
        for _, key in ipairs({
            "What", "CorrectionAmount", "CorrectionActive", "CorrectionID",
            "CorrectionSyncID", "CorrectionReferenceX", "CorrectionReferenceY",
            "CorrectionMasks", "LocalCurveRefineSaturation", "LocalHue",
            "LocalTexture", "LocalGrain", "LocalTemperature", "LocalTint",
            "LocalDehaze", "LocalLuminanceNoise", "LocalExposure2012",
            "LocalContrast2012", "LocalHighlights2012", "LocalShadows2012",
            "LocalWhites2012", "LocalBlacks2012", "LocalClarity2012",
        }) do
            assert.is_not_nil(correction[key], "missing field: " .. key)
        end
        -- Identity is the field this path used to omit entirely.
        assert.is_true(#tostring(correction.CorrectionID) > 0)
        assert.is_true(#tostring(correction.CorrectionSyncID) > 0)
        -- Lightroom stores none of its own corrections with this.
        assert.is_nil(correction.CorrectionRangeMask)
        -- Lightroom's own default, not the 240 this plugin used to seed.
        assert.are.equal(0, correction.LocalToningHue)
        assert.are.equal(0.4, correction.CorrectionReferenceX)
        assert.are.equal(0.6, correction.CorrectionReferenceY)
    end)

    it("fails when the write is discarded once Lightroom re-evaluates", function()
        -- Sleeping before the second read was tried and measured insufficient:
        -- the discard is not on a timer, it happens when Lightroom recomputes
        -- the develop settings. So the check forces a recompute (a throwaway
        -- thumbnail) and only then reads back.
        local reads, thumbnails = 0, 0
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local stored, discarded = nil, false
        p1.applyDevelopSettings = function(_, settings)
            stored = settings.MaskGroupBasedCorrections
        end
        p1.requestJpegThumbnail = function(_, _w, _h, callback)
            thumbnails = thumbnails + 1
            discarded = true          -- the recompute is what drops it
            callback("jpeg", nil)
        end
        p1.getDevelopSettings = function()
            reads = reads + 1
            if discarded then return { MaskGroupBasedCorrections = {} } end
            return { MaskGroupBasedCorrections = stored }
        end
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "radial", exposure = 0.35,
        })

        assert.is_false(r.success)
        assert.are.equal(0, r.masks_after)
        assert.is_true(r.verified_after_recompute)
        assert.are.equal(1, thumbnails)
        assert.are.equal(3, reads)
    end)

    it("reports when it could not force a recompute", function()
        local existing = sampleCorrection()
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        p1.requestJpegThumbnail = function() error("no thumbnail engine") end
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "linear", exposure = 0.3,
        })

        -- The write is still reported, but the caller is told the strong check
        -- did not run rather than being handed a confident answer.
        assert.is_true(r.applied)
        assert.is_false(r.verified_after_recompute)
    end)

    it("fails when Lightroom keeps the correction but drops its mask", function()
        -- The bug this whole change exists for: counting corrections says the
        -- add worked, counting masks says it did not. Measured on LrC 15.4,
        -- where the resulting correction also stopped the photo rendering.
        local p1 = makeMaskEatingPhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "radial", exposure = 0.35,
        })

        assert.is_false(r.success)
        assert.is_false(r.applied)
        assert.are.equal(1, r.after_count)   -- the correction DID land
        assert.are.equal(0, r.masks_after)   -- but the mask did not
        assert.is_not_nil(r.message:find("discarded its mask", 1, true))
        assert.is_not_nil(r.message:find("remove_all", 1, true))
    end)

    it("counts masks, not corrections, when deciding success", function()
        local existing = sampleCorrection()
        local p1 = makePhoto({
            id = "1",
            path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1", mask_type = "linear", exposure = 0.3,
        })

        assert.are.equal(1, r.masks_before)
        assert.are.equal(2, r.masks_after)
        assert.is_not_nil(r.message:find("mask(s)", 1, true))
    end)

    it("reports when the write was not accepted", function()
        -- Lightroom discarding the apply outright: the read-back finds no new
        -- correction. fakePhoto persists applies by default (read-back
        -- verification depends on it), so the discard has to be explicit here.
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        p1.applyDevelopSettings = function() end
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.addLocalAdjustment({
            photo_id = "1",
            mask_type = "linear",
            exposure = 0.3,
        })

        assert.is_false(r.success)
        assert.is_false(r.applied)
        assert.is_not_nil(r.message:find("did not accept", 1, true))
    end)

    it("validates input", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.addLocalAdjustment({ photo_id = "1", mask_type = "magic", exposure = 1 })
        end)
        assert.has_error(function()
            Handler.addLocalAdjustment({ photo_id = "1", mask_type = "linear" })
        end, "at least one adjustment setting is required (e.g. exposure, contrast, saturation)")
        assert.has_error(function()
            Handler.addLocalAdjustment({ mask_type = "linear", exposure = 1 })
        end)
    end)
end)

describe("HandlerLocalAdjustments.setMaskAdjustments", function()
    local function correctionWithMaskId(maskId)
        local c = sampleCorrection()
        c.CorrectionMasks[1].MaskID = maskId
        return c
    end

    it("updates sliders on the correction matching mask_id, leaving geometry untouched", function()
        local existing = correctionWithMaskId("mask-abc")
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { existing } },
        })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-abc", exposure = 0.5, clarity = 10,
        })

        assert.is_true(r.success)
        assert.is_not_nil(r.changed.LocalExposure2012)
        assert.are.equal(0.5, r.changed.LocalExposure2012.after)
        assert.are.equal(0.1, r.changed.LocalClarity2012.after)
        -- Geometry is untouched.
        local after = p1.getDevelopSettings().MaskGroupBasedCorrections[1]
        assert.are.equal(0.4, after.CorrectionMasks[1].ZeroX)
    end)

    it("only touches the correction whose mask matches, not others", function()
        local other = correctionWithMaskId("mask-other")
        local target = correctionWithMaskId("mask-abc")
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { other, target } },
        })
        local _, Handler = setup({ photos = { p1 } })

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-abc", exposure = 1 })

        local corrections = p1.getDevelopSettings().MaskGroupBasedCorrections
        assert.are.equal(-0.075, corrections[1].LocalExposure2012)
        assert.are.equal(1, corrections[2].LocalExposure2012)
    end)

    it("errors when mask_id does not match any correction", function()
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { correctionWithMaskId("mask-abc") } },
        })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "ghost", exposure = 1 })
        end)
    end)

    it("validates input", function()
        local p1 = makePhoto({
            id = "1", path = "/a.jpg",
            developSettings = { MaskGroupBasedCorrections = { correctionWithMaskId("mask-abc") } },
        })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(function() Handler.setMaskAdjustments({}) end, "photo_id is required")
        assert.has_error(function()
            Handler.setMaskAdjustments({ photo_id = "1" })
        end, "mask_id is required (from list_masks or add_ai_mask)")
        assert.has_error(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-abc" })
        end, "at least one adjustment setting is required (e.g. exposure, contrast, saturation)")
    end)
end)
