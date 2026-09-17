import { describe, it, expect, jest } from '@jest/globals';
import { validateToolArgs } from '../src/validate-args.js';
import { createCallToolHandler } from '../src/tool-handler.js';

describe('validateToolArgs', () => {
  it('accepts arguments that satisfy the published schema', () => {
    expect(validateToolArgs('get_photo_metadata', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_photo_metadata', { photo_id: '/a.jpg' })).toBeNull();
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: 3 })).toBeNull();
    expect(validateToolArgs('search_photos', {})).toBeNull();
  });

  it('rejects a photo id that is neither a string nor a number', () => {
    const msg = validateToolArgs('get_photo_metadata', { photo_id: { nested: true } });

    expect(msg).toContain('Invalid arguments for get_photo_metadata');
    expect(msg).toContain('photo_id');
  });

  it('names a misspelled property instead of silently ignoring it', () => {
    const msg = validateToolArgs('search_photos', { not_a_real_filter: 1 });

    expect(msg).toContain('unknown property "not_a_real_filter"');
  });

  it('enforces documented ranges and types', () => {
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: 99 })).toContain('rating');
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: '3' })).toContain('rating');
    expect(validateToolArgs('search_photos', { limit: 'many' })).toContain('limit');
    expect(validateToolArgs('export_photos', {
      photo_ids: [914],
      destination: '/tmp',
      on_existing: 'ask',
    })).toContain('on_existing');
  });

  it('reports a missing required field', () => {
    const msg = validateToolArgs('set_rating', { photo_ids: [914] });

    expect(msg).toContain("required property 'rating'");
  });

  it('treats missing arguments as an empty object', () => {
    expect(validateToolArgs('search_photos', undefined)).toBeNull();
    expect(validateToolArgs('set_rating', undefined)).toContain('required property');
  });

  it('reports a violation that has no field path', () => {
    const msg = validateToolArgs('search_photos', 'not-an-object');

    expect(msg).toContain('Invalid arguments for search_photos');
    expect(msg).toContain('object');
  });

  it('leaves unknown tool names to the dispatcher', () => {
    expect(validateToolArgs('no_such_tool', { anything: true })).toBeNull();
  });
});

