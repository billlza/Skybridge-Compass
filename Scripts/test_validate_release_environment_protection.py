#!/usr/bin/env python3
"""Tests for protected release-environment API validation."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "Scripts/validate_release_environment_protection.py"
SPEC = importlib.util.spec_from_file_location("validate_release_environment_protection", VALIDATOR)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to import release environment protection validator")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def valid_environment(name: str = "release-real-device-evidence") -> dict[str, object]:
    return {
        "id": 1234,
        "name": name,
        "can_admins_bypass": False,
        "protection_rules": [
            {
                "id": 99,
                "type": "required_reviewers",
                "prevent_self_review": True,
                "reviewers": [
                    {
                        "type": "Team",
                        "reviewer": {"id": 5678, "slug": "release-reviewers"},
                    }
                ],
            }
        ],
        "deployment_branch_policy": {
            "protected_branches": True,
            "custom_branch_policies": False,
        },
    }


class ReleaseEnvironmentProtectionTests(unittest.TestCase):
    def test_independent_review_environment_passes(self) -> None:
        MODULE.validate_environment(valid_environment(), "release-real-device-evidence")

    def test_missing_environment_response_cannot_pass_as_empty(self) -> None:
        with self.assertRaises(MODULE.EnvironmentProtectionError):
            MODULE.validate_environment({}, "release-real-device-evidence")

    def test_missing_reviewers_self_review_or_admin_bypass_fails_closed(self) -> None:
        mutations = ("missing-rule", "empty", "self", "admin")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                payload = valid_environment()
                rule = payload["protection_rules"][0]  # type: ignore[index]
                if mutation == "missing-rule":
                    payload["protection_rules"] = []
                elif mutation == "empty":
                    rule["reviewers"] = []  # type: ignore[index]
                elif mutation == "self":
                    rule["prevent_self_review"] = False  # type: ignore[index]
                else:
                    payload["can_admins_bypass"] = True
                with self.assertRaises(MODULE.EnvironmentProtectionError):
                    MODULE.validate_environment(payload, "release-real-device-evidence")

    def test_wrong_name_or_duplicate_reviewer_fails_closed(self) -> None:
        wrong_name = valid_environment("different")
        with self.assertRaises(MODULE.EnvironmentProtectionError):
            MODULE.validate_environment(wrong_name, "release-real-device-evidence")
        duplicate = valid_environment()
        reviewers = duplicate["protection_rules"][0]["reviewers"]  # type: ignore[index]
        reviewers.append(reviewers[0])
        with self.assertRaises(MODULE.EnvironmentProtectionError):
            MODULE.validate_environment(duplicate, "release-real-device-evidence")

    def test_deployment_branch_policy_must_be_explicit_and_restrictive(self) -> None:
        for policy in (
            None,
            {},
            {"protected_branches": False, "custom_branch_policies": False},
            {"protected_branches": False, "custom_branch_policies": True},
            {"protected_branches": True, "custom_branch_policies": True},
            {"protected_branches": "true", "custom_branch_policies": False},
            {
                "protected_branches": True,
                "custom_branch_policies": False,
                "unexpected": False,
            },
        ):
            with self.subTest(policy=policy):
                payload = valid_environment()
                payload["deployment_branch_policy"] = policy
                with self.assertRaises(MODULE.EnvironmentProtectionError):
                    MODULE.validate_environment(payload, "release-real-device-evidence")

        protected = valid_environment()
        protected["deployment_branch_policy"] = {
            "protected_branches": True,
            "custom_branch_policies": False,
        }
        MODULE.validate_environment(protected, "release-real-device-evidence")


if __name__ == "__main__":
    unittest.main()
