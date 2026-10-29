#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from bench_profiles import APPLE_PQC_CONFIG, CONTRAST_CONFIGS, CORE_GATE_CONFIGS

ROOT_DIR = Path(__file__).resolve().parent.parent
RUNS_DIR = ROOT_DIR / "Artifacts" / "runs"
EXPECTED_ARTIFACT_DATE = "2026-01-23"

V1_CFG = "liboqs PQC (ML-KEM-768 + ML-DSA-65)"
V2_CFG = "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"


@dataclass
class RunSnapshot:
    run_id: str
    claims: dict
    exists_count: int
    all_count: int
    main_pdf_hash: str | None
    supp_pdf_hash: str | None


def pick_latest_succeeded_runs() -> tuple[Path, Path]:
    candidates: list[Path] = []
    if not RUNS_DIR.exists():
        raise SystemExit(f"missing runs directory: {RUNS_DIR}")

    for run_dir in RUNS_DIR.iterdir():
        if not run_dir.is_dir():
            continue
        status_env = run_dir / "status.env"
        if not status_env.exists():
            continue
        data = status_env.read_text(encoding="utf-8", errors="ignore")
        if "STATE=succeeded" not in data:
            continue
        candidates.append(run_dir)

    candidates.sort(key=lambda p: p.name)
    if len(candidates) < 2:
        raise SystemExit("need at least two succeeded runs")
    return candidates[-2], candidates[-1]


def parse_tamarin_counts(summary_path: Path) -> tuple[int, int]:
    text = summary_path.read_text(encoding="utf-8")
    exists_count = len(re.findall(r"\(exists-trace\): verified", text))
    all_count = len(re.findall(r"\(all-traces\): verified", text))
    if re.search(r"(falsified|not verified|attack found|unknown)", text):
        raise SystemExit(f"non-verified lemmas found in {summary_path}")
    return exists_count, all_count


def extract_pdf_text_hash(pdf_path: Path) -> str | None:
    if not pdf_path.exists():
        return None
    try:
        proc = subprocess.run(
            ["pdftotext", str(pdf_path), "-"],
            check=True,
            capture_output=True,
            text=True,
        )
    except Exception:
        return None

    text = proc.stdout
    normalized = "\n".join(line.rstrip() for line in text.splitlines() if line.strip())
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def parse_macros(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r"\\newcommand\{\\([A-Za-z0-9]+)\}\{([^}]*)\}")
    return {m.group(1): m.group(2).strip() for m in pattern.finditer(text)}


def _fmt(value: float, digits: int = 3) -> str:
    return f"{value:.{digits}f}"


def verify_claim_macro_alignment(claims: dict, macro_path: Path) -> list[str]:
    issues: list[str] = []
    macros = parse_macros(macro_path)

    latency = claims["latency"]
    v2 = claims["v2_vs_v1"]
    wire = claims["wire_size_bytes"]

    expected = {
        "claimArtifactDate": claims["artifact_date"],
        "claimClassicPNineNineMs": _fmt(latency["Classic (X25519 + Ed25519)"]["p99"]),
        "claimLiboqsPNineNineMs": _fmt(latency["liboqs PQC (ML-KEM-768 + ML-DSA-65)"]["p99"]),
        "claimLiboqsVTwoPNineNineMs": _fmt(latency["liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"]["p99"]),
        "claimClassicPayloadBytes": str(wire["classic_payload_handshake"]),
        "claimLiboqsPayloadBytes": str(wire["liboqs_payload_handshake"]),
        "claimVTwoDeltaPayloadBytes": str(v2["delta_payload_handshake_bytes"]),
        "claimVTwoDeltaMessageABytes": str(v2["delta_message_a_bytes"]),
        "claimVTwoDeltaMessageBBytes": str(v2["delta_message_b_bytes"]),
        "claimVTwoPNineFiveDeltaMs": _fmt(v2["delta_p95_latency_ms"]),
    }

    contrast = claims.get("contrast", {})
    apple_latency = contrast.get("latency", {}).get(APPLE_PQC_CONFIG)
    if apple_latency and "claimCryptoKitPNineNineMs" in macros:
        expected["claimCryptoKitPNineNineMs"] = _fmt(float(apple_latency["p99"]))

    for macro, expected_value in expected.items():
        actual = macros.get(macro)
        if actual != expected_value:
            issues.append(
                f"macro mismatch in {macro_path.name}: {macro} expected '{expected_value}' got '{actual}'"
            )

    return issues


