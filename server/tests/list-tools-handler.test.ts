import { describe, it, expect } from '@jest/globals';
import { Ajv } from 'ajv';
import fs from 'node:fs';
import path from 'node:path';
import { TOOL_DEFINITIONS, listToolsHandler } from '../src/list-tools-handler.js';
import {
  DESTRUCTIVE_TOOL_NAMES,
  DEVELOP_SETTING_KEYS,
  MUTATING_TOOL_NAMES,
  POINT_CURVE_SETTING_KEYS,
  READ_ONLY_TOOL_NAMES,
  TOOL_CONTRACTS,
  TOOLS_WITH_OUTPUT_SCHEMA,
  annotationsFor,
  outputSchemaFor,
} from '../src/tool-contracts.js';

const EXPECTED_TOOL_NAMES = [
  'search_photos',
  'get_selected_photos',
  'get_photo_metadata',
  'list_collections',
  'create_collection',
  'add_to_collection',
  'set_keywords',
  'set_rating',
  'import_photos',
  'export_photos',
  'list_develop_presets',
  'get_develop_preset',
  'compare_develop_presets',
  'create_develop_preset',
  'export_develop_preset',
  'apply_develop_preset',
  'copy_develop_settings',
  'set_develop_settings',
  'ai_denoise',
  'set_noise_reduction',
  'set_white_balance',
  'set_flags',
  'get_spots',
  'add_spots',
  'clear_spots',
  'add_local_adjustment',
  'read_local_adjustments',
  'list_watermarks',
  'add_ai_mask',
  'list_masks',
  'remove_mask',
  'set_tone_curve',
  'get_tone_curve',
  'apply_auto',
  'set_color_label',
  'create_virtual_copies',
  'create_smart_collection',
  'get_photo_preview',
  'get_develop_settings',
  'reset_develop',
  'set_process_version',
  'create_snapshot',
  'select_photos',
  'navigate_photo',
  'get_photo_status',
  'batch_metadata',
  'rotate_photo',
  'remove_from_catalog',
  'list_folders',
  'list_keywords',
  'manage_view_filter',
  'get_collection_photos',
  'create_collection_set',
  'add_range_mask',
  'toggle_mask_overlay',
] as const;

describe('TOOL_DEFINITIONS', () => {
  it('contains exactly 56 tools', () => {
    expect(TOOL_DEFINITIONS).toHaveLength(56);
  });

  it('tool names are unique', () => {
    const names = TOOL_DEFINITIONS.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });

  it.each(EXPECTED_TOOL_NAMES)('"%s" is present', (name) => {
    expect(TOOL_DEFINITIONS.some((t) => t.name === name)).toBe(true);
  });

  it('every tool has name, description, and inputSchema', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(typeof tool.name).toBe('string');
      expect(typeof tool.description).toBe('string');
      expect(tool.inputSchema).toBeDefined();
      expect(tool.inputSchema.type).toBe('object');
    }
  });

  it('is generated from tool contracts, annotations and output schema included', () => {
    expect(TOOL_DEFINITIONS).toEqual(
      TOOL_CONTRACTS.map(({ name, description, inputSchema, annotations, outputSchema }) => {
        const expected: Record<string, unknown> = {
          name,
          description,
          inputSchema,
          annotations: annotations ?? annotationsFor(name),
        };
        const resolved = outputSchema ?? outputSchemaFor(name);
        if (resolved) expected.outputSchema = resolved;
        return expected;
      }),
    );
  });

  it('rejects unknown top-level arguments for every tool', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.inputSchema.additionalProperties).toBe(false);
    }
  });
});

describe('listToolsHandler', () => {
  it('returns { tools: TOOL_DEFINITIONS }', () => {
    const result = listToolsHandler();
    expect(result.tools).toEqual(TOOL_DEFINITIONS);
  });
});

