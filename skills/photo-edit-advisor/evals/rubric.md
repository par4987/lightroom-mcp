# Tier B rubric — judging a proposed edit

Tier A checks the half of this skill that has a right answer. This is the other
half. There is no correct edit, so these cases are judged against criteria rather
than compared to a key, by a person or by an LLM judge given this file.

Score each criterion **pass / weak / fail**. A proposal fails overall if any
criterion below the line fails, regardless of how good the rest is.

## Below the line — any failure sinks the proposal

**1. It does not exceed the noise budget.**
No `Exposure` or `Shadows` lift beyond `headroom_stops`. If the recipe wanted
more, the proposal says the shadows were the limit. Proposing a two-stop lift on
a photo measured at 0.5 stops is the single worst thing this skill can do, because
the person will apply it and not see the damage until later.

**2. It does not promise what the SDK cannot do.**
No claim to have applied an AI mask on the strength of a return value; no promise
to run Distraction Removal, which is UI-only; no offer to restore a snapshot,
which the SDK cannot list or apply. Saying "do this in the Develop panel" is a
pass. Saying "I created the sky mask" without a `list_masks` check is a fail.

**3. It does not state unconfirmed dust as confirmed.**
A single-frame candidate is a candidate. An entry carrying a `background_similarity`
warning is not confirmed. Attribution to the sensor specifically, across different
lenses, is a fail — the distortion profile alone moves a fixed spot.

**4. It proposes deltas from the photo's actual state.**
These photos arrive with a camera profile and non-zero contrast. A proposal that
reads as though every slider were at zero has not looked.

## Above the line — quality

**5. The diagnosis of the light comes before the choice of recipe.**
Backlit, mixed, night: these change the plan more than the subject does. A
proposal that picks "landscape" and ignores that the sun is behind the subject has
classified but not looked.

**6. Restraint.**
Two or three changes that carry the picture, not five that are each defensible.
Count the proposed changes; more than four for an ordinary photo is a weak.

**7. Every change has a reason tied to this photo.**
"Vibrance +12" is weak. "The sky went flat at this hour; +12 vibrance brings the
blue back without touching skin" is a pass. Reasons that would fit any photo are
weak.

**8. The numbers are conservative.**
Inside the bands in `reference/recipes.md`, and toward the lower end unless the
photo argues otherwise. Clarity above +20 on anything with a face, or Dehaze above
+20 anywhere, is a fail on this criterion.

**9. It says what it is NOT doing and why.**
The blown window that cannot be recovered, the shadows the budget will not allow,
the mixed light that cannot be fixed globally. A proposal that only lists wins is
hiding something.

**10. Verification is part of the plan.**
It says how it will check: read the settings back, re-preview at `medium`,
`list_masks` for any mask. "Applied successfully" with no read-back is a weak.

## Notes for the judge

- Judge the PROPOSAL, not the photo. A dull photo honestly diagnosed scores well.
- A refusal to propose, with a stated reason ("the shadows have no headroom and
  the highlights are clipped; this needs a different frame"), is a pass, not a
  dodge — provided the reason is measured rather than asserted.
- Prefer a proposal that admits uncertainty over one that sounds decisive. The
  failure mode this skill is guarding against is a confident over-edit.
