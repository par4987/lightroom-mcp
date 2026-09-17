# Dust: what was measured, and why the obvious approaches fail

Everything here was measured against Lightroom Classic 15.4 (ProcessVersion 15.4)
on a Sony ILCE-6100, over eleven frames of one session. Read it before changing
`detect_dust.py` or before trusting `FilterList`.

## The lens profile moves fixed spots

The same dust, photographed with two different lenses:

| frame | lens | spot position (sensor frame) |
|---|---|---|
| DSC02993 | E PZ 16-50mm @ 24mm f/16 | 0.5745, 0.1320 |
| DSC03092 | E 55-210mm @ 55mm f/14 | 0.5738, 0.1370 |

Both frames carry the identical crop (`CropTop 0.078`, `CropBottom 0.922`), so the
displacement is real. Decomposed against the frame centre for all three spots:

| radius from centre | \|Δ\| | radial | tangential |
|---|---|---|---|
| 0.456 | 0.0060 | −0.0060 | 0.0005 |
| 0.582 | 0.0133 | −0.0133 | 0.0002 |
| 0.737 | 0.0243 | −0.0243 | 0.0010 |

Purely radial, inward, growing with radius, tangential component at noise level.
That is a distortion-correction difference, not motion: `LensProfileEnable: 1` on
both, with different `LensProfileDigest`. **Lightroom does not compensate for this
either** — its own detections drift the same way between the two frames.

Consequence: comparing corrected coordinates across lenses produces "the spot
moved, therefore it is on the lens" with high confidence and no truth in it.
`correlate_dust.py` refuses to attribute across lenses for this reason.

## `FilterList` is not a list of dust coordinates

Coordinates live in `ReferenceImageArea` space (6048×4024); sensor pixel =
`Reference − 12`. Verified by diffing exports before and after removal: **100% of
changed pixels fell inside declared regions, 0% outside**, across 3 frames and 31
regions.

Regions come in two families:

- **square** — `BlackLevels "0,1"`, per-channel `Linearization` polynomials derived from content
- **wide** — `BlackLevels "13107,65535"`, one constant polynomial, identical in every wide region of all three frames

In all 26 regions checked, the payload (`ImageGroup` / `Alpha` `SizeX`×`SizeY`)
matched the box dimensions exactly. Both families get written to — the square ones
are not source patches.

**The box is the processing tile, not the spot.** Where the pixels actually
changed inside each box:

| region | change centroid | spot position |
|---|---|---|
| square #10 | 0.48, 0.54 | 0.48, 0.55 |
| square #8 | 0.45, 0.33 | 0.44, 0.28 |
| wide #9 (1314×232 px) | 0.10, 0.59 | 0.06, 0.62 |

A square tile's centre happens to land on the spot. A wide tile's does not. The
real mask is in the `Alpha` payload, compressed and not exposed through the SDK.

Not verified, so do not assert it: what the two `BlackLevels`/`Linearization`
encodings actually mean.

## Lightroom's detector is deterministic; its tiling is not

| frame | `CompressedSettings` | regions | square |
|---|---|---|---|
| DSC02993 | `36EA08F5…D02F` | 13 | 6 |
| DSC02994 | `E8B3CDC4…A76D` | 5 | 1 |
| DSC03092 | `1844FC1E…BD2E` | 13 | 5 |

Three different digests, so there is no cache across photos. An earlier
observation of an identical repeat was the *same photo* re-detected — deterministic
on identical input.

DSC02993 and DSC02994 are consecutive exposures of one scene, two seconds apart,
and were tiled completely differently. **The dust was removed in both.** What
varies is how the work is divided, not whether detection happens.

Lightroom also removes things that are not dust: one square region in DSC02993 sat
on the treeline and erased a protruding twig. A real distractor, correctly
removed, and not dust.

## Approaches that were tried and failed

**Threshold a high-pass, label connected components.** On DSC02993: 64 detections
in river foam, and none of the three real spots. The blob profile is gradual, so a
threshold near the noise floor leaves a core of a few pixels which the size filter
then discards.

**Estimate the noise scale over the whole frame.** Puts the threshold about 5×
above the signal. Texture dominates the statistic. The scale must be measured
inside the smooth+bright gate.

**Gate on plain local standard deviation.** A well-marked spot raises the local
std and gates *itself* out, leaving only a ring around it — which the detector then
reports as several spots. Measured over a real spot: std 0.0078 against clean sky
0.0045. Using fine-scale detail energy instead: 0.0044 against 0.0040, while foam
reads 0.079 and foliage 0.013.

**Rank candidates by score within one frame.** The strongest candidates in several
frames were ground texture, and they survived Lightroom's removal — which is how we
know they were never dust. Only recurrence across scenes separates them.

**Accept the caller's scene tags.** On a second session (Salta, ƒ/20, same camera
and lens) four frames were tagged as two scenes because they were seventeen
minutes apart. They were one viewpoint. The skyline and the cloud band sat in the
same place in all four, so five of them "recurred across scenes" and came back as
confident dust. Inspected: cloud edges, a mountain ridge, and the sun.

Re-tagged with three genuinely different viewpoints — two of them on a different
day — the same pipeline returned **zero** persistent candidates out of 92, which
is the right answer: those skies are full of cloud structure and dust is not
observable in them.

**Reject blobs by shape only after clustering.** The five false positives were
elongated. A scale-normalised Laplacian answers to ridges as strongly as to
blobs, so the shape test has to run per frame, before anything is correlated.
Comparing the two principal curvatures of the response through the Hessian's
trace and determinant (the test SIFT uses for edge keypoints, at r=5 rather than
10) rejects hundreds to thousands of responses per frame and leaves the three
known dust spots untouched.

## What was tried as a gate and demoted to a hint

Comparing the neighbourhood of a candidate between frames, to catch scene tags
that claim independence they do not have. Three variants, none usable as a filter:

| variant | same viewpoint (false positives) | different viewpoints (real dust) |
|---|---|---|
| raw patch, mean removed | 0.67 – 0.80 | 0.16 – 0.28 |
| ditto, over a featureless clear sky | — | **0.91** (both carry the same gradient) |
| best-fit plane removed as well | 0.26 and below | 0.21 and below |

The first separates the real cases but would discard dust over a clear sky, which
is where dust is easiest to see. The third is safe over sky and no longer
separates anything. So `background_similarity` is reported with a warning above
0.5 and never deletes a finding. Patches below `MIN_PATCH_CONTRAST` return
`null`: measured contrast was 0.0093–0.0100 for clear sky around real dust
against 0.26–0.28 for the cloud and skyline patches.

## Reference numbers

Detector repeatability between consecutive frames: **Δ ≤ 0.0006 (3.6 px on 6000)**.

Agreement with Lightroom's square regions, where both fire:

| frame | detected | Lightroom | Δ |
|---|---|---|---|
| DSC02993 | 0.5745, 0.1320 | 0.5750, 0.1299 | 0.0005 / 0.0021 |
| DSC02993 | 0.1865, 0.0935 | 0.1887, 0.1043 | 0.0022 / 0.0108 |
| DSC03092 | 0.5738, 0.1370 | 0.5729, 0.1424 | 0.0009 / 0.0054 |
| DSC03092 | 0.3017, 0.1230 | 0.3047, 0.1278 | 0.0030 / 0.0048 |
