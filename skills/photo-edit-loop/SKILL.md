---
name: photo-edit-loop
description: >-
  Edit photos in Adobe Lightroom Classic through the lightroom MCP server and
  verify each edit by looking at it. Use when asked to adjust, grade, brighten,
  denoise, mask or batch-process photos in Lightroom — anything where the result
  has to be seen before it is trusted. Handles the preview gate: propose a
  change, render it, look at the render, correct it, then copy the approved
  settings to the rest of the batch.
---

# Photo edit loop

The one thing this server gives you that a blind tool call does not is a
picture of the result. `get_photo_preview` renders a JPEG of the photo **with
its current edits** and attaches it inline, so you look at what you did instead
of assuming it worked.

That only pays off if you look, and if you look at something trustworthy. Most
of this skill is about the second half: a preview is evidence only sometimes,
and the difference is usually a field in the response.

**`mode` is a hard gate, not a description of intent.** Default to `propose`:
describe the change and wait for the person to say yes. Call a
catalog-mutating tool only on an explicit request in the user's own message, or
after a proposal you already made and they approved. Reading, previewing and
proposing are always allowed — they are how you decide what to propose.

## The loop

1. **Look before you change anything.** `get_photo_preview` at `large` to see
   the photo, plus `get_develop_settings` and `get_photo_metadata` to see what is
   already applied. These arrive with a camera profile and non-zero contrast, so
   propose **deltas from what is there**, never from zero. Editing a `+0.7`
   exposure that already sits at `+0.7` does not give you `+1.4`.
2. **Name the change and its number**, and say what you expect it to do. One
   reason per change. "Exposure +0.4 to open the shadows on the left wall, which
   the window is behind" is reviewable; "+0.4 exposure" is not.
3. **Apply it.** `set_develop_settings`, `set_white_balance`, `add_local_adjustment`,
   `add_ai_mask`, `ai_denoise`, `apply_auto`.
4. **Render and look.** `get_photo_preview` at `medium`. Check `size_usable`
   first — see below, this is where the loop silently lies to you.
5. **Say what you actually see**, not what you intended. "The shadows opened but
   the sky went grey" is the useful sentence.
6. **Correct or stop.** Not every loop needs three passes. Two is usually
   enough; if the third pass is not converging, say so instead of grinding.
7. **Only then batch.** `copy_develop_settings` from the approved photo to the
   rest — never to the source photo itself.

## `size_usable` — check it before you trust the image

```
size_usable: false
```

means Lightroom served a rendition that is **not** the edit you just made: a
cached thumbnail from before the change, or the full-resolution original. The
picture will look unchanged, or look like the edit was never applied, and the
obvious conclusion — "the tool didn't work" — is wrong. The work happened; you
are looking at a stale cache.

Before drawing any conclusion from a preview:

- `size_usable` is `false` → the render is not evidence. Re-render, or read the
  settings back with `get_develop_settings` to confirm what is actually applied.
- `rendered_width` is far larger than `size_px` → you got the original, not a
  thumbnail. Fine for checking composition, useless for checking an edit.
- `rendered_width` is far smaller than `size_px` → a thumbnail, and for a fresh
  edit that thumbnail may predate it.

If a preview seems to contradict an edit you know was applied, believe the
settings and re-render before you touch the edit again. Re-applying a change
that already landed is how one photo ends up graded twice.

## Batching

Once one photo is approved:

```json
copy_develop_settings { "source_id": <approved>, "target_ids": [<the rest>] }
```

`target_ids` must not include `source_id`. Copying onto the source is what
makes a photo look doubly-graded.

Three things that bite in a batch:

- **The source has to stay put.** Everything else changes relative to it.
- **Batch tools report per-photo, not all-or-nothing.** `set_rating`,
  `set_flags`, `set_keywords` and `add_ai_mask` return `updated` / `missing` /
  `mismatching` counts. A partial success is the normal case — one masked photo
  fails and the other forty-nine land. Read the counts before reporting, and
  name the photos that did not take.