def _parse_perf_row(line: str) -> tuple[str, float, float, float, float, int] | None:
    pattern = re.compile(
        r"^\s*(Classic|liboqs PQC|liboqs v2 FS)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9,]+)\s*&"
    )
    m = pattern.search(line)
    if not m:
        return None
    return (
        m.group(1),
        float(m.group(2)),
        float(m.group(3)),
        float(m.group(4)),
        float(m.group(5)),
        int(m.group(6).replace(",", "")),
    )


def verify_perf_table_alignment(claims: dict, perf_path: Path, tol: float = 0.03) -> list[str]:
    issues: list[str] = []
    rows = {}

    for raw in perf_path.read_text(encoding="utf-8").splitlines():
        parsed = _parse_perf_row(raw)
        if parsed:
            rows[parsed[0]] = parsed

    mapping = {
        "Classic": "Classic (X25519 + Ed25519)",
        "liboqs PQC": "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
        "liboqs v2 FS": "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)",
    }

    wire = claims["wire_size_bytes"]
    wire_map = {
        "Classic": wire["classic_payload_handshake"],
        "liboqs PQC": wire["liboqs_payload_handshake"],
        "liboqs v2 FS": claims["v2_vs_v1"]["v2_payload_handshake_bytes"],
    }

    for row_name, claim_key in mapping.items():
        row = rows.get(row_name)
        if row is None:
            issues.append(f"missing row '{row_name}' in {perf_path.name}")
            continue

        _, mean_v, p95_v, p50_rtt, p95_rtt, wire_bytes = row
        expected_latency = claims["latency"][claim_key]
        expected_rtt = claims["rtt"][claim_key]

        if abs(mean_v - float(expected_latency["mean"])) > tol:
            issues.append(f"{perf_path.name} {row_name} mean mismatch")
        if abs(p95_v - float(expected_latency["p95"])) > tol:
            issues.append(f"{perf_path.name} {row_name} p95 mismatch")
        if abs(p50_rtt - float(expected_rtt["p50"])) > tol:
            issues.append(f"{perf_path.name} {row_name} p50 RTT mismatch")
        if abs(p95_rtt - float(expected_rtt["p95"])) > tol:
            issues.append(f"{perf_path.name} {row_name} p95 RTT mismatch")
        if wire_bytes != int(wire_map[row_name]):
            issues.append(f"{perf_path.name} {row_name} wire size mismatch")

    return issues


def _parse_v2_compare_row(line: str) -> tuple[str, float, float, float, float, int] | None:
    pattern = re.compile(
        r"^\s*(liboqs v1|liboqs v2 FS)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9.]+)\s*&\s*([0-9,]+)"
    )
    m = pattern.search(line)
    if not m:
        return None
    return (
        m.group(1),
        float(m.group(2)),
        float(m.group(3)),
        float(m.group(4)),
        float(m.group(5)),
        int(m.group(6).replace(",", "")),
    )