describe('LIGHTROOM_MCP_TOOLS server-side tool filtering', () => {
  it('exposes the full set when unset, empty or "all"', () => {
    const warnings: string[] = [];
    expect(listToolsHandler(undefined, (m) => warnings.push(m)).tools).toEqual(TOOL_DEFINITIONS);
    expect(listToolsHandler('', (m) => warnings.push(m)).tools).toEqual(TOOL_DEFINITIONS);
    expect(listToolsHandler('all', (m) => warnings.push(m)).tools).toEqual(TOOL_DEFINITIONS);
    expect(warnings).toEqual([]);
  });

  it('exposes only the requested tools', () => {
    const result = listToolsHandler('search_photos, get_photo_preview');
    expect(result.tools.map((t) => t.name)).toEqual(['search_photos', 'get_photo_preview']);
  });

  it('warns about unknown names and keeps the valid ones', () => {
    const warnings: string[] = [];
    const result = listToolsHandler('search_photos, not_a_tool', (m) => warnings.push(m));
    expect(result.tools.map((t) => t.name)).toEqual(['search_photos']);
    expect(warnings.join('\n')).toMatch(/not_a_tool/);
  });

  it('falls back to the full set when nothing matches', () => {
    const warnings: string[] = [];
    const result = listToolsHandler('bogus_one, bogus_two', (m) => warnings.push(m));
    expect(result.tools).toEqual(TOOL_DEFINITIONS);
    expect(warnings.join('\n')).toMatch(/matched no tools/);
  });
});

describe('tool required fields', () => {
  function toolRequired(name: string): string[] | undefined {
    return TOOL_DEFINITIONS.find((t) => t.name === name)?.inputSchema.required as string[] | undefined;
  }

  it.each<[string, string[]]>([
    ['get_photo_metadata', ['photo_id']],
    ['create_collection', ['name']],
    ['add_to_collection', ['collection_name', 'photo_ids']],
    ['set_keywords', ['photo_ids']],
    ['set_rating', ['photo_ids', 'rating']],
    ['import_photos', ['source_path']],
    ['export_photos', ['photo_ids', 'destination']],
    ['compare_develop_presets', ['base', 'candidate']],
    ['create_develop_preset', ['photo_id', 'preset_name', 'settings']],
    ['export_develop_preset', ['destination_dir']],
    ['apply_develop_preset', ['photo_ids']],
    ['copy_develop_settings', ['source_id', 'target_ids']],
    ['set_develop_settings', ['photo_id', 'settings']],
    ['ai_denoise', ['photo_id']],
    ['set_flags', ['photo_ids', 'flag']],
    ['get_spots', ['photo_id']],
    ['add_spots', ['photo_id', 'spots']],
    ['clear_spots', ['photo_id']],
    ['add_local_adjustment', ['photo_id', 'mask_type']],
    ['read_local_adjustments', ['photo_id']],
  ])('%s requires %j', (name, required) => {
    expect(toolRequired(name)).toEqual(required);
  });

  it.each([
    'search_photos',
    'get_selected_photos',
    'list_collections',
    'list_develop_presets',
    'get_develop_preset',
    'list_watermarks',
  ])(
    '%s has no required fields',
    (name) => {
      expect(toolRequired(name)).toBeUndefined();
    },
  );
});

describe('set_keywords schema', () => {
  it('caps add/remove keyword arrays', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_keywords');
    const properties = tool?.inputSchema.properties as Record<string, { maxItems?: number }>;

    expect(properties.add_keywords.maxItems).toBe(1000);
    expect(properties.remove_keywords.maxItems).toBe(1000);
  });
});

describe('photo array schema', () => {
  it.each([
    ['add_to_collection', 'photo_ids'],
    ['set_keywords', 'photo_ids'],
    ['set_rating', 'photo_ids'],
    ['export_photos', 'photo_ids'],
    ['apply_develop_preset', 'photo_ids'],
    ['copy_develop_settings', 'target_ids'],
  ])('%s.%s requires 1-1000 ids', (toolName, propertyName) => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === toolName);
    const properties = tool?.inputSchema.properties as Record<
      string,
      { minItems?: number; maxItems?: number }
    >;

    expect(properties[propertyName].minItems).toBe(1);
    expect(properties[propertyName].maxItems).toBe(1000);
  });
});

