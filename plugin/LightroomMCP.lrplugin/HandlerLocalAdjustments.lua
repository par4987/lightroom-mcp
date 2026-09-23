local LrApplication = import 'LrApplication'
local LrUUID = import 'LrUUID'
local LrTasks = import 'LrTasks'

-- Lightroom can accept a MaskGroupBasedCorrections write, serve it back on an
-- immediate read, and discard it later. Verifying right after the write
-- therefore reports success for edits that never survive.
--
-- Sleeping before the second read does NOT fix this, which was measured: with a
-- one-second settle the handler still reported success for a write that was
-- gone afterwards. The discard is not on a timer -- Lightroom drops the
-- correction when it next RECOMPUTES the develop settings, which happens on a
-- render and can be much later. So the verification forces a recompute by
-- asking for a tiny thumbnail, and only then reads back.
local RECOMPUTE_PIXELS = 80
local RECOMPUTE_TIMEOUT_S = 6.0
local RECOMPUTE_POLL_S = 0.2

-- Renders a throwaway thumbnail purely for its side effect: it makes Lightroom
-- re-evaluate the settings, which is when a rejected correction disappears.
-- Yields, so it must stay OUTSIDE any catalog access gate.
local function forceRecompute(photo)
    local done = false
    local ok = pcall(function()
        photo:requestJpegThumbnail(RECOMPUTE_PIXELS, RECOMPUTE_PIXELS, function()
            done = true
        end)
    end)
    if not ok then
        return false
    end
    local waited = 0
    while not done and waited < RECOMPUTE_TIMEOUT_S do
        LrTasks.sleep(RECOMPUTE_POLL_S)
        waited = waited + RECOMPUTE_POLL_S
    end
    return done
end

local PhotoLookup = require 'PhotoLookup'
local MaskSummary = require 'MaskSummary'
local Log = require 'Log'

local LocalAdjustmentsHandler = {}

-- =====================================================================
-- Local adjustments (linear and radial gradient masks)
-- =====================================================================
--
-- Lightroom Classic 11+ stores local adjustments in the MaskGroupBasedCorrections
-- develop setting (a table). Adobe does not document the table's internal
-- shape, but it mirrors the public XMP schema:
--
--   {
--     What = "Correction",
--     CorrectionAmount = 1.0,
--     CorrectionActive = true,
--     LocalExposure2012 = <EV>,           -- fractions -1..1 except exposure
--     LocalContrast2012 = <-1..1>,
--     ... further Local* sliders ...
--     CorrectionMasks = {
--       { What = "Mask/Gradient",
--         MaskValue = 1.0,
--         ZeroX = .., ZeroY = .., FullX = .., FullY = .. },     -- linear
--       -- or, for radial:
--       { What = "Mask/CircularGradient",
--         MaskValue = 1.0, Top = .., Left = .., Bottom = .., Right = ..,
--         Angle = 0, Feather = 50, Flipped = false,
--         CenterValue = 1, PerimeterValue = 0 },
--     },
--     CorrectionRangeMask = { ... default range mask ... },
--   }
--
-- To stay robust across Lightroom versions this handler:
--   * never rewrites existing corrections (the new one is appended);
--   * when the photo already has corrections, clones the structure of one as
--     a template so unknown per-version fields survive the round-trip;
--   * verifies the write by reading the corrections back and reports
--     honestly when a version refuses it.

local function clamp01(v)
    if v == nil then return 0 end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function clampRange(v, min, max)
    if v == nil then return 0 end
    if v < min then return min end
    if v > max then return max end
    return v
end

-- UI units (-100..100) to the XMP fraction (-1..1) the corrections use.
local function sliderToFraction(v)
    return clampRange(v, -100, 100) / 100
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do
        copy[k] = deepCopy(val)
    end
    return copy
end

local function resolveOnePhoto(catalog, photoId)
    local photo = nil
    catalog:withReadAccessDo(function()
        photo = PhotoLookup.resolveOne(catalog, photoId)
    end)
    if not photo then
        error("Photo not found: " .. tostring(photoId))
    end
    return photo
end

-- MaskGroupBasedCorrections as a table; tolerates nil, string and weird shapes.
local function readCorrections(photo)
    local settings = photo:getDevelopSettings()
    local value = settings.MaskGroupBasedCorrections
    if type(value) == "table" then return value end
    return {}
end

