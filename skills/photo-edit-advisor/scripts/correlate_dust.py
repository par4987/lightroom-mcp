#!/usr/bin/env python3
"""Turn per-frame dust CANDIDATES into an attributed verdict.

A single frame cannot tell dust from a dark pebble on bright sand: both are
small dark blobs in a smooth, bright area, and on the reference batch the pebbles
scored HIGHER than the dust. Measured, not assumed -- the strongest candidates in
three of the frames were ground texture, and they survived Lightroom's own
removal, which is how we know they were never dust.

What separates them is physics, not appearance: dirt sits on the sensor or in the
lens and therefore lands on the SAME sensor coordinate in every frame, while
anything in the scene moves when the camera does. So the verdict needs several
frames of DIFFERENT scenes.

Two things this deliberately refuses to do:

  * It will not attribute across different lenses. Lightroom applies a lens
    distortion profile before we ever see the pixels, and the profiles differ per
    lens. On the reference pair that produced a purely radial displacement of up
    to 0.024 of frame width, growing with distance from centre -- exactly the
    signature of "the spot moved, so it must be on the lens". Comparing corrected
    coordinates across lenses gives the wrong answer confidently.

  * It will not call something sensor dirt versus lens dirt. Both are fixed in
    sensor coordinates for a given lens; telling them apart needs frames from the
    same lens mounted differently, or the lens profile neutralised. Saying
    "persistent" is honest; saying "sensor" would not be.

Input is a manifest: a JSON list of frames.

    [
      {"image": "/tmp/x/DSC02993.jpg", "scene": "falls",
       "lens": "E PZ 16-50mm F3.5-5.6 OSS", "crop": [0.078, 0.922, 0.0, 1.0]},
      ...
    ]

`scene` groups frames that show the same subject from the same spot: consecutive
frames of one subject share a scene id. Recurrence WITHIN one scene proves
nothing, because the pebble is still there too.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict

try:
    from detect_dust import detect
except ImportError:  # running from another directory
    sys.path.insert(0, __file__.rsplit("/", 1)[0].rsplit("\\", 1)[0])
    from detect_dust import detect

MATCH_TOLERANCE = 0.012   # fraction of frame width; ~72px on a 6000px frame
MIN_SCENES = 2            # a candidate must recur across at least this many scenes

# Two frames only count as independent evidence when they show DIFFERENT things
# at the position in question. Scene tags are supplied by the caller and are
# routinely too optimistic: two frames seventeen minutes apart from the same
# viewpoint carry the same skyline and the same clouds, and a cloud gap then
# "recurs across scenes" exactly like dust would. Measured on a real pair, that
# produced four confident false positives in a row at the same height.
#
# So the background is compared directly. If the surroundings correlate above
# this, the second frame has added nothing.
MIN_PATCH_CONTRAST = 0.005
# Measured patch contrast: clear sky around real dust came to 0.0093-0.0100,
# while the cloud and skyline patches that produced false positives came to
# 0.26-0.28 -- a factor of nearly thirty, so the line is not delicate. It sits
# below clear sky on purpose: there the check is informative (it measured 0.16
# and 0.28 for genuinely different viewpoints) and worth running.
# The background check only means something when there IS a background. Over a
# clear sky the patches hold nothing but a gentle gradient, two unrelated frames
# then correlate above 0.9, and the check would throw away real dust in precisely
# the conditions where dust is easiest to see. A featureless patch cannot testify
# that two viewpoints are the same, so it is not asked to.

BACKGROUND_SIMILAR = 0.50
# REPORTED, NOT ENFORCED, and that is a deliberate retreat. As a gate this was
# tried three ways and none held: comparing raw patches caught the false
# positives (0.67-0.80) but scored two unrelated clear skies at 0.91, because
# both carry the same smooth gradient -- it would have thrown away real dust in
# the conditions dust is easiest to see. Removing the fitted plane fixed the sky
# and lost the false positives (0.26 and below). No threshold separated both
# cases, so the number is surfaced for a human to weigh instead of being used to
# silently delete findings.
#
# The defence that DOES hold is the scene tags. Given genuinely different
# viewpoints the pipeline returned nothing on a frame set with no dust, with or
# without this check.
PATCH_RADII = 4.0         # patch half-size, in blob radii


def _background_patch(frame, x_sensor, y_sensor, radius, cache):
    """The neighbourhood of a sensor position, as that frame renders it."""
    try:
        import numpy as np
        from PIL import Image
    except ImportError:  # pragma: no cover
        return None
    path = frame["image"]
    if path not in cache:
        cache[path] = np.asarray(Image.open(path).convert("L"), dtype=np.float32) / 255.0
    grey = cache[path]
    height, width = grey.shape

    crop = frame.get("crop")
    if crop:
        top, bottom, left, right = crop
        if right <= left or bottom <= top:
            return None
        fx = (x_sensor - left) / (right - left)
        fy = (y_sensor - top) / (bottom - top)
    else:
        fx, fy = x_sensor, y_sensor
    if not (0.0 <= fx < 1.0 and 0.0 <= fy < 1.0):
        return None

    half = max(12, int(PATCH_RADII * radius * width))
    cx, cy = int(fx * width), int(fy * height)
    if not (half <= cx < width - half and half <= cy < height - half):
        return None
    patch = grey[cy - half:cy + half, cx - half:cx + half]
    # Compare at a coarse size: the question is whether the SCENE repeats, not
    # whether the noise does.
    step = max(1, patch.shape[0] // 32)
    return patch[::step, ::step]


def _correlation(a, b):
    """How alike the two neighbourhoods are, as a number to report.

    Only the mean is removed. Subtracting a fitted plane as well was tried, to
    stop two clear skies correlating through their shared gradient, but it also
    flattened the cloud and skyline structure that made the measure useful in the
    first place: the separation between same-viewpoint and different-viewpoint
    collapsed from 0.67-0.80 against 0.16-0.28 down to 0.26 against 0.21. Since
    the number is advisory, the version that discriminates is the better one.
    """
    import numpy as np
    if a is None or b is None:
        return None
    size = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
    a, b = a[:size[0], :size[1]].ravel(), b[:size[0], :size[1]].ravel()
    a, b = a - a.mean(), b - b.mean()
    if min(float(a.std()), float(b.std())) < MIN_PATCH_CONTRAST:
        return None          # nothing to compare: see MIN_PATCH_CONTRAST
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denominator < 1e-9:
        return None
    return float(np.dot(a, b) / denominator)


def _to_sensor(spot, crop):
    """Normalised position in the ORIGINAL frame, undoing the crop."""
    if not crop:
        return spot["x"], spot["y"]
    top, bottom, left, right = crop
    return (left + spot["x"] * (right - left), top + spot["y"] * (bottom - top))


def correlate(frames, k=6.0, tolerance=MATCH_TOLERANCE, min_scenes=MIN_SCENES):
    observations = []
    lenses = set()
    orientations = set()
    for frame in frames:
        result = detect(frame["image"], k=k)
        lens = frame.get("lens")
        if lens:
            lenses.add(lens)
        # Portrait and landscape frames put the same sensor position at
        # transposed coordinates, so mixing them compares nothing. Taken from
        # `orientation` in get_develop_settings, or inferred from the shape.
        orientations.add(frame.get("orientation")
                         or ("portrait" if result["size"][1] > result["size"][0]
                             else "landscape"))
        for spot in result.get("spots", []):
            x, y = _to_sensor(spot, frame.get("crop"))
            observations.append({
                "x": x, "y": y,
                "score": spot["score"], "r": spot["r"],
                "scene": frame.get("scene", frame["image"]),
                "file": result["file"],
                "frame": frame,
            })

    # Greedy single-link clustering, strongest observation first.
    observations.sort(key=lambda o: -o["score"])
    clusters = []
    for obs in observations:
        for cluster in clusters:
            if (abs(obs["x"] - cluster["x"]) < tolerance
                    and abs(obs["y"] - cluster["y"]) < tolerance):
                cluster["members"].append(obs)
                n = len(cluster["members"])
                cluster["x"] += (obs["x"] - cluster["x"]) / n
                cluster["y"] += (obs["y"] - cluster["y"]) / n
                break
        else:
            clusters.append({"x": obs["x"], "y": obs["y"], "members": [obs]})

    mixed_lenses = len(lenses) > 1
    patch_cache = {}
    verdicts = []
    for cluster in clusters:
        scenes = {m["scene"] for m in cluster["members"]}
        files = sorted({m["file"] for m in cluster["members"]})
        background = None
        if len(scenes) >= min_scenes:
            # One representative frame per scene, then the strongest resemblance
            # between any two of them.
            representatives = {}
            for member in cluster["members"]:
                representatives.setdefault(member["scene"], member)
            radius = max(m["r"] for m in cluster["members"])
            patches = [
                _background_patch(m["frame"], cluster["x"], cluster["y"], radius, patch_cache)
                for m in representatives.values()
            ]
            similarities = [
                c for c in (
                    _correlation(patches[i], patches[j])
                    for i in range(len(patches)) for j in range(i + 1, len(patches))
                ) if c is not None
            ]
            background = max(similarities) if similarities else None

        warning = None
        if len(scenes) >= min_scenes:
            verdict = "persistent"
            why = ("present at the same sensor position in {} different scenes: "
                   "fixed relative to the camera, not to the subject".format(len(scenes)))
            if background is not None and background > BACKGROUND_SIMILAR:
                warning = (
                    "the frames tagged as different scenes look alike here "
                    "(background correlation {:.2f}). If they were taken from the "
                    "same viewpoint they are not independent, and this may be a "
                    "feature of the scene rather than dust."
                ).format(background)
        elif len(files) > 1:
            verdict = "inconclusive"
            why = ("repeats only within one scene, so a stationary object in the "
                   "frame explains it just as well")
        else:
            verdict = "single-frame"
            why = "seen once; could be anything dark and small"
        verdicts.append({
            "x": round(cluster["x"], 4),
            "y": round(cluster["y"], 4),
            "r": round(max(m["r"] for m in cluster["members"]), 4),
            "verdict": verdict,
            "why": why,
            "scenes": sorted(scenes),
            "files": files,
            "best_score": round(max(m["score"] for m in cluster["members"]), 1),
            "background_similarity": (None if background is None else round(background, 2)),
            "warning": warning,
        })

    verdicts.sort(key=lambda v: (v["verdict"] != "persistent", -v["best_score"]))
    out = {
        "frames": len(frames),
        "scenes": sorted({f.get("scene", f["image"]) for f in frames}),
        "lenses": sorted(lenses),
        "tolerance": tolerance,
        "persistent": [v for v in verdicts if v["verdict"] == "persistent"],
        "all": verdicts,
    }
    if len(orientations) > 1:
        out["orientation_error"] = (
            "frames are not all in the same orientation ({}). A portrait frame "
            "puts the same sensor position at transposed coordinates, so these "
            "results cannot be compared. Group the frames by orientation and run "
            "each group separately."
        ).format(", ".join(sorted(orientations)))
        out["persistent"] = []
    if mixed_lenses:
        out["attribution_warning"] = (
            "frames come from more than one lens. Lightroom applies a per-lens "
            "distortion profile before export, which shifts a FIXED spot radially "
            "by up to ~0.024 of frame width. Positions across these lenses are not "
            "comparable; group by lens, or disable lens corrections before export."
        )
    if not out["persistent"]:
        out["note"] = (
            "nothing recurred across scenes. Either the frames share one scene, or "
            "there is no dust -- this tool cannot tell those apart."
        )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("manifest", help="JSON list of frames (see module docstring)")
    parser.add_argument("-k", type=float, default=6.0)
    parser.add_argument("--tolerance", type=float, default=MATCH_TOLERANCE)
    parser.add_argument("--min-scenes", type=int, default=MIN_SCENES)
    args = parser.parse_args(argv)

    with open(args.manifest, "r", encoding="utf-8") as handle:
        frames = json.load(handle)
    if not isinstance(frames, list) or not frames:
        parser.error("manifest must be a non-empty JSON list")

    print(json.dumps(
        correlate(frames, args.k, args.tolerance, args.min_scenes), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