describe('develop setting schema', () => {
  function parseLuaDevelopSettingKeys(): string[] {
    const pluginPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'HandlerDevelop.lua');
    const source = fs.readFileSync(pluginPath, 'utf8');
    const match = source.match(/local ALLOWED_DEVELOP_SETTING_KEYS = \{([\s\S]*?)\n\}/);
    if (!match) {
      throw new Error('ALLOWED_DEVELOP_SETTING_KEYS table not found');
    }

    return [...match[1].matchAll(/^\s*"([^"]+)",/gm)].map((entry) => entry[1]);
  }

  it('restricts copy whitelist to allowlisted SDK keys', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'copy_develop_settings');
    const properties = tool?.inputSchema.properties as Record<
      string,
      { items?: { enum?: readonly string[] }; minItems?: number }
    >;

    expect(properties.settings.minItems).toBe(1);
    expect(properties.settings.items?.enum).toEqual(DEVELOP_SETTING_KEYS);
  });

  it('restricts direct settings object to allowlisted SDK keys', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_develop_settings');
    const properties = tool?.inputSchema.properties as Record<
      string,
      { additionalProperties?: boolean; minProperties?: number; properties?: Record<string, unknown> }
    >;

    expect(properties.settings.additionalProperties).toBe(false);
    expect(properties.settings.minProperties).toBe(1);
    expect(Object.keys(properties.settings.properties ?? {})).toEqual(DEVELOP_SETTING_KEYS);
  });

  it('uses numeric arrays for point curves and scalar values for ordinary settings', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_develop_settings');
    const properties = tool?.inputSchema.properties as Record<
      string,
      {
        properties?: Record<
          string,
          {
            type?: string;
            minItems?: number;
            maxItems?: number;
            items?: { type?: string; minimum?: number; maximum?: number };
            oneOf?: unknown[];
          }
        >;
      }
    >;
    const settings = properties.settings.properties ?? {};

    for (const key of POINT_CURVE_SETTING_KEYS) {
      expect(settings[key]).toMatchObject({
        type: 'array',
        minItems: 4,
        maxItems: 64,
        items: { type: 'integer', minimum: 0, maximum: 255 },
      });
    }
    expect(settings.Exposure2012.oneOf).toBeDefined();
    expect(settings.Exposure2012.type).toBeUndefined();
  });

  it('rejects malformed point curve payloads against the published schema', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_develop_settings');
    const validate = new Ajv({ strict: false }).compile(tool!.inputSchema);

    const check = (curve: unknown[]) =>
      validate({ photo_id: '1', settings: { ToneCurvePV2012: curve } });

    expect(check([0, 0, 64, 48, 192, 210, 255, 255])).toBe(true);
    expect(check([0, 0, 255, 255])).toBe(true);
    expect(check([0, 0, 128, 120, 255])).toBe(false);
    expect(check([0, 0, 128.5, 120, 255, 255])).toBe(false);
    expect(check([0, 0, 128, 300, 255, 255])).toBe(false);
    expect(check([0, 0, 128, -1, 255, 255])).toBe(false);
    expect(check([0, 0])).toBe(false);
    expect(check(Array.from({ length: 66 }, () => 0))).toBe(false);
  });

  it('accepts the numeric photo ids the catalog hands back', () => {
    const ajv = new Ajv({ strict: false });
    const validateFor = (name: string) =>
      ajv.compile(TOOL_DEFINITIONS.find((t) => t.name === name)!.inputSchema);

    expect(validateFor('get_photo_metadata')({ photo_id: 914 })).toBe(true);
    expect(validateFor('get_photo_metadata')({ photo_id: '914' })).toBe(true);
    expect(validateFor('set_rating')({ photo_ids: [914, '/a.jpg'], rating: 3 })).toBe(true);
    expect(validateFor('set_develop_settings')({
      photo_id: 914,
      settings: { Exposure2012: 0.5 },
    })).toBe(true);
    expect(validateFor('copy_develop_settings')({ source_id: 914, target_ids: [915] })).toBe(true);

    expect(validateFor('get_photo_metadata')({ photo_id: '' })).toBe(false);
    expect(validateFor('set_rating')({ photo_ids: [], rating: 3 })).toBe(false);
    expect(validateFor('set_rating')({ photo_ids: [true], rating: 3 })).toBe(false);
  });

  it('requires explicit allowlisted keys when creating a preset checkpoint', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'create_develop_preset');
    const properties = tool?.inputSchema.properties as Record<
      string,
      { items?: { enum?: readonly string[] }; minItems?: number; uniqueItems?: boolean }
    >;

    expect(properties.settings.items?.enum).toEqual(DEVELOP_SETTING_KEYS);
    expect(properties.settings.minItems).toBe(1);
    expect(properties.settings.uniqueItems).toBe(true);
  });

  it('matches Lua develop setting allowlist', () => {
    expect(parseLuaDevelopSettingKeys()).toEqual(DEVELOP_SETTING_KEYS);
  });
});

/**
 * Lua DISPATCH entries that exist for e2e setup only: reachable from the raw TCP
 * probe, deliberately absent from TOOL_CONTRACTS so no MCP client can call them.
 */
