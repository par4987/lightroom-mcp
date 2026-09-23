import type { Tool } from "@modelcontextprotocol/sdk/types.js";

type InputSchema = Tool["inputSchema"];

export interface ToolContract {
  name: string;
  description: string;
  luaHandler: string;
  inputSchema: InputSchema;
  annotations?: Tool["annotations"];
  outputSchema?: Tool["outputSchema"];
}

/**
 * Output schemas for the tools an editing loop leans on.
 *
 * Declaring one is a promise: a client may validate the structuredContent we
 * return against it. So these describe only response shapes that have been
 * observed coming back from a real Lightroom, they mark as `required` only the
 * fields every response carries, and they deliberately do NOT set
 * additionalProperties:false — the Lua side adds diagnostic fields over time
 * (get_photo_preview grew `renditions_received` and `size_usable` this way),
 * and a client should never reject a response for telling it more.
 *
 * The rest of the 56 tools stay schema-less rather than carrying a guess.
 */
const photoRef = {
  type: "object",
  description: "The photo this result is about",
  properties: {
    id: { type: "number" },
    path: { type: "string" },
    filename: { type: "string" },
    width: { type: "number" },
    height: { type: "number" },
  },
} as const;

const OUTPUT_SCHEMAS: Record<string, Tool["outputSchema"]> = {
  get_photo_preview: {
    type: "object",
    properties: {
      success: { type: "boolean" },
      photo: photoRef,
      file_path: { type: "string", description: "JPEG written to the previews folder" },
      mime_type: { type: "string" },
      size_px: { type: "number", description: "Size that was REQUESTED" },
      size_bytes: { type: "number", description: "Bytes on disk" },
      rendered_width: { type: "number", description: "Actual width of the JPEG returned" },
      rendered_height: { type: "number", description: "Actual height of the JPEG returned" },
      size_usable: {
        type: "boolean",
        description:
          "False when Lightroom served a rendition that is not what was asked for — smaller (a cached thumbnail, possibly from before the last edit) or far larger (the full-resolution original). Check this before treating the image as proof of an edit.",
      },
      renditions_received: { type: "number" },
      image_attached_by_server: { type: "boolean" },
      warning: { type: "string" },
      message: { type: "string" },
    },
    required: ["success", "file_path", "size_px"],
  },
  get_selected_photos: {
    type: "object",
    properties: {
      photos: {
        type: "array",
        items: {
          type: "object",
          properties: {
            id: { type: "number" },
            path: { type: "string" },
            filename: { type: "string" },
            dateTimeOriginal: { type: "string" },
          },
        },
      },
      count: { type: "number" },
      has_more: { type: "boolean" },
    },
    required: ["photos", "count"],
  },
  get_develop_settings: {
    type: "object",
    properties: {
      success: { type: "boolean" },
      photo: photoRef,
      fields: { type: "string", enum: ["basic", "all"] },
      settings: { type: "object", description: "Develop setting keys and their stored values" },
      setting_count: { type: "number" },
      skipped_fields: {
        type: "array",
        items: { type: "string" },
        description: "Keys this Lightroom version would not serialise",
      },
      message: { type: "string" },
    },
    required: ["success", "settings"],
  },
  list_masks: {
    type: "object",
    properties: {
      success: { type: "boolean" },
      photo: photoRef,
      fields: { type: "string", enum: ["summary", "full"] },
      masks: {
        type: "array",
        description:
          "Stored CorrectionMasks entries. In 'summary' each carries the correction_id that owns it.",
        items: { type: "object" },
      },
      count: { type: "number", description: "Masks, not corrections" },
      corrections: { type: "number" },
      note: { type: "string" },
      message: { type: "string" },
    },
    required: ["success", "masks", "count"],
  },
  read_local_adjustments: {
    type: "object",
    properties: {
      success: { type: "boolean" },
      photo_id: { type: "number" },
      fields: { type: "string", enum: ["summary", "full"] },
      count: { type: "number" },
      corrections: {
        type: "array",
        description:
          "Summary view: correction_id, name, active, amount, the sliders actually set, and each mask's id/name. fields='full' returns the verbatim MaskGroupBasedCorrections instead.",
        items: { type: "object" },
      },
      note: { type: "string" },
    },
    required: ["success", "corrections", "count"],
  },
};

export function outputSchemaFor(name: string): Tool["outputSchema"] | undefined {
  return OUTPUT_SCHEMAS[name];
}

export const TOOLS_WITH_OUTPUT_SCHEMA: readonly string[] = Object.keys(OUTPUT_SCHEMAS);

/**
 * Behaviour classification for every tool, as MCP annotations.
 *
 * This matters more here than in most servers: an agent driving this one is
 * editing someone's actual photo library, and until now nothing machine-
 * readable said which of the 56 tools merely look and which ones destroy. The
 * destructiveness of `remove_from_catalog` lived only in the prose of its
 * description.
 *
 * Every tool must appear in exactly one of the three lists below — enforced by
 * a test, so a new tool fails CI until someone classifies it rather than
 * silently inheriting a default.
 *
 * `openWorldHint` is false for all of them: this server talks to one local
 * Lightroom catalog, not an open-ended external world.
 */
const READ_ONLY_TOOLS = [
  "search_photos",
  "get_selected_photos",
  "get_photo_metadata",
  "get_photo_status",
  "get_photo_preview",
  "get_develop_settings",
  "get_tone_curve",
  "get_spots",
  "get_develop_preset",
  "get_collection_photos",
  "compare_develop_presets",
  "read_local_adjustments",
  "list_collections",
  "list_develop_presets",
  "list_watermarks",
  "list_masks",
  "list_folders",
  "list_keywords",
] as const;

/**
 * Tools that can take away work the user already has. `reset_develop` wipes
 * adjustments, `clear_spots` drops every spot correction, `remove_mask` with
 * remove_all strips all masks, and `remove_from_catalog` removes photos from
 * the catalog (files on disk survive, but the edits recorded against them do
 * not).
 */
const DESTRUCTIVE_TOOLS = [
  "reset_develop",
  "clear_spots",
  "remove_mask",
  "remove_from_catalog",
] as const;

/** Everything else: it writes, but only adds or overwrites its own target. */
const MUTATING_TOOLS = [
  "create_collection",
  "create_collection_set",
  "create_smart_collection",
  "add_to_collection",
  "create_virtual_copies",
  "create_snapshot",
  "create_develop_preset",
  "export_develop_preset",
  "apply_develop_preset",
  "copy_develop_settings",
  "set_develop_settings",
  "set_white_balance",
  "set_tone_curve",
  "set_process_version",
  "set_noise_reduction",
  "set_mask_adjustments",
  "set_keywords",
  "set_rating",
  "set_flags",
  "set_color_label",
  "batch_metadata",
  "add_spots",
  "add_local_adjustment",
  "add_ai_mask",
  "add_range_mask",
  "apply_auto",
  "ai_denoise",
  "rotate_photo",
  "import_photos",
  "export_photos",
  "select_photos",
  "navigate_photo",
  "toggle_mask_overlay",
  "manage_view_filter",
] as const;

/**
 * Calling these again with the same arguments lands on the same state.
 * Deliberately excluded: every `add_*`/`create_*` (each call appends another
 * mask, spot, copy or snapshot), `rotate_photo` and `navigate_photo` (they
 * move relative to where they are), `toggle_mask_overlay` (it flips),
 * `apply_auto` and `ai_denoise` (they re-analyse and can land differently),
 * and `export_photos` (on_existing: "rename" writes an extra file each time).
 */
