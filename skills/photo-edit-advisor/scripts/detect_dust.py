#!/usr/bin/env python3
"""Detect sensor/lens dust in a photo exported at full resolution.

Dust is a soft DARK blob on a SMOOTH BRIGHT background. All three conditions are
load-bearing. Darkness alone finds foliage and gravel; smoothness alone finds
sky; without the brightness gate every shadow qualifies.

Why a scale-space Laplacian and not a threshold on a high-pass: the blob profile
is gradual, so any threshold near the noise floor leaves a core of a few pixels
and a size filter then discards the real spot. Measured on a reference frame,
the threshold-and-label approach returned 64 detections in river foam and NONE
of the three actual dust spots. A normalised Laplacian-of-Gaussian responds to
the blob as a whole and peaks at the scale matching its radius, which also
recovers the radius for free.

The noise scale is measured INSIDE the smooth+bright gate, never over the whole
frame. Measuring it globally puts the threshold about 5x above the signal, which
is the single mistake that makes this method look like it does not work.

Coordinates come out in the frame of the image passed in. If that image was
exported from a CROPPED photo, pass --crop so results are also reported in the
original sensor frame -- the only space in which spots from different photos are
comparable.

Dependencies: numpy and pillow. Deliberately not scipy.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover - environment problem, not logic
    sys.exit(
        "missing dependency: {}\n"
        "install with:  python -m pip install numpy pillow".format(exc.name)
    )

# --- tuning, all in pixels of a full-resolution frame -----------------------

SCALES = (9.0, 13.0, 18.0, 25.0, 35.0)
# Below sigma 9 the responses are birds, hot pixels and JPEG artifacts, not dust
# at any aperture a photographer would use.

ROUGH_WIN = 61        # window for the local-roughness estimate
FINE_SIGMA = 3.0      # roughness is measured as FINE-scale detail energy, not as
                      # plain local standard deviation. A plain std counts the
                      # dust blob itself as roughness, so a well-marked spot
                      # gates ITSELF out and only a ring around it survives --
                      # which is exactly what the detector then reports. Measured
                      # over a real spot: std 0.0078 vs clean sky 0.0045, against
                      # fine-detail 0.0044 vs 0.0040. Texture has energy at this
                      # scale (foam 0.079, foliage 0.013); a soft blob has none.
ROUGH_MAX = 0.010     # ABSOLUTE ceiling for "smooth". Scaling it by a global
                      # sigma lets textured bright areas in, and they then
                      # dominate the very statistic the threshold depends on.
BRIGHT_MIN = 0.30     # dust is not observable in dark parts of the scene
BRIGHT_SIGMA = 30.0
NMS_RADIUS = 30       # px floor; the real radius scales with the accepted blob,
                      # because one spot answers at several scales at once and a
                      # fixed radius reports the same dust two or three times
WORK_WIDTH = 3000     # the scale space runs here, not at full resolution: dust
                      # at sigma >= 9 is still well resolved at half size, and
                      # centroid precision stays inside the 3.6px repeatability
                      # measured between consecutive frames
MIN_GATE_PX = 20000   # below this there is no usable smooth region at all
MIN_RESPONSE = 0.003  # absolute floor, on top of the k-sigma threshold. Over a
                      # genuinely flat sky the robust sigma collapses to the
                      # sensor noise, and then 6 sigma is smaller than an 8-bit
                      # quantisation step or a JPEG block edge -- the detector
                      # starts reporting the compressor. Dust worth removing is
                      # at least ~0.01 deep and the matched response runs about
                      # 0.4 of depth, so this floor sits just under real dust.
DOG_K = 1.6           # Difference-of-Gaussians stand-in for the Laplacian
EDGE_RATIO_MAX = 7.2  # (r+1)^2/r with r=5: reject responses whose two principal
                      # curvatures differ by more than 5x. A Laplacian answers
                      # strongly along RIDGES as well as blobs, so without this
                      # the detector reports cloud edges, mountain skylines and
                      # -- measured, on a real frame -- the sun. Dust is round,
                      # so its two curvatures are nearly equal. This is the same
                      # test SIFT uses to drop edge keypoints, at a tighter
                      # threshold because dust is rounder than a generic feature.
EDGE_MARGIN = int(2 * max(SCALES))
# The blur pads by edge replication, so the outermost rows and columns carry a
# bias that the scale space reads as a large, shallow dark blob. Every frame in
# the reference batch produced one of these at y=0. They are an artefact of the
# filter, not of the lens, so they are excluded rather than reported.


# --- separable box blur, and a gaussian built from three of them ------------
# A box blur costs the same at any radius, so a sigma-35 blur over a 24Mpx frame
# stays cheap. Three passes approximate a gaussian closely enough for blob
# detection; this is what lets the script drop scipy.

def _slice_along(ndim, axis, start, stop):
    key = [slice(None)] * ndim
    key[axis] = slice(start, stop)
    return tuple(key)


def _box1d(a, radius, axis):
    if radius <= 0:
        return a
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (radius, radius)
    padded = np.pad(a, pad, mode="edge")
    cumulative = np.cumsum(padded, axis=axis, dtype=np.float64)
    lead = list(cumulative.shape)
    lead[axis] = 1
    cumulative = np.concatenate([np.zeros(lead), cumulative], axis=axis)
    width = 2 * radius + 1
    # Plain slicing, not np.take with an index array: fancy indexing copies and
    # is several times slower on a 24Mpx frame, which is the whole budget here.
    hi = cumulative[_slice_along(a.ndim, axis, width, width + n)]
    lo = cumulative[_slice_along(a.ndim, axis, 0, n)]
    return ((hi - lo) / width).astype(np.float32)


def _box2d(a, radius):
    return _box1d(_box1d(a, radius, 0), radius, 1)


def _box_widths(sigma, passes=3):
    """Box widths whose repeated application approximates a gaussian."""
    ideal = math.sqrt((12.0 * sigma * sigma / passes) + 1.0)
    lower = int(math.floor(ideal))
    if lower % 2 == 0:
        lower -= 1
    lower = max(lower, 1)
    upper = lower + 2
    m = round(
        (12.0 * sigma * sigma - passes * lower * lower - 4.0 * passes * lower - 3.0 * passes)
        / (-4.0 * lower - 4.0)
    )
    return [lower if i < m else upper for i in range(passes)]


def gaussian(a, sigma):
    out = a
    for width in _box_widths(sigma):
        out = _box2d(out, max(0, (width - 1) // 2))
    return out


def _is_edge_response(response, y, x, work_sigma):
    """True when the peak lies on a ridge rather than on a round blob.

    The two principal curvatures of the response are compared through the
    trace and determinant of the Hessian, so no eigenvalue solve is needed.
    On a ridge one curvature is near zero, the determinant collapses and the
    ratio blows up; on a round blob the two are nearly equal and the ratio sits
    near 4.
    """
    height, width = response.shape
    step = max(2, int(round(0.7 * work_sigma)))
    if not (step <= y < height - step and step <= x < width - step):
        return True                      # too close to the border to judge
    centre = float(response[y, x])
    dxx = float(response[y, x + step]) - 2.0 * centre + float(response[y, x - step])
    dyy = float(response[y + step, x]) - 2.0 * centre + float(response[y - step, x])
    dxy = (float(response[y + step, x + step]) - float(response[y + step, x - step])
           - float(response[y - step, x + step]) + float(response[y - step, x - step])) / 4.0
    trace = dxx + dyy
    determinant = dxx * dyy - dxy * dxy
    if determinant <= 0.0:
        return True                      # saddle: not a blob at all
    return (trace * trace / determinant) > EDGE_RATIO_MAX


def _mad_sigma(values):
    """Robust scale. The median absolute deviation ignores the spots themselves,
    which a plain standard deviation would fold into the noise estimate."""
    median = float(np.median(values))
    return 1.4826 * float(np.median(np.abs(values - median)))


def detect(path, k=6.0, crop=None, max_spots=40):
    """Find dust blobs.

    `crop` is (top, bottom, left, right) exactly as Lightroom stores CropTop /
    CropBottom / CropLeft / CropRight: fractions of the ORIGINAL frame.
    """
    image = Image.open(path).convert("L")
    full_width, full_height = image.size
    # Every tuning constant above is expressed in FULL-resolution pixels; scale
    # them once here so the working resolution never changes what is detected.
    scale = min(1.0, float(WORK_WIDTH) / full_width)
    width, height = max(1, int(full_width * scale)), max(1, int(full_height * scale))
    if scale < 1.0:
        image = image.resize((width, height), Image.LANCZOS)
    grey = np.asarray(image, dtype=np.float32) / 255.0

    rough_radius = max(1, int(ROUGH_WIN * scale) // 2)
    edge_margin = max(1, int(EDGE_MARGIN * scale))

    detail = grey - gaussian(grey, max(1.0, FINE_SIGMA * scale))
    roughness = np.sqrt(np.maximum(_box2d(detail * detail, rough_radius), 0.0))
    gate = (roughness < ROUGH_MAX) & (gaussian(grey, BRIGHT_SIGMA * scale) > BRIGHT_MIN)
    if height > 2 * edge_margin and width > 2 * edge_margin:
        interior = np.zeros_like(gate)
        interior[edge_margin:-edge_margin, edge_margin:-edge_margin] = True
        gate &= interior

    result = {
        "file": path.replace("\\", "/").rsplit("/", 1)[-1],
        "size": [full_width, full_height],
        "work_scale": round(scale, 3),
        "gate_fraction": round(float(gate.mean()), 4),
    }
    if int(gate.sum()) < MIN_GATE_PX:
        result.update(
            count=0,
            spots=[],
            note="no smooth bright region -- dust is not observable in this frame",
        )
        return result

    # Scale space. Difference of Gaussians stands in for the scale-normalised
    # Laplacian: DoG ~= (k-1) * sigma^2 * laplacian(G), so dividing by (k-1)
    # gives a response comparable across scales. It is POSITIVE over a dark blob.
    best = np.full((height, width), -np.inf, dtype=np.float32)
    best_sigma = np.zeros((height, width), dtype=np.float32)
    for sigma in SCALES:
        work_sigma = sigma * scale
        response = (
            gaussian(grey, work_sigma * DOG_K) - gaussian(grey, work_sigma)
        ) / (DOG_K - 1.0)
        better = response > best
        best[better] = response[better]
        best_sigma[better] = sigma   # recorded in FULL-resolution pixels

    sigma_noise = _mad_sigma(best[gate])
    threshold = max(k * sigma_noise, MIN_RESPONSE)
    result["threshold_source"] = (
        "absolute floor" if MIN_RESPONSE > k * sigma_noise else "k * sigma"
    )

    candidates = gate & (best > threshold)
    ys, xs = np.nonzero(candidates)
    result["sigma"] = round(sigma_noise, 6)
    result["threshold"] = round(threshold, 6)
    if ys.size == 0:
        result.update(count=0, spots=[])
        return result

    scores = best[ys, xs]
    order = np.argsort(-scores)[:20000]

    # Greedy non-maximum suppression: walk peaks strongest first and drop any
    # that falls inside an already accepted spot.
    edge_rejected = 0
    kept = []
    for index in order:
        y, x, score = int(ys[index]), int(xs[index]), float(scores[index])
        sigma_full = float(best_sigma[y, x])
        radius = sigma_full * math.sqrt(2) * scale
        if _is_edge_response(best, y, x, sigma_full * scale):
            edge_rejected += 1
            continue
        # Two blobs overlap when they are closer than the sum of their radii, so
        # the guard has to account for BOTH. Using only the accepted spot's
        # radius lets a wide, shallow secondary response sitting on the flank of
        # a strong spot through, and the same dust gets reported three times.
        if any(
            (x - kx) ** 2 + (y - ky) ** 2 < max(NMS_RADIUS, kr + radius) ** 2
            for kx, ky, _, _, kr in kept
        ):
            continue
        kept.append((x, y, score, sigma_full, radius))
        if len(kept) >= max_spots:
            break

    spots = []
    for x, y, score, sigma, _radius in kept:
        spot = {
            "x": round(x / width, 4),
            "y": round(y / height, 4),
            "r": round(sigma * math.sqrt(2) / full_width, 4),
            "r_px": round(sigma * math.sqrt(2), 1),
            "score": round(score / sigma_noise, 1),
        }
        if crop:
            top, bottom, left, right = crop
            spot["x_orig"] = round(left + spot["x"] * (right - left), 4)
            spot["y_orig"] = round(top + spot["y"] * (bottom - top), 4)
        spots.append(spot)

    result.update(count=len(spots), spots=spots, edge_rejected=edge_rejected)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("image", help="full-resolution JPEG/TIFF exported from Lightroom")
    parser.add_argument("-k", type=float, default=6.0,
                        help="threshold in robust sigmas (default 6; lower finds more)")
    parser.add_argument("--crop", default=None,
                        help="CropTop,CropBottom,CropLeft,CropRight from get_develop_settings, "
                             "so results are also reported in the original sensor frame")
    parser.add_argument("--max-spots", type=int, default=40)
    args = parser.parse_args(argv)

    crop = None
    if args.crop:
        parts = [float(v) for v in args.crop.split(",")]
        if len(parts) != 4:
            parser.error("--crop needs exactly 4 numbers: top,bottom,left,right")
        crop = (parts[0], parts[1], parts[2], parts[3])

    print(json.dumps(detect(args.image, args.k, crop, args.max_spots), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