const TEST_ONLY_ACTIONS: Record<string, string> = {
  set_selection: 'HandlerSelection.setSelection',
};

describe('tool annotations', () => {
  const byName = new Map(TOOL_DEFINITIONS.map((tool) => [tool.name, tool]));

  /**
   * The drift guard. A new tool that nobody classified lands in none of the
   * three lists and fails here, instead of shipping with silent defaults that
   * would tell a client it is safe to call.
   */
  it('classifies every tool exactly once', () => {
    const classified = [
      ...READ_ONLY_TOOL_NAMES,
      ...DESTRUCTIVE_TOOL_NAMES,
      ...MUTATING_TOOL_NAMES,
    ];
    expect(new Set(classified).size).toBe(classified.length);
    expect([...classified].sort()).toEqual(TOOL_CONTRACTS.map((c) => c.name).sort());
  });

  it('exposes annotations on every published tool', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.annotations).toBeDefined();
      expect(tool.annotations?.openWorldHint).toBe(false);
    }
  });

  it('marks read-only tools as read-only', () => {
    for (const name of READ_ONLY_TOOL_NAMES) {
      expect(byName.get(name)?.annotations?.readOnlyHint).toBe(true);
    }
  });

  it('marks the tools that can destroy work the user already has', () => {
    for (const name of DESTRUCTIVE_TOOL_NAMES) {
      const annotations = byName.get(name)?.annotations;
      expect(annotations?.readOnlyHint).toBe(false);
      expect(annotations?.destructiveHint).toBe(true);
    }
    // Writing is not the same as destroying: adding a mask or a rating must
    // not carry the same warning as wiping every adjustment.
    for (const name of MUTATING_TOOL_NAMES) {
      const annotations = byName.get(name)?.annotations;
      expect(annotations?.readOnlyHint).toBe(false);
      expect(annotations?.destructiveHint).toBe(false);
    }
  });

  it('does not claim idempotence for tools that accumulate', () => {
    for (const name of ['add_ai_mask', 'add_spots', 'create_snapshot', 'create_virtual_copies',
      'rotate_photo', 'toggle_mask_overlay', 'navigate_photo', 'export_photos']) {
      expect(byName.get(name)?.annotations?.idempotentHint).toBe(false);
    }
    for (const name of ['set_rating', 'set_develop_settings', 'reset_develop']) {
      expect(byName.get(name)?.annotations?.idempotentHint).toBe(true);
    }
  });
});

