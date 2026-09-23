local PhotoFields = {}

-- =====================================================================
-- Photo metadata reads that need more than a raw SDK key
-- =====================================================================
--
-- Colour labels are the case this exists for, and they have two traps.
--
-- 1. The WRITE key and the READ key differ. You set a label with
--    setRawMetadata('label', ...) but you must read it back with
--    getRawMetadata('colorNameForLabel') — reading 'label' makes Lightroom
--    throw `Unknown key: "label"`. Three handlers had that bug at once,
--    including the read-back that was supposed to VERIFY set_color_label.
--
-- 2. An unlabelled photo does not read back as nil or "none": Lightroom
--    answers "gray", which is not one of the five labels it offers
--    (red/yellow/green/blue/purple) and reads to a caller like a colour that
--    was deliberately chosen.
--
-- Both are handled here so every caller agrees, and so the vocabulary
-- matches what set_color_label accepts.

local NO_LABEL = "none"

-- What Lightroom reports for a photo with no colour label.
local UNLABELLED = {
    gray = true,
    grey = true,
    [""] = true,
}

-- Reads a photo's colour label, normalised to set_color_label's vocabulary:
-- "red" | "yellow" | "green" | "blue" | "purple" | "none", or the raw value
-- for a custom label set (Lightroom lets users rename labels).
function PhotoFields.colorLabel(photo)
    local ok, value = pcall(function()
        return photo:getRawMetadata('colorNameForLabel')
    end)
    if not ok or value == nil then return NO_LABEL end
    if type(value) ~= "string" then return NO_LABEL end
    if UNLABELLED[value:lower()] then return NO_LABEL end
    return value
end

PhotoFields.NO_LABEL = NO_LABEL

return PhotoFields
