local LrTasks = import 'LrTasks'

-- Shared access to MaskGroupBasedCorrections, the develop setting where
-- Lightroom Classic 11+ stores every local adjustment -- gradients, radials,
-- range masks and AI selections alike.
--
-- This module exists because two halves of the server disagreed about the same
-- photo. `read_local_adjustments` read this table and reported one mask;
-- `list_masks` and `remove_mask` asked LrDevelopController.getAllMasks() and
-- reported zero, so neither removal path could delete what add_local_adjustment
-- had written. getAllMasks() reflects the photo loaded in the Develop module;
-- this table is what is actually stored. When they disagree, this one is right.
--
-- Nothing here touches LrDevelopController, so none of it needs the Develop
-- module to be open or the photo to be selected.

local Corrections = {}

-- A throwaway render is the only reliable way to find out whether a write
-- survived: Lightroom accepts a correction, serves it back on an immediate
-- read, and discards it when it next RECOMPUTES the settings. Sleeping instead
-- was measured insufficient. Yields, so keep it OUTSIDE any catalog gate.
local RECOMPUTE_PIXELS = 80
local RECOMPUTE_TIMEOUT_S = 6.0
local RECOMPUTE_POLL_S = 0.2

function Corrections.deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = Corrections.deepCopy(v)
    end
    return copy
end

-- Tolerates nil, a string, and any other shape Lightroom might hand back.
function Corrections.read(photo)
    local settings = photo:getDevelopSettings()
    local value = settings and settings.MaskGroupBasedCorrections
    if type(value) == "table" then return value end
    return {}
end

-- Masks, not corrections. A correction whose CorrectionMasks Lightroom threw
-- away still counts as a correction while doing nothing at all, and counting
-- the outer table is how a no-op used to report success.
function Corrections.countMasks(corrections)
    local total = 0
    for _, correction in ipairs(corrections or {}) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            total = total + #correction.CorrectionMasks
        end
    end
    return total
end

-- Every mask in the photo, flattened, each with the correction it belongs to.
function Corrections.flatten(corrections)
    local out = {}
    for correctionIndex, correction in ipairs(corrections or {}) do
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            for maskIndex, mask in ipairs(correction.CorrectionMasks) do
                table.insert(out, {
                    mask = mask,
                    correction = correction,
                    correction_index = correctionIndex,
                    mask_index = maskIndex,
                })
            end
        end
    end
    return out
end

function Corrections.write(catalog, photo, corrections, historyName)
    catalog:withWriteAccessDo(historyName or "Update Local Adjustments", function()
        photo:applyDevelopSettings({
            EnableMaskGroupBasedCorrections = true,
            MaskGroupBasedCorrections = corrections,
        }, historyName or "MCP Update Local Adjustments")
    end)
end

function Corrections.forceRecompute(photo)
    local done = false
    local ok = pcall(function()
        photo:requestJpegThumbnail(RECOMPUTE_PIXELS, RECOMPUTE_PIXELS, function()
            done = true
        end)
    end)
    if not ok then return false end
    local waited = 0
    while not done and waited < RECOMPUTE_TIMEOUT_S do
        LrTasks.sleep(RECOMPUTE_POLL_S)
        waited = waited + RECOMPUTE_POLL_S
    end
    return done
end

-- Returns a copy of `corrections` with the mask carrying `maskId` gone. A
-- correction left with no masks is dropped entirely rather than kept: an
-- adjustment with no geometry is the exact broken shape that stopped a photo
-- rendering previews, so removal must never create one.
function Corrections.withoutMask(corrections, maskId)
    local kept, removed = {}, 0
    for _, correction in ipairs(corrections or {}) do
        if type(correction) ~= "table" then
            table.insert(kept, correction)
        else
            local copy = Corrections.deepCopy(correction)
            local masks = {}
            for _, mask in ipairs(copy.CorrectionMasks or {}) do
                if type(mask) == "table" and tostring(mask.MaskID) == tostring(maskId) then
                    removed = removed + 1
                else
                    table.insert(masks, mask)
                end
            end
            copy.CorrectionMasks = masks
            if #masks > 0 then
                table.insert(kept, copy)
            end
        end
    end
    return kept, removed
end

return Corrections