const IDEMPOTENT_TOOLS = new Set<string>([
  "set_develop_settings",
  "set_white_balance",
  "set_tone_curve",
  "set_process_version",
  "set_noise_reduction",
  "set_mask_adjustments",
  "set_keywords",
  "set_rating",
  "set_flags",
  "set_color_label",
  "batch_metadata",
  "select_photos",
  "manage_view_filter",
  "add_to_collection",
  "apply_develop_preset",
  "copy_develop_settings",
  "export_develop_preset",
  "reset_develop",
  "clear_spots",
  "remove_mask",
  "remove_from_catalog",
]);

export const READ_ONLY_TOOL_NAMES: readonly string[] = READ_ONLY_TOOLS;
export const DESTRUCTIVE_TOOL_NAMES: readonly string[] = DESTRUCTIVE_TOOLS;
export const MUTATING_TOOL_NAMES: readonly string[] = MUTATING_TOOLS;

const READ_ONLY_SET = new Set<string>(READ_ONLY_TOOLS);
const DESTRUCTIVE_SET = new Set<string>(DESTRUCTIVE_TOOLS);

export function annotationsFor(name: string): Tool["annotations"] {
  const readOnly = READ_ONLY_SET.has(name);
  if (readOnly) {
    return { readOnlyHint: true, openWorldHint: false };
  }
  return {
    readOnlyHint: false,
    destructiveHint: DESTRUCTIVE_SET.has(name),
    idempotentHint: IDEMPOTENT_TOOLS.has(name),
    openWorldHint: false,
  };
}

const MAX_BULK_PHOTO_IDS = 1000;
const MAX_KEYWORDS = 1000;

export const POINT_CURVE_SETTING_KEYS = [
  "ToneCurvePV2012",
  "ToneCurvePV2012Red",
  "ToneCurvePV2012Green",
  "ToneCurvePV2012Blue",
] as const;

export const DEVELOP_SETTING_KEYS = [
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
  ...POINT_CURVE_SETTING_KEYS,
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
] as const;

const stringArray = (description: string, maxItems?: number) => ({
  type: "array",
  items: { type: "string" },
  minItems: 1,
  ...(maxItems ? { maxItems } : {}),
  description,
});

/**
 * Photo ids come back from the catalog as numbers (`localIdentifier`), so a
 * caller piping search/selection output straight into a write tool sends
 * numbers. Accept both rather than making every caller stringify.
 */
const photoIdSchema = (description: string) => ({
  oneOf: [{ type: "string", minLength: 1 }, { type: "number" }],
  description,
});

const photoIdArray = (description: string) => ({
  type: "array",
  items: { oneOf: [{ type: "string", minLength: 1 }, { type: "number" }] },
  minItems: 1,
  maxItems: MAX_BULK_PHOTO_IDS,
  description,
});

const dateStringSchema = (description: string) => ({
  type: "string",
  pattern: "^\\d{4}-\\d{2}-\\d{2}$",
  description,
});

const scalarDevelopSettingValueSchema = {
  oneOf: [{ type: "number" }, { type: "string" }, { type: "boolean" }],
};

const POINT_CURVE_MIN_PAIRS = 2;
const POINT_CURVE_MAX_PAIRS = 32;

const evenLengthSchemas = Array.from(
  { length: POINT_CURVE_MAX_PAIRS - POINT_CURVE_MIN_PAIRS + 1 },
  (_, index) => {
    const length = (POINT_CURVE_MIN_PAIRS + index) * 2;
    return { minItems: length, maxItems: length };
  },
);

const pointCurveDevelopSettingValueSchema = {
  type: "array",
  items: { type: "integer", minimum: 0, maximum: 255 },
  minItems: POINT_CURVE_MIN_PAIRS * 2,
  maxItems: POINT_CURVE_MAX_PAIRS * 2,
  anyOf: evenLengthSchemas,
  description:
    "Flat input/output pairs for a Lightroom point curve, e.g. [0, 0, 64, 48, 192, 210, 255, 255]. Values are integers from 0 to 255 and the array holds 2 to 32 pairs, so its length is always even. Inputs must be strictly increasing and the curve must start at input 0 and end at input 255.",
};

const pointCurveSettingKeySet = new Set<string>(POINT_CURVE_SETTING_KEYS);

const developSettingsProperties = Object.fromEntries(
  DEVELOP_SETTING_KEYS.map((key) => [
    key,
    pointCurveSettingKeySet.has(key)
      ? pointCurveDevelopSettingValueSchema
      : scalarDevelopSettingValueSchema,
  ]),
);

const presetSelectorProperties = {
  preset_name: { type: "string", minLength: 1, description: "Develop preset name" },
  preset_uuid: { type: "string", minLength: 1, description: "Develop preset UUID (preferred)" },
  preset_folder: { type: "string", minLength: 1, description: "Preset folder for disambiguation" },
  preset_scope: {
    type: "string",
    enum: ["lightroom", "plugin"],
    description: "Lightroom-visible preset or plugin-managed checkpoint",
  },
};

const presetSelectorSchema: InputSchema = {
  type: "object",
  additionalProperties: false,
  properties: presetSelectorProperties,
  anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
};

/**
 * Advanced findPhotos/searchDesc rules — the same { criteria, operation,
 * value, value2? } shape Lightroom uses internally, shared by
 * search_photos (advanced filters) and manage_view_filter (set).
 */
const searchRulesArray = (description: string) => ({
  type: "array",
  minItems: 1,
  maxItems: 20,
  description,
  items: {
    type: "object",
    additionalProperties: false,
    properties: {
      criteria: { type: "string", minLength: 1, description: "Field to test (e.g. 'keywords', 'rating', 'cameraModel', 'lens', 'isoSpeedRating', 'copyName', 'hasAdjustments', 'captureTime', 'text')" },
      operation: { type: "string", minLength: 1, description: "Test (e.g. 'all', 'any', '==', '>=', 'in', 'startsWith')" },
      value: {
        oneOf: [{ type: "string" }, { type: "number" }],
        description: "Value to compare (string or number)",
      },
      value2: {
        oneOf: [{ type: "string" }, { type: "number" }],
        description: "Second value for 'in' (range) operations",
      },
    },
    required: ["criteria", "operation", "value"],
  },
});