def verify_v2_table_alignment(claims: dict, table_path: Path, tol: float = 0.03) -> list[str]:
    issues: list[str] = []
    rows = {}

    for raw in table_path.read_text(encoding="utf-8").splitlines():
        parsed = _parse_v2_compare_row(raw)
        if parsed:
            rows[parsed[0]] = parsed

    if "liboqs v1" not in rows:
        issues.append(f"missing row 'liboqs v1' in {table_path.name}")
    if "liboqs v2 FS" not in rows:
        issues.append(f"missing row 'liboqs v2 FS' in {table_path.name}")
    if issues:
        return issues

    v1 = rows["liboqs v1"]
    v2 = rows["liboqs v2 FS"]

    claims_v2 = claims["v2_vs_v1"]
    lat = claims["v2_latency"]
    rtt = claims["v2_rtt"]

    expected = {
        "liboqs v1": {
            "mean": float(lat[V1_CFG]["mean"]),
            "p95": float(lat[V1_CFG]["p95"]),
            "p50_rtt": float(rtt[V1_CFG]["p50"]),
            "p95_rtt": float(rtt[V1_CFG]["p95"]),
            "payload": int(claims_v2["v1_payload_handshake_bytes"]),
        },
        "liboqs v2 FS": {
            "mean": float(lat[V2_CFG]["mean"]),
            "p95": float(lat[V2_CFG]["p95"]),
            "p50_rtt": float(rtt[V2_CFG]["p50"]),
            "p95_rtt": float(rtt[V2_CFG]["p95"]),
            "payload": int(claims_v2["v2_payload_handshake_bytes"]),
        },
    }

    for row_name, row in (("liboqs v1", v1), ("liboqs v2 FS", v2)):
        _, mean_v, p95_v, p50_rtt, p95_rtt, payload = row
        exp = expected[row_name]
        if abs(mean_v - exp["mean"]) > tol:
            issues.append(f"{table_path.name} {row_name} mean mismatch")
        if abs(p95_v - exp["p95"]) > tol:
            issues.append(f"{table_path.name} {row_name} p95 mismatch")
        if abs(p50_rtt - exp["p50_rtt"]) > tol:
            issues.append(f"{table_path.name} {row_name} p50 RTT mismatch")
        if abs(p95_rtt - exp["p95_rtt"]) > tol:
            issues.append(f"{table_path.name} {row_name} p95 RTT mismatch")
        if payload != exp["payload"]:
            issues.append(f"{table_path.name} {row_name} payload mismatch")

    return issues


def load_snapshot(run_dir: Path, artifact_date: str) -> RunSnapshot:
    snapshot = run_dir / "snapshot"
    if not snapshot.exists():
        raise SystemExit(f"missing snapshot dir: {snapshot}")

    claims_path = snapshot / f"claims_{artifact_date}.json"
    tamarin_path = snapshot / f"tamarin_skybridge_v2_summary_{artifact_date}.txt"
    macros_path = snapshot / "claims_macros.tex"
    perf_table_path = snapshot / "perf_summary.tex"
    v2_table_path = snapshot / "s12_v2_v1_compare.tex"

    required = [claims_path, tamarin_path, macros_path, perf_table_path, v2_table_path]
    for path in required:
        if not path.exists():
            raise SystemExit(f"missing snapshot artifact: {path}")

    claims = json.loads(claims_path.read_text(encoding="utf-8"))

    if claims.get("artifact_date") != artifact_date:
        raise SystemExit(
            f"claims artifact date mismatch in {claims_path}: {claims.get('artifact_date')}"
        )

    exists_count, all_count = parse_tamarin_counts(tamarin_path)
    if exists_count < 2:
        raise SystemExit(f"{tamarin_path.name}: exists-trace verified count < 2")
    if all_count < 6:
        raise SystemExit(f"{tamarin_path.name}: all-traces verified count < 6")

    claim_issues = []
    claim_issues.extend(verify_claim_macro_alignment(claims, macros_path))
    claim_issues.extend(verify_perf_table_alignment(claims, perf_table_path))
    claim_issues.extend(verify_v2_table_alignment(claims, v2_table_path))
    if claim_issues:
        joined = "; ".join(claim_issues)
        raise SystemExit(f"claim/table consistency failed for run {run_dir.name}: {joined}")

    return RunSnapshot(
        run_id=run_dir.name,
        claims=claims,
        exists_count=exists_count,
        all_count=all_count,
        main_pdf_hash=extract_pdf_text_hash(
            snapshot / "TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
        ),
        supp_pdf_hash=extract_pdf_text_hash(snapshot / "TDSC-2026-01-0318_supplementary.pdf"),
    )


