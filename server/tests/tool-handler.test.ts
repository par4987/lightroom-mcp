import { describe, it, expect } from '@jest/globals';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { createCallToolHandler } from '../src/tool-handler.js';

import type { PluginResponse } from '../src/dispatcher.js';

function makeHandler(opts: {
  ready?: boolean;
  call?: (action: string, params: unknown) => Promise<PluginResponse>;
} = {}) {
  return createCallToolHandler({
    isReady: () => opts.ready ?? true,
    dispatcher: {
      call: opts.call ?? (async () => ({ id: 'x', result: null })),
    },
  });
}

describe('createCallToolHandler', () => {
  it('returns isError when plugin not connected', async () => {
    const handler = makeHandler({ ready: false });
    const result = await handler('list_collections', {});
    expect(result.isError).toBe(true);
    expect((result.content[0] as { type: "text"; text: string }).text).toMatch(/not connected/i);
  });

  it('forwards action and args to dispatcher', async () => {
    let captured: { action: string; params: unknown } | null = null;
    const handler = makeHandler({
      call: async (action, params) => {
        captured = { action, params };
        return { id: '1', result: { ok: true } };
      },
    });
    await handler('search_photos', { rating: 5 });
    expect(captured).toEqual({ action: 'search_photos', params: { rating: 5 } });
  });

  it('serializes successful result as pretty JSON in text content', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', result: { count: 3, items: ['a', 'b'] } }),
    });
    const result = await handler('list_collections', {});
    expect(result.isError).toBeUndefined();
    expect(result.content[0].type).toBe('text');
    expect(JSON.parse((result.content[0] as { type: "text"; text: string }).text)).toEqual({ count: 3, items: ['a', 'b'] });
  });

  it('returns isError with prefixed message on plugin error response', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', error: 'Unknown action' }),
    });
    const result = await handler('bogus', {});
    expect(result.isError).toBe(true);
    expect((result.content[0] as { type: "text"; text: string }).text).toBe('Error: Unknown action');
  });

  it('catches dispatcher rejections and returns isError', async () => {
    const handler = makeHandler({
      call: async () => {
        throw new Error('Plugin response timeout (30s)');
      },
    });
    const result = await handler('x', {});
    expect(result.isError).toBe(true);
    expect((result.content[0] as { type: "text"; text: string }).text).toBe('Plugin response timeout (30s)');
  });

  it('handles non-Error throws by stringifying', async () => {
    const handler = makeHandler({
      call: async () => {
        throw 'raw string';
      },
    });
    const result = await handler('x', {});
    expect(result.isError).toBe(true);
    expect((result.content[0] as { type: "text"; text: string }).text).toBe('raw string');
  });
});

describe('createCallToolHandler preview image attachment', () => {
  function writeTempJpeg(bytes: number[]): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-preview-'));
    const file = path.join(dir, 'preview_914_640px_1234567.jpg');
    fs.writeFileSync(file, Buffer.from(bytes));
    return file;
  }

  it('inlines the plugin-written JPEG as an MCP image content block', async () => {
    const file = writeTempJpeg([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: {
          success: true,
          image_attached_by_server: true,
          file_path: file,
          mime_type: 'image/jpeg',
          size_bytes: 8,
        },
      }),
    });

    const result = await handler('get_photo_preview', { photo_id: 914 });

    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(2);
    expect(result.content[0].type).toBe('text');
    const image = result.content[1];
    expect(image.type).toBe('image');
    if (image.type === 'image') {
      expect(image.mimeType).toBe('image/jpeg');
      expect(image.data).toBe(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString('base64'));
    }
  });

  it('warns honestly when the preview file is missing', async () => {
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: {
          success: true,
          image_attached_by_server: true,
          file_path: path.join(os.tmpdir(), 'definitely-not-here-914.jpg'),
        },
      }),
    });

    const result = await handler('get_photo_preview', { photo_id: 914 });

    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(2);
    const first = result.content[0];
    expect(first.type).toBe('text');
    expect((first as { text: string }).text).toMatch(/Preview file could not be read back/);
    expect(result.content[1].type).toBe('text');
  });

  it('leaves ordinary results untouched (no image block, no warning)', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', result: { success: true, count: 1 } }),
    });

    const result = await handler('list_collections', {});

    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe('text');
  });
});