-- Pick a correction to clone the structure from: prefer one whose masks array
-- holds a mask of the wanted type so geometry keys stay consistent.
-- Returns BOTH the correction and the matching mask entry. The mask half is the
-- half that matters: the per-version fields Lightroom requires live on the mask
-- (Version, MaskBlendMode, Midpoint, Roundness), not on the correction wrapper.
-- Cloning only the wrapper and building a fresh mask -- which is what this
-- handler used to do -- makes Lightroom accept the correction and silently drop
-- the mask, leaving CorrectionMasks empty. Measured on LrC 15.4: the photo then
-- carries an adjustment with no geometry, and stops rendering previews.
local function findTemplate(corrections, maskWhat)
    for _, correction in ipairs(corrections) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            for _, mask in ipairs(correction.CorrectionMasks) do
                if type(mask) == "table" and mask.What == maskWhat then
                    return correction, mask
                end
            end
        end
    end
    return nil, nil
end

-- Every mask entry Lightroom writes carries these. They are OBSERVED on a
-- radial mask drawn by hand in LrC 15.4; the linear case is assumed to match
-- and is not verified, which is one more reason to prefer a real template.
local MASK_DEFAULTS = {
    MaskActive = true,
    MaskInverted = false,
    MaskBlendMode = 0,
    Midpoint = 50,
    Roundness = 0,
    Version = 2,
}

-- Lightroom does NOT name a mask that arrives without one: it shows up blank in
-- the Masks panel, which is how an earlier fix here traded duplicate names
-- ("Máscara 1" twice, from cloning a template verbatim) for no names at all.
-- So every mask gets one, and the caller can supply a meaningful one.
local function defaultName(maskType, index)
    local label = (maskType == "linear") and "Linear gradient" or "Radial gradient"
    return label .. " " .. tostring(index)
end

local function newUuid()
    return LrUUID.generateUUID()
end

-- Lightroom's *SyncID fields are 32 hex characters with no dashes, unlike the
-- dashed *ID fields. A UUID with its dashes stripped is exactly that.
local function newSyncId()
    return (newUuid():gsub("%-", "")):upper()
end

-- What actually has to grow for an add to have worked. Counting CORRECTIONS
-- instead is what let a correction with an empty CorrectionMasks report success.
local function countMasks(corrections)
    local total = 0
    for _, correction in ipairs(corrections) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            total = total + #correction.CorrectionMasks
        end
    end
    return total
end

local LINEAR_MASK = "Mask/Gradient"
local RADIAL_MASK = "Mask/CircularGradient"

-- Geometry for a linear gradient from center + angle + span.
-- Angle 0 means the effect grows upward (bottom -> top); 90 grows to the
-- right; both endpoints are clamped to the image.
local function linearMaskGeometry(args)
    local cx = clamp01(tonumber(args.center_x) or 0.5)
    local cy = clamp01(tonumber(args.center_y) or 0.5)
    local angle = clampRange(tonumber(args.angle) or 0, -360, 360)
    local span = clampRange(tonumber(args.span) or 0.6, 0.02, 2)

    local radians = math.rad(angle)
    local dx = math.sin(radians) * span / 2
    local dy = -math.cos(radians) * span / 2

    return {
        ZeroX = clamp01(cx - dx),
        ZeroY = clamp01(cy - dy),
        FullX = clamp01(cx + dx),
        FullY = clamp01(cy + dy),
    }
end

local function radialMaskGeometry(args)
    local cx = clamp01(tonumber(args.center_x) or 0.5)
    local cy = clamp01(tonumber(args.center_y) or 0.5)
    local rx = clampRange(tonumber(args.radius_x) or tonumber(args.radius) or 0.3, 0.01, 1)
    local ry = clampRange(tonumber(args.radius_y) or tonumber(args.radius) or 0.3, 0.01, 1)

    return {
        Top = clamp01(cy - ry),
        Left = clamp01(cx - rx),
        Bottom = clamp01(cy + ry),
        Right = clamp01(cx + rx),
        Angle = 0,
        Feather = clampRange(tonumber(args.feather) or 50, 0, 100),
        Flipped = args.invert == true,
    }
end

-- The full set of local sliders Lightroom understands, with their XMP names.
-- Exposure is in EV like the global slider; everything else is -1..1.
local LOCAL_SLIDERS = {
    { arg = "exposure", key = "LocalExposure2012", ev = true },
    { arg = "contrast", key = "LocalContrast2012" },
    { arg = "highlights", key = "LocalHighlights2012" },
    { arg = "shadows", key = "LocalShadows2012" },
    { arg = "whites", key = "LocalWhites2012" },
    { arg = "blacks", key = "LocalBlacks2012" },
    { arg = "clarity", key = "LocalClarity2012" },
    { arg = "dehaze", key = "LocalDehaze" },
    { arg = "saturation", key = "LocalSaturation" },
    { arg = "sharpness", key = "LocalSharpness" },
    { arg = "noise_reduction", key = "LocalLuminanceNoise" },
    { arg = "temperature", key = "LocalTemperature" },
    { arg = "tint", key = "LocalTint" },
}

