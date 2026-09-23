# Evals

Two tiers, because the skill has two halves.

**Tier A** — dust positions, verdict counts, headroom ordering. These have right
answers, measured against Lightroom Classic 15.4, and `scripts/run_evals.py`
passes or fails them.

**Tier B** — whether a proposed edit is any good. No right answer; judged against
`rubric.md` by a person or an LLM judge.

## Why this is not in CI

The photos live on the photographer's disk (`D:\RAW\...`) and are re-exported per
run. Bundling JPEGs would turn the suite into a regression lock on one export
pipeline and add megabytes of binaries to the repo, so `cases.json` names photos
by catalogue id and path instead. `mise run skill:test` runs the unit tests, which
DO work everywhere; the evals are a manual gate against the real catalogue.

## Running Tier A

1. Check the `requires` notes in `cases.json`. Two cases need opposite states of
   the same photo — `arocena-dust-present` needs Dust Removal absent,
   `removal-verified` needs it applied — so they cannot both be exported at once.
2. Create the export directory. `export_photos` does **not** create it and fails
   with a Lightroom error in the UI's language if it is missing.
3. Export every file named in `cases.json` as JPEG quality 92, at full size, into
   that one directory.
4. Run it:

```bash
python scripts/run_evals.py /path/to/exports
```

Exit code is non-zero if any Tier A case fails. A missing export fails its case
rather than silently skipping it.

## Running Tier B

Export the frames, give the skill the case `prompt`, and score the resulting
proposal against `rubric.md`. Record the scores next to the date and the skill
version — the point is the trend, not a single number.

## Keeping the expectations honest

Every number in `cases.json` came from a measurement, and the dust positions were
cross-checked against Lightroom's own Dust Removal regions (agreement 0.0005 to
0.008 of frame width). If a case starts failing, check whether the photo was
edited before assuming the code broke — that is the likeliest cause, and it is why
each case carries a `requires` note.

Adding a case: prefer a photo that would have caught a bug you actually hit. The
three Tier A dust cases exist because each one caught something — false positives
in river foam, ridge lines read as blobs, and one viewpoint mislabelled as two.
