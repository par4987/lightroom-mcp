# Scene recipes

Load this only once the scene is identified. Every recipe here is a STARTING
POINT to propose, not a formula to apply. The numbers are deliberately smaller
than they could be: the commonest failure of automatic editing is over-processing,
and an amateur cannot spot it in their own photo — they see the change and read it
as improvement.

## Rules that outrank every recipe

1. **The noise budget wins.** Never propose an `Exposure` or `Shadows` lift beyond
   `headroom_stops` from `estimate_noise.py`. When a recipe wants more than the
   budget allows, take the budget and say the shadows were the limit.

   The budget is in STOPS and only `Exposure` is in stops. `Shadows` runs -100 to
   +100 with no published mapping, and its effect depends on how dark the pixel
   already is. So treat the comparison as approximate and stay well inside it:

   | headroom | Exposure | Shadows |
   |---|---|---|
   | >= 2.0 | up to +1.0 | up to +40 |
   | 1.0 - 2.0 | up to +0.5 | up to +25 |
   | 0.5 - 1.0 | up to +0.25 | up to +15 |
   | < 0.5 | none | up to +10, and say why it is small |

   These are a working rule, not a measurement, and they are deliberately
   conservative. After applying, re-export and re-measure rather than trusting
   the table. When `confidence` is `low`, take one row lower than the number
   says: the estimate came from scraps of flat shadow between detail.
2. **One idea per edit.** A photo that needs exposure, contrast, saturation, a
   sky mask and a vignette does not need all five. Pick the two that carry the
   picture.
3. **Say what the change is for.** "Vibrance +12" is not a proposal; "the sky is
   washed out at this hour, +12 vibrance brings the blue back without touching
   skin" is.
4. **What Lightroom already did is a floor, not a starting point.** Photos in this
   catalogue arrive with a camera profile and `Contrast: 25` already applied.
   Read the current settings before proposing a delta.

## What actually works through the SDK

Reliable: global sliders (`set_develop_settings`), `apply_auto`, tone curves,
white balance, noise reduction.

Unreliable here: `add_ai_mask`. The underlying `createNewMask` call returns nil on
this Lightroom build even when it works from the UI.

`add_local_adjustment` works, with or without an existing mask on the photo.
Verified on LrC 15.4: the correction survives a recompute, matches the structure
Lightroom writes itself in 33 of 34 fields, and the pixels inside a radial rose
23.7 levels while everything outside fell 2.2. Check `verified_after_recompute`
in the result — when it is false the strong check did not run.

**But a mask this tool creates cannot be removed by any tool.** `list_masks` and
`remove_mask` read the Develop module's mask API, which does not see corrections
written into `MaskGroupBasedCorrections`: on a photo where
`read_local_adjustments` reported one mask, `list_masks` reported zero and both
`remove_mask` by id and `remove_all` did nothing. So:

- Do not add a mask casually. There is no undo through the server.
- To cancel one, zero its sliders with `set_mask_adjustments` — that works and
  reports a before/after diff — and tell the person the inert entry is theirs to
  delete in the Masks panel.
- Say this before applying a masked edit to a photo they care about.

Not available at all: Distraction Removal (dust, people) is UI-only.

---

## Landscape — open, distant, sky present

The usual faults are a flat sky, haze, and a foreground that fell dark because the
meter protected the sky.

- `apply_auto` (tone) as a baseline — but note the tension with propose mode: you
  cannot say what Auto will do without running it, and running it is a change. So
  either propose Auto as step one and pause for a yes before the rest, or skip it
  and propose explicit sliders. Do not propose "Auto, then +X" as a single plan;
  the +X is guesswork until Auto has run.
- Haze: `Dehaze +8..15`. Above 20 it turns skies cyan and crushes distant detail.
- `Vibrance +10..20` rather than `Saturation`; vibrance protects what is already saturated.
- `Texture +5..15` for rock and foliage. `Clarity` above +20 gives the grey halo look.
- Sky: a linear `add_local_adjustment` from the top down, `exposure -0.3..-0.6`,
  `highlights -20`. Prefer this over the `darken_sky` AI preset, which uses
  exposure -0.7 and saturation +15 — strong for a photo that is merely bright.
- Foreground lift bounded by the noise budget.

## Portrait — one or a few people, the subject fills the frame

Skin is where over-processing shows first and is forgiven least.

- Never raise global `Clarity` or `Texture` on a face: both sharpen pores. If the
  scene needs texture, mask it away from skin.
- `Shadows +10..25` to open the face, bounded by the budget. Backlit portraits
  routinely want more than the budget allows — that is the signal to say so.
- `Highlights -15..30` recovers a blown forehead or shoulder.
- Keep white balance alone unless it is visibly wrong. Warm skin that looks warm
  is usually the photographer's intent.
- `Vibrance` yes, `Saturation` no: saturation turns skin orange before it does
  anything for the rest of the frame.
- The eyes are worth one radial `add_local_adjustment` at `exposure +0.2`; that
  single move does more than any global slider.

## Group and event — several people, uncontrolled light

- Prioritise getting every face readable over making the photo pretty.
  `Shadows +15..25`, `Highlights -20`.
- Mixed light (window plus tungsten) cannot be fixed globally. Say so rather than
  choosing which half to serve.
- Flash frames: `Highlights -25` and a gentle curve lift in the shadows beats an
  exposure change.

## Animals

- Fur and feathers take `Texture +10..20` well, and unlike skin they want it.
- Eyes: same radial lift as a portrait; a bird or dog with dead eyes reads as a
  record shot.
- Birds against a bright sky are the one case where `Highlights -40` is reasonable.
- Do not lift shadows on black fur to "reveal detail" — it is the one place noise
  arrives instantly, and the budget will usually say no.

## Urban

- Straight lines are the subject. Check `PerspectiveUpright` before any tonal work;
  a converging building is more distracting than a dark one.
- `Clarity +10..20` suits concrete, brick and glass — this is the scene type where
  clarity is not a mistake.
- Night: `Highlights -30` on streetlights, and watch the noise budget closely.
  High ISO plus lifted shadows is exactly the "broken photo" case.
- Colour casts from sodium and LED are usually worth correcting; `set_white_balance`
  by Kelvin rather than by preset.

## Rural and interiors

- Rural: keep greens honest. `HueAdjustmentGreen` a few points towards yellow
  reads as sunlight; more reads as a filter.
- Interiors: the window is blown and cannot be recovered from a single frame.
  Recover what is recoverable, then say the window is gone.
- `Dehaze` is not for interiors. It grabs the shadows and makes rooms muddy.

## Backlit — any subject, light behind

Diagnose this before choosing a scene recipe; it changes the plan more than the
subject does.

- `Highlights -30..50`, `Shadows +20..35`, both bounded by the budget.
- `Dehaze +5..10` restores the contrast that flare stole.
- Do not try to make it look front-lit. Keep the rim light; it is why the photo
  was taken.

## Night and low light

- Measure first. `estimate_noise.py` will often return a negative headroom, and
  the honest proposal is then `ai_denoise` before any tonal work.
- Resist lifting to daylight. A night photo that looks like dusk is a worse photo.
- `Blacks -5..10` restores the sense of night that shadow lifting removes.
