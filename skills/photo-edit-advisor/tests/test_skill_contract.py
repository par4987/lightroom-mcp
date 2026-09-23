"""Drift guard for the SKILL.md contract.

The `mode` behaviour (propose unless the user explicitly asks to apply) is
enforced nowhere at runtime: SKILL.md *is* the enforcement, because the skill
ships as instructions and has no hook to intercept a tool call. That makes the
wording itself the mechanism -- so it gets the same treatment as the manifest
and annotation guards: a test that fails when a future edit quietly turns the
gate back into a suggestion.

Standard library only: this file must run where numpy/pillow are missing.
"""

import os
import unittest

SKILL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "SKILL.md"
)

# The mutating tools the gate has to name. Removing them from the list is the
# failure mode this test exists to catch, so they are spelled out here too.
MUTATING_TOOLS = (
    "set_develop_settings",
    "set_white_balance",
    "apply_auto",
    "set_mask_",
    "delete_collection",
    "add_to_collection",
    "ai_denoise",
    "distraction_removal",
    "apply_preset",
)


class SkillContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SKILL, encoding="utf-8") as fh:
            cls.text = fh.read()

    def test_propose_is_the_documented_default(self):
        self.assertIn("Default to `propose`", self.text)

    def test_mode_gate_is_stated_as_a_requirement(self):
        # "hard gate ... MUST NOT call" is the load-bearing wording; softening
        # it to "should"/"try not to" drops the enforcement this skill has.
        self.assertIn("`mode` is a hard gate", self.text)
        self.assertIn("MUST NOT call any catalog-mutating tool", self.text)

    def test_gate_names_the_mutating_tools(self):
        for tool in MUTATING_TOOLS:
            self.assertIn(tool, self.text, "gate lost the tool: " + tool)

    def test_gate_still_allows_the_two_flows_it_needs(self):
        # Reading and exporting are how the measurements happen; a gate that
        # blocks them would make the skill unusable in propose mode.
        self.assertIn("Reading, exporting and proposing are\nalways allowed", self.text)

    def test_an_explicit_yes_switches_modes(self):
        self.assertIn("switch to `auto` for that edit", self.text)


if __name__ == "__main__":
    unittest.main()
