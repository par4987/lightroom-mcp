local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'

local PhotoLookup = require 'PhotoLookup'
local Paging = require 'Paging'
local Log = require 'Log'

local DevelopHandler = {}

local MAX_BULK_PHOTO_IDS = 1000
local MAX_POINT_CURVE_VALUES = 64

local POINT_CURVE_SETTING_KEYS = {
    "ToneCurvePV2012",
    "ToneCurvePV2012Red",
    "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue",
}

local ALLOWED_DEVELOP_SETTING_KEYS = {
    "WhiteBalance",
    "Temperature",
    "Tint",
    "Exposure2012",
    "Contrast2012",
    "Highlights2012",
    "Shadows2012",
    "Whites2012",
    "Blacks2012",
    "Texture",
    "Clarity2012",
    "Dehaze",
    "Vibrance",
    "Saturation",
    "SaturationAdjustmentRed",
    "SaturationAdjustmentOrange",
    "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen",
    "SaturationAdjustmentAqua",
    "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple",
    "SaturationAdjustmentMagenta",
    "HueAdjustmentRed",
    "HueAdjustmentOrange",
    "HueAdjustmentYellow",
    "HueAdjustmentGreen",
    "HueAdjustmentAqua",
    "HueAdjustmentBlue",
    "HueAdjustmentPurple",
    "HueAdjustmentMagenta",
    "LuminanceAdjustmentRed",
    "LuminanceAdjustmentOrange",
    "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen",
    "LuminanceAdjustmentAqua",
    "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple",
    "LuminanceAdjustmentMagenta",
    "ParametricShadows",
    "ParametricDarks",
    "ParametricLights",
    "ParametricHighlights",
    "ParametricShadowSplit",
    "ParametricMidtoneSplit",
    "ParametricHighlightSplit",
    "ToneCurvePV2012",
    "ToneCurvePV2012Red",
    "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue",
    "ToneCurveName2012",
    "ConvertToGrayscale",
    "Sharpness",
    "SharpenRadius",
    "SharpenDetail",
    "SharpenEdgeMasking",
    "LuminanceSmoothing",
    "LuminanceNoiseReductionDetail",
    "LuminanceNoiseReductionContrast",
    "ColorNoiseReduction",
    "ColorNoiseReductionDetail",
    "ColorNoiseReductionSmoothness",
    "LensProfileEnable",
    "LensManualDistortionAmount",
    "PerspectiveVertical",
    "PerspectiveHorizontal",
    "PerspectiveRotate",
    "PerspectiveScale",
    "PerspectiveAspect",
    "PerspectiveUpright",
    "PostCropVignetteAmount",
    "PostCropVignetteMidpoint",
    "PostCropVignetteRoundness",
    "PostCropVignetteFeather",
    "PostCropVignetteStyle",
    "GrainAmount",
    "GrainSize",
    "GrainFrequency",
    "CropTop",
    "CropLeft",
    "CropBottom",
    "CropRight",
    "CropAngle",
}

local ALLOWED_DEVELOP_SETTING_LOOKUP = {}
for _, key in ipairs(ALLOWED_DEVELOP_SETTING_KEYS) do
    ALLOWED_DEVELOP_SETTING_LOOKUP[key] = true
end

local POINT_CURVE_SETTING_LOOKUP = {}
for _, key in ipairs(POINT_CURVE_SETTING_KEYS) do
    POINT_CURVE_SETTING_LOOKUP[key] = true
end

local function requireString(value, name)
    if type(value) ~= "string" or value == "" then
        error(name .. " is required")
    end
end

-- Photo ids leave the catalog as numbers (localIdentifier), so a caller feeding
-- search/selection output back in sends numbers. PhotoLookup normalizes with
-- tostring; only these validators used to reject them, which surfaced as a
-- misleading "photo_id is required".
local function requirePhotoId(value, name)
    if type(value) == "number" then
        return tostring(value)
    end
    requireString(value, name)
    return value
end

local function requireStringArray(value, name, maxItems)
    if type(value) ~= "table" then
        error(name .. " is required")
    end

    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(name .. " must be an array")
        end
        if type(item) ~= "string" or item == "" then
            error(name .. "[" .. tostring(key) .. "] must be a non-empty string")
        end
        count = count + 1
    end

    if count == 0 then
        error(name .. " is required")
    end
    if count ~= #value then
        error(name .. " must be an array")
    end
    if maxItems and count > maxItems then
        error(name .. " must contain at most " .. tostring(maxItems) .. " items")
    end
end

local function requirePhotoIdArray(value, name, maxItems)
    if type(value) ~= "table" then
        error(name .. " is required")
    end

    local normalized = {}
    local count = 0
    local maxIndex = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(name .. " must be an array")
        end
        if type(item) == "number" then
            normalized[key] = tostring(item)
        elseif type(item) == "string" and item ~= "" then
            normalized[key] = item
        else
            error(name .. "[" .. tostring(key) .. "] must be a photo id or file path")
        end
        count = count + 1
        if key > maxIndex then maxIndex = key end
    end

    if count == 0 then
        error(name .. " is required")
    end
    if count ~= maxIndex then
        error(name .. " must be an array")
    end
    if maxItems and count > maxItems then
        error(name .. " must contain at most " .. tostring(maxItems) .. " items")
    end

    return normalized
end

local function requireAllowedDevelopSettingKey(key)
    if not ALLOWED_DEVELOP_SETTING_LOOKUP[key] then
        error("Unsupported develop setting key: " .. tostring(key))
    end
end

local function requirePointCurve(value, name)
    if type(value) ~= "table" then
        error(name .. " must be an array of input/output number pairs")
    end

    local count = 0
    for index, item in pairs(value) do
        if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
            error(name .. " must be an array")
        end
        if type(item) ~= "number" or item < 0 or item > 255 or item ~= math.floor(item) then
            error(name .. "[" .. tostring(index) .. "] must be an integer from 0 to 255")
        end
        count = count + 1
    end

    if count ~= #value then
        error(name .. " must be an array")
    end
    if count < 4 or count > MAX_POINT_CURVE_VALUES or count % 2 ~= 0 then
        error(name .. " must contain 2 to 32 input/output pairs")
    end
    if value[1] ~= 0 or value[count - 1] ~= 255 then
        error(name .. " must start at input 0 and end at input 255")
    end

    local previousInput = nil
    for index = 1, count, 2 do
        local input = value[index]
        if previousInput ~= nil and input <= previousInput then
            error(name .. " input values must be strictly increasing")
        end
        previousInput = input
    end
end

