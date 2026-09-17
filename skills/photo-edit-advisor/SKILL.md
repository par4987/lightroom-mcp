---
name: photo-edit-advisor
description: >-
  Analyse photos in Adobe Lightroom Classic through the lightroom MCP server and
  propose edits. Finds sensor and lens dust and tells it apart from things that
  merely look like dust, and measures how far the shadows can be lifted before
  noise breaks the photo. Use when asked to clean up dust spots, to check whether
  a photo can take an exposure lift, or to propose an edit for a photo.
---

# Photo edit advisor

Two measurements this skill can make that an agent cannot make by looking at a
preview: **where the dust is**, and **how much lift the shadows will take**. Both
need full-resolution pixels; both are wrong if done by eye on a downscaled JPEG.

Default to `propose`: report findings and the edit you would make, and let the
person say yes. Apply directly only when they have asked for that.

## Before anything

The scripts need `numpy` and `pillow` (`pip install -r requirements.txt`). They
deliberately do NOT need scipy.

Three things about the MCP server that will otherwise cost a round trip each:

- `export_photos` does **not create the destination folder**. Create it first, or
  Lightroom fails with a message in the UI's language.
- `get_develop_settings` takes `fields: "basic" | "all"` — not `"full"`, and the
  error does not say so. Reading `FilterList` needs `fields: "all"` **and**
  `max_depth: 16`.
- Exports are **cropped**. Read `CropTop/CropBottom/CropLeft/CropRight` and pass
  them to the scripts, or every coordinate is in the wrong space.

## Dust

Detection runs in two stages, and the second one is not optional.

**Stage 1 — candidates, per frame.**

```bash
python scripts/detect_dust.py exported.jpg --crop 0.078,0.922,0,1
```

Returns dark, round, soft blobs sitting in smooth bright areas. It cannot tell
dust from a dark pebble on bright sand, and on real frames the pebbles scored
higher than the dust. Treat the output as candidates. Never report it as "the
dust in this photo".

**Stage 2 — verdict, across frames.**

```bash
python scripts/correlate_dust.py manifest.json
```

The manifest lists frames with a `scene` tag, the `lens`, and the crop:

```json
[{"image": "/tmp/dust/DSC02993.jpg", "scene": "falls",
  "lens": "E PZ 16-50mm F3.5-5.6 OSS", "crop": [0.078, 0.922, 0.0, 1.0]}]
```

Dirt lands on the same sensor coordinate in every frame; anything in the scene
does not. So a candidate becomes `persistent` only when it recurs across at least
two **different scenes**.

**The scene tags carry the whole argument, so get them right.** Two frames belong
to the same scene when the camera was pointed at the same thing — regardless of
the clock. Frames seventeen minutes apart from one viewpoint share a skyline and
the same clouds, and tagging them as two scenes turned five cloud gaps into five
confident false positives on a real run. Different scene means the camera moved
and is looking at something else.

Every `persistent` entry carries `background_similarity`: how alike the
surroundings are in the frames that agreed. Near zero is what independent
viewpoints look like (0.16 and 0.28 on measured real dust). Above 0.5 the entry
also carries a `warning`, and on the bad run those read 0.67, 0.70 and 0.80. It
is a hint, not a filter — over a featureless clear sky it has nothing to measure
and returns `null`. Weigh it; do not treat a warned entry as confirmed dust.

Report the `persistent` list, minus anything warned, and say when entries were
held back. Mention the rest only if asked.

If the result carries `orientation_error`, the frames mix portrait and landscape.
A portrait frame puts the same sensor position at transposed coordinates, so the
groups have to be run separately.

**Two things to never say.** Do not compare coordinates across different lenses:
Lightroom applies a per-lens distortion profile before export, and on a measured
pair that shifted a fixed spot radially by up to 0.024 of frame width, growing
with distance from centre — exactly the signature of "the spot moved, so it is on
the lens". And do not call a spot sensor dirt rather than lens dirt: both are
fixed in sensor coordinates, and telling them apart needs the lens profile
neutralised. `persistent` is the honest word.

**Removal.** Lightroom's Distraction Removal (Dust) does this well and there is
no SDK call for it — it is UI-only. Tell the person where the spots are and let
them run it. To verify afterwards, re-export and run stage 1 again: the spots
should be gone.

Do not try to read dust positions out of `FilterList`. Its boxes are processing
tiles, not spots; in a measured case the actual edit sat at 10% of the width of a
1314px-wide box. See `reference/dust-attribution.md`.

## Noise

```bash
python scripts/estimate_noise.py exported.jpg
```

Gives per-band noise and `headroom_stops` — how much the shadows can be lifted
before grain becomes objectionable. Use it to bound `Exposure` and `Shadows`
before proposing them, and when headroom runs out, raise `set_noise_reduction`
luminance **alongside** the lift rather than afterwards.

If `headroom_stops` is `null` the photo has no flat shadow area to measure. Say
that; do not substitute a guess from the ISO.

This measures the rendered image, after Lightroom's demosaic and default noise
reduction — which is what matters for "will it look broken", and is not a
statement about the sensor. Foliage or fabric in the shadows can inflate the
estimate, so an unexpectedly low headroom is worth a second look before it
becomes a refusal.

## Proposing an edit

Default mode is **propose**: present the plan, wait for a yes. Apply directly only
when asked to.

1. `create_snapshot` first when applying. Be straight about what that buys: the
   SDK can create snapshots but cannot list or restore them, so the person
   restores from Lightroom's panel. The rollback you can actually perform is
   `reset_develop`, which discards everything, not just your changes.
2. `get_photo_preview` at `large` to see the photo, and `get_photo_metadata` plus
   `get_develop_settings` to see what is already applied. These photos arrive with
   a camera profile and non-zero contrast — propose deltas from what is there, not
   from zero.
3. Classify the scene, and separately diagnose the light (backlit, mixed, night).
   The light changes the plan more than the subject does.
4. Run `estimate_noise.py` before proposing any shadow or exposure lift. The
   budget is a hard ceiling, not a suggestion.
5. Pick a recipe from `reference/recipes.md` — load it only now — and cut it down.
   Two changes that carry the picture beat five that are individually defensible.
6. State each change with its reason and its number. If the noise budget forced a
   smaller lift than the recipe wanted, say that; it is the most useful sentence
   in the proposal.
7. After applying, `get_photo_preview` at `medium` to verify, and report what
   actually changed by reading the settings back rather than assuming.

Be careful about what you promise to apply. `add_ai_mask` is unreliable on this
build — the underlying call returns nil even when it works from the UI — so verify
with `list_masks` and never report a mask as created on the strength of the return
value.

## Honest limits

- Both scripts need a **full-resolution export**, not `get_photo_preview`.
- Dust is only observable in smooth, bright areas. A frame with no sky and no
  flat highlights returns nothing, and that is not evidence there is no dust.
- One frame can never settle whether a blob is dust. If only one frame is
  available, say what was found and that it cannot be confirmed.

## Reference

- `reference/recipes.md` — scene taxonomy and conservative starting recipes. Load
  once the scene is known, not before.
- `evals/` — reference cases with measured answers, and the rubric for judging a
  proposed edit. Read `evals/rubric.md` if you want to know what a good proposal
  is held to; its four "below the line" criteria are the ones that sink one.
- `reference/dust-attribution.md` — what was measured against Lightroom, the
  `FilterList` structure, and the lens-profile trap, with the numbers.