export const TOOL_CONTRACTS: ToolContract[] = [
  {
    name: "search_photos",
    luaHandler: "HandlerSearch.searchPhotos",
    description:
      "Search for photos in Lightroom catalog by criteria (paginated, default limit 100). Use the simplified filters (filename, keywords, rating, dates) or advanced `rules` for any findPhotos criterion (cameraModel, lens, isoSpeedRating, copyName, hasAdjustments...). Providing at least one filter significantly improves performance on large catalogs; with no filters at all it lists the whole catalog.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        filename: { type: "string", description: "Search by filename (partial match)" },
        keywords: stringArray("Search by keywords"),
        rating: {
          type: "number",
          description: "Filter by star rating (0-5)",
          minimum: 0,
          maximum: 5,
        },
        start_date: dateStringSchema("Start date (YYYY-MM-DD)"),
        end_date: dateStringSchema("End date (YYYY-MM-DD)"),
        rules: searchRulesArray(
          "Advanced criteria rules (same format as create_smart_collection). Intersect with the simplified filters unless combine is 'union'.",
        ),
        combine: {
          type: "string",
          enum: ["intersect", "union"],
          description: "How filters combine: 'intersect' (AND, default) or 'union' (OR)",
        },
        limit: { type: "number", description: "Max photos to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "get_selected_photos",
    luaHandler: "HandlerSelection.getSelectedPhotos",
    description: "Get currently selected photos in Lightroom (or filmstrip if no selection). Paginated, default limit 100.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max photos to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "get_photo_metadata",
    luaHandler: "HandlerMetadata.getPhotoMetadata",
    description:
      "Get detailed metadata for a specific photo: EXIF, title/caption/headline, GPS (latitude/longitude/altitude), IPTC location (sublocation/city/stateProvince/country/isoCountryCode), copyright, and develop settings",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "list_collections",
    luaHandler: "HandlerCollections.listCollections",
    description: "List all collections in Lightroom catalog (paginated, default limit 100)",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max collections to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of collections to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "create_collection",
    luaHandler: "HandlerCollections.createCollection",
    description: "Create a new collection",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", description: "Collection name" },
        parent: { type: "string", description: "Parent collection set (optional)" },
      },
      required: ["name"],
    },
  },
  {
    name: "add_to_collection",
    luaHandler: "HandlerCollections.addToCollection",
    description: "Add photos to a collection",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: { type: "string", description: "Collection name" },
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["collection_name", "photo_ids"],
    },
  },
  {
    name: "set_keywords",
    luaHandler: "HandlerOrganization.setKeywords",
    description: "Add or remove keywords from photos",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        add_keywords: stringArray("Keywords to add", MAX_KEYWORDS),
        remove_keywords: stringArray("Keywords to remove", MAX_KEYWORDS),
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_rating",
    luaHandler: "HandlerOrganization.setRating",
    description: "Set star rating for photos",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        rating: {
          type: "number",
          description: "Star rating (0-5)",
          minimum: 0,
          maximum: 5,
        },
      },
      required: ["photo_ids", "rating"],
    },
  },
  {
    name: "import_photos",
    luaHandler: "HandlerImport.importPhotos",
    description: "Import photos into Lightroom catalog",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_path: { type: "string", description: "Path to photo or folder to import" },
        collection_name: {
          type: "string",
          description: "Collection to add imported photos to (optional)",
        },
        copy_to: {
          type: "string",
          description: "Destination folder for copying files (optional)",
        },
      },
      required: ["source_path"],
    },
  },
  {
    name: "export_photos",
    luaHandler: "HandlerExport.exportPhotos",
    description:
      "Export photos from Lightroom. Creates the destination folder when it does not exist (the response reports created_directory: true); fails with the path when it cannot.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths to export"),
        destination: { type: "string", description: "Export destination folder" },
        format: {
          type: "string",
          description: "Export format (jpeg, png, tiff, original)",
          enum: ["jpeg", "png", "tiff", "original"],
        },
        quality: {
          type: "number",
          description: "JPEG quality (0-100)",
          minimum: 0,
          maximum: 100,
        },
        width: { type: "number", description: "Max width in pixels (optional)" },
        height: { type: "number", description: "Max height in pixels (optional)" },
        on_existing: {
          type: "string",
          description:
            "What to do when the destination already holds a file with that name (default rename). Lightroom never prompts.",
          enum: ["rename", "overwrite", "skip"],
        },
        watermark: {
          type: "string",
          minLength: 1,
          description:
            "Name of a Lightroom watermark preset to apply (list exact names with list_watermarks). Not valid with format 'original'.",
        },
      },
      required: ["photo_ids", "destination"],
    },
  },
  {
    name: "list_develop_presets",
    luaHandler: "HandlerDevelop.listDevelopPresets",
    description: "List Lightroom-visible Develop presets and plugin-managed preset checkpoints",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max presets to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of presets to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "get_develop_preset",
    luaHandler: "HandlerDevelop.getDevelopPreset",
    description:
      "Read the settings and backing-file metadata for one exact Develop preset. Use preset_uuid or provide folder/scope when names are duplicated.",
    inputSchema: presetSelectorSchema,
  },
  {
    name: "compare_develop_presets",
    luaHandler: "HandlerDevelop.compareDevelopPresets",
    description:
      "Compare two Develop presets and return a deterministic per-setting diff for iterative style matching",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        base: { ...presetSelectorSchema, description: "Approved historical/base preset" },
        candidate: { ...presetSelectorSchema, description: "Candidate preset checkpoint" },
      },
      required: ["base", "candidate"],
    },
  },
  {
    name: "create_develop_preset",
    luaHandler: "HandlerDevelop.createDevelopPreset",
    description:
      "Create a versioned plugin-managed Develop preset checkpoint from selected settings on one photo. The checkpoint is hidden from the Develop panel; export it for handoff.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Source photo ID or file path"),
        preset_name: {
          type: "string",
          minLength: 1,
          description: "Unique versioned checkpoint name; existing plugin names are refused",
        },
        settings: {
          type: "array",
          items: { type: "string", enum: DEVELOP_SETTING_KEYS },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          uniqueItems: true,
          description: "Explicit Lightroom SDK setting keys to capture from the source photo",
        },
      },
      required: ["photo_id", "preset_name", "settings"],
    },
  },
  {
    name: "export_develop_preset",
    luaHandler: "HandlerDevelop.exportDevelopPreset",
    description:
      "Copy one exact custom or plugin-managed Develop preset backing file to a destination directory. Existing files are never overwritten; built-in presets without backing files cannot be exported.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...presetSelectorProperties,
        destination_dir: {
          type: "string",
          minLength: 1,
          description: "Destination directory; created when missing",
        },
        filename: {
          type: "string",
          minLength: 1,
          description: "Optional leaf filename. Extension must match the Lightroom backing file.",
        },
      },
      required: ["destination_dir"],
      anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
    },
  },
  {
    name: "apply_develop_preset",
    luaHandler: "HandlerDevelop.applyDevelopPreset",
    description: "Apply one exact Develop preset to one or more photos",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        preset_name: {
          type: "string",
          description: "Preset name",
        },
        preset_uuid: { type: "string", description: "Preset UUID (preferred)" },
        preset_folder: { type: "string", description: "Preset folder for disambiguation" },
        preset_scope: { type: "string", enum: ["lightroom", "plugin"] },
      },
      required: ["photo_ids"],
      anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
    },
  },
  {
    name: "copy_develop_settings",
    luaHandler: "HandlerDevelop.copyDevelopSettings",
    description: "Copy Develop settings from one photo to others",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_id: photoIdSchema("Source photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
        settings: {
          type: "array",
          items: {
            type: "string",
            enum: DEVELOP_SETTING_KEYS,
          },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          description:
            "Optional whitelist of SDK setting keys (e.g., Exposure2012, Contrast2012, HueAdjustmentOrange). Omit to copy all.",
        },
      },
      required: ["source_id", "target_ids"],
    },
  },
  {
    name: "set_develop_settings",
    luaHandler: "HandlerDevelop.setDevelopSettings",
    description:
      "Set Develop settings directly on a photo. Keys use allowlisted Lightroom SDK names (Exposure2012, WhiteBalance, Contrast2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Vibrance, Saturation, HueAdjustmentRed, SaturationAdjustmentOrange, LuminanceAdjustmentYellow, etc.), plus RGB composite and per-channel point curves via ToneCurvePV2012, ToneCurvePV2012Red, ToneCurvePV2012Green, and ToneCurvePV2012Blue. Reads the settings back: the response carries `verified` (what Lightroom stored) and, when a key was refused, `not_applied` plus a warning -- so a follow-up verification call is unnecessary.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        settings: {
          type: "object",
          properties: developSettingsProperties,
          additionalProperties: false,
          minProperties: 1,
          description:
            "Allowlisted SDK setting key/value pairs (e.g., {\"Exposure2012\": 0.5, \"SaturationAdjustmentOrange\": -10})",
        },
      },
      required: ["photo_id", "settings"],
    },
  },
  {
    name: "ai_denoise",
    luaHandler: "HandlerAI.aiDenoise",
    description:
      "Hybrid AI noise reduction for one RAW/DNG photo. First tries Adobe's native AI Denoise (Photo > Enhance) by selecting the photo in Lightroom and replaying a configurable SendKeys sequence against the Lightroom window (Windows + Lightroom in the foreground required; defaults target the English menu). Verifies success by waiting for the new DNG that AI Denoise writes next to the original. If the native path cannot be verified, falls back to smart manual noise reduction sliders (ISO-aware) and reports which method it used via 'method' ('native' | 'manual_fallback'). Setup: keep Lightroom Classic focused, and adjust native_automation keys if your Lightroom uses another menu language.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path (must be RAW or DNG for the native path)"),
        fallback: {
          type: "string",
          enum: ["manual", "none"],
          description:
            "What to do when the native AI Denoise cannot be verified. 'manual' (default) applies smart manual noise reduction; 'none' returns an error instead.",
        },
        manual_settings: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          description:
            "Overrides for the manual fallback sliders. Defaults are ISO-aware (luminance 35-65, color 25).",
          properties: {
            luminance: { type: "number", minimum: 0, maximum: 100, description: "Luminance noise reduction (0-100)" },
            color: { type: "number", minimum: 0, maximum: 100, description: "Color noise reduction (0-100)" },
            luminance_detail: { type: "number", minimum: 0, maximum: 100, description: "Luminance detail (0-100)" },
            luminance_contrast: { type: "number", minimum: 0, maximum: 100, description: "Luminance contrast (0-100)" },
            color_detail: { type: "number", minimum: 0, maximum: 100, description: "Color detail (0-100)" },
            color_smoothness: { type: "number", minimum: 0, maximum: 100, description: "Color smoothness (0-100)" },
          },
        },
        native_automation: {
          type: "object",
          additionalProperties: false,
          description:
            "SendKeys automation overrides. Defaults: window_title 'Lightroom Classic', menu_keys '%pe' (Alt+P opens the Photo menu, then E picks Enhance), confirm_keys '{ENTER}', key_delay_ms 600, verify_timeout_s 90. Use arrow navigation (e.g. '%p{DOWN 3}{ENTER}') or a different first key for other menu languages.",
          properties: {
            window_title: { type: "string", minLength: 1, description: "Lightroom window title (partial match)" },
            menu_keys: {
              type: "string",
              minLength: 1,
              description: "SendKeys sequence that opens Photo > Enhance (e.g. '%pe')",
            },
            confirm_keys: {
              type: "string",
              minLength: 1,
              description: "SendKeys sequence that confirms the Enhance dialog (default '{ENTER}')",
            },
            pre_delay_ms: {
              type: "number",
              minimum: 0,
              maximum: 5000,
              description: "Delay after activating the window before the first keys (default 400)",
            },
            key_delay_ms: {
              type: "number",
              minimum: 0,
              maximum: 5000,
              description: "Delay between the menu keys and the confirm keys (default 600)",
            },
            verify_timeout_s: {
              type: "number",
              minimum: 10,
              maximum: 240,
              description: "Seconds to wait for the new DNG before falling back (default 90)",
            },
          },
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "set_noise_reduction",
    luaHandler: "HandlerAI.setNoiseReduction",
    description:
      "Set manual noise reduction and sharpening sliders (SDK-native, works on any photo). Luminance = LuminanceSmoothing, color = ColorNoiseReduction, plus detail/smoothness controls and the sharpening group.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        luminance: { type: "number", minimum: 0, maximum: 100, description: "Luminance noise reduction (0-100)" },
        color: { type: "number", minimum: 0, maximum: 100, description: "Color noise reduction (0-100)" },
        luminance_detail: { type: "number", minimum: 0, maximum: 100, description: "Luminance detail (0-100)" },
        luminance_contrast: { type: "number", minimum: 0, maximum: 100, description: "Luminance contrast (0-100)" },
        color_detail: { type: "number", minimum: 0, maximum: 100, description: "Color detail (0-100)" },
        color_smoothness: { type: "number", minimum: 0, maximum: 100, description: "Color smoothness (0-100)" },
        sharpness: { type: "number", minimum: 0, maximum: 150, description: "Sharpening amount (0-150)" },
        sharpen_radius: { type: "number", minimum: 0.5, maximum: 3, description: "Sharpening radius (0.5-3)" },
        sharpen_detail: { type: "number", minimum: 0, maximum: 100, description: "Sharpening detail (0-100)" },
        sharpen_edge_masking: { type: "number", minimum: 0, maximum: 100, description: "Edge masking (0-100)" },
      },
      required: ["photo_ids"],
      anyOf: [
        { required: ["luminance"] },
        { required: ["color"] },
        { required: ["luminance_detail"] },
        { required: ["luminance_contrast"] },
        { required: ["color_detail"] },
        { required: ["color_smoothness"] },
        { required: ["sharpness"] },
        { required: ["sharpen_radius"] },
        { required: ["sharpen_detail"] },
        { required: ["sharpen_edge_masking"] },
      ],
    },
  },
  {
    name: "set_white_balance",
    luaHandler: "HandlerDevelop.setWhiteBalance",
    description:
      "Set white balance on photos via a preset (As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash) or explicit Kelvin temperature (2000-50000) and/or tint (-150 green to 150 magenta). 'Auto' is computed synchronously on SDK 13+. Full effect only on RAW/DNG files.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        preset: {
          type: "string",
          enum: ["As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash"],
          description: "White balance preset",
        },
        temperature: {
          type: "number",
          minimum: 2000,
          maximum: 50000,
          description: "Custom temperature in Kelvin (implies preset 'Custom')",
        },
        tint: {
          type: "number",
          minimum: -150,
          maximum: 150,
          description: "Custom tint, -150 (green) to 150 (magenta)",
        },
      },
      required: ["photo_ids"],
      anyOf: [{ required: ["preset"] }, { required: ["temperature"] }, { required: ["tint"] }],
    },
  },
  {
    name: "set_flags",
    luaHandler: "HandlerOrganization.setFlags",
    description:
      "Set the pick/reject flag on photos ('pick', 'reject', or 'none' to clear). Uses the UI selection commands and verifies per photo; photos hidden from the current view source are retried individually and reported.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        flag: {
          type: "string",
          enum: ["pick", "reject", "none"],
          description: "Flag to set ('none' clears pick/reject)",
        },
      },
      required: ["photo_ids", "flag"],
    },
  },
  {
    name: "get_spots",
    luaHandler: "HandlerSpots.getSpots",
    description:
      "List the spot removal (heal/clone) spots of a photo: normalized center, type, source, radius, plus the raw RetouchInfo entries.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "add_spots",
    luaHandler: "HandlerSpots.addSpots",
    description:
      "Add spot removal spots (heal or clone) to a photo. Coordinates are normalized 0..1 (x right, y down; get_photo_metadata dimensions help convert pixels). The source point defaults to an offset left of the spot; Lightroom recomputes optimal sources automatically in most cases. Existing spots are preserved verbatim and the write is verified by reading back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        spots: {
          type: "array",
          minItems: 1,
          maxItems: 50,
          description: "Spots to add",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              x: { type: "number", minimum: 0, maximum: 1, description: "Center X (normalized 0..1)" },
              y: { type: "number", minimum: 0, maximum: 1, description: "Center Y (normalized 0..1)" },
              radius: { type: "number", minimum: 0.001, maximum: 1, description: "Radius (normalized; default 0.05)" },
              type: { type: "string", enum: ["heal", "clone"], description: "Spot type (default 'heal')" },
              source_x: { type: "number", minimum: 0, maximum: 1, description: "Source X (optional; auto when omitted)" },
              source_y: { type: "number", minimum: 0, maximum: 1, description: "Source Y (optional; auto when omitted)" },
            },
            required: ["x", "y"],
          },
        },
      },
      required: ["photo_id", "spots"],
    },
  },
  {
    name: "clear_spots",
    luaHandler: "HandlerSpots.clearSpots",
    description: "Remove ALL spot removal spots from a photo (verified by reading back).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "add_local_adjustment",
    luaHandler: "HandlerLocalAdjustments.addLocalAdjustment",
    description:
      "Add a local adjustment with a linear (gradient) or radial mask. Linear geometry: center_x/center_y (0..1), angle in degrees (0 = effect grows upward, 90 = to the right), span (0.02-2, default 0.6). Radial geometry: center_x/center_y, radius_x/radius_y (or radius for both, 0.01-1, default 0.3), feather (0-100, default 50), invert (mask outside the ellipse). Sliders use global Develop units: exposure in EV (-5..5), the rest -100..100. Appends to existing masks without touching them; verifies by reading back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        name: {
          type: "string",
          minLength: 1,
          maxLength: 120,
          description:
            "Name shown for the mask in Lightroom's Masks panel. Defaults to 'Radial gradient N' / 'Linear gradient N'. Lightroom does NOT name a mask that arrives without one — it appears blank — so give it something meaningful ('People', 'Sky') when the photo will get more than one.",
        },
        mask_type: { type: "string", enum: ["linear", "radial"], description: "Mask shape" },
        center_x: { type: "number", minimum: 0, maximum: 1, description: "Center X (normalized 0..1, default 0.5)" },
        center_y: { type: "number", minimum: 0, maximum: 1, description: "Center Y (normalized 0..1, default 0.5)" },
        angle: { type: "number", minimum: -360, maximum: 360, description: "Linear: rotation degrees (0 = up)" },
        span: { type: "number", minimum: 0.02, maximum: 2, description: "Linear: total gradient length (default 0.6)" },
        radius: { type: "number", minimum: 0.01, maximum: 1, description: "Radial: radius (default 0.3)" },
        radius_x: { type: "number", minimum: 0.01, maximum: 1, description: "Radial: horizontal radius" },
        radius_y: { type: "number", minimum: 0.01, maximum: 1, description: "Radial: vertical radius" },
        feather: { type: "number", minimum: 0, maximum: 100, description: "Radial: edge feather (default 50)" },
        flow: { type: "number", minimum: 0, maximum: 1, description: "Mask opacity/flow (default 1)" },
        invert: { type: "boolean", description: "Radial: invert to affect outside the ellipse" },
        exposure: { type: "number", minimum: -5, maximum: 5, description: "Local exposure (EV)" },
        contrast: { type: "number", minimum: -100, maximum: 100, description: "Local contrast" },
        highlights: { type: "number", minimum: -100, maximum: 100, description: "Local highlights" },
        shadows: { type: "number", minimum: -100, maximum: 100, description: "Local shadows" },
        whites: { type: "number", minimum: -100, maximum: 100, description: "Local whites" },
        blacks: { type: "number", minimum: -100, maximum: 100, description: "Local blacks" },
        clarity: { type: "number", minimum: -100, maximum: 100, description: "Local clarity" },
        dehaze: { type: "number", minimum: -100, maximum: 100, description: "Local dehaze" },
        saturation: { type: "number", minimum: -100, maximum: 100, description: "Local saturation" },
        sharpness: { type: "number", minimum: -100, maximum: 100, description: "Local sharpness" },
        noise_reduction: { type: "number", minimum: -100, maximum: 100, description: "Local noise reduction" },
        temperature: { type: "number", minimum: -100, maximum: 100, description: "Local temperature" },
        tint: { type: "number", minimum: -100, maximum: 100, description: "Local tint" },
      },
      required: ["photo_id", "mask_type"],
      anyOf: [
        { required: ["exposure"] },
        { required: ["contrast"] },
        { required: ["highlights"] },
        { required: ["shadows"] },
        { required: ["whites"] },
        { required: ["blacks"] },
        { required: ["clarity"] },
        { required: ["dehaze"] },
        { required: ["saturation"] },
        { required: ["sharpness"] },
        { required: ["noise_reduction"] },
        { required: ["temperature"] },
        { required: ["tint"] },
      ],
    },
  },
  {
    name: "read_local_adjustments",
    luaHandler: "HandlerLocalAdjustments.readLocalAdjustments",
    description:
      "Read the local adjustment masks a photo currently has (MaskGroupBasedCorrections), including AI/subject/sky masks. Returns a compact summary by default — mask ids (which set_mask_adjustments needs), names, and only the sliders that were actually set. Pass fields='full' for the verbatim structure, e.g. to learn the exact format your Lightroom version stores.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        fields: {
          type: "string",
          enum: ["summary", "full"],
          description:
            "'summary' (default): ids, names and only the sliders actually set — compact enough for an edit/verify loop. 'full': the verbatim structure this Lightroom version stores, including digest/sync bookkeeping.",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "set_mask_adjustments",
    luaHandler: "HandlerLocalAdjustments.setMaskAdjustments",
    description:
      "Apply local sliders to a mask the photo ALREADY has (from list_masks or add_ai_mask) — companion to add_local_adjustment, which only appends new masks. Writes the same MaskGroupBasedCorrections structure directly (photo:applyDevelopSettings), not through the Develop module UI, so it also works for masks created by hand in Lightroom or when add_ai_mask's createNewMask path is unavailable. Geometry is left untouched — only the Local* slider values change. Verifies by reading the mask back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: {
          oneOf: [{ type: "string", minLength: 1 }, { type: "number" }],
          description: "Mask id to adjust (the MaskID inside a CorrectionMasks entry, as returned by list_masks or add_ai_mask)",
        },
        exposure: { type: "number", minimum: -5, maximum: 5, description: "Local exposure (EV)" },
        contrast: { type: "number", minimum: -100, maximum: 100, description: "Local contrast" },
        highlights: { type: "number", minimum: -100, maximum: 100, description: "Local highlights" },
        shadows: { type: "number", minimum: -100, maximum: 100, description: "Local shadows" },
        whites: { type: "number", minimum: -100, maximum: 100, description: "Local whites" },
        blacks: { type: "number", minimum: -100, maximum: 100, description: "Local blacks" },
        clarity: { type: "number", minimum: -100, maximum: 100, description: "Local clarity" },
        dehaze: { type: "number", minimum: -100, maximum: 100, description: "Local dehaze" },
        saturation: { type: "number", minimum: -100, maximum: 100, description: "Local saturation" },
        sharpness: { type: "number", minimum: -100, maximum: 100, description: "Local sharpness" },
        noise_reduction: { type: "number", minimum: -100, maximum: 100, description: "Local noise reduction" },
        temperature: { type: "number", minimum: -100, maximum: 100, description: "Local temperature" },
        tint: { type: "number", minimum: -100, maximum: 100, description: "Local tint" },
      },
      required: ["photo_id", "mask_id"],
      anyOf: [
        { required: ["exposure"] },
        { required: ["contrast"] },
        { required: ["highlights"] },
        { required: ["shadows"] },
        { required: ["whites"] },
        { required: ["blacks"] },
        { required: ["clarity"] },
        { required: ["dehaze"] },
        { required: ["saturation"] },
        { required: ["sharpness"] },
        { required: ["noise_reduction"] },
        { required: ["temperature"] },
        { required: ["tint"] },
      ],
    },
  },
  {
    name: "list_watermarks",
    luaHandler: "HandlerWatermark.listWatermarks",
    description:
      "List the watermark presets defined in Lightroom (from the Watermark Presets folder). Use these names with export_photos' watermark option.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
  },
  {
    name: "add_ai_mask",
    luaHandler: "HandlerAIMasks.addAIMask",
    description:
      "Create an AI selection mask on photos — the SDK-exposed equivalent of Select Subject / Select Sky / Select Background / Select Objects / Select People / Select Landscape — and optionally apply adjustment sliders to the new mask in one pass (e.g., subject mask with exposure +0.5 and clarity +10). Requires Lightroom Classic 12.4+ with AI masking; drives the Develop module UI, so Lightroom must be running. Per-photo errors are reported instead of failing the batch; verify visually with get_photo_preview or list_masks.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        selection_type: {
          type: "string",
          enum: ["subject", "sky", "background", "objects", "people", "landscape"],
          description:
            "AI selection target. Availability depends on the Lightroom version and photo content (people/landscape need LrC 12.4+).",
        },
        adjustments: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          description:
            "Sliders applied to the new mask (mask-context units). Local color adjustments are not offered here — use add_local_adjustment for those.",
          properties: {
            exposure: { type: "number", minimum: -5, maximum: 5, description: "Local exposure (EV)" },
            contrast: { type: "number", minimum: -100, maximum: 100, description: "Local contrast" },
            highlights: { type: "number", minimum: -100, maximum: 100, description: "Local highlights" },
            shadows: { type: "number", minimum: -100, maximum: 100, description: "Local shadows" },
            whites: { type: "number", minimum: -100, maximum: 100, description: "Local whites" },
            blacks: { type: "number", minimum: -100, maximum: 100, description: "Local blacks" },
            texture: { type: "number", minimum: -100, maximum: 100, description: "Local texture" },
            clarity: { type: "number", minimum: -100, maximum: 100, description: "Local clarity" },
            dehaze: { type: "number", minimum: -100, maximum: 100, description: "Local dehaze" },
            vibrance: { type: "number", minimum: -100, maximum: 100, description: "Local vibrance" },
            saturation: { type: "number", minimum: -100, maximum: 100, description: "Local saturation" },
            sharpness: { type: "number", minimum: 0, maximum: 150, description: "Local sharpening" },
          },
        },
        adjustment_preset: {
          type: "string",
          enum: ["darken_sky", "brighten_subject", "blur_background", "enhance_landscape"],
          description:
            "Named adjustment recipe instead of a manual adjustments object: darken_sky (exposure -0.7, highlights -30, saturation +15), brighten_subject (exposure +0.5, shadows +20, clarity +10), blur_background (sharpness -80, clarity -40), enhance_landscape (clarity +30, vibrance +25, dehaze +15).",
        },
      },
      required: ["photo_ids", "selection_type"],
      // adjustments and adjustment_preset are alternatives, not companions.
      not: { required: ["adjustments", "adjustment_preset"] },
    },
  },
  {
    name: "list_masks",
    luaHandler: "HandlerAIMasks.listMasks",
    description:
      "List the masks of a photo, read straight from the stored MaskGroupBasedCorrections — NOT through the Develop module. LrDevelopController.getAllMasks() only sees the photo loaded in Develop and misses corrections written by add_local_adjustment, which reported zero masks on photos that demonstrably had them. Returns every mask with the correction_id that owns it (for set_mask_adjustments and remove_mask), plus counts of masks and corrections. Does not switch modules or change the selection. Pair with read_local_adjustments to see the sliders set on each mask.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        fields: {
          type: "string",
          enum: ["summary", "full"],
          description:
            "'summary' (default): ids, names and only the sliders actually set — compact enough for an edit/verify loop. 'full': the verbatim structure this Lightroom version stores, including digest/sync bookkeeping.",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "remove_mask",
    luaHandler: "HandlerAIMasks.removeMask",
    description:
      "Remove one mask from a photo by its id (from list_masks / add_ai_mask's mask_id), or every mask at once with remove_all=true (requires confirm=true). Rewrites the stored MaskGroupBasedCorrections rather than calling the Develop module's deleteMask/resetMasking, which silently removed nothing for masks written by add_local_adjustment. A correction left with no masks is dropped, never kept empty. Verified by re-reading after forcing a recompute; an id that matches nothing returns success=false instead of a hollow success.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: {
          oneOf: [{ type: "string", minLength: 1 }, { type: "number" }],
          description: "Mask id to delete (as returned by add_ai_mask or list_masks)",
        },
        remove_all: {
          type: "boolean",
          description: "Strip every mask from the photo (Lightroom's resetMasking)",
        },
        confirm: {
          type: "boolean",
          description: "Required confirmation when remove_all=true",
        },
      },
      required: ["photo_id"],
      anyOf: [{ required: ["mask_id"] }, { required: ["remove_all"] }],
      // A specific mask and remove_all are alternatives.
      not: { required: ["mask_id", "remove_all"] },
    },
  },
  {
    name: "set_tone_curve",
    luaHandler: "HandlerDevelop.setToneCurve",
    description:
      "Set a point curve on a photo: the main luminance curve or an RGB channel curve. Points are [x, y] pairs in 0-255 space with strictly increasing x; missing (0,0)/(255,255) endpoints are added automatically, so a single interior point works. Presets 'linear', 'medium_contrast' and 'strong_contrast' approximate Lightroom's built-in curve dropdown entries. Verified by reading the curve back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        channel: {
          type: "string",
          enum: ["main", "red", "green", "blue"],
          description: "Curve channel (default 'main')",
        },
        points: {
          type: "array",
          minItems: 1,
          maxItems: 32,
          description:
            "Curve points as [x, y] pairs (0-255, x strictly increasing; endpoints are added automatically), e.g. [[64,56],[192,202]]",
          items: {
            type: "array",
            minItems: 2,
            maxItems: 2,
            items: { type: "number", minimum: 0, maximum: 255 },
          },
        },
        preset: {
          type: "string",
          enum: ["linear", "medium_contrast", "strong_contrast"],
          description: "Built-in curve shape (alternative to points)",
        },
      },
      required: ["photo_id"],
      anyOf: [{ required: ["points"] }, { required: ["preset"] }],
    },
  },
  {
    name: "get_tone_curve",
    luaHandler: "HandlerDevelop.getToneCurve",
    description:
      "Read a photo's tone curves: curve name plus the main/red/green/blue point curves as [x, y] point arrays (and their raw flat SDK arrays).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "apply_auto",
    luaHandler: "HandlerDevelop.applyAuto",
    description:
      "Apply Lightroom's official Auto commands — Auto Tone and/or Auto White Balance (the same analysis as the Auto button in Develop) — to photos. Drives the Develop module UI, so Lightroom must be running. Reports per photo which sliders actually changed (before/after diff); 'no slider changes' means the settings were already optimal or the file type does not support Auto.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        operations: {
          type: "array",
          minItems: 1,
          maxItems: 2,
          uniqueItems: true,
          items: { type: "string", enum: ["tone", "white_balance"] },
          description:
            "Which Auto commands to run. Defaults to both ('tone' = Auto Tone, 'white_balance' = Auto WB).",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_color_label",
    luaHandler: "HandlerOrganization.setColorLabel",
    description:
      "Set the color label on photos ('red', 'yellow', 'green', 'blue', 'purple', or 'none' to clear). Verified per photo by reading the label back (case-insensitive to tolerate custom label sets).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        label: {
          type: "string",
          enum: ["red", "yellow", "green", "blue", "purple", "none"],
          description: "Color label ('none' clears it)",
        },
      },
      required: ["photo_ids", "label"],
    },
  },
  {
    name: "create_virtual_copies",
    luaHandler: "HandlerOrganization.createVirtualCopies",
    description:
      "Create virtual copies of photos (same file, independent develop settings — e.g., one color edit and one B&W from the same original). Returns the ids of the new copies, stacked with their sources.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        count: {
          type: "integer",
          minimum: 1,
          maximum: 20,
          description: "Copies to create per photo (default 1)",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "create_smart_collection",
    luaHandler: "HandlerOrganization.createSmartCollection",
    description:
      "Create a smart collection that auto-populates from rules (the same criteria format Lightroom uses internally). Example: rules [{criteria:'keywords',operation:'all',value:'wedding'},{criteria:'rating',operation:'>=',value:'3'}] with combine 'intersect' (AND) keeps keyword AND rating matches; 'union' (OR) matches either. Common criteria: keywords, rating, filename, captureTime, copyName, cameraModel, lens, isoSpeedRating, hasAdjustments, text. Operations: all/any (containment), ==/</>/<=/>=, in (ranges, with value2), startsWith/endsWith.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", minLength: 1, maxLength: 255, description: "Collection name" },
        combine: {
          type: "string",
          enum: ["intersect", "union"],
          description: "How rules combine: 'intersect' (AND, default) or 'union' (OR)",
        },
        rules: {
          type: "array",
          minItems: 1,
          maxItems: 20,
          description: "Smart collection rules",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              criteria: { type: "string", minLength: 1, description: "Field to test (e.g. 'keywords', 'rating', 'captureTime')" },
              operation: { type: "string", minLength: 1, description: "Test (e.g. 'all', 'any', '==', '>=', 'in', 'startsWith')" },
              value: {
                oneOf: [{ type: "string" }, { type: "number" }],
                description: "Value to compare (string or number)",
              },
              value2: {
                oneOf: [{ type: "string" }, { type: "number" }],
                description: "Second value for 'in' (range) operations",
              },
            },
            required: ["criteria", "operation", "value"],
          },
        },
      },
      required: ["name", "rules"],
    },
  },
  {
    name: "get_photo_preview",
    luaHandler: "HandlerPreview.getPhotoPreview",
    description:
      "Render a JPEG preview of a photo (with its current edits) and attach it inline as an image to the tool response — the visual feedback loop for AI edits: edit a photo, call get_photo_preview, and look at the result before batching (the 'preview gate' pattern). The file is also written to the lightroom-mcp previews folder and its path returned for clients that cannot render images. Rendering is asynchronous; photos still building standard previews can take a while.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        size: {
          oneOf: [
            { type: "string", enum: ["small", "medium", "large"] },
            { type: "number", minimum: 32, maximum: 2048 },
          ],
          description:
            "Preview size: 'small' (240px), 'medium' (640px, default), 'large' (1024px), or an exact pixel size (32-2048)",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_develop_settings",
    luaHandler: "HandlerDevelop.getDevelopSettings",
    description:
      "Read a photo's develop settings (the stored values: exposure, contrast, WB, curves, ...). fields='basic' (default) returns the common develop sliders — small, LLM-friendly; fields='all' returns everything including mask structures. Read-only counterpart of set_develop_settings, and the 'before' half of before/after comparisons.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        fields: {
          type: "string",
          enum: ["basic", "all"],
          description: "'basic' (default): common sliders + curves; 'all': full stored settings",
        },
        max_depth: {
          type: "number",
          minimum: 1,
          maximum: 16,
          description:
            "How deep to serialise nested structures (default 6). Raise it to read a field that would otherwise appear in skipped_fields — Lightroom's FilterList (Distraction Removal: dust and people) nests one level past the default and needs 8.",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "reset_develop",
    luaHandler: "HandlerDevelop.resetDevelop",
    description:
      "Reset a photo's develop settings: scope='all' (like the Reset button), scope='tools' (reset crop/transforms/spot_removal/redeye/healing/masking/gradient/circular_gradient/brushing individually), or scope='params' (reset specific parameters by name). Drives the Develop module; reports a before/after slider diff so you can see what actually changed.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        scope: {
          type: "string",
          enum: ["all", "tools", "params"],
          description: "What to reset: everything, specific tools, or specific parameters (default 'all')",
        },
        tools: {
          type: "array",
          minItems: 1,
          uniqueItems: true,
          items: {
            type: "string",
            enum: [
              "crop",
              "transforms",
              "spot_removal",
              "redeye",
              "healing",
              "masking",
              "gradient",
              "circular_gradient",
              "brushing",
            ],
          },
          description: "Tools to reset when scope='tools' ('masking' removes ALL masks)",
        },
        params: {
          type: "array",
          minItems: 1,
          maxItems: 100,
          items: { type: "string", enum: [...DEVELOP_SETTING_KEYS] },
          description: "Parameter names to reset when scope='params' (same names set_develop_settings accepts)",
        },
      },
      required: ["photo_id"],
      // tools/params arrays are required by their scope.
      allOf: [
        {
          if: { properties: { scope: { const: "tools" } }, required: ["scope"] },
          then: { required: ["tools"] },
        },
        {
          if: { properties: { scope: { const: "params" } }, required: ["scope"] },
          then: { required: ["params"] },
        },
      ],
    },
  },
  {
    name: "set_process_version",
    luaHandler: "HandlerDevelop.setProcessVersion",
    description:
      "Switch a photo's process version (the calibration engine): 'Version 3' = Process 2012, higher numbers are newer engines (LrC 13+ = 'Version 6'). Modernizing an old photo unlocks AI masking and modern sliders at the cost of a rendering change; going back reverts the look. Reports the version before/after as Lightroom reports it.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        version: {
          type: "string",
          enum: ["Version 1", "Version 2", "Version 3", "Version 4", "Version 5", "Version 6"],
          description: "Process version to switch to",
        },
      },
      required: ["photo_id", "version"],
    },
  },
  {
    name: "create_snapshot",
    luaHandler: "HandlerDevelop.createSnapshot",
    description:
      "Create a named develop snapshot of a photo (an entry in Lightroom's Snapshots panel) — an undo checkpoint before risky edits, e.g., 'before AI denoise' or 'client-approved color'. Create-only: the SDK cannot list or switch snapshots back, so verify in the Snapshots panel.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        name: { type: "string", minLength: 1, maxLength: 255, description: "Snapshot name" },
      },
      required: ["photo_id", "name"],
    },
  },
  {
    name: "select_photos",
    luaHandler: "HandlerSelection.selectPhotos",
    description:
      "Set which photos are selected in Lightroom's UI — the selection drives every LrSelection-based command and stages the photo the Develop module loads. Pass photo_ids to replace the selection, or mode: 'all', 'none', 'inverse', 'deselect_others'. Photos outside the current view source are ignored by Lightroom; the response reports how many actually got selected.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths to select (first becomes active)"),
        mode: {
          type: "string",
          enum: ["all", "none", "inverse", "deselect_others"],
          description: "UI selection mode instead of explicit ids",
        },
      },
      anyOf: [{ required: ["photo_ids"] }, { required: ["mode"] }],
      // Explicit ids and a UI mode are alternatives.
      not: { required: ["photo_ids", "mode"] },
    },
  },
  {
    name: "navigate_photo",
    luaHandler: "HandlerSelection.navigatePhoto",
    description:
      "Move to the next or previous photo in the filmstrip (like the arrow keys); the loupe view follows. Returns the now-active photo so you can chain get_photo_preview or develop tools without an extra round-trip.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        direction: {
          type: "string",
          enum: ["next", "previous"],
          description: "Direction to move (default 'next')",
        },
      },
    },
  },
  {
    name: "get_photo_status",
    luaHandler: "HandlerOrganization.getPhotoStatus",
    description:
      "Read the review status of photos in one call: flag (pick/reject/none), star rating and color label per photo. The read-only counterpart of set_flags / set_rating / set_color_label — ideal for triage flows ('show me everything unflagged', then batch-flag).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "batch_metadata",
    luaHandler: "HandlerOrganization.batchMetadata",
    description:
      "Set IPTC text metadata (title, caption, headline, location, city, stateProvince, country, isoCountryCode, creator, copyright) on many photos at once; a null value clears the field. Verified per photo by reading every field back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        metadata: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          description: "Fields to write (null clears a field)",
          properties: {
            title: { type: "string", description: "IPTC title" },
            caption: { type: "string", description: "IPTC caption / description" },
            headline: { type: "string", description: "IPTC headline" },
            location: { type: "string", description: "IPTC location (sublocation)" },
            city: { type: "string", description: "IPTC city" },
            stateProvince: { type: "string", description: "IPTC state/province" },
            country: { type: "string", description: "IPTC country (readable name)" },
            isoCountryCode: { type: "string", description: "IPTC country code (e.g. 'AR')" },
            creator: { type: "string", description: "IPTC creator / photographer" },
            copyright: { type: "string", description: "IPTC copyright notice" },
          },
        },
      },
      required: ["photo_ids", "metadata"],
    },
  },
  {
    name: "rotate_photo",
    luaHandler: "HandlerOrganization.rotatePhoto",
    description:
      "Rotate photos 90 degrees left or right (batch). Applies to the stored orientation, so previews and exports pick it up.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        direction: {
          type: "string",
          enum: ["left", "right"],
          description: "Rotation direction (default 'right' — clockwise)",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "remove_from_catalog",
    luaHandler: "HandlerOrganization.removeFromCatalog",
    description:
      "Remove photos from the Lightroom catalog. DESTRUCTIVE (undo is limited) but files on disk are NOT deleted — only the catalog entries. Requires confirm=true; the handler verifies the ids no longer resolve afterwards.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        confirm: {
          type: "boolean",
          enum: [true],
          description: "Must be true — guards against accidental catalog removal",
        },
      },
      required: ["photo_ids", "confirm"],
    },
  },
  {
    name: "list_folders",
    luaHandler: "HandlerCatalog.listFolders",
    description:
      "List the catalog's folder tree (the Folders panel): each root folder with its name, path and photo counts; set include_subfolders for the full tree. Folders are identified by path (they have no numeric id) — use the paths with search_photos rules or when importing.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max folders to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of folders to skip (default 0)", minimum: 0 },

        include_subfolders: {
          type: "boolean",
          description: "Also list subfolders recursively (default false: only root folders)",
        },
      },
    },
  },
  {
    name: "list_keywords",
    luaHandler: "HandlerCatalog.listKeywords",
    description:
      "List the catalog's top-level keyword tree entries with their photo counts — the vocabulary set_keywords can draw from (use set_keywords with add_keywords to attach them to photos).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max keywords to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of keywords to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "manage_view_filter",
    luaHandler: "HandlerCatalog.manageViewFilter",
    description:
      "Read, set or clear Lightroom's Library view filter (the filter bar above the grid). Set uses the same rule format as create_smart_collection (e.g., rating >= 3 AND keyword 'wedding'). The filter changes what the grid shows — combine with get_selected_photos / select_photos mode 'all' to operate on the filtered set.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        action: {
          type: "string",
          enum: ["get", "set", "clear"],
          description: "Read the current filter, apply rules, or clear it (default 'get')",
        },
        combine: {
          type: "string",
          enum: ["intersect", "union"],
          description: "How rules combine: 'intersect' (AND, default) or 'union' (OR)",
        },
        rules: searchRulesArray("Filter rules (required when action='set')"),
      },
      // rules are only mandatory for the 'set' action.
      allOf: [
        {
          if: { properties: { action: { const: "set" } }, required: ["action"] },
          then: { required: ["rules"] },
        },
      ],
    },
  },
  {
    name: "get_collection_photos",
    luaHandler: "HandlerCollections.getCollectionPhotos",
    description:
      "List the photos inside a collection (by name, including inside collection sets), paginated, with id/path/filename/rating/label per photo — the bridge from a collection to the tools that work on photo ids.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: { type: "string", minLength: 1, description: "Collection name (as shown by list_collections)" },
        limit: { type: "number", description: "Max photos to return (default 100; 0 returns only the total)", minimum: 0, maximum: 1000 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
      required: ["collection_name"],
    },
  },
  {
    name: "create_collection_set",
    luaHandler: "HandlerCollections.createCollectionSet",
    description:
      "Create a collection set (a folder that groups collections in the Catalog panel). Optional parent_set_name nests it inside another set.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", minLength: 1, maxLength: 255, description: "Set name" },
        parent_set_name: { type: "string", minLength: 1, description: "Parent set to nest inside (optional)" },
      },
      required: ["name"],
    },
  },
  {
    name: "add_range_mask",
    luaHandler: "HandlerAIMasks.addRangeMask",
    description:
      "Create a range mask (luminance / color / depth) on photos and optionally apply adjustment sliders to it — e.g., a luminance mask with exposure -0.5 darkens the bright tones. HONEST LIMITATION: the SDK cannot set the range bounds or sample points, so the mask starts covering the full range; refine the bounds in Lightroom's UI, or drive the look through the sliders. 'depth' needs photos with depth data (e.g., iPhone portraits).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        range_type: {
          type: "string",
          enum: ["luminance", "color", "depth"],
          description: "What the mask selects by (default 'luminance')",
        },
        adjustments: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          description: "Sliders applied to the new mask (mask-context units)",
          properties: {
            exposure: { type: "number", minimum: -5, maximum: 5, description: "Local exposure (EV)" },
            contrast: { type: "number", minimum: -100, maximum: 100, description: "Local contrast" },
            highlights: { type: "number", minimum: -100, maximum: 100, description: "Local highlights" },
            shadows: { type: "number", minimum: -100, maximum: 100, description: "Local shadows" },
            whites: { type: "number", minimum: -100, maximum: 100, description: "Local whites" },
            blacks: { type: "number", minimum: -100, maximum: 100, description: "Local blacks" },
            texture: { type: "number", minimum: -100, maximum: 100, description: "Local texture" },
            clarity: { type: "number", minimum: -100, maximum: 100, description: "Local clarity" },
            dehaze: { type: "number", minimum: -100, maximum: 100, description: "Local dehaze" },
            vibrance: { type: "number", minimum: -100, maximum: 100, description: "Local vibrance" },
            saturation: { type: "number", minimum: -100, maximum: 100, description: "Local saturation" },
            sharpness: { type: "number", minimum: 0, maximum: 150, description: "Local sharpening" },
          },
        },
        adjustment_preset: {
          type: "string",
          enum: ["darken_sky", "brighten_subject", "blur_background", "enhance_landscape"],
          description: "Named adjustment recipe instead of a manual adjustments object",
        },
      },
      required: ["photo_ids"],
      not: { required: ["adjustments", "adjustment_preset"] },
    },
  },
  {
    name: "toggle_mask_overlay",
    luaHandler: "HandlerAIMasks.toggleMaskOverlay",
    description:
      "Toggle the red mask overlay in Lightroom's Develop view for a photo — the fastest way for a human to eyeball what add_ai_mask / add_local_adjustment actually selected. Also useful after AI masking to review the selection edges before batching.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
];