local function requireDevelopSettingValue(key, value)
    if POINT_CURVE_SETTING_LOOKUP[key] then
        requirePointCurve(value, key)
        return
    end

    local valueType = type(value)
    if valueType ~= "number" and valueType ~= "string" and valueType ~= "boolean" then
        error("Unsupported value for develop setting key: " .. tostring(key))
    end
end

local function requireCapturedSettingValue(key, value)
    local valueType = type(value)
    if valueType == "number" or valueType == "string" or valueType == "boolean" then
        return
    end
    if POINT_CURVE_SETTING_LOOKUP[key] and valueType == "table" then
        local count = 0
        for index, item in pairs(value) do
            if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
                error("Develop setting " .. tostring(key) .. " is not a capturable array")
            end
            if type(item) ~= "number" then
                error("Develop setting " .. tostring(key) .. " must contain only numbers")
            end
            count = count + 1
        end
        if count ~= #value or count % 2 ~= 0 or count < 4 or count > MAX_POINT_CURVE_VALUES then
            error("Develop setting " .. tostring(key) .. " is not a capturable point curve")
        end
        return
    end
    error("Unsupported value for develop setting key: " .. tostring(key))
end

local function requireDevelopSettingsObject(settings)
    if type(settings) ~= "table" then
        error("settings is required")
    end

    local count = 0
    for key, value in pairs(settings) do
        if type(key) ~= "string" then
            error("settings keys must be strings")
        end
        requireAllowedDevelopSettingKey(key)
        requireDevelopSettingValue(key, value)
        count = count + 1
    end

    if count == 0 then
        error("settings is required")
    end
end