- **`updated: 0` with a `missing` list means nothing matched.** It is not a
  silent no-op. Either the ids are stale or the photos are not in the catalog.

After copying, preview **one** target to confirm the copy landed. Do not trust a
count.

## Things that take real time

These have their own timeouts on the server (30s default is not enough), and a
premature failure looks like a failure of the tool, not of the clock:

| Tool | Timeout | Why |
| --- | --- | --- |
| `export_photos`, `import_photos`, `ai_denoise` | 300s | batch render, or a real DNG render |
| `add_ai_mask` | 120s | on-device AI, seconds per photo |
| `add_local_adjustment`, `remove_mask` | 120s | force a recompute before verifying |
| `set_flags` | 120s | large batches go through the UI, one at a time |
| `create_virtual_copies` | 120s | measured 26–36s for 7–8 copies |

`get_photo_preview` is asynchronous — Lightroom builds standard previews in the
background, so a photo that has never been previewed can take a while. A slow
first render is not an error.

## Verify by reading back, not by assuming

The return value of a write is not proof. After anything that rewrites stored
settings:

- `get_develop_settings` — confirms what is applied, per parameter
- `list_masks` — confirms a mask exists, and its id
- `reset_develop` — returns a before/after slider diff; that diff is the evidence

`add_ai_mask` in particular: the underlying SDK call returns nil even when it
works from the UI. Never report a mask as created on the strength of the return
value — confirm with `list_masks`. When it genuinely fails, the response carries
screenshots of Lightroom's own warning banner as attached images: read the image
to see what it actually said before picking a different `selection_type` or
falling back to `add_local_adjustment`.

## Rollback

`create_snapshot` before you start, and be straight about what it buys: the SDK
can create snapshots but cannot list or restore them, so the person restores
from Lightroom's own panel.

The rollback **you** can perform is `reset_develop`, and it is not partial —
`scope: "params"` with the parameter names, or `scope: "tools"` for crop /
spot removal / masking / gradients, or `scope: "all"` which is the Reset button
and discards everything. Name exactly which you are about to run. If the person
had work in the Develop module before you started, `reset_develop` is the wrong
tool and you should say so before running it.

`create_virtual_copies` is the cheaper safety net when the batch is the risk:
copies are catalog entries pointing at the same files, so you can practice and
then remove them from the catalog without touching anything on disk.

## Destructive tools

`remove_from_catalog` and `remove_mask` with `remove_all: true` require an
explicit `confirm: true`. That flag is not a formality — it is the only thing
between the call and deleted catalog entries. Ask before you set it, and do not
set it in the same breath as the proposal; wait for the answer.

## Before anything

Four things about this server that cost a round trip each if you do not know
them:

- `get_develop_settings` takes `fields: "basic" | "all"` — not `"full"`, and the
  error does not say so. Reading the full filter list needs `fields: "all"`
  **and** `max_depth: 16`.
- `get_photo_preview`'s `size` takes `"small"` / `"medium"` / `"large"` or an
  exact pixel size 32–2048. `small` is 240px, `medium` 640, `large` 1024.
- Batch tools take plural `photo_ids`; `get_photo_metadata`, `get_develop_settings`
  and `list_masks` take singular `photo_id`. Passing an array where a single id
  belongs is an error, not a silent batch.
- `import_photos` takes `{ "source_path": ... }`. It needs the file to exist and
  be a format Lightroom reads — a 22-byte hand-written JPEG is rejected with
  `dng_error_bad_format`.

## Reference

- `reference/recipes.md` is **not** loaded here. It belongs to the
  `photo-edit-advisor` skill, which measures dust and noise before proposing.
  Use that skill instead of guessing at lifts when the question is how far a
  photo can be pushed. This skill starts from a photo the person already wants
  edited.
- `evals/` in `photo-edit-advisor` holds reference cases and a rubric for
  judging a proposed edit — useful if you want to know what a good proposal is
  held to before you write one.