describe('createCallToolHandler warning screenshot attachment', () => {
  function writeTempShot(name: string, bytes: number[] | Buffer): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-warn-'));
    const file = path.join(dir, name);
    fs.writeFileSync(file, Buffer.from(bytes));
    return file;
  }

  it('inlines add_ai_mask warning screenshots after the JSON, deduplicated', async () => {
    const a = writeTempShot('warn_subject_early_1_1.jpg', [0xff, 0xd8, 1]);
    const b = writeTempShot('warn_subject_final_1_2.jpg', [0xff, 0xd8, 9]);
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: {
          success: false,
          failed: 1,
          warning: 'AI detection produced no mask on 1 photo(s); read the attached screenshots.',
          // Top-level aggregation and the per-photo fields name the same
          // files: the collector must not inline either of them twice.
          warning_screenshots: [a, b],
          results: [
            {
              photo: { id: 914 },
              failure_kind: 'detection_failed',
              warning_screenshots: [a, b],
              warning_screenshot: a,
              suggested_action: "no subject was detected: try selection_type 'background'",
            },
          ],
        },
      }),
    });

    const result = await handler('add_ai_mask', { photo_ids: [914], selection_type: 'subject' });

    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(3);
    expect(result.content[0].type).toBe('text'); // the JSON block stays first
    const first = result.content[1];
    const second = result.content[2];
    expect(first.type).toBe('image');
    expect(second.type).toBe('image');
    if (first.type === 'image' && second.type === 'image') {
      expect(first.mimeType).toBe('image/jpeg');
      expect(first.data).toBe(Buffer.from([0xff, 0xd8, 1]).toString('base64'));
      expect(second.data).toBe(Buffer.from([0xff, 0xd8, 9]).toString('base64'));
    }
  });

  it('picks the mime type from the file extension', async () => {
    const png = writeTempShot('warn_subject_final_1_1.png', [0x89, 0x50, 0x4e, 0x47]);
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: { success: false, results: [{ warning_screenshot: png }] },
      }),
    });

    const result = await handler('add_ai_mask', { photo_ids: [914], selection_type: 'subject' });

    const image = result.content[1];
    expect(image.type).toBe('image');
    if (image.type === 'image') expect(image.mimeType).toBe('image/png');
  });

  it('warns honestly when a warning screenshot file is missing', async () => {
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: {
          success: false,
          results: [
            { warning_screenshots: [path.join(os.tmpdir(), 'definitely-not-here-warn.jpg')] },
          ],
        },
      }),
    });

    const result = await handler('add_ai_mask', { photo_ids: [914], selection_type: 'subject' });

    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(2);
    expect(result.content[0].type).toBe('text');
    expect((result.content[0] as { text: string }).text).toMatch(/Warning screenshot could not be read back/);
    expect(result.content[1].type).toBe('text');
  });

  it('inlines at most 6 warning screenshots and reports the overflow', async () => {
    const files = Array.from({ length: 8 }, (_, i) => writeTempShot(`warn_${i}.jpg`, [i]));
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: { success: false, warning_screenshots: files, results: [] },
      }),
    });

    const result = await handler('add_ai_mask', { photo_ids: [914], selection_type: 'subject' });

    // 1 JSON text + 1 overflow warning + 6 images.
    expect(result.content).toHaveLength(8);
    expect((result.content[0] as { text: string }).text).toMatch(/2 of 8 warning screenshots were not inlined/);
    expect(result.content.slice(2).every((block) => block.type === 'image')).toBe(true);
  });

  it('reports a screenshot over the per-file size cap instead of inlining it', async () => {
    const big = writeTempShot('warn_big.jpg', Buffer.alloc(5 * 1024 * 1024 + 1));
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: { success: false, warning_screenshots: [big], results: [] },
      }),
    });

    const result = await handler('add_ai_mask', { photo_ids: [914], selection_type: 'subject' });

    expect(result.content).toHaveLength(2);
    expect(result.content[0].type).toBe('text');
    expect((result.content[0] as { text: string }).text).toMatch(/over the 5242880 inline cap/);
  });
});

describe('structuredContent', () => {
  const previewResult = {
    success: true,
    file_path: 'C:\previews\p1.jpg',
    size_px: 320,
    size_usable: true,
    rendered_width: 480,
    rendered_height: 320,
  };

  it('is returned for a tool that declares an outputSchema', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', result: previewResult }),
    });
    const result = await handler('get_photo_preview', { photo_id: 1 });

    expect(result.structuredContent).toEqual(previewResult);
    // The JSON text block stays: the spec asks for it for backwards
    // compatibility, and text-only clients read nothing else.
    const text = (result.content[0] as { type: 'text'; text: string }).text;
    expect(JSON.parse(text)).toEqual(previewResult);
  });

  it('is omitted for a tool that declares none', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', result: { created: true } }),
    });
    const result = await handler('create_collection', { name: 'x' });

    expect(result.structuredContent).toBeUndefined();
    expect(result.content).toHaveLength(1);
  });

  it('is omitted on an error response', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', error: 'boom' }),
    });
    const result = await handler('get_photo_preview', { photo_id: 1 });

    expect(result.isError).toBe(true);
    expect(result.structuredContent).toBeUndefined();
  });
});
