local MaskSummary = {}

-- =====================================================================
-- Compact views of Lightroom's mask structures
-- =====================================================================
--
-- read_local_adjustments and list_masks used to return what the SDK hands
-- over, verbatim. That is the right default for learning an undocumented
-- format, but it is the wrong one for an agent: a single correction carries
-- ~30 Local* sliders (nearly all at their default), plus MaskDigest,
-- InputDigest, LocalInputDigest, CorrectionSyncID, MaskSyncID, ModelVersion
-- and WholeImageArea. Two masks came to roughly 90 lines of JSON, of which
-- three numbers had actually been set. An edit → look → refine loop pays
-- that cost on every single turn.
--
-- The summary keeps everything that is actionable — above all the ids, which
-- set_mask_adjustments needs — and drops what only Lightroom cares about.
-- `fields = "full"` still returns the verbatim structure.

-- Bookkeeping Lightroom uses to decide whether a cached render is stale.
-- None of it tells a caller anything about the edit.
local NOISE_KEYS = {
    MaskDigest = true,
    InputDigest = true,
    LocalInputDigest = true,
    InputDigestVersion = true,
    LocalInputDigestVersion = true,
    CorrectionSyncID = true,
    MaskSyncID = true,
    ModelVersion = true,
    MaskVersion = true,
    WholeImageArea = true,
}

-- Sliders whose "untouched" value is not (only) zero. Each entry lists every
-- value that means "nobody touched this".
--
-- LocalToningHue needs both: the structure this plugin writes for a new
-- correction seeds it at 240, while corrections Lightroom itself created on a
-- real catalog carry 0. Without both, every summary reports a phantom
-- adjustment on every mask.
local UNTOUCHED_VALUES = {
    LocalToningHue = { [0] = true, [240] = true },
    LocalCurveRefineSaturation = { [0] = true, [100] = true },
}

local function isUntouched(key, value)
    if type(value) ~= "number" then return false end
    local allowed = UNTOUCHED_VALUES[key]
    if allowed then return allowed[value] == true end
    return value == 0
end

-- Only the sliders that were actually set. Returns nil when none were, so the
-- caller can tell "mask with no adjustments yet" from "mask set to zero".
local function activeAdjustments(correction)
    local out, count = {}, 0
    for key, value in pairs(correction) do
        if type(key) == "string" and key:match("^Local")
            and type(value) == "number" and not isUntouched(key, value) then
            out[key] = value
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return out
end

local function summarizeMaskEntry(mask)
    if type(mask) ~= "table" then return mask end
    return {
        mask_id = mask.MaskID,
        name = mask.MaskName,
        what = mask.What,
        subtype = mask.MaskSubType,
        category_id = mask.MaskSubCategoryID,
        inverted = mask.MaskInverted,
        active = mask.MaskActive,
        -- Kept because it is the only hint that an AI mask matched several
        -- subjects: "Select People" on two people returns two instances.
        instances = mask.InstanceBounds and #mask.InstanceBounds or nil,
    }
end

-- Exported so list_masks can summarise the stored mask entries it now reads
-- straight out of MaskGroupBasedCorrections.
MaskSummary.summarizeMask = summarizeMaskEntry

-- One entry of MaskGroupBasedCorrections, reduced to what a caller can act on.
function MaskSummary.summarizeCorrection(correction)
    if type(correction) ~= "table" then return correction end
    local masks = {}
    if type(correction.CorrectionMasks) == "table" then
        for _, mask in ipairs(correction.CorrectionMasks) do
            table.insert(masks, summarizeMaskEntry(mask))
        end
    end
    return {
        correction_id = correction.CorrectionID,
        name = correction.CorrectionName,
        active = correction.CorrectionActive,
        amount = correction.CorrectionAmount,
        adjustments = activeAdjustments(correction),
        masks = masks,
    }
end

function MaskSummary.summarizeCorrections(corrections)
    if type(corrections) ~= "table" then return {} end
    local out = {}
    for _, correction in ipairs(corrections) do
        table.insert(out, MaskSummary.summarizeCorrection(correction))
    end
    return out
end

-- An entry from LrDevelopController.getAllMasks(). Its shape varies between
-- Lightroom versions, so anything unrecognised is passed through rather than
-- dropped: a summary that silently loses a new field is worse than a verbose
-- one.
function MaskSummary.summarizeMaskGroup(group)
    if type(group) ~= "table" then return group end
    local tools = {}
    if type(group.Tools) == "table" then
        for _, tool in ipairs(group.Tools) do
            if type(tool) == "table" then
                local entry = {}
                for key, value in pairs(tool) do
                    if not NOISE_KEYS[key] then entry[key] = value end
                end
                table.insert(tools, entry)
            else
                table.insert(tools, tool)
            end
        end
    end
    local out = {}
    for key, value in pairs(group) do
        if key ~= "Tools" and not NOISE_KEYS[key] then out[key] = value end
    end
    out.Tools = tools
    return out
end

function MaskSummary.summarizeMaskGroups(groups)
    if type(groups) ~= "table" then return {} end
    local out = {}
    for _, group in ipairs(groups) do
        table.insert(out, MaskSummary.summarizeMaskGroup(group))
    end
    return out
end

-- Shared validation so both tools reject the same typo the same way.
function MaskSummary.requireFields(fields)
    local value = fields or "summary"
    if value ~= "summary" and value ~= "full" then
        error("fields must be 'summary' (default) or 'full'")
    end
    return value
end

return MaskSummary
