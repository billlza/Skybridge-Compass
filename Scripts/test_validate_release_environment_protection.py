#!/usr/bin/env python3
"""Tests for protected release-environment API validation."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


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


def single_maintainer_environment(name: str = "macos-production-release") -> dict[str, Any]:
    return {
        "name": name,
        "can_admins_bypass": False,
        "protection_rules": [{
            "type": "required_reviewers",
            "prevent_self_review": False,
            "reviewers": [{
                "type": "User",
                "reviewer": {"id": 149552943, "login": "billlza"},
            }],
        }],
        "deployment_branch_policy": {
            "protected_branches": True,
            "custom_branch_policies": False,
        },
    }


class ReleaseEnvironmentProtectionTests(unittest.TestCase):
    def test_designated_maintainer_requires_explicit_policy(self) -> None:
        for name in ("macos-production-release", "release-real-device-evidence"):
            with self.subTest(name=name):
                payload = single_maintainer_environment(name)
                MODULE.validate_environment(payload, name, "single-maintainer")
                with self.assertRaises(MODULE.EnvironmentProtectionError):
                    MODULE.validate_environment(payload, name)

    def test_self_approval_does_not_extend_to_other_environments(self) -> None:
        for name in ("release-ios-app-store-export", "skybridge-cli-github-release", "other"):
            with self.subTest(name=name), self.assertRaises(MODULE.EnvironmentProtectionError):
                MODULE.validate_environment(single_maintainer_environment(name), name, "single-maintainer")
        for policy in ("", "self", "single-maintainer ", None):
            with self.subTest(policy=policy), self.assertRaises(MODULE.EnvironmentProtectionError):
                MODULE.validate_environment(single_maintainer_environment(), "macos-production-release", policy)

    def test_self_approval_is_bound_to_one_exact_user_identity(self) -> None:
        for mutation in (
            "missing", "extra", "duplicate", "team", "wrong-id", "wrong-login",
            "missing-login", "boolean-id", "string-id", "unexpected-schema",
        ):
            with self.subTest(mutation=mutation):
                payload = single_maintainer_environment()
                rule = payload["protection_rules"][0]
                entry = rule["reviewers"][0]
                if mutation == "missing":
                    rule["reviewers"] = []
                elif mutation == "extra":
                    rule["reviewers"].append({"type": "User", "reviewer": {"id": 42, "login": "other"}})
                elif mutation == "duplicate":
                    rule["reviewers"].append(entry.copy())
                elif mutation == "team":
                    entry["type"] = "Team"
                elif mutation == "wrong-id":
                    entry["reviewer"]["id"] = 42
                elif mutation == "wrong-login":
                    entry["reviewer"]["login"] = "other"
                elif mutation == "missing-login":
                    del entry["reviewer"]["login"]
                elif mutation == "boolean-id":
                    entry["reviewer"]["id"] = True
                elif mutation == "string-id":
                    entry["reviewer"]["id"] = "149552943"
                else:
                    entry["unexpected"] = True
                with self.assertRaises(MODULE.EnvironmentProtectionError):
                    MODULE.validate_environment(payload, "macos-production-release", "single-maintainer")

    def test_self_approval_preserves_environment_protection_boundaries(self) -> None:
        for mutation in ("wrong-name", "no-rule", "no-self-policy", "independent", "null-self-policy", "admin", "no-branch-policy", "unprotected"):
            with self.subTest(mutation=mutation):
                payload = single_maintainer_environment()
                rule = payload["protection_rules"][0]
                if mutation == "wrong-name":
                    payload["name"] = "other"
                elif mutation == "no-rule":
                    payload["protection_rules"] = []
                elif mutation == "no-self-policy":
                    del rule["prevent_self_review"]
                elif mutation == "independent":
                    rule["prevent_self_review"] = True
                elif mutation == "null-self-policy":
                    rule["prevent_self_review"] = None
                elif mutation == "admin":
                    payload["can_admins_bypass"] = True
                elif mutation == "no-branch-policy":
                    payload["deployment_branch_policy"] = None
                else:
                    payload["deployment_branch_policy"]["protected_branches"] = False
                with self.assertRaises(MODULE.EnvironmentProtectionError):
                    MODULE.validate_environment(payload, "macos-production-release", "single-maintainer")

    def test_command_line_requires_explicit_self_approval_selection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            response = Path(directory) / "environment.json"
            response.write_text(json.dumps(single_maintainer_environment()), encoding="utf-8")
            command = [sys.executable, str(VALIDATOR), "--response", str(response), "--expected-name", "macos-production-release"]
            independent = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(independent.returncode, 1, independent.stdout + independent.stderr)
            self.assertIn("must prevent self-review", independent.stderr)
            owner = subprocess.run(command + ["--approval-policy", "single-maintainer"], capture_output=True, text=True, check=False)
            self.assertEqual(owner.returncode, 0, owner.stdout + owner.stderr)

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
