#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import tomllib
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate claim->snapshot->artifact traceability contracts")
    parser.add_argument("--snapshots", default="Docs/artifact_snapshots.toml")
    parser.add_argument("--claims", default="Docs/claim_manifest.yaml")
    parser.add_argument("--main-tex", default="Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex")
    parser.add_argument("--out-json", default="Artifacts/claim_traceability_report.json")
    parser.add_argument("--out-md", default="Artifacts/claim_traceability_report.md")
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def resolve_ref_path(root: Path, raw: str) -> Path:
    candidate = raw.strip().split("#", 1)[0]
    probe = root / candidate
    if probe.exists():
        return probe

    parts = candidate.split(":")
    while len(parts) > 1:
        candidate = ":".join(parts[:-1])
        probe = root / candidate
        if probe.exists():
            return probe
        parts = parts[:-1]

    return root / raw.strip()


def build_md(status: str, violations: list[dict[str, str]]) -> str:
    lines = [
        "# Claim Traceability Report",
        "",
        f"- Generated at: {dt.datetime.now(dt.timezone.utc).isoformat()}",
        f"- Status: **{status.upper()}**",
        "",
        "## Violations",
        "",
    ]
    if not violations:
        lines.append("- none")
    else:
        for violation in violations:
            lines.append(
                f"- `{violation['rule']}` ({violation['location']}): {violation['detail']}"
            )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[1]
    snapshots_path = root / args.snapshots
    claims_path = root / args.claims
    main_tex_path = root / args.main_tex
    out_json = root / args.out_json
    out_md = root / args.out_md
    violations: list[dict[str, str]] = []

    def add(rule: str, location: str, detail: str) -> None:
        violations.append({"rule": rule, "location": location, "detail": detail})

    if not snapshots_path.exists():
        add("missing_snapshots_file", str(snapshots_path), "artifact snapshot contract file does not exist")
        snapshots = []
    else:
        snapshots_raw = tomllib.loads(snapshots_path.read_text(encoding="utf-8"))
        snapshots = snapshots_raw.get("snapshots", [])
        if not isinstance(snapshots, list) or not snapshots:
            add("empty_snapshots", str(snapshots_path), "snapshots list must be non-empty")
            snapshots = []

    snapshot_by_id: dict[str, dict[str, str]] = {}
    for index, snapshot in enumerate(snapshots):
        location = f"{snapshots_path}:{index + 1}"
        required = ["id", "artifact_date", "tier", "git_commit", "os", "toolchain", "dataset_path", "dataset_sha256"]
        for key in required:
            if key not in snapshot or not str(snapshot[key]).strip():
                add("snapshot_missing_field", location, f"missing required field `{key}`")
        snapshot_id = str(snapshot.get("id", "")).strip()
        if snapshot_id:
            snapshot_by_id[snapshot_id] = snapshot

        artifact_date = str(snapshot.get("artifact_date", "")).strip()
        if artifact_date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", artifact_date):
            add("snapshot_bad_artifact_date", location, f"invalid artifact_date format: {artifact_date}")

        tier = str(snapshot.get("tier", "")).strip()
        if tier not in {"primary", "secondary"}:
            add("snapshot_bad_tier", location, f"tier must be primary|secondary, got `{tier}`")

        git_commit = str(snapshot.get("git_commit", "")).strip()
        if git_commit and not re.fullmatch(r"[0-9a-f]{7,40}", git_commit):
            add("snapshot_bad_git_commit", location, f"git_commit must be 7-40 lowercase hex chars, got `{git_commit}`")

        expected_sha = str(snapshot.get("dataset_sha256", "")).strip().lower().removeprefix("sha256:")
        if expected_sha and not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
            add("snapshot_bad_dataset_sha", location, f"dataset_sha256 must be 64 hex chars, got `{snapshot.get('dataset_sha256')}`")
        dataset_path = str(snapshot.get("dataset_path", "")).strip()
        if dataset_path:
            resolved = root / dataset_path
            if not resolved.exists():
                add("snapshot_missing_dataset", location, f"dataset_path does not exist: {dataset_path}")
            elif expected_sha:
                actual_sha = sha256_file(resolved)
                if actual_sha.lower() != expected_sha:
                    add(
                        "snapshot_sha_mismatch",
                        location,
                        f"dataset sha mismatch for {dataset_path}: expected {expected_sha}, got {actual_sha}",
                    )

    if not claims_path.exists():
        add("missing_claim_manifest", str(claims_path), "claim manifest file does not exist")
        claims = []
    else:
        try:
            claims_root = json.loads(claims_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            add("claim_manifest_parse_error", str(claims_path), f"manifest must be JSON-compatible YAML: {exc}")
            claims_root = {}
        claims = claims_root.get("claims", [])
        if not isinstance(claims, list) or not claims:
            add("empty_claims", str(claims_path), "claims list must be non-empty")
            claims = []

    for index, claim in enumerate(claims):
        location = f"{claims_path}:{index + 1}"
        required = ["id", "target", "scope", "text", "assumptions", "snapshot_id", "code_refs", "artifact_refs"]
        for key in required:
            if key not in claim:
                add("claim_missing_field", location, f"missing required field `{key}`")

        claim_id = str(claim.get("id", "")).strip()
        if not claim_id:
            add("claim_missing_id", location, "claim id must be non-empty")

        scope = str(claim.get("scope", "")).strip()
        if not scope:
            add("claim_missing_scope", location, "scope must be non-empty")

        assumptions = claim.get("assumptions", [])
        if not isinstance(assumptions, list) or not assumptions or any(not str(item).strip() for item in assumptions):
            add("claim_missing_assumptions", location, "assumptions must be a non-empty string list")

        snapshot_id = str(claim.get("snapshot_id", "")).strip()
        snapshot = snapshot_by_id.get(snapshot_id)
        if not snapshot:
            add("claim_unknown_snapshot", location, f"snapshot_id `{snapshot_id}` not found in snapshots contract")
        else:
            target = str(claim.get("target", "")).strip().lower()
            if target == "main" and str(snapshot.get("tier", "")) != "primary":
                add(
                    "main_claim_not_primary_snapshot",
                    location,
                    f"main-target claim must bind to primary snapshot, got `{snapshot_id}` ({snapshot.get('tier')})",
                )

        code_refs = claim.get("code_refs", [])
        if not isinstance(code_refs, list) or not code_refs:
            add("claim_missing_code_refs", location, "code_refs must be non-empty list")
        else:
            for ref in code_refs:
                resolved = resolve_ref_path(root, str(ref))
                if not resolved.exists():
                    add("claim_missing_code_ref", location, f"code ref does not exist: {ref}")

        artifact_refs = claim.get("artifact_refs", [])
        if not isinstance(artifact_refs, list) or not artifact_refs:
            add("claim_missing_artifact_refs", location, "artifact_refs must be non-empty list")
        else:
            for ref in artifact_refs:
                resolved = resolve_ref_path(root, str(ref))
                if not resolved.exists():
                    add("claim_missing_artifact_ref", location, f"artifact ref does not exist: {ref}")

    if main_tex_path.exists():
        main_text = main_tex_path.read_text(encoding="utf-8", errors="ignore")
        for snapshot in snapshot_by_id.values():
            if str(snapshot.get("tier", "")) != "secondary":
                continue
            sec_date = str(snapshot.get("artifact_date", "")).strip()
            if sec_date and sec_date in main_text:
                add(
                    "secondary_snapshot_leak_in_main",
                    str(main_tex_path),
                    f"main text must not reference secondary artifact date {sec_date}",
                )
    else:
        add("missing_main_tex", str(main_tex_path), "main tex file does not exist")

    status = "pass" if not violations else "fail"
    payload = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "snapshots_file": str(snapshots_path),
        "claims_file": str(claims_path),
        "violations": violations,
    }

    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(build_md(status, violations), encoding="utf-8")

    print(f"[claim-traceability] status={status}")
    print(f"[claim-traceability] wrote {out_json}")
    print(f"[claim-traceability] wrote {out_md}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
