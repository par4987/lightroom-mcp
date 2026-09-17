#!/usr/bin/env python3
"""How far the shadows can be lifted before the photo breaks.

Raising Exposure or Shadows multiplies whatever noise is already in the dark
parts of the frame. The amount of headroom is a property of THIS photo -- its
ISO, its exposure, the noise reduction already applied -- so it has to be
measured, not guessed from the ISO number alone.

Method: noise is the fine-scale energy that survives in areas with no structure.
Detail at sigma 3 separates noise from content; a robust (MAD) scale per
luminance band then ignores the edges and specks that slip through. The estimate
is taken per band because noise is not uniform: shadows are always worse, and
shadows are exactly what gets lifted.

Read the numbers for what they are: this measures the RENDERED image, after
Lightroom's demosaic and default noise reduction. That is the right thing to
measure when the question is "will this look broken", and the wrong thing if the
question is about raw sensor performance.

Dependencies: numpy and pillow.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    sys.exit(
        "missing dependency: {}\n"
        "install with:  python -m pip install numpy pillow".format(exc.name)
    )

sys.path.insert(0, __file__.replace("\\", "/").rsplit("/", 1)[0])
from detect_dust import _box2d, _mad_sigma, gaussian  # noqa: E402

WORK_WIDTH = 2000
FINE_SIGMA = 3.0
STRUCTURE_WIN = 31
STRUCTURE_SIGMA = 4.0   # structure is measured on a DE-NOISED copy. Measuring it
                        # on the raw pixels makes noise itself read as structure,
                        # so the noisiest photos look the most textured.
STRUCTURE_MAX = 0.010   # ABSOLUTE ceiling. This used to be "the flattest 40% of
                        # the frame", which always selects 40% however textured
                        # the photo is: on a telephoto river shot it picked the
                        # gaps BETWEEN branches and called them flat shadow,
                        # reporting 0.0142 of noise where an absolute gate
                        # measures 0.011 and says most of the shadow is foliage.
BANDS = ((0.00, 0.10, "black"), (0.10, 0.25, "deep shadow"),
         (0.25, 0.45, "shadow"), (0.45, 0.70, "midtone"), (0.70, 1.01, "highlight"))

# Above this, fine grain in a smooth area reads as "broken" rather than "grainy"
# at normal viewing size -- about 4.6 levels out of 255. This is a PERCEPTUAL
# JUDGEMENT, not a measurement, and it is the one number here worth arguing
# about. It is exposed as a constant so it can be argued with.
#
# The model behind the headroom is deliberately crude and pessimistic: lifting by
# E stops is treated as multiplying noise by 2**E. Lightroom's Shadows slider is
# not a linear gain and perceived grain does not track amplitude exactly, so real
# headroom is usually a little better than what comes out here. Err that way on
# purpose: over-processing is the failure mode an amateur cannot spot.
VISIBLE_NOISE = 0.018
MIN_BAND_PX = 2000


def _structure_mask(grey, radius, scale=1.0):
    """True where the neighbourhood holds no real content, only noise.

    Without this the estimate counts foliage and fabric as noise and declares
    every detailed photo unliftable. With a RELATIVE threshold it does the same
    thing more quietly, because some fixed share of the frame always qualifies.
    """
    smooth = gaussian(grey, max(1.0, STRUCTURE_SIGMA * scale))
    mean = _box2d(smooth, radius)
    variance = np.maximum(_box2d(smooth * smooth, radius) - mean * mean, 0.0)
    return np.sqrt(variance) < STRUCTURE_MAX


def estimate(path):
    image = Image.open(path).convert("L")
    full_width, full_height = image.size
    scale = min(1.0, float(WORK_WIDTH) / full_width)
    if scale < 1.0:
        image = image.resize(
            (int(full_width * scale), int(full_height * scale)), Image.LANCZOS)
    grey = np.asarray(image, dtype=np.float32) / 255.0

    detail = grey - gaussian(grey, max(1.0, FINE_SIGMA * scale))
    flat = _structure_mask(grey, max(1, int(STRUCTURE_WIN * scale) // 2), scale)

    bands = []
    shadow_sigma = None
    thin_shadow = False
    for low, high, label in BANDS:
        in_band = (grey >= low) & (grey < high)
        selected = flat & in_band
        count = int(selected.sum())
        band_px = int(in_band.sum())
        # What FRACTION of the band was flat enough to measure. A low share means
        # the band is mostly detail, and the number that follows describes a few
        # scraps rather than the shadows as a whole.
        flat_share = round(count / band_px, 3) if band_px else 0.0
        if count < MIN_BAND_PX:
            bands.append({"band": label, "range": [low, round(high, 2)],
                          "pixels": count, "flat_share": flat_share, "noise": None,
                          "note": "too little flat area here to measure"})
            continue
        sigma = _mad_sigma(detail[selected])
        bands.append({"band": label, "range": [low, round(high, 2)],
                      "pixels": count, "flat_share": flat_share,
                      "noise": round(float(sigma), 5)})
        if label in ("deep shadow", "shadow"):
            shadow_sigma = max(shadow_sigma or 0.0, float(sigma))
            if flat_share < 0.10:
                thin_shadow = True

    result = {
        "file": path.replace("\\", "/").rsplit("/", 1)[-1],
        "size": [full_width, full_height],
        "bands": bands,
        "visible_noise_threshold": VISIBLE_NOISE,
    }

    # `is None`, not falsiness: a measured noise of exactly 0.0 means perfectly
    # clean shadows, which is the best possible answer, not a failed measurement.
    if shadow_sigma is None:
        result["headroom_stops"] = None
        result["advice"] = (
            "no flat shadow area large enough to measure. Lift carefully and "
            "judge by eye; this photo gives the measurement nothing to work with."
        )
        return result

    # Lifting by E stops multiplies the signal, and the noise with it.
    headroom = math.log2(VISIBLE_NOISE / shadow_sigma) if shadow_sigma > 0 else 4.0
    headroom = max(-2.0, min(4.0, headroom))
    result["shadow_noise"] = round(shadow_sigma, 5)
    result["headroom_stops"] = round(headroom, 2)
    if thin_shadow:
        result["confidence"] = "low"
        result["confidence_note"] = (
            "under 10% of the shadow band was flat enough to measure, so this "
            "figure comes from scraps between detail. Treat it as a hint and "
            "check the result by eye."
        )

    if headroom >= 2.0:
        result["advice"] = (
            "clean shadows: about {:.1f} stops of lift before grain becomes "
            "objectionable. No noise reduction needed for a normal edit."
        ).format(headroom)
    elif headroom >= 0.75:
        result["advice"] = (
            "about {:.1f} stops of lift available. Past that, raise "
            "set_noise_reduction luminance alongside the lift rather than after it."
        ).format(headroom)
    elif headroom > 0.0:
        # There IS room here, just very little. Saying "this will break" of a
        # photo that can take half a stop is the same kind of wrong as saying it
        # can take three.
        result["advice"] = (
            "barely any room: about {:.1f} stops. Lift that far at most, and "
            "raise set_noise_reduction luminance in the same edit rather than "
            "afterwards."
        ).format(headroom)
    else:
        result["advice"] = (
            "shadows are already at or past the visible-noise limit ({:.3f} vs "
            "{:.3f}). Lifting them will break the photo. Recover highlights and "
            "contrast instead, or run ai_denoise first and measure again."
        ).format(shadow_sigma, VISIBLE_NOISE)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("image", help="JPEG/TIFF exported from Lightroom")
    args = parser.parse_args(argv)
    print(json.dumps(estimate(args.image), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
