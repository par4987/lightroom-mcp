"""Drift guard for the SKILL.md contract.

Same reasoning as photo-edit-advisor's guard: a skill ships as instructions with
no hook to intercept a tool call, so the wording IS the enforcement. These tests
fail when a future edit quietly turns a gate back into a suggestion.

Standard library only: this file must run where numpy/pillow are missing.
"""

import os
import unittest

SKILL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "SKILL.md"
)

# The mutating tools the gate has to name. Dropping one from the list is the
# failure mode this test exists to catch, so they are spelled out here too.
MUTATING_TOOLS = (
    "set_develop_settings",
    "set_white_balance",
    "add_local_adjustment",
    "add_ai_mask",
    "ai_denoise",
    "apply_auto",
    "copy_develop_settings",
    "create_snapshot",
)


class SkillContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SKILL, encoding="utf-8") as fh:
            cls.text = fh.read()

    def test_propose_is_the_documented_default(self):
        self.assertIn("Default to `propose`", self.text)

    def test_mode_gate_is_stated_as_a_requirement(self):
        # The load-bearing wording. Softening it to "should" or "try not to"
        # drops the only enforcement this skill has.
        self.assertIn("`mode` is a hard gate", self.text)
        self.assertIn("Call a\ncatalog-mutating tool only on an explicit request", self.text)

    def test_gate_names_the_mutating_tools(self):
        for tool in MUTATING_TOOLS:
            self.assertIn(tool, self.text, "gate lost the tool: " + tool)

    def test_gate_still_allows_reading_and_previewing(self):
        # Those two are the whole point of the skill; a gate that blocked them
        # would make it unusable in propose mode.
        self.assertIn("Reading, previewing and\nproposing are always allowed", self.text)

    def test_an_explicit_yes_switches_modes(self):
        self.assertIn("after a proposal you already made and they approved", self.text)

    def test_size_usable_gate_survives(self):
        # The whole reason this skill exists rather than "just call the tools":
        # a stale thumbnail makes an applied edit look like a failed one, and
        # the agent's next move is to apply it again.
        self.assertIn("`size_usable` — check it before you trust the image", self.text)
        self.assertIn("is not evidence", self.text)

    def test_stale_cache_must_not_be_read_as_a_failed_edit(self):
        self.assertIn("believe the\nsettings and re-render before you touch the edit again", self.text)

    def test_batch_copy_excludes_the_source(self):
        # Copying settings onto the photo they came from double-grades it.
        self.assertIn("`target_ids` must not include `source_id`", self.text)

    def test_partial_success_is_read_before_reporting(self):
        # These tools return per-photo counts; a partial batch is normal.
        self.assertIn("A partial success is the normal case", self.text)
        self.assertIn("Read the counts before reporting", self.text)

    def test_writes_are_verified_by_reading_back(self):
        # add_ai_mask's SDK call returns nil even when it worked from the UI.
        self.assertIn("The return value of a write is not proof", self.text)
        self.assertIn("confirm with `list_masks`", self.text)

    def test_destructive_calls_need_a_separate_yes(self):
        # confirm: true is the only thing between the call and deleted catalog
        # entries, so it cannot be set in the same breath as the proposal.
        self.assertIn("do not\nset it in the same breath as the proposal", self.text)

    def test_reset_develop_is_named_as_destructive_too(self):
        self.assertIn("and it is not partial", self.text)
        self.assertIn("Name exactly which you are about to run", self.text)

    def test_it_does_not_reinvent_the_other_skill(self):
        # Dust/noise measurement belongs to photo-edit-advisor. Duplicating it
        # here would put two answers in front of the model for the same question.
        self.assertIn("`reference/recipes.md` is **not** loaded here", self.text)
        self.assertIn("photo-edit-advisor", self.text)


if __name__ == "__main__":
    unittest.main()
