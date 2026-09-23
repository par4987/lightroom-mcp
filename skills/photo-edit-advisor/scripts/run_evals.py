#!/usr/bin/env python3
"""Run the Tier A eval cases against a directory of exported JPEGs.

Tier A is the half of this skill that has a right answer: dust positions, a
verdict count, the ordering of shadow headroom. Those are checked here and they
pass or fail.

Tier B -- whether a proposed edit is any good -- has no right answer, so it is
not graded here. The cases are listed so they are not forgotten, and
`evals/rubric.md` says how to judge them.

This cannot run in CI: the photos live on the photographer's disk and are
re-exported per run. Export the files named in cases.json to one directory
(the server creates it when missing, as long as the path itself is writable)
and point this at it.

    python scripts/run_evals.py /tmp/evalexports
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from correlate_dust import correlate          # noqa: E402
from detect_dust import detect                # noqa: E402
from estimate_noise import estimate           # noqa: E402

CASES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "evals", "cases.json")


class Result:
    def __init__(self):
        self.checks = []

    def check(self, ok, label, detail=""):
        self.checks.append((bool(ok), label, detail))

    @property
    def passed(self):
        return all(ok for ok, _, _ in self.checks)


def _near(spots, target, tolerance):
    return any(abs(s[0] - target[0]) < tolerance and abs(s[1] - target[1]) < tolerance
               for s in spots)


def _frames(case, directory):
    frames = []
    for frame in case["frames"]:
        path = os.path.join(directory, frame["file"])
        if not os.path.exists(path):
            return None, frame["file"]
        entry = {"image": path}
        for key in ("scene", "lens", "crop", "orientation"):
            if key in frame:
                entry[key] = frame[key]
        frames.append(entry)
    return frames, None


def run_case(case, directory, k=6.0):
    result = Result()
    frames, missing = _frames(case, directory)
    if frames is None:
        result.check(False, "exports present", "missing {}".format(missing))
        return result

    expect = case["expect"]

    if any(key in expect for key in
           ("persistent_count", "min_warned", "max_unwarned_persistent")):
        out = correlate(frames, k=k)
        persistent = out["persistent"]
        if "persistent_count" in expect:
            result.check(len(persistent) == expect["persistent_count"],
                         "persistent count",
                         "expected {}, got {}".format(expect["persistent_count"],
                                                      len(persistent)))
        if "persistent_near" in expect:
            found = [(p["x"], p["y"]) for p in persistent]
            for target in expect["persistent_near"]:
                result.check(_near(found, target, expect.get("tolerance", 0.015)),
                             "spot near {}".format(target),
                             "got {}".format([(round(x, 3), round(y, 3)) for x, y in found]))
        if "attribution_warning" in expect:
            result.check(("attribution_warning" in out) == expect["attribution_warning"],
                         "lens attribution warning")
        if "min_warned" in expect:
            warned = sum(1 for p in persistent if p.get("warning"))
            result.check(warned >= expect["min_warned"], "entries flagged for review",
                         "expected >= {}, got {}".format(expect["min_warned"], warned))
        if "max_persistent" in expect:
            result.check(len(persistent) <= expect["max_persistent"],
                         "persistent count ceiling",
                         "expected <= {}, got {}".format(expect["max_persistent"],
                                                         len(persistent)))
        if "max_unwarned_persistent" in expect:
            unwarned = sum(1 for p in persistent if not p.get("warning"))
            result.check(unwarned <= expect["max_unwarned_persistent"],
                         "persistent findings carrying no review warning",
                         "expected <= {}, got {}".format(
                             expect["max_unwarned_persistent"], unwarned))

    if "min_edge_rejected" in expect or "max_spots" in expect:
        single = detect(frames[0]["image"], k=k)
        if "min_edge_rejected" in expect:
            rejected = single.get("edge_rejected", 0)
            result.check(rejected >= expect["min_edge_rejected"],
                         "ridge responses rejected",
                         "expected >= {}, got {}".format(expect["min_edge_rejected"],
                                                         rejected))
        if "max_spots" in expect:
            result.check(single["count"] <= expect["max_spots"], "single-frame spot ceiling",
                         "expected <= {}, got {}".format(expect["max_spots"],
                                                         single["count"]))

    if "spot_near" in expect:
        spots = detect(frames[0]["image"], k=k)["spots"]
        found = [(s["x"], s["y"]) for s in spots]
        for target in expect["spot_near"]:
            result.check(_near(found, target, expect.get("tolerance", 0.015)),
                         "spot found near {}".format(target),
                         "got {}".format([(round(x, 3), round(y, 3))
                                          for x, y in found]))

    if "no_spot_near" in expect:
        spots = detect(frames[0]["image"], k=k)["spots"]
        found = [(s["x"], s["y"]) for s in spots]
        for target in expect["no_spot_near"]:
            result.check(not _near(found, target, expect.get("tolerance", 0.02)),
                         "no spot left near {}".format(target))

    if "headroom_descending" in expect:
        measured = {}
        for frame in frames:
            name = os.path.basename(frame["image"])
            measured[name] = estimate(frame["image"])["headroom_stops"]
        order = expect["headroom_descending"]
        values = [measured.get(n) for n in order]
        result.check(all(v is not None for v in values), "headroom measurable",
                     str(measured))
        if all(v is not None for v in values):
            result.check(all(a >= b for a, b in zip(values, values[1:])),
                         "headroom ordering",
                         " >= ".join("{}={}".format(n, v) for n, v in zip(order, values)))
        for name, (low, high) in expect.get("headroom_bands", {}).items():
            value = measured.get(name)
            result.check(value is not None and low <= value <= high,
                         "{} within [{}, {}]".format(name, low, high),
                         "got {}".format(value))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("directory", help="directory holding the exported JPEGs")
    parser.add_argument("--cases", default=CASES)
    parser.add_argument("-k", type=float, default=6.0)
    parser.add_argument("--only", default=None, help="run one case by id")
    args = parser.parse_args(argv)

    with open(args.cases, "r", encoding="utf-8") as handle:
        suite = json.load(handle)

    failures = 0
    skipped = []
    for case in suite["cases"]:
        if args.only and case["id"] != args.only:
            continue
        if case.get("tier") != "A":
            skipped.append(case["id"])
            continue
        result = run_case(case, args.directory, args.k)
        status = "PASS" if result.passed else "FAIL"
        print("{}  {}  -- {}".format(status, case["id"], case["what_it_checks"]))
        for ok, label, detail in result.checks:
            if not ok:
                print("      x {}{}".format(label, ": " + detail if detail else ""))
        failures += 0 if result.passed else 1

    if skipped:
        print("\nTier B, judged against evals/rubric.md rather than here: {}"
              .format(", ".join(skipped)))
    print("\n{} tier-A case(s) failed".format(failures) if failures
          else "\nall tier-A cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