def relative_drift(a: float, b: float) -> float:
    base = max(abs(a), 1e-9)
    return abs(a - b) / base


def compare_claims(a: dict, b: dict, max_drift: float) -> list[str]:
    issues: list[str] = []

    for category in ("latency", "rtt"):
        for cfg in CORE_GATE_CONFIGS:
            row_a = a.get(category, {}).get(cfg)
            row_b = b.get(category, {}).get(cfg)
            if not row_a:
                issues.append(f"missing {category} config in runA claims: {cfg}")
                continue
            if not row_b:
                issues.append(f"missing {category} config in runB claims: {cfg}")
                continue

            for field in ("mean", "p95"):
                drift = relative_drift(float(row_a[field]), float(row_b[field]))
                if drift > max_drift:
                    issues.append(
                        f"{category} drift {cfg} {field}: {drift * 100:.2f}% (> {max_drift * 100:.2f}%)"
                    )

    wire_a = a.get("wire_size_bytes")
    wire_b = b.get("wire_size_bytes")
    if wire_a != wire_b:
        issues.append("message size mismatch: wire_size_bytes differs")

    v2_a = a.get("v2_vs_v1", {})
    v2_b = b.get("v2_vs_v1", {})
    exact_keys = [
        "v1_payload_handshake_bytes",
        "v2_payload_handshake_bytes",
        "delta_payload_handshake_bytes",
        "delta_message_a_bytes",
        "delta_message_b_bytes",
    ]
    for key in exact_keys:
        if v2_a.get(key) != v2_b.get(key):
            issues.append(f"message size mismatch: v2_vs_v1.{key} differs")

    return issues


def compare_contrast(a: dict, b: dict, max_drift: float) -> list[str]:
    notes: list[str] = []
    contrast_a = a.get("contrast", {})
    contrast_b = b.get("contrast", {})
    lat_a = contrast_a.get("latency", {})
    lat_b = contrast_b.get("latency", {})
    rtt_a = contrast_a.get("rtt", {})
    rtt_b = contrast_b.get("rtt", {})

    for cfg in CONTRAST_CONFIGS:
        if cfg not in lat_a or cfg not in lat_b or cfg not in rtt_a or cfg not in rtt_b:
            continue
        for category, aa, bb in (
            ("latency", lat_a[cfg], lat_b[cfg]),
            ("rtt", rtt_a[cfg], rtt_b[cfg]),
        ):
            for field in ("mean", "p95"):
                drift = relative_drift(float(aa[field]), float(bb[field]))
                label = f"{category} drift {cfg} {field}: {drift * 100:.2f}%"
                if drift > max_drift:
                    notes.append(f"contrast_high_drift {label}")
                else:
                    notes.append(f"contrast_ok {label}")
    return notes


