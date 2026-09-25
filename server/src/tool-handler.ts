import { readFile } from "node:fs/promises";
import type { Dispatcher } from "./dispatcher.js";
import { validateToolArgs } from "./validate-args.js";
import { outputSchemaFor } from "./tool-contracts.js";

export interface ToolHandlerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
  notReadyMessage?: () => string;
  settleReadiness?: () => Promise<void>;
}

export type ToolContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

export interface ToolResponse {
  content: ToolContentBlock[];
  isError?: boolean;
  [key: string]: unknown;
}

export const NOT_CONNECTED_MESSAGE =
  "Lightroom plugin not connected. Open Lightroom and click 'Start Server' in Plug-in Manager.";

/**
 * JPEG previews inline-attached by get_photo_preview are capped here: the
 * MCP spec allows several-MB base64 images and Claude Desktop renders them,
 * but a pathological 2048px preview of a huge panorama should not flood the
 * context. Above the cap the tool response still carries the file path.
 */
const MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024;

interface PluginToolResult {
  image_attached_by_server?: boolean;
  file_path?: string;
  mime_type?: string;
  size_bytes?: number;
  message?: string;
  [key: string]: unknown;
}

/**
 * The Lightroom plugin cannot push binary through the line-delimited JSON
 * socket, so HandlerPreview writes the JPEG to disk and flags the result.
 * Here the server reads it back and attaches it as an MCP image content
 * block — vision-capable clients (Claude) see the photo inline; text-only
 * clients still get the path from the JSON text.
 */
async function attachPreviewImage(
  result: PluginToolResult,
): Promise<{ image?: ToolContentBlock; warning?: string }> {
  if (result.image_attached_by_server !== true) return {};
  if (typeof result.file_path !== "string" || result.file_path === "") {
    return { warning: "Preview was rendered but the plugin reported no file path." };
  }

  try {
    const bytes = await readFile(result.file_path);
    if (bytes.byteLength > MAX_INLINE_IMAGE_BYTES) {
      return {
        warning:
          `Preview file is ${bytes.byteLength} bytes (over the ${MAX_INLINE_IMAGE_BYTES} inline cap); ` +
          `open it from ${result.file_path}`,
      };
    }
    return {
      image: {
        type: "image",
        data: bytes.toString("base64"),
        mimeType: typeof result.mime_type === "string" ? result.mime_type : "image/jpeg",
      },
    };
  } catch (err) {
    return {
      warning:
        `Preview file could not be read back (${err instanceof Error ? err.message : String(err)}); ` +
        `it should still exist at ${result.file_path}`,
    };
  }
}

/**
 * AI-mask detection failures (add_ai_mask) carry screenshot paths: the
 * plugin photographed the Lightroom WINDOW while Lightroom's "could not
 * find..." banner was on screen, because the SDK cannot read banner text
 * at all. A vision-capable client reads the inlined image and picks the
 * fallback; text-only clients still get the paths, `failure_kind` and
 * `suggested_action` from the JSON text block.
 *
 * Top-level `warning_screenshots` plus each photo's `warning_screenshots`
 * / `warning_screenshot` are collected in order (deduplicated) and inlined
 * up to this cap. Anything that cannot be inlined — past the cap, over the
 * per-file size limit, unreadable — surfaces as a `Warning:` text block,
 * so a screenshot never silently vanishes for a text-only harness.
 */
const MAX_INLINE_WARNING_SHOT_IMAGES = 6;

/** Paths of the Lightroom-window screenshots a failed add_ai_mask captured. */
function collectWarningShotPaths(result: PluginToolResult): string[] {
  const paths: string[] = [];
  const seen = new Set<string>();
  const add = (value: unknown): void => {
    if (typeof value === "string" && value !== "" && !seen.has(value)) {
      seen.add(value);
      paths.push(value);
    }
  };

  if (Array.isArray(result.warning_screenshots)) {
    for (const p of result.warning_screenshots) add(p);
  }
  if (Array.isArray(result.results)) {
    for (const entry of result.results) {
      if (entry === null || typeof entry !== "object") continue;
      const e = entry as { warning_screenshots?: unknown; warning_screenshot?: unknown };
      if (Array.isArray(e.warning_screenshots)) {
        for (const p of e.warning_screenshots) add(p);
      }
      add(e.warning_screenshot);
    }
  }
  return paths;
}

