#!/usr/bin/env python3
import argparse
import json
import os
from dataclasses import dataclass
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
RUNS_DIR = ROOT_DIR / "Artifacts" / "runs"
EXPECTED_ARTIFACT_DATE = "2026-01-23"

CORE_CONFIGS = [
    "Classic (X25519 + Ed25519)",
    "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
    "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
    "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)",
]

METRICS = [
    ("latency", "mean"),
    ("latency", "p95"),
    ("rtt", "mean"),
    ("rtt", "p95"),
]


@dataclass
class DiffRow:
    config: str
    category: str
    field: str
    baseline: float
    candidate: float
    delta_ratio: float


def _resolve_artifact_date(value: str | None) -> str:
    if value:
        date = value.strip()
    else:
        date = (
            os.environ.get("ARTIFACT_DATE")
            or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
            or EXPECTED_ARTIFACT_DATE
        ).strip()
    if date != EXPECTED_ARTIFACT_DATE:
        raise SystemExit(f"ARTIFACT_DATE must be {EXPECTED_ARTIFACT_DATE}, got {date}")
    return date


def _pick_latest_succeeded_runs() -> tuple[Path, Path]:
    candidates: list[Path] = []
    if not RUNS_DIR.exists():
        raise SystemExit(f"missing runs directory: {RUNS_DIR}")

    for run_dir in RUNS_DIR.iterdir():
        if not run_dir.is_dir():
            continue
        status_env = run_dir / "status.env"
        if not status_env.exists():
            continue
        text = status_env.read_text(encoding="utf-8", errors="ignore")
        if "STATE=succeeded" in text:
            candidates.append(run_dir)

    candidates.sort(key=lambda p: p.name)
    if len(candidates) < 2:
        raise SystemExit("need at least two succeeded runs")
    return candidates[-2], candidates[-1]


def _load_claims(run_dir: Path, artifact_date: str) -> dict:
    snapshot_claims = run_dir / "snapshot" / f"claims_{artifact_date}.json"
    if snapshot_claims.exists():
        return json.loads(snapshot_claims.read_text(encoding="utf-8"))

    root_claims = ROOT_DIR / "Artifacts" / f"claims_{artifact_date}.json"
    if root_claims.exists():
        return json.loads(root_claims.read_text(encoding="utf-8"))

    raise SystemExit(f"missing claims for run {run_dir.name}: {snapshot_claims}")


def _safe_ratio_delta(baseline: float, candidate: float) -> float:
    denom = max(abs(baseline), 1e-9)
    return (candidate - baseline) / denom


def _collect_diffs(baseline: dict, candidate: dict) -> list[DiffRow]:
    rows: list[DiffRow] = []

    for category, field in METRICS:
        b_bucket = baseline.get(category, {})
        c_bucket = candidate.get(category, {})

        for config in CORE_CONFIGS:
            b_values = b_bucket.get(config)
            c_values = c_bucket.get(config)
            if b_values is None:
                raise SystemExit(f"missing baseline {category} config: {config}")
            if c_values is None:
                raise SystemExit(f"missing candidate {category} config: {config}")

            baseline_value = float(b_values[field])
            candidate_value = float(c_values[field])
            rows.append(
                DiffRow(
                    config=config,
                    category=category,
                    field=field,
                    baseline=baseline_value,
                    candidate=candidate_value,
                    delta_ratio=_safe_ratio_delta(baseline_value, candidate_value),
                )
            )

    return rows


def _format_config(config: str) -> str:
    if config.startswith("Classic"):
        return "Classic"
    if config.startswith("liboqs PQC v2 FS"):
        return "liboqs v2 FS"
    if config.startswith("liboqs PQC"):
        return "liboqs PQC"
    if config.startswith("CryptoKit PQC"):
        return "CryptoKit PQC"
    return config