local function requireDevelopSettingWhitelist(settings)
    if settings == nil then
        return
    end

    requireStringArray(settings, "settings", #ALLOWED_DEVELOP_SETTING_KEYS)
    for _, key in ipairs(settings) do
        requireAllowedDevelopSettingKey(key)
    end
end

local function callPresetMethod(preset, methodName)
    local method = preset and preset[methodName]
    if type(method) ~= "function" then
        return nil
    end
    local ok, value = pcall(method, preset)
    if not ok then
        return nil
    end
    return value
end

local function presetEntry(preset, folder, scope)
    return {
        preset = preset,
        name = callPresetMethod(preset, "getName"),
        folder = folder,
        scope = scope,
        uuid = callPresetMethod(preset, "getUuid"),
        file = callPresetMethod(preset, "getFile"),
    }
end

local function allDevelopPresetEntries()
    local entries = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            table.insert(entries, presetEntry(preset, folder:getName(), "lightroom"))
        end
    end

    if _PLUGIN and type(LrApplication.getDevelopPresetsForPlugin) == "function" then
        local pluginPresets = LrApplication.getDevelopPresetsForPlugin(_PLUGIN) or {}
        for _, preset in ipairs(pluginPresets) do
            table.insert(entries, presetEntry(preset, "Plugin Develop Presets", "plugin"))
        end
    end

    return entries
end

local function presetSummary(entry)
    return {
        name = entry.name,
        folder = entry.folder,
        scope = entry.scope,
        uuid = entry.uuid,
        file = entry.file,
    }
end

local function requirePresetSelector(args)
    if type(args) ~= "table" then
        error("preset selector is required")
    end
    local hasName = type(args.preset_name) == "string" and args.preset_name ~= ""
    local hasUuid = type(args.preset_uuid) == "string" and args.preset_uuid ~= ""
    if not hasName and not hasUuid then
        error("preset_name or preset_uuid is required")
    end
    if args.preset_folder ~= nil then requireString(args.preset_folder, "preset_folder") end
    if args.preset_scope ~= nil and args.preset_scope ~= "lightroom" and args.preset_scope ~= "plugin" then
        error("preset_scope must be lightroom or plugin")
    end
end

local function sharesOneUuid(matches)
    local uuid = matches[1].uuid
    if uuid == nil then
        return false
    end
    for index = 2, #matches do
        if matches[index].uuid ~= uuid then
            return false
        end
    end
    return true
end

local function findPreset(args)
    requirePresetSelector(args)
    local matches = {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        local uuidMatches = args.preset_uuid == nil or entry.uuid == args.preset_uuid
        local nameMatches = args.preset_name == nil or entry.name == args.preset_name
        local folderMatches = args.preset_folder == nil or entry.folder == args.preset_folder
        local scopeMatches = args.preset_scope == nil or entry.scope == args.preset_scope
        if uuidMatches and nameMatches and folderMatches and scopeMatches then
            table.insert(matches, entry)
        end
    end
    if #matches == 0 then
        error("Preset not found")
    end
    -- Lightroom can expose the same preset more than once (for example, as a
    -- favourite and in its original group). Those aliases share one UUID, so
    -- a UUID selector is still exact even when the flattened folder list has
    -- multiple entries for it.
    if #matches > 1 and args.preset_uuid == nil and not sharesOneUuid(matches) then
        error("Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end
    return matches[1]
end

-- Shape probe for values cloneSerializable refuses.
--
-- That function is all-or-nothing: one unsupported leaf anywhere makes the
-- whole field vanish into skipped_fields, with no clue whether it was too
-- deep, too wide, cyclic, or held userdata. That is exactly what happened
-- with FilterList, where Lightroom stores Distraction Removal (dust and
-- people) -- a feature worth reaching, and unreachable while its format is
-- invisible. This walks deeper than the clone does and reports STRUCTURE
-- only (types, counts, key names), never bulk content, so the answer stays
-- small enough to put in a response.
local DESCRIBE_MAX_DEPTH = 12
local DESCRIBE_MAX_KEYS = 12

local function describeValue(value, depth)
    local valueType = type(value)
    if valueType ~= "table" then
        return valueType
    end
    if depth >= DESCRIBE_MAX_DEPTH then
        return "table(depth-limit)"
    end

    local arrayCount = #value
    local keys, total = {}, 0
    for key in pairs(value) do
        total = total + 1
        if #keys < DESCRIBE_MAX_KEYS and type(key) == "string" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local out = {
        __count = total,
        __array_len = arrayCount,
    }
    if #keys > 0 then out.__keys = keys end

    -- Describe the first array entry: these structures are homogeneous, so
    -- one sample tells the shape of all of them.
    if arrayCount > 0 then
        out.__item = describeValue(value[1], depth + 1)
    end
    for _, key in ipairs(keys) do
        out[key] = describeValue(value[key], depth + 1)
    end
    return out
end

-- maxDepth defaults to 6, the long-standing cap. It is a parameter because
-- Lightroom's newer structures are deeper than that and vanish wholesale:
-- FilterList (Distraction Removal) nests
-- FilterList > Filters > [n] > Images > [n] > Alpha > [n], which is exactly
-- one level past the cap, so a caller that needs the dust/people geometry
-- can ask for it instead of getting nothing.
local CLONE_DEFAULT_MAX_DEPTH = 6
local CLONE_HARD_MAX_DEPTH = 16

local function cloneSerializable(value, depth, seen, maxDepth)
    maxDepth = maxDepth or CLONE_DEFAULT_MAX_DEPTH
    local valueType = type(value)
    if valueType == "number" or valueType == "string" or valueType == "boolean" then
        return value, true
    end
    if valueType ~= "table" or depth >= maxDepth or seen[value] then
        return nil, false
    end

    seen[value] = true
    local out = {}
    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then
            seen[value] = nil
            return nil, false
        end
        count = count + 1
        if count > 2000 then
            seen[value] = nil
            return nil, false
        end
        local cloned, supported = cloneSerializable(item, depth + 1, seen, maxDepth)
        if not supported then
            seen[value] = nil
            return nil, false
        end
        out[key] = cloned
    end
    seen[value] = nil
    return out, true
end

local function normalizedPresetSettings(preset)
    local settings = callPresetMethod(preset, "getSetting")
    if type(settings) ~= "table" then
        error("Preset settings are unavailable")
    end
    local normalized, supported = cloneSerializable(settings, 0, {})
    if not supported then
        error("Preset settings contain unsupported nested values")
    end
    return normalized
end

-- Lightroom mints a fresh CorrectionID/MaskID on every getSetting() call, so
-- they identify a read rather than the preset. Comparing them made every
-- masked preset (all the Adaptive/AI ones) differ from itself.
local VOLATILE_SETTING_KEYS = {
    CorrectionID = true,
    MaskID = true,
}

local function withoutVolatileIds(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        if not VOLATILE_SETTING_KEYS[key] then
            out[key] = withoutVolatileIds(item)
        end
    end
    return out
end

local function deepEqual(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not deepEqual(value, right[key]) then return false end
    end
    for key, _ in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function sortedSettingKeys(settings)
    local keys = {}
    for key, _ in pairs(settings) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

function DevelopHandler.listDevelopPresets(args)
    local out = {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        table.insert(out, presetSummary(entry))
    end

    local page, meta = Paging.slice(out, args)

    Log.info(string.format("Listed %d/%d develop presets", meta.count, meta.total))

    return {
        success = true,
        presets = page,
        count = meta.count,
        total = meta.total,
        offset = meta.offset,
        limit = meta.limit,
        has_more = meta.has_more,
    }
end

function DevelopHandler.getDevelopPreset(args)
    local entry = findPreset(args)
    local settings = normalizedPresetSettings(entry.preset)
    local result = presetSummary(entry)
    result.success = true
    result.settings = settings
    result.setting_count = #sortedSettingKeys(settings)
    return result
end

function DevelopHandler.compareDevelopPresets(args)
    if type(args.base) ~= "table" or type(args.candidate) ~= "table" then
        error("base and candidate preset selectors are required")
    end
    local base = findPreset(args.base)
    local candidate = findPreset(args.candidate)
    local baseSettings = normalizedPresetSettings(base.preset)
    local candidateSettings = normalizedPresetSettings(candidate.preset)
    local keys = {}
    for key, _ in pairs(baseSettings) do keys[key] = true end
    for key, _ in pairs(candidateSettings) do keys[key] = true end

    local keyList = {}
    for key, _ in pairs(keys) do table.insert(keyList, key) end
    table.sort(keyList)

    local changes = {}
    for _, key in ipairs(keyList) do
        local before = withoutVolatileIds(baseSettings[key])
        local after = withoutVolatileIds(candidateSettings[key])
        if not deepEqual(before, after) then
            local change = {
                key = key,
                before_present = baseSettings[key] ~= nil,
                after_present = candidateSettings[key] ~= nil,
            }
            if before ~= nil then change.before = before end
            if after ~= nil then change.after = after end
            table.insert(changes, change)
        end
    end

    return {
        success = true,
        base = presetSummary(base),
        candidate = presetSummary(candidate),
        changes = changes,
        changed_count = #changes,
    }
end

function DevelopHandler.createDevelopPreset(args)
    args.photo_id = requirePhotoId(args.photo_id, "photo_id")
    requireString(args.preset_name, "preset_name")
    requireStringArray(args.settings, "settings", #ALLOWED_DEVELOP_SETTING_KEYS)
    requireDevelopSettingWhitelist(args.settings)

    if not _PLUGIN or type(LrApplication.addDevelopPresetForPlugin) ~= "function" then
        error("Plugin preset creation is unavailable")
    end
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if entry.scope == "plugin" and entry.name == args.preset_name then
            error("Plugin preset already exists; use a versioned preset_name")
        end
    end

    local catalog = LrApplication.activeCatalog()
    local sourceSettings
    catalog:withReadAccessDo(function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. args.photo_id)
        end
        sourceSettings = photo:getDevelopSettings()
    end)

    local presetSettings = {}
    for _, key in ipairs(args.settings) do
        local value = sourceSettings[key]
        if value == nil then
            error("Source photo has no develop setting: " .. key)
        end
        requireCapturedSettingValue(key, value)
        presetSettings[key] = value
    end

    local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, args.preset_name, presetSettings)
    if not preset then error("Lightroom did not create the plugin preset") end
    local entry = presetEntry(preset, "Plugin Develop Presets", "plugin")
    local result = presetSummary(entry)
    result.success = true
    result.source_photo_id = args.photo_id
    result.settings = args.settings
    result.visible_in_develop = false
    result.message = "Created plugin-managed Develop preset checkpoint"
    Log.info(string.format("Created plugin preset %s from photo %s", args.preset_name, args.photo_id))
    return result
end

local function requireLeafFilename(filename)
    requireString(filename, "filename")
    if filename == "." or filename == ".." or LrPathUtils.leafName(filename) ~= filename then
        error("filename must be a leaf filename without path separators")
    end
end

function DevelopHandler.exportDevelopPreset(args)
    requireString(args.destination_dir, "destination_dir")
    local entry = findPreset(args)
    local source = entry.file
    if type(source) ~= "string" or source == "" or LrFileUtils.exists(source) ~= "file" then
        error("Preset has no exportable backing file")
    end

    local sourceExtension = LrPathUtils.extension(source)
    if type(sourceExtension) ~= "string" or sourceExtension == "" then
        error("Preset backing file has no extension")
    end
    local filename = args.filename or LrPathUtils.leafName(source)
    requireLeafFilename(filename)
    local requestedExtension = LrPathUtils.extension(filename)
    if requestedExtension == "" then
        filename = filename .. "." .. sourceExtension
    elseif requestedExtension:lower() ~= sourceExtension:lower() then
        error("filename extension must match preset backing file: ." .. sourceExtension)
    end

    if LrFileUtils.exists(args.destination_dir) == false then
        LrFileUtils.createAllDirectories(args.destination_dir)
    end
    if LrFileUtils.exists(args.destination_dir) ~= "directory" then
        error("destination_dir is not a directory")
    end

    local destination = LrPathUtils.child(args.destination_dir, filename)
    if LrFileUtils.exists(destination) then
        error("destination preset already exists; choose a new filename")
    end
    local copied, copyError = LrFileUtils.copy(source, destination)
    if not copied then
        error("Preset export failed: " .. tostring(copyError))
    end

    local result = presetSummary(entry)
    result.success = true
    result.destination = destination
    result.message = "Exported Develop preset without overwriting existing files"
    Log.info(string.format("Exported preset %s to %s", tostring(entry.name), destination))
    return result
end

function DevelopHandler.applyDevelopPreset(args)
    args.photo_ids = requirePhotoIdArray(args.photo_ids, "photo_ids", MAX_BULK_PHOTO_IDS)
    local selectedPreset = findPreset(args)

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    local missingIds = {}
    local missingCount = 0

    catalog:withWriteAccessDo("Apply Develop Preset", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, resolvedEntry in ipairs(resolved) do
            if resolvedEntry.photo then
                if selectedPreset.scope == "plugin" then
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset, _PLUGIN)
                else
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset)
                end
                appliedCount = appliedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(resolvedEntry.id)
            end
        end
    end)

    Log.info(string.format("Applied preset %s to %d photos", selectedPreset.name, appliedCount))

    return {
        success = true,
        applied = appliedCount,
        preset = selectedPreset.name,
        folder = selectedPreset.folder,
        scope = selectedPreset.scope,
        uuid = selectedPreset.uuid,
        missing = missingIds,
        message = string.format("Applied preset %s to %d photos (%d ids not found)",
            selectedPreset.name, appliedCount, missingCount),
    }
end

function DevelopHandler.copyDevelopSettings(args)
    args.source_id = requirePhotoId(args.source_id, "source_id")
    args.target_ids = requirePhotoIdArray(args.target_ids, "target_ids", MAX_BULK_PHOTO_IDS)
    requireDevelopSettingWhitelist(args.settings)

    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    catalog:withReadAccessDo(function()
        local source = PhotoLookup.resolveOne(catalog, args.source_id)
        if not source then
            error("Source photo not found: " .. args.source_id)
        end
        sourceSettings = source:getDevelopSettings()
    end)

    local toApply = sourceSettings
    if args.settings then
        toApply = {}
        for _, key in ipairs(args.settings) do
            toApply[key] = sourceSettings[key]
        end
    end

    local copiedCount = 0
    local missingIds = {}
    local missingCount = 0

    catalog:withWriteAccessDo("Copy Develop Settings", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.target_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopSettings(toApply)
                copiedCount = copiedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount))

    return {
        success = true,
        copied = copiedCount,
        source = args.source_id,
        missing = missingIds,
        message = string.format("Copied develop settings from %s to %d photos (%d ids not found)",
            args.source_id, copiedCount, missingCount),
    }
end

function DevelopHandler.setDevelopSettings(args)
    args.photo_id = requirePhotoId(args.photo_id, "photo_id")
    requireDevelopSettingsObject(args.settings)

    local catalog = LrApplication.activeCatalog()
    local applied = false

    catalog:withWriteAccessDo("Set Develop Settings", function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. args.photo_id)
        end
        photo:applyDevelopSettings(args.settings)
        applied = true
    end)

    Log.info(string.format("Set develop settings on photo %s", args.photo_id))

    return {
        success = applied,
        photo_id = args.photo_id,
    }