describe('validateToolArgs — new AI/adjustment tools', () => {
  it('accepts a minimal ai_denoise call', () => {
    expect(validateToolArgs('ai_denoise', { photo_id: 914 })).toBeNull();
  });

  it('accepts a fully-configured ai_denoise call', () => {
    expect(validateToolArgs('ai_denoise', {
      photo_id: '914',
      fallback: 'manual',
      manual_settings: { luminance: 40, color: 20 },
      native_automation: {
        window_title: 'Lightroom Classic',
        menu_keys: '%pe',
        confirm_keys: '{ENTER}',
        key_delay_ms: 800,
        verify_timeout_s: 120,
      },
    })).toBeNull();
  });

  it('rejects ai_denoise automation typos', () => {
    expect(validateToolArgs('ai_denoise', {
      photo_id: 914,
      native_automation: { menu_keyz: '%pe' },
    })).toContain('unknown property "menu_keyz"');
  });

  it('rejects an invalid ai_denoise fallback', () => {
    expect(validateToolArgs('ai_denoise', { photo_id: 914, fallback: 'maybe' })).toContain('fallback');
  });

  it('rejects ai_denoise manual sliders out of range', () => {
    expect(validateToolArgs('ai_denoise', {
      photo_id: 914,
      manual_settings: { luminance: 150 },
    })).toContain('manual_settings.luminance');
  });

  it('requires at least one slider on set_noise_reduction', () => {
    expect(validateToolArgs('set_noise_reduction', { photo_ids: [914] })).toContain('anyOf');
  });

  it('accepts a set_noise_reduction call with sliders', () => {
    expect(validateToolArgs('set_noise_reduction', {
      photo_ids: [914, 915],
      luminance: 35,
      sharpen_radius: 1.2,
    })).toBeNull();
  });

  it('rejects an unknown white balance preset', () => {
    expect(validateToolArgs('set_white_balance', {
      photo_ids: [914],
      preset: 'Sunny',
    })).toContain('preset');
  });

  it('accepts custom Kelvin white balance', () => {
    expect(validateToolArgs('set_white_balance', {
      photo_ids: [914],
      temperature: 5600,
      tint: 8,
    })).toBeNull();
  });

  it('requires preset or temperature/tint on set_white_balance', () => {
    expect(validateToolArgs('set_white_balance', { photo_ids: [914] })).toContain('anyOf');
  });

  it('validates set_flags', () => {
    expect(validateToolArgs('set_flags', { photo_ids: [914], flag: 'pick' })).toBeNull();
    expect(validateToolArgs('set_flags', { photo_ids: [914], flag: 'star' })).toContain('flag');
    expect(validateToolArgs('set_flags', { photo_ids: [914] })).toContain("required property 'flag'");
  });

  it('validates add_spots entries', () => {
    expect(validateToolArgs('add_spots', {
      photo_id: 914,
      spots: [{ x: 0.5, y: 0.5, radius: 0.05, type: 'heal' }],
    })).toBeNull();

    expect(validateToolArgs('add_spots', {
      photo_id: 914,
      spots: [{ x: 0.5 }],
    })).toContain('spots.0');

    expect(validateToolArgs('add_spots', {
      photo_id: 914,
      spots: [{ x: 1.5, y: 0.5 }],
    })).toContain('spots.0.x');

    expect(validateToolArgs('add_spots', {
      photo_id: 914,
      spots: [{ x: 0.5, y: 0.5, type: 'magic' }],
    })).toContain('spots.0.type');
  });

  it('validates add_local_adjustment', () => {
    expect(validateToolArgs('add_local_adjustment', {
      photo_id: 914,
      mask_type: 'linear',
      exposure: 0.5,
    })).toBeNull();

    expect(validateToolArgs('add_local_adjustment', {
      photo_id: 914,
      mask_type: 'circular',
      exposure: 0.5,
    })).toContain('mask_type');

    expect(validateToolArgs('add_local_adjustment', {
      photo_id: 914,
      mask_type: 'linear',
    })).toContain('anyOf');
  });

  it('accepts export watermarking and rejects it for original format co-use checks schema-wise', () => {
    expect(validateToolArgs('export_photos', {
      photo_ids: [914],
      destination: '/tmp',
      watermark: 'Copyright Juan',
    })).toBeNull();

    expect(validateToolArgs('export_photos', {
      photo_ids: [914],
      destination: '/tmp',
      watermark: '',
    })).toContain('watermark');
  });

  it('accepts a minimal add_ai_mask call', () => {
    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'subject',
    })).toBeNull();
  });

  it('accepts add_ai_mask with adjustments and rejects bad sliders', () => {
    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914, 915],
      selection_type: 'sky',
      adjustments: { exposure: 0.5, clarity: 10 },
    })).toBeNull();

    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'sky',
      adjustments: { exposure: 12 },
    })).toContain('adjustments.exposure');

    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'volcano',
    })).toContain('selection_type');
  });

  it('requires mask_id on remove_mask and accepts string or number ids', () => {
    expect(validateToolArgs('remove_mask', { photo_id: 914 })).toContain('required');

    expect(validateToolArgs('remove_mask', { photo_id: 914, mask_id: 'abc123' })).toBeNull();
    expect(validateToolArgs('remove_mask', { photo_id: 914, mask_id: 7 })).toBeNull();
  });

  it('validates set_tone_curve points and channels', () => {
    expect(validateToolArgs('set_tone_curve', {
      photo_id: 914,
      channel: 'red',
      points: [[0, 0], [128, 140], [255, 255]],
    })).toBeNull();

    expect(validateToolArgs('set_tone_curve', {
      photo_id: 914,
      channel: 'cyan',
      points: [[0, 0], [255, 255]],
    })).toContain('channel');

    expect(validateToolArgs('set_tone_curve', {
      photo_id: 914,
      points: [[0, 0], [128, 400], [255, 255]],
    })).toContain('points');

    expect(validateToolArgs('set_tone_curve', { photo_id: 914 })).toContain('anyOf');
  });

  it('accepts apply_auto with valid operations and rejects unknown ones', () => {
    expect(validateToolArgs('apply_auto', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('apply_auto', {
      photo_ids: [914],
      operations: ['tone'],
    })).toBeNull();
    expect(validateToolArgs('apply_auto', {
      photo_ids: [914],
      operations: ['tone', 'white_balance'],
    })).toBeNull();

    expect(validateToolArgs('apply_auto', {
      photo_ids: [914],
      operations: ['denoise'],
    })).toContain('operations');
  });

  it('validates set_color_label labels', () => {
    expect(validateToolArgs('set_color_label', {
      photo_ids: [914],
      label: 'red',
    })).toBeNull();

    expect(validateToolArgs('set_color_label', {
      photo_ids: [914],
      label: 'crimson',
    })).toContain('label');
  });

  it('validates create_virtual_copies count', () => {
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('create_virtual_copies', {
      photo_ids: [914],
      count: 3,
    })).toBeNull();

    expect(validateToolArgs('create_virtual_copies', {
      photo_ids: [914],
      count: 21,
    })).toContain('count');

    expect(validateToolArgs('create_virtual_copies', {
      photo_ids: [914],
      count: 2.5,
    })).toContain('count');
  });

  it('validates create_smart_collection rules', () => {
    expect(validateToolArgs('create_smart_collection', {
      name: 'Best of wedding',
      rules: [
        { criteria: 'keywords', operation: 'all', value: 'wedding' },
        { criteria: 'rating', operation: '>=', value: 3 },
      ],
    })).toBeNull();

    expect(validateToolArgs('create_smart_collection', {
      name: 'Best of wedding',
    })).toContain('required');

    expect(validateToolArgs('create_smart_collection', {
      name: 'Best of wedding',
      rules: [{ criteria: 'keywords', operation: 'all' }],
    })).toContain('rules');

    expect(validateToolArgs('create_smart_collection', {
      name: 'Best of wedding',
      combine: 'xor',
      rules: [{ criteria: 'keywords', operation: 'all', value: 'x' }],
    })).toContain('combine');
  });

  it('validates search_photos advanced rules and combine', () => {
    expect(validateToolArgs('search_photos', {
      rules: [{ criteria: 'cameraModel', operation: '==', value: 'Canon EOS R5' }],
    })).toBeNull();

    expect(validateToolArgs('search_photos', {
      rules: [{ criteria: 'cameraModel', operation: '==', value: 'Canon EOS R5' }],
      combine: 'union',
    })).toBeNull();

    expect(validateToolArgs('search_photos', {
      rules: [{ criteria: 'cameraModel', operation: '==' }],
    })).toContain('rules');

    expect(validateToolArgs('search_photos', {
      rules: [{ criteria: 'cameraModel', operation: '==', value: 'R5' }],
      combine: 'xor',
    })).toContain('combine');
  });

  it('validates get_photo_preview size', () => {
    expect(validateToolArgs('get_photo_preview', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 'large' })).toBeNull();
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 512 })).toBeNull();

    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 'huge' })).toContain('size');
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 16 })).toContain('size');
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 4096 })).toContain('size');
  });

  it('validates get_develop_settings fields', () => {
    expect(validateToolArgs('get_develop_settings', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_develop_settings', { photo_id: 914, fields: 'all' })).toBeNull();

    expect(validateToolArgs('get_develop_settings', { photo_id: 914, fields: 'everything' })).toContain('fields');
  });

  it('validates reset_develop scopes', () => {
    expect(validateToolArgs('reset_develop', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('reset_develop', { photo_id: 914, scope: 'tools', tools: ['crop'] })).toBeNull();
    expect(validateToolArgs('reset_develop', {
      photo_id: 914,
      scope: 'params',
      params: ['Exposure2012'],
    })).toBeNull();

    expect(validateToolArgs('reset_develop', { photo_id: 914, scope: 'everything' })).toContain('scope');
    expect(validateToolArgs('reset_develop', { photo_id: 914, scope: 'tools', tools: ['lens'] })).toContain('tools');
    expect(validateToolArgs('reset_develop', { photo_id: 914, scope: 'tools' })).toContain('tools');
    expect(validateToolArgs('reset_develop', {
      photo_id: 914,
      scope: 'params',
      params: ['NotARealParam'],
    })).toContain('params');
  });

  it('validates set_process_version versions', () => {
    expect(validateToolArgs('set_process_version', {
      photo_id: 914,
      version: 'Version 3',
    })).toBeNull();

    expect(validateToolArgs('set_process_version', {
      photo_id: 914,
      version: 'PV2012',
    })).toContain('version');
  });

  it('validates select_photos requires ids or mode, not both', () => {
    expect(validateToolArgs('select_photos', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('select_photos', { mode: 'all' })).toBeNull();

    expect(validateToolArgs('select_photos', {})).toContain('select_photos');
    expect(validateToolArgs('select_photos', { mode: 'some' })).toContain('mode');
  });

  it('validates batch_metadata fields', () => {
    expect(validateToolArgs('batch_metadata', {
      photo_ids: [914],
      metadata: { title: 'Sunset', caption: 'Blue hour' },
    })).toBeNull();

    expect(validateToolArgs('batch_metadata', {
      photo_ids: [914],
      metadata: { shutterSpeed: '1/200' },
    })).toContain('metadata');
  });

  it('validates remove_from_catalog demands confirm', () => {
    expect(validateToolArgs('remove_from_catalog', { photo_ids: [914], confirm: true })).toBeNull();

    expect(validateToolArgs('remove_from_catalog', { photo_ids: [914] })).toContain('required');
    expect(validateToolArgs('remove_from_catalog', { photo_ids: [914], confirm: false })).toContain('confirm');
  });

  it('validates remove_mask accepts mask_id or remove_all', () => {
    expect(validateToolArgs('remove_mask', { photo_id: 914, mask_id: 'mask-1' })).toBeNull();
    expect(validateToolArgs('remove_mask', { photo_id: 914, remove_all: true })).toBeNull();

    expect(validateToolArgs('remove_mask', { photo_id: 914 })).toContain('remove_mask');
  });

  it('validates add_ai_mask adjustment_preset and mutual exclusion', () => {
    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'sky',
      adjustment_preset: 'darken_sky',
    })).toBeNull();

    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'sky',
      adjustment_preset: 'vivid_sky',
    })).toContain('adjustment_preset');

    expect(validateToolArgs('add_ai_mask', {
      photo_ids: [914],
      selection_type: 'sky',
      adjustments: { exposure: 0.5 },
      adjustment_preset: 'darken_sky',
    })).toContain('add_ai_mask');
  });

  it('validates manage_view_filter set requires rules', () => {
    expect(validateToolArgs('manage_view_filter', {})).toBeNull();
    expect(validateToolArgs('manage_view_filter', { action: 'get' })).toBeNull();
    expect(validateToolArgs('manage_view_filter', {
      action: 'set',
      rules: [{ criteria: 'rating', operation: '>=', value: 3 }],
    })).toBeNull();
    expect(validateToolArgs('manage_view_filter', { action: 'clear' })).toBeNull();

    expect(validateToolArgs('manage_view_filter', { action: 'set' })).toContain('manage_view_filter');
    expect(validateToolArgs('manage_view_filter', { action: 'apply' })).toContain('action');
  });
});

describe('tool handler argument validation', () => {
  it('fails before touching Lightroom', async () => {
    const call = jest.fn((_action: string, _params: unknown) =>
      Promise.resolve({ id: 'req_1', result: {} }));
    const handler = createCallToolHandler({ dispatcher: { call }, isReady: () => true });

    const res = await handler('get_photo_metadata', { photo_id: { nested: true } });

    expect(res.isError).toBe(true);
    expect((res.content[0] as { type: "text"; text: string }).text).toContain('Invalid arguments');
    expect(call).not.toHaveBeenCalled();
  });

  it('lets a valid call through', async () => {
    const call = jest.fn((_action: string, _params: unknown) =>
      Promise.resolve({ id: 'req_1', result: { ok: true } }));
    const handler = createCallToolHandler({ dispatcher: { call }, isReady: () => true });

    const res = await handler('get_photo_metadata', { photo_id: 914 });

    expect(res.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('get_photo_metadata', { photo_id: 914 });
  });
});