local function hasAnySlider(args)
    for _, slider in ipairs(LOCAL_SLIDERS) do
        if args[slider.arg] ~= nil then return true end
    end
    return false
end

local function applyLocalSliders(correction, args)
    for _, slider in ipairs(LOCAL_SLIDERS) do
        local value = args[slider.arg]
        if value ~= nil then
            if slider.ev then
                correction[slider.key] = clampRange(value, -5, 5)
            else
                correction[slider.key] = sliderToFraction(value)
            end
        end
    end
end

function LocalAdjustmentsHandler.readLocalAdjustments(args)
    args = args or {}
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end
    local fields = MaskSummary.requireFields(args.fields)

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    local corrections = readCorrections(photo)

    Log.info(string.format("read_local_adjustments: %d corrections on photo %s (fields=%s)",
        #corrections, tostring(args.photo_id), fields))

    if fields == "full" then
        return {
            success = true,
            photo_id = photo.localIdentifier,
            fields = fields,
            count = #corrections,
            corrections = corrections,
            note = "MaskGroupBasedCorrections as stored by this Lightroom version. "
                .. "Use add_local_adjustment to append linear/radial masks; existing corrections are never modified.",
        }
    end

    return {
        success = true,
        photo_id = photo.localIdentifier,
        fields = fields,
        count = #corrections,
        corrections = MaskSummary.summarizeCorrections(corrections),
        note = "Summary view: mask ids, names and only the sliders that were "
            .. "actually set. Digest/sync bookkeeping and untouched sliders are "
            .. "omitted — pass fields='full' for the verbatim structure. "
            .. "Use set_mask_adjustments with a mask_id to change an existing "
            .. "mask, or add_local_adjustment to append a new one.",
    }
end

function LocalAdjustmentsHandler.addLocalAdjustment(args)
    args = args or {}
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local maskType = args.mask_type
    if maskType ~= "linear" and maskType ~= "radial" then
        error("mask_type must be 'linear' or 'radial'")
    end

    if not hasAnySlider(args) then
        error("at least one adjustment setting is required (e.g. exposure, contrast, saturation)")
    end

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    local corrections = readCorrections(photo)
    local beforeCount = #corrections
    -- Captured before the insert below mutates `corrections` in place.
    local beforeMasks = countMasks(corrections)

    local maskWhat = (maskType == "linear") and LINEAR_MASK or RADIAL_MASK
    local flow = clampRange(tonumber(args.flow) or 1, 0, 1)

    -- Build on a template cloned from an existing correction of the same mask
    -- type when present, so per-version fields survive; otherwise use the
    -- canonical structure observed in Lightroom-written XMP.
    local template, templateMask = findTemplate(corrections, maskWhat)
    local correction
    if template then
        correction = deepCopy(template)
        -- A clone that keeps the template's identifiers is not a second
        -- correction, it is the same one twice: Lightroom showed both under one
        -- name and the pair broke preview rendering. Give the copy its own.
        correction.CorrectionID = newUuid()
        correction.CorrectionSyncID = newSyncId()
        -- Not the template's name (that is how two corrections ended up both
        -- called "Máscara 1"), and not nil either (blank in the panel).
        correction.CorrectionName = args.name or defaultName(maskType, beforeCount + 1)
    else
        -- Mirrors, field for field, what LrC 15.4 stores for a correction it
        -- wrote itself. Established by diffing a hand-drawn mask against what
        -- this path used to produce: 18 fields were missing and one was extra.
        --
        -- The two that matter most are CorrectionID and CorrectionSyncID. This
        -- path never set them, so the correction arrived with no identity at
        -- all -- and Lightroom accepted it, served it back on an immediate
        -- read, then dropped it at the next recompute. Every other difference
        -- here is parity; those two are the suspected cause.
        --
        -- CorrectionRangeMask is deliberately ABSENT: none of the corrections
        -- Lightroom wrote carries it, and this path used to send one.
        correction = {
            What = "Correction",
            CorrectionAmount = 1.0,
            CorrectionActive = true,
            CorrectionID = newUuid(),
            CorrectionSyncID = newSyncId(),
            CorrectionName = args.name or defaultName(maskType, beforeCount + 1),
            -- Legacy PV2003/2010 sliders (always zero in modern edits) kept
            -- for structural parity with Lightroom-written files.
            LocalExposure = 0,
            LocalSaturation = 0,
            LocalContrast = 0,
            LocalClarity = 0,
            LocalSharpness = 0,
            LocalBrightness = 0,
            -- 0, not 240: 240 is what this plugin used to seed, but Lightroom's
            -- own corrections store 0. Both are read as "untouched".
            LocalToningHue = 0,
            LocalToningSaturation = 0,
            LocalDefringe = 0,
            LocalMoire = 0,
            LocalHue = 0,
            LocalTexture = 0,
            LocalGrain = 0,
            LocalTemperature = 0,
            LocalTint = 0,
            LocalDehaze = 0,
            LocalLuminanceNoise = 0,
            LocalCurveRefineSaturation = 100,
            LocalExposure2012 = 0,
            LocalContrast2012 = 0,
            LocalHighlights2012 = 0,
            LocalShadows2012 = 0,
            LocalWhites2012 = 0,
            LocalBlacks2012 = 0,
            LocalClarity2012 = 0,
        }
    end

    applyLocalSliders(correction, args)

    local geometry = (maskType == "linear")
        and linearMaskGeometry(args)
        or radialMaskGeometry(args)

    -- Lightroom recomputes these from the mask (a clone's inherited values were
    -- observed being replaced by the new centre), but every correction it
    -- stores carries them, so write them rather than leaving a hole.
    correction.CorrectionReferenceX = clamp01(tonumber(args.center_x) or 0.5)
    correction.CorrectionReferenceY = clamp01(tonumber(args.center_y) or 0.5)

    -- Start from the template's OWN mask entry when there is one, so the fields
    -- this Lightroom version requires come along even if we do not know what
    -- they are. Only geometry and identity are overwritten.
    local maskEntry
    if templateMask then
        maskEntry = deepCopy(templateMask)
    else
        maskEntry = {}
        for k, v in pairs(MASK_DEFAULTS) do
            maskEntry[k] = v
        end
    end
    maskEntry.What = maskWhat
    maskEntry.MaskValue = flow
    maskEntry.MaskID = newUuid()
    maskEntry.MaskSyncID = newSyncId()
    maskEntry.MaskName = args.name or defaultName(maskType, beforeMasks + 1)
    for k, v in pairs(geometry) do
        maskEntry[k] = v
    end

    -- A new adjustment carries exactly one mask; drop any masks the template
    -- carried over from a multi-mask correction.
    correction.CorrectionMasks = { maskEntry }

    table.insert(corrections, correction)

    catalog:withWriteAccessDo("Add Local Adjustment", function()
        photo:applyDevelopSettings({
            EnableMaskGroupBasedCorrections = true,
            MaskGroupBasedCorrections = corrections,
        }, "MCP Add Local Adjustment")
    end)

    -- Verify by reading back. The MASK count is the test, not the correction
    -- count: Lightroom will happily keep a correction whose CorrectionMasks it
    -- threw away, and that shape reports success while doing nothing and breaks
    -- preview rendering for the photo.
    local afterCorrections = readCorrections(photo)
    local afterMasks = countMasks(afterCorrections)
    local recomputed = false
    if afterMasks > beforeMasks then
        -- It looks like it landed. Make Lightroom re-evaluate the photo and ask
        -- again: the first answer is the one that has been wrong.
        recomputed = forceRecompute(photo)
        afterCorrections = readCorrections(photo)
        afterMasks = countMasks(afterCorrections)
    end
    local took = afterMasks > beforeMasks

    Log.info(string.format(
        "add_local_adjustment: %d->%d correction(s), %d->%d mask(s) on photo %s",
        beforeCount, #afterCorrections, beforeMasks, afterMasks, tostring(args.photo_id)))

    if not took then
        local detail
        if #afterCorrections > beforeCount then
            detail = "Lightroom kept the correction but discarded its mask, so the "
                .. "adjustment has no geometry to act on. Remove it (remove_mask with "
                .. "remove_all) before retrying; left in place it can stop the photo "
                .. "rendering previews."
        else
            detail = "Lightroom did not accept the MaskGroupBasedCorrections write on "
                .. "this version."
        end
        return {
            success = false,
            applied = false,
            photo_id = photo.localIdentifier,
            before_count = beforeCount,
            after_count = #afterCorrections,
            masks_before = beforeMasks,
            masks_after = afterMasks,
            verified_after_recompute = recomputed,
            message = detail .. " Draw one gradient/radial mask manually on the photo, "
                .. "then retry: the existing correction AND its mask entry are then used "
                .. "as a structure template and round-trip safely.",
        }
    end

    return {
        success = true,
        applied = true,
        photo_id = photo.localIdentifier,
        mask_type = maskType,
        before_count = beforeCount,
        after_count = #afterCorrections,
        masks_before = beforeMasks,
        masks_after = afterMasks,
        -- False means the mask is there but Lightroom was not made to
        -- re-evaluate, so this is the weak check that has been wrong before.
        verified_after_recompute = recomputed,
        geometry = geometry,
        used_template = templateMask ~= nil,
        message = string.format("Added %s local adjustment (photo now has %d mask(s)).",
            maskType, afterMasks),
    }
end

-- =====================================================================
-- set_mask_adjustments — apply sliders to an ALREADY-EXISTING correction
-- =====================================================================
--
-- Companion to addLocalAdjustment: instead of appending a new correction,
-- finds the one whose CorrectionMasks contains a mask matching mask_id
-- (as returned by list_masks / add_ai_mask) and updates its Local* slider
-- fields in place, writing the whole MaskGroupBasedCorrections array back
-- via photo:applyDevelopSettings — the same direct-XMP-write path
-- addLocalAdjustment uses, NOT LrDevelopController (no Develop-module UI
-- drive needed, so this works even when createNewMask is unavailable for
-- the current session; masks created by hand in the UI or by add_ai_mask
-- both round-trip through this the same way). Geometry is left untouched.

local function findCorrectionByMaskId(corrections, maskId)
    local wanted = tostring(maskId)
    for _, correction in ipairs(corrections) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            for _, mask in ipairs(correction.CorrectionMasks) do
                if type(mask) == "table" and tostring(mask.MaskID) == wanted then
                    return correction
                end
            end
        end
    end
    return nil
end

function LocalAdjustmentsHandler.setMaskAdjustments(args)
    args = args or {}
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end
    if args.mask_id == nil or args.mask_id == "" then
        error("mask_id is required (from list_masks or add_ai_mask)")
    end
    if not hasAnySlider(args) then
        error("at least one adjustment setting is required (e.g. exposure, contrast, saturation)")
    end

    local catalog = LrApplication.activeCatalog()
    local photo = resolveOnePhoto(catalog, args.photo_id)

    local corrections = readCorrections(photo)
    local target = findCorrectionByMaskId(corrections, args.mask_id)
    if not target then
        error("No mask found with id " .. tostring(args.mask_id)
            .. " on this photo (check list_masks for valid ids)")
    end

    local before = {}
    for _, slider in ipairs(LOCAL_SLIDERS) do
        before[slider.key] = target[slider.key]
    end

    applyLocalSliders(target, args)

    catalog:withWriteAccessDo("Set Mask Adjustments", function()
        photo:applyDevelopSettings({
            EnableMaskGroupBasedCorrections = true,
            MaskGroupBasedCorrections = corrections,
        }, "MCP Set Mask Adjustments")
    end)

    -- Verify by reading the same correction back.
    local afterCorrections = readCorrections(photo)
    local afterTarget = findCorrectionByMaskId(afterCorrections, args.mask_id)

    local changed = {}
    if afterTarget then
        for _, slider in ipairs(LOCAL_SLIDERS) do
            local b, a = before[slider.key], afterTarget[slider.key]
            if b ~= a then
                changed[slider.key] = { before = b, after = a }
            end
        end
    end
    local verified = next(changed) ~= nil

    Log.info(string.format("set_mask_adjustments: mask %s on photo %s, verified=%s",
        tostring(args.mask_id), tostring(args.photo_id), tostring(verified)))

    if not afterTarget then
        return {
            success = false,
            applied = false,
            photo_id = photo.localIdentifier,
            mask_id = args.mask_id,
            message = "Lightroom did not accept the MaskGroupBasedCorrections write on this version, "
                .. "or the mask disappeared from the write-back.",
        }
    end

    return {
        success = verified,
        applied = true,
        photo_id = photo.localIdentifier,
        mask_id = args.mask_id,
        changed = verified and changed or nil,
        message = verified
            and "Applied adjustments to the existing mask."
            or "Write completed but no slider value actually changed (already at the requested value?).",
    }
end

return LocalAdjustmentsHandler