end

-- White balance presets accepted by the WhiteBalance develop setting. "Auto"
-- is resolved immediately thanks to applyDevelopSettings' optFlattenAutoNow
-- (SDK 13+; older versions resolve lazily on the next Develop render).
local WHITE_BALANCE_PRESETS = {
    ["As Shot"] = true,
    ["Auto"] = true,
    ["Daylight"] = true,
    ["Cloudy"] = true,
    ["Shade"] = true,
    ["Tungsten"] = true,
    ["Fluorescent"] = true,
    ["Flash"] = true,
}

function DevelopHandler.setWhiteBalance(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local settings = {}

    if args.preset ~= nil then
        if not WHITE_BALANCE_PRESETS[args.preset] then
            error("preset must be one of: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash")
        end
        settings.WhiteBalance = args.preset
    end

    if args.temperature ~= nil or args.tint ~= nil then
        settings.WhiteBalance = "Custom"
        if args.temperature ~= nil then
            if type(args.temperature) ~= "number" or args.temperature < 2000 or args.temperature > 50000 then
                error("temperature must be a Kelvin number between 2000 and 50000")
            end
            settings.Temperature = args.temperature
        end
        if args.tint ~= nil then
            if type(args.tint) ~= "number" or args.tint < -150 or args.tint > 150 then
                error("tint must be a number between -150 (green) and 150 (magenta)")
            end
            settings.Tint = args.tint
        end
    end

    if next(settings) == nil then
        error("provide a preset, or temperature and/or tint")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local nonRaw = 0
    local missingIds = {}
    local missingCount = 0

    catalog:withWriteAccessDo("Set White Balance", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                -- optFlattenAutoNow resolves "Auto" synchronously when the
                -- SDK supports it (3rd parameter, SDK 13+).
                photo:applyDevelopSettings(settings, "MCP White Balance", true)
                updatedCount = updatedCount + 1
                local format = photo:getRawMetadata('fileFormat')
                if format ~= "RAW" and format ~= "DNG" then
                    nonRaw = nonRaw + 1
                end
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    -- Read back the effective values of the first photo so the caller can
    -- verify what Lightroom actually stored.
    local verified = nil
    if updatedCount > 0 then
        catalog:withReadAccessDo(function()
            local resolved = PhotoLookup.resolveMany(catalog, { args.photo_ids[1] })
            if resolved[1] and resolved[1].photo then
                local current = resolved[1].photo:getDevelopSettings()
                verified = {
                    WhiteBalance = current.WhiteBalance,
                    Temperature = current.Temperature,
                    Tint = current.Tint,
                }
            end
        end)
    end

    Log.info(string.format("Set white balance for %d photos", updatedCount))

    local result = {
        success = true,
        updated = updatedCount,
        missing = missingIds,
        verified = verified,
        message = string.format("Set white balance on %d photos (%d ids not found)",
            updatedCount, missingCount),
    }
    if nonRaw > 0 then
        result.warning = string.format(
            "%d photo(s) are not RAW/DNG: white balance has limited effect on JPEG/TIFF/PSD files.", nonRaw)
    end
    return result
end

-- =====================================================================
-- Tone curve (PV2012 point curves)
-- =====================================================================
--
-- Lightroom stores each point curve as a flat array of x,y pairs in
-- 0..255 input/output space: { 0,0, 128,140, 255,255 }. The dedicated
-- set_tone_curve / get_tone_curve tools wrap that flat format with a
-- friendlier [[x,y], ...] shape, endpoint normalization, monotonic-x
-- validation and read-back verification.

local TONE_CURVE_CHANNELS = {
    main = "ToneCurvePV2012",
    red = "ToneCurvePV2012Red",
    green = "ToneCurvePV2012Green",
    blue = "ToneCurvePV2012Blue",
}

-- Approximations of the built-in Lightroom curve presets; the UI name is
-- reported alongside so Lightroom shows the matching dropdown entry.
local TONE_CURVE_PRESETS = {
    linear = {
        name = "Linear",
        points = { { 0, 0 }, { 255, 255 } },
    },
    medium_contrast = {
        name = "Medium Contrast",
        points = { { 0, 0 }, { 64, 56 }, { 128, 128 }, { 192, 202 }, { 255, 255 } },
    },
    strong_contrast = {
        name = "Strong Contrast",
        points = { { 0, 0 }, { 64, 42 }, { 128, 128 }, { 192, 216 }, { 255, 255 } },
    },
}

local MAX_CURVE_POINTS = 32

local function parseCurveToPoints(curveArray)
    local points = {}
    if type(curveArray) == "table" then
        for i = 1, #curveArray, 2 do
            table.insert(points, { curveArray[i], curveArray[i + 1] })
        end
    end
    return points
end

local function buildCurveArray(points)
    local flat = {}
    for _, p in ipairs(points) do
        table.insert(flat, p[1])
        table.insert(flat, p[2])
    end
    return flat
end

-- Validate + normalize caller-supplied points. Lightroom expects the curve
-- to start at (0,0) and end at (255,255) with strictly increasing x, so
-- missing endpoints are inserted (and reported) rather than rejected.
local function normalizeCurvePoints(points)
    if type(points) ~= "table" or #points < 1 then
        error("points must be an array of at least 1 [x, y] pair")
    end
    if #points > MAX_CURVE_POINTS then
        error("points must contain at most " .. MAX_CURVE_POINTS .. " points")
    end

    local normalized = {}
    local endpointsAdded = false
    for i, pair in ipairs(points) do
        if type(pair) ~= "table" or #pair ~= 2
            or type(pair[1]) ~= "number" or type(pair[2]) ~= "number" then
            error("points[" .. i .. "] must be an [x, y] pair of numbers")
        end
        local x = math.floor(pair[1] + 0.5)
        local y = math.floor(pair[2] + 0.5)
        if x < 0 or x > 255 or y < 0 or y > 255 then
            error("points[" .. i .. "] coordinates must be between 0 and 255")
        end
        if #normalized > 0 and x <= normalized[#normalized][1] then
            error("points must have strictly increasing x values")
        end
        table.insert(normalized, { x, y })
    end

    if normalized[1][1] ~= 0 or normalized[1][2] ~= 0 then
        table.insert(normalized, 1, { 0, 0 })
        endpointsAdded = true
    end
    if normalized[#normalized][1] ~= 255 or normalized[#normalized][2] ~= 255 then
        if normalized[#normalized][1] >= 255 then
            error("the last point must end at (255, 255)")
        end
        table.insert(normalized, { 255, 255 })
        endpointsAdded = true
    end
    return normalized, endpointsAdded
end

function DevelopHandler.setToneCurve(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local channel = args.channel or "main"
    local key = TONE_CURVE_CHANNELS[channel]
    if not key then
        error("channel must be one of: main, red, green, blue")
    end

    local points, endpointsAdded, curveName
    if args.preset ~= nil then
        local preset = TONE_CURVE_PRESETS[args.preset]
        if not preset then
            error("preset must be one of: linear, medium_contrast, strong_contrast")
        end
        curveName = preset.name
        endpointsAdded = false
        points = {}
        for i, p in ipairs(preset.points) do points[i] = { p[1], p[2] } end
    else
        points, endpointsAdded = normalizeCurvePoints(args.points)
        curveName = "Custom"
    end

    local catalog = LrApplication.activeCatalog()
    local updated = false
    local missing = true

    catalog:withWriteAccessDo("Set Tone Curve", function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] and resolved[1].photo then
            missing = false
            resolved[1].photo:applyDevelopSettings({
                [key] = buildCurveArray(points),
                ToneCurveName2012 = curveName,
            }, "MCP Tone Curve")
            updated = true
        end
    end)

    if missing then
        error("No photo matched photo_id")
    end

    -- Read back the stored curve so the caller can verify what Lightroom
    -- actually kept (values may be snapped by the tone engine).
    local verified = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] and resolved[1].photo then
            local current = resolved[1].photo:getDevelopSettings()
            verified = {
                curve_name = current.ToneCurveName2012,
                points = parseCurveToPoints(current[key]),
                raw = current[key],
            }
        end
    end)

    Log.info(string.format("Set %s tone curve on photo %s",
        channel, tostring(args.photo_id)))

    local result = {
        success = updated,
        channel = channel,
        curve_name = curveName,
        endpoints_added = endpointsAdded or nil,
        verified = verified,
        message = string.format("Set %s tone curve to '%s' (%d points)",
            channel, curveName, #points),
    }
    if endpointsAdded then
        result.message = result.message
            .. "; (0,0)/(255,255) endpoints were added automatically"
    end
    return result
end

function DevelopHandler.getToneCurve(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local catalog = LrApplication.activeCatalog()
    local out = nil

    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] and resolved[1].photo then
            local s = resolved[1].photo:getDevelopSettings()
            local channels = {}
            for channel, key in pairs(TONE_CURVE_CHANNELS) do
                channels[channel] = {
                    points = parseCurveToPoints(s[key]),
                    raw = s[key],
                }
            end
            out = {
                curve_name = s.ToneCurveName2012,
                channels = channels,
            }
        end
    end)

    if not out then
        error("No photo matched photo_id")
    end

    out.success = true
    out.message = string.format("Tone curves for photo %s (curve name: %s)",
        tostring(args.photo_id), tostring(out.curve_name))
    return out
end

-- =====================================================================
-- apply_auto — official Auto Tone / Auto White Balance commands
-- =====================================================================
--
-- LrDevelopController.setAutoTone() / setAutoWhiteBalance() are the same
-- commands as the Auto button in the Develop panel: they run Lightroom's
-- own analysis on the photo loaded in the Develop module. Because they
-- drive the running UI, the handler switches to Develop once, selects
-- each photo (outside any catalog gate), fires the commands, and diffs the
-- main sliders before/after so the caller sees what actually changed.

local AUTO_READBACK_KEYS = {
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
    "Whites2012", "Blacks2012", "Temperature", "Tint",
}

local AUTO_SETTLE_AFTER_MODULE_SWITCH_S = 0.5
local AUTO_SETTLE_BETWEEN_PHOTOS_S = 0.3
local AUTO_SETTLE_AFTER_COMMAND_S = 0.5

-- Every LrDevelopController command goes through here.
--
-- These commands drive the running Develop module and open their own catalog
-- transaction. Wrapping one in catalog:withWriteAccessDo nests a SECOND write
-- request, which real Lightroom rejects every single time with "blocked by
-- another write access call" — deterministically, not intermittently, and
-- regardless of the photo. The mistake shipped three times (apply_auto twice,
-- set_process_version once) because the spec mock was a bare passthrough that
-- could not represent nesting; spec_helper now throws on it, so a gated call
-- fails its spec instead of reaching a user.
--
-- Genuine catalog writes (photo:applyDevelopSettings, photo:createVirtualCopy,
-- catalog:removePhoto, ...) still belong INSIDE withWriteAccessDo. This helper
-- is only for the controller surface.
local function runDevelopCommand(name, fn)
    local ok, err = pcall(fn)
    if ok then return true end
    return false, string.format("%s failed: %s", name, tostring(err))
end

function DevelopHandler.applyAuto(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local operations = args.operations
    if operations == nil or #operations == 0 then
        operations = { "tone", "white_balance" }
    end
    local doTone, doWB = false, false
    for _, op in ipairs(operations) do
        if op == "tone" then
            doTone = true
        elseif op == "white_balance" then
            doWB = true
        else
            error("operations must contain only 'tone' and/or 'white_balance'")
        end
    end
    if not doTone and not doWB then
        error("operations must include at least one of 'tone', 'white_balance'")
    end

    local catalog = LrApplication.activeCatalog()

    local photos = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then table.insert(photos, entry.photo) end
        end
    end)
    if #photos == 0 then
        error("No photos matched photo_ids")
    end

    -- switchToModule and setSelectedPhotos both yield to the UI thread, so
    -- they must run OUTSIDE any catalog access gate (#134/#124).
    local switchOk, switchErr = pcall(function()
        LrApplicationView.switchToModule("develop")
    end)
    if not switchOk then
        error("could not switch Lightroom to the Develop module: "
            .. tostring(switchErr))
    end
    LrTasks.sleep(AUTO_SETTLE_AFTER_MODULE_SWITCH_S)

    local results = {}
    local succeeded = 0

    for i, photo in ipairs(photos) do
        if i > 1 then LrTasks.sleep(AUTO_SETTLE_BETWEEN_PHOTOS_S) end

        local entry = {
            photo = {
                id = photo.localIdentifier,
                path = photo:getRawMetadata('path'),
                filename = photo:getFormattedMetadata('fileName'),
            },
            applied = {},
        }
        table.insert(results, entry)

        local selectOk = pcall(function()
            catalog:setSelectedPhotos(photo, { photo })
        end)
        if not selectOk then
            entry.error = "could not select the photo in Lightroom"
        else
            LrTasks.sleep(AUTO_SETTLE_BETWEEN_PHOTOS_S)

            local before = nil
            catalog:withReadAccessDo(function()
                before = photo:getDevelopSettings()
            end)

            if doTone then
                local ok, err = runDevelopCommand("setAutoTone", function()
                    LrDevelopController.setAutoTone()
                end)
                entry.applied.tone = ok
                if not ok then entry.tone_error = err end
            end
            if doWB then
                local ok, err = runDevelopCommand("setAutoWhiteBalance", function()
                    LrDevelopController.setAutoWhiteBalance()
                end)
                entry.applied.white_balance = ok
                if not ok then entry.white_balance_error = err end
            end

            -- The Auto commands commit through the Develop pipeline; give
            -- them a beat before reading back, then diff the main sliders so
            -- the caller sees exactly what Lightroom changed.
            LrTasks.sleep(AUTO_SETTLE_AFTER_COMMAND_S)
            local after = nil
            catalog:withReadAccessDo(function()
                after = photo:getDevelopSettings()
            end)

            local commandsRan = (not doTone or entry.applied.tone)
                and (not doWB or entry.applied.white_balance)

            if type(before) == "table" and type(after) == "table" then
                local changed = {}
                for _, k in ipairs(AUTO_READBACK_KEYS) do
                    if before[k] ~= after[k] then
                        changed[k] = { before = before[k], after = after[k] }
                    end
                end
                if next(changed) ~= nil then
                    entry.changed = changed
                elseif commandsRan then
                    entry.note = "Auto made no slider changes (settings may already be optimal, or the file type does not support Auto)"
                else
                    -- Do NOT reach for the benign explanation here: the sliders
                    -- are unchanged because the command never ran.
                    entry.note = "No sliders changed because the Auto command did not run — see tone_error / white_balance_error"
                end
            end

            if commandsRan then
                succeeded = succeeded + 1
            end
        end
    end

    Log.info(string.format("applyAuto(%s): %d/%d photos",
        table.concat(operations, "+"), succeeded, #photos))

    local result = {
        success = succeeded == #photos,
        requested = #photos,
        succeeded = succeeded,
        failed = #photos - succeeded,
        operations = operations,
        results = results,
        method = "LrDevelopController.setAutoTone/setAutoWhiteBalance",
        message = string.format("Applied Auto (%s) to %d of %d photos",
            table.concat(operations, "+"), succeeded, #photos),
    }
    if succeeded < #photos then
        result.message = result.message
            .. ". Check each photo's 'error'/'tone_error'/'white_balance_error' entry."
    end
    return result
end

-- =====================================================================
-- get_develop_settings — read the develop settings of a photo
-- =====================================================================
--
-- The read-only counterpart of set_develop_settings: photo:getDevelopSettings()
-- inside a read gate returns the full stored settings table. "basic" filters
-- to the common develop sliders (plus curves) so the response stays small
-- and LLM-friendly; "all" passes everything through cloneSerializable
-- (depth-limited, handles the nested mask/retouch structures safely).
-- Ported from lightroom-cli getSettings, which instead polls
-- LrDevelopController per parameter; getDevelopSettings is one catalog read
-- and works without switching modules.

local BASIC_DEVELOP_READ_KEYS = {
    "WhiteBalance", "Temperature", "Tint",
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
    "Whites2012", "Blacks2012", "Texture", "Clarity2012", "Dehaze",
    "Vibrance", "Saturation",
    "Sharpness", "LuminanceSmoothing", "ColorNoiseReduction",
    "ParametricShadows", "ParametricDarks", "ParametricLights",
    "ParametricHighlights",
    "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue", "ToneCurveName2012",
    "ConvertToGrayscale", "PostCropVignetteAmount", "GrainAmount",
    "CropAngle", "ProcessVersion",
}

function DevelopHandler.getDevelopSettings(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local fields = args.fields or "basic"
    if fields ~= "basic" and fields ~= "all" then
        error("fields must be 'basic' (default) or 'all'")
    end

    -- Opt-in depth. Default is unchanged, so nothing a caller already relies
    -- on shifts; raise it only to reach a structure that would otherwise be
    -- reported in skipped_fields (see the note on cloneSerializable).
    local maxDepth = tonumber(args.max_depth) or CLONE_DEFAULT_MAX_DEPTH
    if maxDepth < 1 or maxDepth > CLONE_HARD_MAX_DEPTH then
        error(string.format("max_depth must be between 1 and %d", CLONE_HARD_MAX_DEPTH))
    end

    local catalog = LrApplication.activeCatalog()

    local photo = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] then photo = resolved[1].photo end
    end)
    if not photo then
        error("No photo matched photo_id")
    end

    local settings = nil
    catalog:withReadAccessDo(function()
        settings = photo:getDevelopSettings()
    end)
    if type(settings) ~= "table" then
        error("getDevelopSettings returned no settings table")
    end

    local out = {}
    local skipped = {}
    local skippedShapes = {}
    local skippedCount = 0
    local function copySetting(key, value)
        local cloned, supported = cloneSerializable(value, 0, {}, maxDepth)
        if supported then
            out[key] = cloned
        else
            skippedCount = skippedCount + 1
            table.insert(skipped, key)
            skippedShapes[key] = describeValue(value, 0)
        end
    end

    if fields == "all" then
        for key, value in pairs(settings) do
            copySetting(key, value)
        end
    else
        for _, key in ipairs(BASIC_DEVELOP_READ_KEYS) do
            if settings[key] ~= nil then
                copySetting(key, settings[key])
            end
        end
    end

    local count = 0
    for _ in pairs(out) do count = count + 1 end

    Log.info(string.format("getDevelopSettings: %d field(s) (fields=%s, %d skipped)",
        count, fields, skippedCount))

    local result = {
        success = true,
        photo = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
            filename = photo:getFormattedMetadata('fileName'),
        },
        fields = fields,
        settings = out,
        setting_count = count,
        max_depth = maxDepth,
        message = string.format("Read %d develop setting(s)", count),
    }
    if skippedCount > 0 then
        result.skipped_fields = skipped
        -- Naming a skipped field says nothing about why. The shape does:
        -- types, counts and key names, deep enough to see the structure and
        -- shallow on content so the response stays small.
        result.skipped_field_shapes = skippedShapes
        result.message = result.message
            .. string.format(" (%d non-serializable field(s) skipped)", skippedCount)
    end
    return result
end

-- =====================================================================
-- reset_develop — reset all adjustments, per tool, or per parameter
-- =====================================================================
--
-- LrDevelopController exposes three reset surfaces (all reverse-engineered
-- by lightroom-cli and verified against LrC 12/13):
--   resetAllDevelopAdjustments()            — everything, like the Reset button
--   resetCrop()/resetTransforms()/...       — per Develop tool
--   resetToDefault(param)                   — one named parameter
-- Like every LrDevelopController call they act on the photo loaded in the
-- Develop module, so the handler switches modules and selects the photo
-- first (outside any gate), then runs the resets inside write gates and
-- verifies through a before/after settings diff.

local RESET_TOOLS = {
    crop = function() LrDevelopController.resetCrop() end,
    transforms = function() LrDevelopController.resetTransforms() end,
    spot_removal = function() LrDevelopController.resetSpotRemoval() end,
    redeye = function() LrDevelopController.resetRedeye() end,
    healing = function() LrDevelopController.resetHealing() end,
    masking = function() LrDevelopController.resetMasking() end,
    gradient = function() LrDevelopController.resetGradient() end,
    circular_gradient = function() LrDevelopController.resetCircularGradient() end,
    brushing = function() LrDevelopController.resetBrushing() end,
}

local function switchToDevelopAndSelectPhoto(catalog, photo)
    local switchOk, switchErr = pcall(function()
        LrApplicationView.switchToModule("develop")
    end)
    if not switchOk then
        error("could not switch Lightroom to the Develop module: " .. tostring(switchErr))
    end
    LrTasks.sleep(AUTO_SETTLE_AFTER_MODULE_SWITCH_S)

    local selectOk = pcall(function()
        catalog:setSelectedPhotos(photo, { photo })
    end)
    if not selectOk then
        error("could not select the photo in Lightroom")
    end
    LrTasks.sleep(AUTO_SETTLE_BETWEEN_PHOTOS_S)
end

function DevelopHandler.resetDevelop(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local scope = args.scope or "all"
    if scope ~= "all" and scope ~= "tools" and scope ~= "params" then
        error("scope must be 'all' (default), 'tools' or 'params'")
    end

    local tools = args.tools
    local params = args.params

    if scope == "tools" then
        if type(tools) ~= "table" or #tools == 0 then
            error("tools array is required when scope is 'tools' (crop, transforms, spot_removal, redeye, healing, masking, gradient, circular_gradient, brushing)")
        end
        for i, tool in ipairs(tools) do
            if not RESET_TOOLS[tool] then
                error("tools[" .. i .. "] '" .. tostring(tool) .. "' is not a resettable tool")
            end
        end
    elseif scope == "params" then
        if type(params) ~= "table" or #params == 0 then
            error("params array is required when scope is 'params'")
        end
        for i, key in ipairs(params) do
            requireAllowedDevelopSettingKey(key)
        end
    end

    local catalog = LrApplication.activeCatalog()

    local photo = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] then photo = resolved[1].photo end
    end)
    if not photo then
        error("No photo matched photo_id")
    end

    switchToDevelopAndSelectPhoto(catalog, photo)

    local before = nil
    catalog:withReadAccessDo(function()
        before = photo:getDevelopSettings()
    end)

    local applied = {}
    local errors = {}

    -- LrDevelopController.* reset commands are UI-menu-command style calls
    -- (like LrApplicationView.switchToModule and the LrSelection commands
    -- elsewhere in this codebase) — they drive the live Develop session and
    -- manage their own catalog transaction internally. Wrapping them in our
    -- own catalog:withWriteAccessDo nests a second write-access request that
    -- Lightroom always rejects with "blocked by another write access call",
    -- 100% reproducibly, regardless of timing or concurrency (#<TBD>: the
    -- spec mocks never caught this because withWriteAccessDo is stubbed as a
    -- plain passthrough in spec_helper.lua). Call them bare, no gate.
    if scope == "all" then
        local ok, err = pcall(function()
            LrDevelopController.resetAllDevelopAdjustments()
        end)
        if ok then
            applied.all = true
        else
            errors.all = tostring(err)
        end
    elseif scope == "tools" then
        for _, tool in ipairs(tools) do
            local ok, err = pcall(function()
                RESET_TOOLS[tool]()
            end)
            if ok then
                applied[tool] = true
            else
                errors[tool] = tostring(err)
            end
        end
    else
        for _, key in ipairs(params) do
            local ok, err = pcall(function()
                LrDevelopController.resetToDefault(key)
            end)
            if ok then
                applied[key] = true
            else
                errors[key] = tostring(err)
            end
        end
    end

    -- Give the Develop pipeline a beat, then diff the main sliders so the
    -- caller sees what actually changed (same read-back as applyAuto).
    LrTasks.sleep(AUTO_SETTLE_AFTER_COMMAND_S)
    local after = nil
    catalog:withReadAccessDo(function()
        after = photo:getDevelopSettings()
    end)

    local changed = {}
    if type(before) == "table" and type(after) == "table" then
        for _, k in ipairs(BASIC_DEVELOP_READ_KEYS) do
            if before[k] ~= nil and before[k] ~= after[k] then
                changed[k] = { before = before[k], after = after[k] }
            end
        end
    end

    local failedCount = 0
    for _ in pairs(errors) do failedCount = failedCount + 1 end

    Log.info(string.format("resetDevelop(%s): %d reset(s), %d error(s)",
        scope, (scope == "all" and 1 or (scope == "tools" and #tools or #params)), failedCount))

    local result = {
        success = failedCount == 0,
        scope = scope,
        applied = applied,
        errors = (next(errors) ~= nil) and errors or nil,
        changed = (next(changed) ~= nil) and changed or nil,
        message = string.format("Reset develop settings (scope=%s)%s",
            scope, failedCount > 0 and (" — " .. failedCount .. " error(s)") or ""),
    }
    if next(changed) == nil and failedCount == 0 then
        result.note = "No slider changed — the settings may already be at defaults."
    end
    return result
end

-- =====================================================================
-- set_process_version — process/engine version of the loaded photo
-- =====================================================================
--
-- LrDevelopController.setProcessVersion("Version N") switches the process
-- (calibration engine) of the photo loaded in Develop: Version 3 is
-- Process 2012, higher numbers are newer engines (LrC 13+ = Version 6).
-- Older photos can be modernized (then AI masking/Denoise unlock) at the
-- cost of a rendering change. Read-back via getProcessVersion confirms.

function DevelopHandler.setProcessVersion(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local version = args.version
    if version == nil then
        error("version is required (e.g. 'Version 3' = Process 2012, 'Version 6' = newest)")
    end

    local catalog = LrApplication.activeCatalog()

    local photo = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] then photo = resolved[1].photo end
    end)
    if not photo then
        error("No photo matched photo_id")
    end

    switchToDevelopAndSelectPhoto(catalog, photo)

    local beforeVersion = nil
    pcall(function() beforeVersion = LrDevelopController.getProcessVersion() end)

    local ok, err = runDevelopCommand("setProcessVersion", function()
        LrDevelopController.setProcessVersion(version)
    end)
    if not ok then
        error(err .. " (the photo may already be on this engine, or the LrC version does not accept it)")
    end

    LrTasks.sleep(AUTO_SETTLE_AFTER_COMMAND_S)
    local afterVersion = nil
    pcall(function() afterVersion = LrDevelopController.getProcessVersion() end)

    Log.info(string.format("setProcessVersion: %s -> %s (requested %s)",
        tostring(beforeVersion), tostring(afterVersion), version))

    local result = {
        success = true,
        version = version,
        before = beforeVersion,
        after = afterVersion,
        verified = (afterVersion ~= nil and afterVersion == version),
        message = string.format("Process version: %s -> %s",
            tostring(beforeVersion), tostring(afterVersion or version)),
    }
    if afterVersion ~= nil and afterVersion ~= version then
        result.warning = "Lightroom reports a different process version than requested: "
            .. tostring(afterVersion)
    end
    return result
end

-- =====================================================================
-- create_snapshot — named develop snapshot (undo checkpoint)
-- =====================================================================
--
-- photo:createDevelopSnapshot(name) records the current develop state as
-- a Snapshots panel entry. The SDK exposes no list/apply/delete for
-- snapshots, so this is create-only — reported honestly instead of
-- pretending a read-back. Ported from lightroom-cli createDevelopSnapshot.

function DevelopHandler.createSnapshot(args)
    if args.photo_id == nil or args.photo_id == "" then
        error("photo_id is required")
    end

    local name = args.name
    if type(name) ~= "string" or name == "" then
        error("name is required")
    end
    if #name > 255 then
        error("name must be at most 255 characters")
    end

    local catalog = LrApplication.activeCatalog()

    local photo = nil
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, { args.photo_id })
        if resolved[1] then photo = resolved[1].photo end
    end)
    if not photo then
        error("No photo matched photo_id")
    end

    catalog:withWriteAccessDo("Create Develop Snapshot", function()
        photo:createDevelopSnapshot(name)
    end)

    Log.info(string.format("createSnapshot('%s') on photo %s", name, tostring(photo.localIdentifier)))

    return {
        success = true,
        photo = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
        },
        name = name,
        message = string.format("Created develop snapshot '%s'", name),
        note = "The SDK cannot list snapshots back; verify visually in Lightroom's Snapshots panel.",
    }
end

return DevelopHandler