function mimeTypeForShot(filePath: string): string {
  return filePath.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
}

async function attachWarningShots(
  result: PluginToolResult,
): Promise<{ images: ToolContentBlock[]; warnings: string[] }> {
  const paths = collectWarningShotPaths(result);
  const images: ToolContentBlock[] = [];
  const warnings: string[] = [];
  if (paths.length === 0) return { images, warnings };

  const overflow = paths.slice(MAX_INLINE_WARNING_SHOT_IMAGES);
  if (overflow.length > 0) {
    warnings.push(
      `${overflow.length} of ${paths.length} warning screenshots were not inlined ` +
        `(cap of ${MAX_INLINE_WARNING_SHOT_IMAGES} images per call): ${overflow.join(", ")}`,
    );
  }

  for (const filePath of paths.slice(0, MAX_INLINE_WARNING_SHOT_IMAGES)) {
    try {
      const bytes = await readFile(filePath);
      if (bytes.byteLength > MAX_INLINE_IMAGE_BYTES) {
        warnings.push(
          `Warning screenshot is ${bytes.byteLength} bytes ` +
            `(over the ${MAX_INLINE_IMAGE_BYTES} inline cap); open it from ${filePath}`,
        );
        continue;
      }
      images.push({
        type: "image",
        data: bytes.toString("base64"),
        mimeType: mimeTypeForShot(filePath),
      });
    } catch (err) {
      warnings.push(
        `Warning screenshot could not be read back ` +
          `(${err instanceof Error ? err.message : String(err)}); ` +
          `it should still exist at ${filePath}`,
      );
    }
  }
  return { images, warnings };
}

export function createCallToolHandler(deps: ToolHandlerDeps) {
  return async (name: string, args: unknown): Promise<ToolResponse> => {
    const invalid = validateToolArgs(name, args);
    if (invalid) {
      return {
        content: [{ type: "text", text: invalid }],
        isError: true,
      };
    }

    await deps.settleReadiness?.();

    if (!deps.isReady()) {
      return {
        content: [{ type: "text", text: deps.notReadyMessage?.() ?? NOT_CONNECTED_MESSAGE }],
        isError: true,
      };
    }

    try {
      const resp = await deps.dispatcher.call(name, args);
      if (resp.error) {
        return {
          content: [{ type: "text", text: `Error: ${resp.error}` }],
          isError: true,
        };
      }

      const result = resp.result as PluginToolResult | undefined;
      const content: ToolContentBlock[] = [
        { type: "text", text: JSON.stringify(result ?? {}, null, 2) },
      ];

      if (result) {
        const { image, warning } = await attachPreviewImage(result);
        if (image) content.push(image);
        const shots = await attachWarningShots(result);
        for (const shot of shots.images) content.push(shot);
        const warnings = [...(warning ? [warning] : []), ...shots.warnings];
        if (warnings.length > 0) {
          content.unshift(
            ...warnings.map(
              (message): ToolContentBlock => ({ type: "text", text: `Warning: ${message}` }),
            ),
          );
        }
      }

      // Tools that declare an outputSchema also return the parsed result as
      // structuredContent, so a client can read fields instead of re-parsing
      // the text block. The JSON text block stays either way: the spec asks
      // for it for backwards compatibility, and it is what text-only clients
      // (and the DeepSeek harness) actually read.
      if (result && outputSchemaFor(name)) {
        return { content, structuredContent: result };
      }

      return { content };
    } catch (e) {
      return {
        content: [{ type: "text", text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      };
    }
  };
}