def build_markdown_report(
    run_a: RunSnapshot,
    run_b: RunSnapshot,
    max_drift: float,
    issues: list[str],
    warnings: list[str],
    contrast_notes: list[str],
) -> str:
    lines: list[str] = []
    lines.append("# Stability Report")
    lines.append("")
    lines.append(f"- Run A: `{run_a.run_id}`")
    lines.append(f"- Run B: `{run_b.run_id}`")
    lines.append(f"- Drift threshold: {max_drift * 100:.2f}%")
    lines.append("")

    lines.append("## Gate Results")
    lines.append("- Claim-level drift gate: " + ("FAIL" if any("drift" in x for x in issues) else "PASS"))
    lines.append("- Message-size exact match gate: " + ("FAIL" if any("message size mismatch" in x for x in issues) else "PASS"))
    lines.append(
        "- Tamarin lemma-count gate: "
        + (
            "PASS"
            if run_a.exists_count == run_b.exists_count and run_a.all_count == run_b.all_count
            else "FAIL"
        )
    )
    lines.append(
        "- Claim/table consistency gate: "
        + ("FAIL" if any("claim/table" in x for x in issues) else "PASS")
    )
    lines.append("")

    lines.append("## Tamarin")
    lines.append(f"- runA exists-trace verified: {run_a.exists_count}")
    lines.append(f"- runA all-traces verified: {run_a.all_count}")
    lines.append(f"- runB exists-trace verified: {run_b.exists_count}")
    lines.append(f"- runB all-traces verified: {run_b.all_count}")
    lines.append("")

    lines.append("## Contrast (Non-Gating)")
    if contrast_notes:
        for note in contrast_notes:
            lines.append(f"- {note}")
    else:
        lines.append("- contrast data unavailable in one or both runs")
    lines.append("")

    if warnings:
        lines.append("## Warnings")
        for warning in warnings:
            lines.append(f"- {warning}")
        lines.append("")

    lines.append("## Verdict")
    if issues:
        lines.append("- FAIL")
        for issue in issues:
            lines.append(f"- {issue}")
    else:
        lines.append("- PASS")

    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare two run snapshots for stability")
    parser.add_argument("--run-a", help="run id for baseline")
    parser.add_argument("--run-b", help="run id for comparison")
    parser.add_argument(
        "--max-drift",
        type=float,
        default=0.07,
        help="max allowed relative drift for core metrics",
    )
    parser.add_argument(
        "--artifact-date",
        default=EXPECTED_ARTIFACT_DATE,
        help="artifact date suffix used in snapshots",
    )
    parser.add_argument("--output", help="optional markdown report path")
    args = parser.parse_args()

    if args.max_drift <= 0:
        raise SystemExit("--max-drift must be > 0")

    if args.artifact_date != EXPECTED_ARTIFACT_DATE:
        raise SystemExit(
            f"artifact date must be {EXPECTED_ARTIFACT_DATE}, got {args.artifact_date}"
        )

    if args.run_a and args.run_b:
        run_a_dir = RUNS_DIR / args.run_a
        run_b_dir = RUNS_DIR / args.run_b
    else:
        run_a_dir, run_b_dir = pick_latest_succeeded_runs()

    run_a = load_snapshot(run_a_dir, args.artifact_date)
    run_b = load_snapshot(run_b_dir, args.artifact_date)

    issues = compare_claims(run_a.claims, run_b.claims, max_drift=args.max_drift)

    if run_a.exists_count != run_b.exists_count:
        issues.append("tamarin exists-trace lemma count mismatch")
    if run_a.all_count != run_b.all_count:
        issues.append("tamarin all-traces lemma count mismatch")

    warnings: list[str] = []
    contrast_notes = compare_contrast(run_a.claims, run_b.claims, max_drift=args.max_drift)
    if run_a.main_pdf_hash and run_b.main_pdf_hash and run_a.main_pdf_hash != run_b.main_pdf_hash:
        warnings.append("main paper text hash mismatch (warning only)")
    if run_a.supp_pdf_hash and run_b.supp_pdf_hash and run_a.supp_pdf_hash != run_b.supp_pdf_hash:
        warnings.append("supplementary paper text hash mismatch (warning only)")

    report_text = build_markdown_report(run_a, run_b, args.max_drift, issues, warnings, contrast_notes)

    if args.output:
        report_path = Path(args.output)
    else:
        report_path = RUNS_DIR / f"stability_{run_a.run_id}_vs_{run_b.run_id}.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report_text, encoding="utf-8")

    print(f"stability_report={report_path}")
    for warning in warnings:
        print(f"WARN: {warning}")

    if issues:
        for issue in issues:
            print(f"FAIL: {issue}")
        raise SystemExit(1)

    print("Stability check passed.")
    print(f"run_a={run_a.run_id}")
    print(f"run_b={run_b.run_id}")


if __name__ == "__main__":
    main()
