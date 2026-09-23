"""Tests for the dust detection scripts.

The fixtures are SYNTHETIC on purpose: a real photo would make these tests a
regression lock on one camera, and would not say whether the method works. Here
the ground truth is known exactly, so a failure means the algorithm changed, not
that a JPEG was re-encoded.
"""

import json
import math
import os
import sys
import tempfile
import unittest

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    raise unittest.SkipTest("needs numpy and pillow: {}".format(exc))

import correlate_dust
import detect_dust
import estimate_noise


WIDTH, HEIGHT = 1400, 900


def synthetic_frame(path, blobs, seed=0, texture=False, background=0.62, ridges=()):
    """A flat bright field with gaussian dark blobs, saved as a JPEG.

    `blobs` is a list of (x_fraction, y_fraction, sigma_px, depth).
    `ridges` is a list of (x_fraction, y_fraction, sigma_px, depth) drawn as long
    horizontal bars -- the shape a cloud edge or a skyline presents, which a
    Laplacian answers to just as strongly as it does to a blob.
    """
    rng = np.random.default_rng(seed)
    ys, xs = np.mgrid[0:HEIGHT, 0:WIDTH]
    field = np.full((HEIGHT, WIDTH), background, dtype=np.float64)
    # A gentle gradient, like a real sky: the detector must not read it as signal.
    field -= 0.05 * (ys / HEIGHT)
    if texture:
        coarse = rng.normal(0, 0.09, (HEIGHT // 8 + 1, WIDTH // 8 + 1))
        field += np.kron(coarse, np.ones((8, 8)))[:HEIGHT, :WIDTH]
    for fx, fy, sigma, depth in ridges:
        cy = fy * HEIGHT
        field -= depth * np.exp(-((ys - cy) ** 2) / (2.0 * sigma ** 2))
    for fx, fy, sigma, depth in blobs:
        cx, cy = fx * WIDTH, fy * HEIGHT
        field -= depth * np.exp(-(((xs - cx) ** 2 + (ys - cy) ** 2) / (2.0 * sigma ** 2)))
    field += rng.normal(0, 0.004, field.shape)
    Image.fromarray(
        (np.clip(field, 0, 1) * 255).astype(np.uint8)
    ).save(path, quality=95)
    return path


class BlurTest(unittest.TestCase):
    def test_box_widths_are_odd_and_track_sigma(self):
        for sigma in (2.0, 9.0, 35.0):
            widths = detect_dust._box_widths(sigma)
            self.assertEqual(len(widths), 3)
            for width in widths:
                self.assertEqual(width % 2, 1, "box width must be odd")
            self.assertGreater(max(widths), sigma)

    def test_gaussian_preserves_mean(self):
        a = np.random.default_rng(1).random((200, 260)).astype(np.float32)
        blurred = detect_dust.gaussian(a, 8.0)
        self.assertAlmostEqual(float(a.mean()), float(blurred.mean()), places=3)

    def test_gaussian_spreads_a_point(self):
        a = np.zeros((201, 201), dtype=np.float32)
        a[100, 100] = 1.0
        blurred = detect_dust.gaussian(a, 10.0)
        # Mass is conserved and the peak is at the impulse.
        self.assertAlmostEqual(float(blurred.sum()), 1.0, places=2)
        self.assertEqual(np.unravel_index(int(np.argmax(blurred)), blurred.shape), (100, 100))

    def test_mad_sigma_ignores_outliers(self):
        values = np.concatenate([np.random.default_rng(2).normal(0, 1.0, 10000),
                                 np.full(300, 50.0)])
        self.assertLess(detect_dust._mad_sigma(values), 1.2)


class DetectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def test_finds_planted_blobs(self):
        planted = [(0.30, 0.35, 16.0, 0.05), (0.62, 0.55, 20.0, 0.06)]
        image = synthetic_frame(self.path("a.jpg"), planted)
        result = detect_dust.detect(image, k=6.0)
        self.assertGreaterEqual(result["count"], len(planted))
        for fx, fy, _, _ in planted:
            self.assertTrue(
                any(abs(s["x"] - fx) < 0.02 and abs(s["y"] - fy) < 0.02
                    for s in result["spots"]),
                "no detection near planted blob ({}, {}): got {}".format(
                    fx, fy, [(s["x"], s["y"]) for s in result["spots"]]),
            )

    def test_clean_frame_reports_nothing(self):
        image = synthetic_frame(self.path("clean.jpg"), [])
        self.assertEqual(detect_dust.detect(image, k=6.0)["count"], 0)

    def test_textured_frame_is_gated_out(self):
        image = synthetic_frame(self.path("rough.jpg"), [(0.5, 0.5, 16.0, 0.05)],
                                texture=True)
        result = detect_dust.detect(image, k=6.0)
        # Texture must not be mistaken for dust: either the gate closes entirely
        # or nothing survives the threshold.
        self.assertEqual(result["count"], 0, result.get("spots"))

    def test_dark_frame_is_gated_out(self):
        image = synthetic_frame(self.path("dark.jpg"), [(0.5, 0.5, 16.0, 0.05)],
                                background=0.12)
        result = detect_dust.detect(image, k=6.0)
        self.assertEqual(result["count"], 0)
        self.assertIn("note", result)

    def test_edge_artifacts_are_not_reported(self):
        image = synthetic_frame(self.path("edge.jpg"), [])
        for spot in detect_dust.detect(image, k=4.0)["spots"]:
            self.assertGreater(spot["y"], 0.0)
            self.assertLess(spot["y"], 1.0)

    def test_one_blob_is_reported_once(self):
        image = synthetic_frame(self.path("single.jpg"), [(0.45, 0.45, 22.0, 0.07)])
        spots = detect_dust.detect(image, k=6.0)["spots"]
        near = [s for s in spots if abs(s["x"] - 0.45) < 0.06 and abs(s["y"] - 0.45) < 0.06]
        self.assertEqual(len(near), 1, "a blob answers at several scales: {}".format(near))

    def test_crop_maps_into_the_sensor_frame(self):
        # y=0.30, deliberately NOT 0.5: a symmetric crop maps the midline onto
        # itself, so a blob at 0.5 would pass this test even if the mapping were
        # dropped entirely.
        image = synthetic_frame(self.path("crop.jpg"), [(0.30, 0.30, 18.0, 0.06)])
        crop = (0.078, 0.922, 0.0, 1.0)
        result = detect_dust.detect(image, k=6.0, crop=crop)
        spot = min(result["spots"], key=lambda s: abs(s["x"] - 0.30) + abs(s["y"] - 0.30))
        self.assertAlmostEqual(spot["x_orig"], spot["x"], places=4)
        self.assertAlmostEqual(spot["y_orig"], 0.078 + spot["y"] * 0.844, places=4)
        # Cropping the top off pushes everything DOWN the original frame.
        self.assertGreater(spot["y_orig"], spot["y"])

    def test_lower_k_is_never_more_selective(self):
        image = synthetic_frame(self.path("k.jpg"), [(0.35, 0.40, 16.0, 0.04)])
        loose = detect_dust.detect(image, k=3.0)["count"]
        tight = detect_dust.detect(image, k=9.0)["count"]
        self.assertGreaterEqual(loose, tight)

    def test_ridges_are_not_reported_as_dust(self):
        """A Laplacian answers to lines as loudly as to blobs.

        Without a shape test the detector reports cloud edges and skylines. On a
        real frame it reported the sun and four stretches of cloud, all in a row
        at the same height, and the cross-frame check then confirmed them because
        the two "scenes" were one viewpoint.
        """
        image = synthetic_frame(self.path("ridge.jpg"), [],
                                ridges=[(0.5, 0.35, 14.0, 0.07)])
        result = detect_dust.detect(image, k=6.0)
        self.assertEqual(result["count"], 0, result["spots"])
        self.assertGreater(result.get("edge_rejected", 0), 0,
                           "the ridge should have been seen and then rejected")

    def test_a_blob_beside_a_ridge_still_survives(self):
        image = synthetic_frame(self.path("both.jpg"), [(0.30, 0.70, 18.0, 0.06)],
                                ridges=[(0.5, 0.25, 14.0, 0.07)])
        spots = detect_dust.detect(image, k=6.0)["spots"]
        self.assertTrue(any(abs(s["x"] - 0.30) < 0.03 and abs(s["y"] - 0.70) < 0.03
                            for s in spots), spots)
        self.assertFalse(any(abs(s["y"] - 0.25) < 0.03 for s in spots), spots)

    def test_reported_radius_tracks_blob_size(self):
        small = detect_dust.detect(
            synthetic_frame(self.path("s.jpg"), [(0.5, 0.5, 10.0, 0.06)]), k=6.0)
        large = detect_dust.detect(
            synthetic_frame(self.path("l.jpg"), [(0.5, 0.5, 30.0, 0.06)]), k=6.0)
        self.assertLess(small["spots"][0]["r_px"], large["spots"][0]["r_px"])


class CorrelateTest(unittest.TestCase):
    """The part that separates dust from a pebble.

    Dust lands on the same sensor coordinate whatever the camera is pointed at;
    scene objects do not. These fixtures encode exactly that difference.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dust = (0.62, 0.40, 18.0, 0.06)

    def frame(self, name, blobs, seed, ridges=()):
        return synthetic_frame(os.path.join(self.tmp.name, name), blobs,
                               seed=seed, ridges=ridges)

    def manifest(self):
        pebble_a = (0.28, 0.62, 16.0, 0.07)
        pebble_b = (0.75, 0.70, 16.0, 0.07)
        shared = {"lens": "L", "crop": [0.0, 1.0, 0.0, 1.0]}
        return [
            dict(image=self.frame("s1a.jpg", [self.dust, pebble_a], 11), scene="one", **shared),
            dict(image=self.frame("s1b.jpg", [self.dust, pebble_a], 12), scene="one", **shared),
            dict(image=self.frame("s2a.jpg", [self.dust, pebble_b], 13), scene="two", **shared),
        ]

    def test_dust_is_persistent_and_scene_objects_are_not(self):
        out = correlate_dust.correlate(self.manifest(), k=6.0)
        self.assertEqual(len(out["persistent"]), 1, out["all"])
        found = out["persistent"][0]
        self.assertAlmostEqual(found["x"], self.dust[0], delta=0.02)
        self.assertAlmostEqual(found["y"], self.dust[1], delta=0.02)
        self.assertEqual(found["scenes"], ["one", "two"])

        # The object that repeats only inside scene "one" must not be promoted.
        repeated_in_one_scene = [v for v in out["all"] if v["verdict"] == "inconclusive"]
        self.assertTrue(repeated_in_one_scene)
        for verdict in repeated_in_one_scene:
            self.assertEqual(verdict["scenes"], ["one"])

    def test_single_lens_carries_no_attribution_warning(self):
        out = correlate_dust.correlate(self.manifest(), k=6.0)
        self.assertNotIn("attribution_warning", out)

    def test_mixed_lenses_refuse_attribution(self):
        frames = self.manifest()
        frames[-1]["lens"] = "OTHER"
        out = correlate_dust.correlate(frames, k=6.0)
        self.assertIn("attribution_warning", out)
        self.assertIn("lens", out["attribution_warning"])

    def test_same_viewpoint_labelled_as_two_scenes_is_refused(self):
        """Scene tags are the caller's claim, and callers get this wrong.

        Two frames from one viewpoint, seventeen minutes apart, carry the same
        skyline and the same clouds. Tagged as different scenes they make every
        cloud gap look like dust. The background is therefore checked directly:
        if both frames show the same thing there, the second one added nothing.
        """
        # Close enough to the spot to fall INSIDE the compared patch: the check
        # looks at the immediate surroundings, not at the frame as a whole.
        structure = [(0.5, 0.35, 10.0, 0.09), (0.5, 0.46, 9.0, 0.07)]
        shared = {"lens": "L", "crop": [0.0, 1.0, 0.0, 1.0]}
        frames = [
            dict(image=self.frame("v1.jpg", [self.dust], 21), scene="claimed-one", **shared),
            dict(image=self.frame("v2.jpg", [self.dust], 22), scene="claimed-two", **shared),
        ]
        # Same landscape in both, only the noise differs -- exactly the real case.
        for frame, seed in zip(frames, (21, 22)):
            synthetic_frame(frame["image"], [self.dust], seed=seed, ridges=structure)

        out = correlate_dust.correlate(frames, k=6.0)
        flagged = [v for v in out["all"] if v.get("warning")]
        self.assertTrue(flagged, out["all"])
        self.assertIn("same viewpoint", flagged[0]["warning"])
        # Advisory, not a gate: the finding is still reported, with the doubt
        # attached, because no threshold separated this case from a clear sky.
        self.assertEqual(flagged[0]["verdict"], "persistent")

    def test_background_similarity_measures_what_it_claims(self):
        """The measure itself, without the image pipeline in the way.

        Building two synthetic frames that are genuinely different scenes AND
        keep the planted dust detectable turned out to be harder than testing the
        measure directly, and a fixture fought into shape would have tested the
        fixture.
        """
        rng = np.random.default_rng(3)
        structure = rng.normal(0, 0.1, (32, 32)).astype(np.float32)
        other = rng.normal(0, 0.1, (32, 32)).astype(np.float32)
        featureless = np.full((32, 32), 0.6, np.float32) + rng.normal(0, 0.0005, (32, 32))

        same = correlate_dust._correlation(structure, structure.copy())
        different = correlate_dust._correlation(structure, other)
        nothing = correlate_dust._correlation(featureless, featureless.copy())

        self.assertGreater(same, 0.95, "identical surroundings must correlate")
        self.assertLess(abs(different), 0.3, "unrelated surroundings must not")
        self.assertIsNone(nothing, "a featureless patch cannot testify either way")

    def test_mixed_orientation_refuses_to_compare(self):
        """A portrait frame transposes the sensor, so the axes no longer agree."""
        frames = self.manifest()
        frames[-1]["orientation"] = "portrait"
        out = correlate_dust.correlate(frames, k=6.0)
        self.assertIn("orientation_error", out)
        self.assertEqual(out["persistent"], [])

    def test_one_scene_cannot_conclude(self):
        frames = [f for f in self.manifest() if f["scene"] == "one"]
        out = correlate_dust.correlate(frames, k=6.0)
        self.assertEqual(out["persistent"], [])
        self.assertIn("note", out)


class NoiseTest(unittest.TestCase):
    """Headroom has to fall as noise rises, and the advice has to change with it.

    The fixtures put a genuinely dark, genuinely flat region in frame, because
    that is the only thing the measurement can work from -- and a photo without
    one has to say so rather than invent a number.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def noisy_frame(self, name, shadow_noise, seed=5):
        rng = np.random.default_rng(seed)
        field = np.empty((HEIGHT, WIDTH), dtype=np.float64)
        field[:, : WIDTH // 2] = 0.18          # flat shadow half
        field[:, WIDTH // 2:] = 0.62           # flat midtone half
        field += rng.normal(0, shadow_noise, field.shape)
        path = os.path.join(self.tmp.name, name)
        Image.fromarray((np.clip(field, 0, 1) * 255).astype(np.uint8)).save(path, quality=98)
        return path

    def test_headroom_falls_as_noise_rises(self):
        clean = estimate_noise.estimate(self.noisy_frame("clean.jpg", 0.002))
        dirty = estimate_noise.estimate(self.noisy_frame("dirty.jpg", 0.030))
        self.assertIsNotNone(clean["headroom_stops"])
        self.assertIsNotNone(dirty["headroom_stops"])
        self.assertGreater(clean["headroom_stops"], dirty["headroom_stops"])

    def test_heavy_noise_refuses_the_lift(self):
        result = estimate_noise.estimate(self.noisy_frame("bad.jpg", 0.045))
        self.assertLess(result["headroom_stops"], 0.75)
        self.assertIn("break", result["advice"])

    def test_clean_shadows_allow_a_lift(self):
        result = estimate_noise.estimate(self.noisy_frame("good.jpg", 0.0015))
        self.assertGreaterEqual(result["headroom_stops"], 2.0)
        self.assertIn("No noise reduction needed", result["advice"])

    def test_headroom_is_bounded_or_declines_to_answer(self):
        # An almost noiseless frame must not report unlimited headroom, and a
        # frame that is mostly noise must not report a number at all: at 0.2 the
        # tones smear across every band and nothing flat is left to measure.
        pristine = estimate_noise.estimate(self.noisy_frame("p.jpg", 0.0001))
        self.assertLessEqual(pristine["headroom_stops"], 4.0)

        ruined = estimate_noise.estimate(self.noisy_frame("r.jpg", 0.2))
        if ruined["headroom_stops"] is None:
            self.assertIn("judge by eye", ruined["advice"])
        else:
            self.assertGreaterEqual(ruined["headroom_stops"], -2.0)
            self.assertLess(ruined["headroom_stops"], 0.75)

    def test_frame_without_shadows_says_so_instead_of_guessing(self):
        rng = np.random.default_rng(7)
        field = np.full((HEIGHT, WIDTH), 0.80) + rng.normal(0, 0.003, (HEIGHT, WIDTH))
        path = os.path.join(self.tmp.name, "bright.jpg")
        Image.fromarray((np.clip(field, 0, 1) * 255).astype(np.uint8)).save(path, quality=98)
        result = estimate_noise.estimate(path)
        self.assertIsNone(result["headroom_stops"])
        self.assertIn("judge by eye", result["advice"])

    def test_every_band_is_reported_even_when_empty(self):
        result = estimate_noise.estimate(self.noisy_frame("bands.jpg", 0.004))
        self.assertEqual(len(result["bands"]), len(estimate_noise.BANDS))
        for band in result["bands"]:
            self.assertIn("pixels", band)
            if band["noise"] is None:
                self.assertIn("note", band)


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_detect_cli_emits_json(self):
        import io
        from contextlib import redirect_stdout

        image = synthetic_frame(os.path.join(self.tmp.name, "c.jpg"),
                                [(0.4, 0.45, 18.0, 0.06)])
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            detect_dust.main([image, "-k", "6", "--crop", "0.078,0.922,0,1"])
        payload = json.loads(buffer.getvalue())
        self.assertIn("spots", payload)
        self.assertTrue(all("x_orig" in s for s in payload["spots"]))

    def test_detect_cli_rejects_a_bad_crop(self):
        image = synthetic_frame(os.path.join(self.tmp.name, "b.jpg"), [])
        with self.assertRaises(SystemExit):
            detect_dust.main([image, "--crop", "0.1,0.2"])


if __name__ == "__main__":
    unittest.main()
