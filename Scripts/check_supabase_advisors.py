#!/usr/bin/env python3
"""Read-only deployment gate; never changes remote configuration or suppresses errors."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def access_token() -> str:
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    if token:
        return token
    if sys.platform != "darwin":
        raise RuntimeError("SUPABASE_ACCESS_TOKEN is required")
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "Supabase CLI", "-a", "supabase", "-w"],
        capture_output=True, text=True, timeout=15, check=False,
    )
    if result.returncode:
        raise RuntimeError("Supabase CLI credential unavailable in Keychain")
    token = result.stdout.strip()
    if token.startswith("go-keyring-base64:"):
        token = base64.b64decode(token.split(":", 1)[1], validate=True).decode()
    if not token:
        raise RuntimeError("Supabase credential is empty")
    return token


def api(token: str, project: str, suffix: str, query: str | None = None):
    # The sole POST is a read-only SQL query; migrations use the CLI separately.
    payload = None if query is None else json.dumps({"query": query, "read_only": True}).encode()
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project}/{suffix}", data=payload,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Never print config payloads, headers, or potentially sensitive error bodies.
        raise RuntimeError(f"Supabase {suffix}: HTTP {error.code}") from None


def findings(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("lints"), list):
        raise ValueError("Unknown Advisor response shape")
    for lint in payload["lints"]:
        if not all(key in lint for key in ("name", "level")):
            raise ValueError("Advisor finding is missing severity or name")
        if "findings" in lint:
            if not isinstance(lint["findings"], list):
                raise ValueError("Invalid grouped Advisor findings")
            if lint.get("count", len(lint["findings"])) != len(lint["findings"]):
                raise ValueError("Advisor findings are incomplete")
            for item in lint["findings"]:
                yield {**lint, **item, "metadata": item.get("metadata", {})}
        else:
            yield lint


def classify(payload, contract):
    report = {"intentional": [], "informational": [], "unresolved": []}
    for finding in findings(payload):
        name, level = finding["name"], finding["level"]
        metadata = finding.get("metadata", {})
        item = {"name": name, "level": level, "metadata": metadata,
                "remediation": finding.get("remediation")}
        expected = any(entry["lint"] == name and entry["metadata"] == metadata
                       for entry in contract["intentional"])
        if level not in ("INFO", "WARN", "ERROR"):
            raise ValueError(f"Unknown Advisor severity: {level}")
        if expected and level != "ERROR":
            report["intentional"].append(item)
        elif level == "INFO" and name in ("rls_enabled_no_policy", "unused_index"):
            report["informational"].append(item)
        else:
            report["unresolved"].append(item)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contract = json.loads((ROOT / "supabase/advisor_contract.json").read_text())
    if not re.fullmatch(r"[a-z]{20}", args.project_ref) or args.project_ref != contract["project_ref"]:
        raise ValueError("Project reference does not match the reviewed contract")
    token = access_token()
    report = {"project_ref": args.project_ref, "checks": {}, "advisors": {}}
    for category in ("security", "performance"):
        report["advisors"][category] = classify(api(token, args.project_ref, f"advisors/{category}"), contract)
    auth = api(token, args.project_ref, "config/auth")
    otp = auth.get("mailer_otp_exp")
    report["checks"]["email_otp_bounded"] = isinstance(otp, int) and 0 < otp <= contract["email_otp_max_seconds"]
    report["auth"] = {"mailer_otp_exp": otp, "password_hibp_enabled": auth.get("password_hibp_enabled")}
    rest = api(token, args.project_ref, "postgrest")
    schemas = rest.get("db_schema")
    if not isinstance(schemas, str):
        raise ValueError("Unknown Data API schema configuration")
    report["checks"]["net_schema_private"] = "net" not in {s.strip().strip('"') for s in schemas.split(",")}
    report["data_api_schemas"] = schemas
    routine_contract = json.loads((ROOT / "supabase/routine_contract.json").read_text())
    routines = api(token, args.project_ref, "database/query", routine_contract["query"])
    if not isinstance(routines, list):
        raise ValueError("Unknown routine inventory response")
    observed = {row["signature"]: hashlib.sha256(json.dumps(
        row, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode()).hexdigest() for row in routines}
    expected_routines = routine_contract["sha256"]
    report["routine_drift"] = sorted(name for name in set(observed) | set(expected_routines)
                                      if observed.get(name) != expected_routines.get(name))
    report["checks"]["routine_definitions_match"] = not report["routine_drift"]
    remote = api(token, args.project_ref, "database/query",
                 "SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version")
    if not isinstance(remote, list) or any("version" not in entry or "name" not in entry for entry in remote):
        raise ValueError("Unknown migration history response shape")
    local = {p.name.split("_", 1)[0]: p.stem.split("_", 1)[1]
             for p in (ROOT / "supabase/migrations").glob("*.sql")}
    applied = {entry["version"]: entry["name"] for entry in remote}
    report["migrations"] = {
        "pending": sorted(set(local) - set(applied)),
        "remote_only": sorted(set(applied) - set(local)),
        "name_mismatch": sorted(v for v in set(local) & set(applied) if local[v] != applied[v]),
    }
    report["checks"]["migration_history_matches"] = not any(report["migrations"].values())
    try:
        api(token, args.project_ref, "database/query",
            (ROOT / "supabase/verification/auth_privilege_boundaries_acceptance.sql").read_text()
            + "\n" + (ROOT / "supabase/verification/advisor_security_acceptance.sql").read_text())
        report["checks"]["database_invariants"] = True
    except RuntimeError as error:
        report["checks"]["database_invariants"] = False
        report["database_check_error"] = str(error)
    report["passed"] = all(report["checks"].values()) and not any(
        r["unresolved"] for r in report["advisors"].values())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "checks": report["checks"],
                      "migrations": report["migrations"],
                      "advisors": {k: {s: len(v) for s, v in r.items()}
                                   for k, r in report["advisors"].items()}}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Supabase check failed: {error}", file=sys.stderr)
        raise SystemExit(2)