def _write_report(
    output_path: Path,
    run_a: str,
    run_b: str,
    threshold: float,
    regressions: list[DiffRow],
    breakthroughs: list[DiffRow],
    all_rows: list[DiffRow],
) -> None:
    lines: list[str] = []
    lines.append("# Flagship Performance Report")
    lines.append("")
    lines.append(f"- Baseline run: `{run_a}`")
    lines.append(f"- Candidate run: `{run_b}`")
    lines.append(f"- Regression threshold: {threshold * 100:.2f}%")
    lines.append("")

    lines.append("## Verdict")
    if regressions:
        lines.append(f"- FAIL: {len(regressions)} regression(s) exceeded threshold.")
    else:
        lines.append("- PASS: no metric regressed beyond threshold.")

    if breakthroughs:
        lines.append(f"- BREAKTHROUGH: {len(breakthroughs)} metric(s) improved beyond threshold.")
    else:
        lines.append("- BREAKTHROUGH: none above threshold.")

    lines.append("")
    lines.append("## Core Metrics")
    lines.append("")
    lines.append("| Config | Metric | Baseline | Candidate | Delta |")
    lines.append("|---|---|---:|---:|---:|")
    for row in all_rows:
        metric_name = f"{row.category}.{row.field}"
        lines.append(
            "| "
            + " | ".join(
                [
                    _format_config(row.config),
                    metric_name,
                    f"{row.baseline:.4f}",
                    f"{row.candidate:.4f}",
                    f"{row.delta_ratio * 100:+.2f}%",
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append("## Regressions")
    if regressions:
        for row in regressions:
            lines.append(
                f"- {_format_config(row.config)} {row.category}.{row.field}: {row.delta_ratio * 100:+.2f}%"
            )
    else:
        lines.append("- none")

    lines.append("")
    lines.append("## Breakthroughs")
    if breakthroughs:
        for row in breakthroughs:
            lines.append(
                f"- {_format_config(row.config)} {row.category}.{row.field}: {row.delta_ratio * 100:+.2f}%"
            )
    else:
        lines.append("- none")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Check flagship performance regression between two runs")
    parser.add_argument("--run-a", help="baseline run id")
    parser.add_argument("--run-b", help="candidate run id")
    parser.add_argument("--artifact-date", default=None, help="artifact date (must be 2026-01-23)")
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.03,
        help="regression/improvement threshold as fraction (default: 0.03)",
    )
    parser.add_argument("--output", default=None, help="markdown report output path")
    args = parser.parse_args()

    if args.threshold <= 0:
        raise SystemExit("--threshold must be > 0")

    artifact_date = _resolve_artifact_date(args.artifact_date)

    if args.run_a and args.run_b:
        run_a_dir = RUNS_DIR / args.run_a
        run_b_dir = RUNS_DIR / args.run_b
    else:
        run_a_dir, run_b_dir = _pick_latest_succeeded_runs()

    if not run_a_dir.exists():
        raise SystemExit(f"missing run directory: {run_a_dir}")
    if not run_b_dir.exists():
        raise SystemExit(f"missing run directory: {run_b_dir}")

    baseline = _load_claims(run_a_dir, artifact_date)
    candidate = _load_claims(run_b_dir, artifact_date)

    diffs = _collect_diffs(baseline, candidate)

    regressions = [row for row in diffs if row.delta_ratio > args.threshold]
    breakthroughs = [row for row in diffs if row.delta_ratio < -args.threshold]

    if args.output:
        output_path = Path(args.output)
    else:
        output_path = RUNS_DIR / f"flagship_{run_a_dir.name}_vs_{run_b_dir.name}.md"

    _write_report(
        output_path=output_path,
        run_a=run_a_dir.name,
        run_b=run_b_dir.name,
        threshold=args.threshold,
        regressions=regressions,
        breakthroughs=breakthroughs,
        all_rows=diffs,
    )

    print(f"flagship_report={output_path}")
    if regressions:
        for row in regressions:
            print(
                "FAIL: "
                f"{_format_config(row.config)} {row.category}.{row.field} regressed {row.delta_ratio * 100:.2f}%"
            )
        raise SystemExit(1)

    if breakthroughs:
        for row in breakthroughs:
            print(
                "BREAKTHROUGH: "
                f"{_format_config(row.config)} {row.category}.{row.field} improved {abs(row.delta_ratio) * 100:.2f}%"
            )

    print("Flagship performance gate passed.")


if __name__ == "__main__":
    main()
