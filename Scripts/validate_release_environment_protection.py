#!/usr/bin/env python3
"""Fail closed unless a GitHub release environment requires independent review."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
from pathlib import Path
from typing import Any, NoReturn


MAXIMUM_RESPONSE_BYTES = 1024 * 1024
ENVIRONMENT_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z", re.ASCII)


class EnvironmentProtectionError(RuntimeError):
    """The environment is missing or does not enforce independent approval."""


def fail(message: str) -> NoReturn:
    raise EnvironmentProtectionError(message)


def load_response(path: Path) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"unable to open environment response: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            fail("environment response must be a single-link regular file")
        if metadata.st_size < 1 or metadata.st_size > MAXIMUM_RESPONSE_BYTES:
            fail("environment response size is outside the fixed boundary")
        content = os.read(descriptor, metadata.st_size + 1)
        if len(content) != metadata.st_size:
            fail("environment response changed while reading")
    finally:
        os.close(descriptor)
    try:
        payload = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"environment response is invalid JSON: {exc}")
    if not isinstance(payload, dict):
        fail("environment response must be an object")
    return payload


def validate_environment(payload: dict[str, Any], expected_name: str) -> None:
    if ENVIRONMENT_NAME_PATTERN.fullmatch(expected_name) is None:
        fail("expected environment name is invalid")
    if payload.get("name") != expected_name:
        fail("environment response name does not match the requested environment")
    rules = payload.get("protection_rules")
    if not isinstance(rules, list):
        fail("environment protection_rules must be an array")
    required_review_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    if len(required_review_rules) != 1:
        fail("environment must have exactly one required_reviewers protection rule")
    rule = required_review_rules[0]
    if rule.get("prevent_self_review") is not True:
        fail("environment must prevent self-review")
    reviewers = rule.get("reviewers")
    if not isinstance(reviewers, list) or not reviewers:
        fail("environment required_reviewers rule has no reviewers")
    reviewer_ids: set[tuple[str, int]] = set()
    for entry in reviewers:
        if not isinstance(entry, dict) or set(entry) != {"type", "reviewer"}:
            fail("environment reviewer entry has an unexpected schema")
        reviewer_type = entry.get("type")
        reviewer = entry.get("reviewer")
        if reviewer_type not in {"User", "Team"} or not isinstance(reviewer, dict):
            fail("environment reviewer must be a user or team")
        reviewer_id = reviewer.get("id")
        if isinstance(reviewer_id, bool) or not isinstance(reviewer_id, int) or reviewer_id <= 0:
            fail("environment reviewer id must be a positive integer")
        identity = (reviewer_type, reviewer_id)
        if identity in reviewer_ids:
            fail("environment contains a duplicate required reviewer")
        reviewer_ids.add(identity)
    if payload.get("can_admins_bypass") is not False:
        fail("environment must disallow administrator protection-rule bypass")
    deployment_policy = payload.get("deployment_branch_policy")
    if (
        not isinstance(deployment_policy, dict)
        or set(deployment_policy) != {"protected_branches", "custom_branch_policies"}
    ):
        fail("environment deployment branch policy has an unexpected schema")
    protected_branches = deployment_policy.get("protected_branches")
    custom_branch_policies = deployment_policy.get("custom_branch_policies")
    if not isinstance(protected_branches, bool) or not isinstance(
        custom_branch_policies, bool
    ):
        fail("environment deployment branch policy values must be booleans")
    if protected_branches is not True or custom_branch_policies is not False:
        fail("environment must restrict deployments to protected branches")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--response", type=Path, required=True)
    parser.add_argument("--expected-name", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        validate_environment(load_response(args.response), args.expected_name)
    except EnvironmentProtectionError as exc:
        print(f"release environment protection rejected: {exc}", file=os.sys.stderr)
        return 1
    print(f"release environment protection valid: {args.expected_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
