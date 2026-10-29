#!/usr/bin/env python3
"""Claim-language guardrails for TDSC manuscript text.

This script is intentionally conservative: it flags wording drift that can
over-claim v1/v2 secrecy semantics or downgrade resistance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List


@dataclass
class Violation:
    rule: str
    file: str
    line: int
    text: str
    detail: str


def _line_qualifies_forward_secrecy(line: str) -> bool:
    lower = line.lower()
    qualifiers = (
        "v1",
        "v2",
        "hybrid",
        "suite-dependent",
        "post-compromise",
        "does not",
        "do not",
        "not claim",
        "not claimed",
        "no full",
        "legacy",
        "static kem",
    )
    return any(q in lower for q in qualifiers)


def check_file(path: Path) -> List[Violation]:
    violations: List[Violation] = []
    text = path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()

    fs_pat = re.compile(r"\bforward secrecy\b|\bPFS\b", re.IGNORECASE)
    downgrade_abs_pat = re.compile(
        r"(?i)(?:\bnever\b|\bcannot\b|\bimpossible\b).{0,40}\bdowngrad|\bdowngrad.{0,40}(?:\bnever\b|\bcannot\b|\bimpossible\b)"
    )

    for idx, line in enumerate(lines, start=1):
        if "\\bibitem" in line:
            continue

        if fs_pat.search(line):
            if "&" in line and "pfs" in line.lower():
                continue
            start = max(0, idx - 5)
            end = min(len(lines), idx + 2)
            context = " ".join(lines[start:end])
            if _line_qualifies_forward_secrecy(context):
                continue
            violations.append(
                Violation(
                    rule="unqualified_forward_secrecy_reference",
                    file=str(path),
                    line=idx,
                    text=line.strip(),
                    detail="forward-secrecy wording should carry explicit v1/v2 or hybrid qualifier",
                )
            )

        if downgrade_abs_pat.search(line):
            lower = line.lower()
            contextual_terms = ("strict", "default", "policy", "model", "under ", "gate")
            if not any(term in lower for term in contextual_terms):
                violations.append(
                    Violation(
                        rule="absolute_downgrade_claim_without_scope",
                        file=str(path),
                        line=idx,
                        text=line.strip(),
                        detail="downgrade-impossibility claims must include explicit scope/conditions",
                    )
                )

    return violations


def required_phrase_checks(main_text: str, main_file: Path) -> List[Violation]:
    violations: List[Violation] = []
    if not re.search(r"do not claim forward secrecy.*v1", main_text, re.IGNORECASE | re.DOTALL):
        violations.append(
            Violation(
                rule="missing_v1_non_fs_guardrail",
                file=str(main_file),
                line=1,
                text="",
                detail="missing explicit v1 non-forward-secrecy disclaimer",
            )
        )
    if not re.search(r"v2.*hybrid", main_text, re.IGNORECASE | re.DOTALL):
        violations.append(
            Violation(
                rule="missing_v2_hybrid_guardrail",
                file=str(main_file),
                line=1,
                text="",
                detail="missing explicit v2 hybrid secrecy qualifier",
            )
        )
    return violations


def check_claim_manifest_contract(path: Path) -> List[Violation]:
    violations: List[Violation] = []
    if not path.exists():
        violations.append(
            Violation(
                rule="missing_claim_manifest",
                file=str(path),
                line=1,
                text="",
                detail="claim manifest file is missing",
            )
        )
        return violations

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        violations.append(
            Violation(
                rule="claim_manifest_parse_error",
                file=str(path),
                line=1,
                text="",
                detail=f"claim manifest must be JSON-compatible YAML: {exc}",
            )
        )
        return violations

    claims = payload.get("claims")
    if not isinstance(claims, list) or not claims:
        violations.append(
            Violation(
                rule="empty_claim_manifest",
                file=str(path),
                line=1,
                text="",
                detail="claim manifest must define a non-empty `claims` list",
            )
        )
        return violations

    for idx, claim in enumerate(claims, start=1):
        scope = str(claim.get("scope", "")).strip() if isinstance(claim, dict) else ""
        assumptions = claim.get("assumptions") if isinstance(claim, dict) else None

        if not scope:
            violations.append(
                Violation(
                    rule="missing_claim_scope",
                    file=str(path),
                    line=idx,
                    text="",
                    detail="each claim must declare non-empty `scope`",
                )
            )
        if not isinstance(assumptions, list) or not assumptions or any(not str(a).strip() for a in assumptions):
            violations.append(
                Violation(
                    rule="missing_claim_assumptions",
                    file=str(path),
                    line=idx,
                    text="",
                    detail="each claim must declare non-empty `assumptions` list",
                )
            )

    return violations


def build_markdown_report(artifact_date: str, violations: List[Violation], checked_files: List[Path]) -> str:
    status = "PASS" if not violations else "FAIL"
    out: List[str] = []
    out.append("# Claim Guardrail Report")
    out.append("")
    out.append(f"- Generated at: {dt.datetime.now(dt.timezone.utc).isoformat()}")
    out.append(f"- Artifact date: {artifact_date}")
    out.append(f"- Status: **{status}**")
    out.append("")
    out.append("## Checked Files")
    out.append("")
    for file in checked_files:
        out.append(f"- `{file}`")
    out.append("")
    out.append("## Violations")
    out.append("")
    if not violations:
        out.append("- none")
    else:
        for v in violations:
            loc = f"{v.file}:{v.line}"
            snippet = v.text if v.text else "(document-level check)"
            out.append(f"- `{v.rule}` at `{loc}`: {v.detail}. Snippet: `{snippet}`")
    out.append("")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-date", default="2026-01-23")
    parser.add_argument(
        "--files",
        nargs="+",
        default=[
            "Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex",
            "Docs/TDSC-2026-01-0318_supplementary.tex",
        ],
    )
    parser.add_argument("--out-json")
    parser.add_argument("--out-md")
    parser.add_argument("--claim-manifest", default="Docs/claim_manifest.yaml")
    args = parser.parse_args()

    checked_files = [Path(f) for f in args.files]
    violations: List[Violation] = []
    for file in checked_files:
        if not file.exists():
            violations.append(
                Violation(
                    rule="missing_file",
                    file=str(file),
                    line=1,
                    text="",
                    detail="file does not exist",
                )
            )
            continue
        violations.extend(check_file(file))

    main_file = checked_files[0]
    if main_file.exists():
        main_text = main_file.read_text(encoding="utf-8", errors="ignore")
        violations.extend(required_phrase_checks(main_text, main_file))

    violations.extend(check_claim_manifest_contract(Path(args.claim_manifest)))

    out_json = Path(args.out_json or f"Artifacts/claim_guardrails_{args.artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/claim_guardrails_{args.artifact_date}.md")
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "status": "pass" if not violations else "fail",
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": args.artifact_date,
        "checked_files": [str(p) for p in checked_files],
        "violations": [v.__dict__ for v in violations],
    }
    out_json.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(
        build_markdown_report(args.artifact_date, violations, checked_files),
        encoding="utf-8",
    )

    print(f"[claim-guardrails] status={payload['status']}")
    print(f"[claim-guardrails] wrote {out_json}")
    print(f"[claim-guardrails] wrote {out_md}")
    return 0 if payload["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