describe('tool output schemas', () => {
  const byName = new Map(TOOL_DEFINITIONS.map((tool) => [tool.name, tool]));

  it('declares an outputSchema only where one is defined', () => {
    for (const tool of TOOL_DEFINITIONS) {
      const declared = tool.outputSchema !== undefined;
      expect(declared).toBe(TOOLS_WITH_OUTPUT_SCHEMA.includes(tool.name));
    }
  });

  it('every declared schema is a valid JSON Schema object', () => {
    const ajv = new Ajv({ strict: false });
    for (const name of TOOLS_WITH_OUTPUT_SCHEMA) {
      const schema = byName.get(name)?.outputSchema;
      expect(schema?.type).toBe('object');
      expect(() => ajv.compile(schema!)).not.toThrow();
    }
  });

  /**
   * The guard that makes an outputSchema worth declaring: these are responses
   * captured from a real Lightroom, not invented shapes. A schema that drifts
   * away from what the Lua side actually returns is worse than no schema,
   * because a validating client will reject a perfectly good response.
   */
  const REAL_RESPONSES: Record<string, unknown> = {
    get_photo_preview: {
      photo: { path: 'D:\RAW\Arocena\DSC02990.ARW', filename: 'DSC02990.ARW', id: 742399, height: 4000, width: 6000 },
      image_attached_by_server: true,
      rendered_height: 320,
      rendered_width: 480,
      file_path: 'C:\Users\pablo\.config\lightroom-mcp\previews\preview_p742399_320px_1789652025.jpg',
      message: 'Preview written to ... (51524 bytes, 320px)',
      renditions_received: 1,
      success: true,
      size_usable: true,
      mime_type: 'image/jpeg',
      size_bytes: 51524,
      size_px: 320,
    },
    get_selected_photos: {
      photos: [
        { path: 'D:\RAW\Arocena\DSC02990.ARW', filename: 'DSC02990.ARW', id: 742399, dateTimeOriginal: '20/10/2024 16:18:50.000' },
      ],
      count: 1,
      has_more: false,
    },
    get_develop_settings: {
      photo: { id: 742399, path: 'D:\RAW\Arocena\DSC02990.ARW', filename: 'DSC02990.ARW' },
      fields: 'basic',
      success: true,
      setting_count: 31,
      message: 'Read 31 develop setting(s)',
      settings: { Contrast2012: 0, Exposure2012: 0, ProcessVersion: '15.4', ToneCurvePV2012: [0, 0, 255, 255] },
    },
    list_masks: {
      photo: { id: 742399, path: 'D:\RAW\Arocena\DSC02990.ARW' },
      fields: 'summary',
      success: true,
      note: 'Summary view: ...',
      masks: [{ ID: 'FE7E0779', Name: 'Máscara 1', Hidden: false, Tools: [{ Type: 'aiSelection', Subtype: 'skin' }] }],
      count: 1,
      message: 'Photo has 1 mask(s)',
    },
    read_local_adjustments: {
      fields: 'summary',
      success: true,
      corrections: [
        {
          correction_id: '1F01737B-6F77-4211-9E7A-52A03F79A778',
          name: 'Máscara 2',
          active: true,
          amount: 1,
          adjustments: { LocalExposure2012: 0.5, LocalShadows2012: 0.2 },
          masks: [{ mask_id: 'B31B480B', name: 'Persona 1', instances: 2 }],
        },
      ],
      note: 'Summary view: ...',
      count: 1,
      photo_id: 742399,
    },
  };

  it.each(TOOLS_WITH_OUTPUT_SCHEMA)('%s accepts a real captured response', (name) => {
    const captured = REAL_RESPONSES[name];
    expect(captured).toBeDefined();
    const validate = new Ajv({ strict: false }).compile(byName.get(name)!.outputSchema!);
    const ok = validate(captured);
    if (!ok) throw new Error(`${name}: ${JSON.stringify(validate.errors)}`);
    expect(ok).toBe(true);
  });

  it('tolerates fields the Lua side adds later', () => {
    const validate = new Ajv({ strict: false }).compile(
      byName.get('get_photo_preview')!.outputSchema!,
    );
    expect(
      validate({ ...(REAL_RESPONSES.get_photo_preview as object), some_future_diagnostic: 'x' }),
    ).toBe(true);
  });
});

describe('tool contracts vs Lua dispatch', () => {
  function parseLuaDispatch(): Record<string, string> {
    const pluginPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'PluginInfoProvider.lua');
    const source = fs.readFileSync(pluginPath, 'utf8');
    const match = source.match(/local DISPATCH = \{([\s\S]*?)\n\}/);
    if (!match) {
      throw new Error('DISPATCH table not found');
    }

    return Object.fromEntries(
      [...match[1].matchAll(/^\s*([a-z_]+)\s*=\s*([A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*)\s*,/gm)]
        .map((entry) => [entry[1], entry[2]]),
    );
  }

  it('matches manifest names and handler targets', () => {
    const dispatch = parseLuaDispatch();
    const manifest = Object.fromEntries(
      TOOL_CONTRACTS.map((contract) => [contract.name, contract.luaHandler]),
    );

    for (const action of Object.keys(TEST_ONLY_ACTIONS)) {
      delete dispatch[action];
    }

    expect(dispatch).toEqual(manifest);
  });

  it('keeps test-only actions off the MCP tool surface', () => {
    const dispatch = parseLuaDispatch();

    for (const [action, luaHandler] of Object.entries(TEST_ONLY_ACTIONS)) {
      expect(dispatch[action]).toBe(luaHandler);
      expect(TOOL_CONTRACTS.some((contract) => contract.name === action)).toBe(false);
    }
  });

  /**
   * The Desktop Extension bundle keeps its own copy of the tool list. Nothing
   * validated it, and it had already drifted: the bundle advertised 55 tools
   * while the server served 56, so set_mask_adjustments was invisible to every
   * .mcpb user. Same bidirectional check as the Lua dispatch above.
   */
  it('matches the mcpb bundle manifest', () => {
    const manifestPath = path.resolve(process.cwd(), '..', 'mcpb', 'manifest.json');
    const bundle = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as {
      tools: { name: string }[];
    };

    const bundled = bundle.tools.map((tool) => tool.name).sort();
    const served = TOOL_CONTRACTS.map((contract) => contract.name).sort();

    expect(bundled).toEqual(served);
  });
});
