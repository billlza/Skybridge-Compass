#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
from statistics import median

from bench_profiles import APPLE_PQC_CONFIG, APPLE_XWING_CONFIG, CONTRAST_CONFIGS


def _resolve_date(value: str | None) -> str:
    if value:
        return value
    env_value = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    if env_value:
        return env_value.strip()
    raise SystemExit("ARTIFACT_DATE is required (arg or env)")


def _read_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _safe_float(raw: str | None) -> float:
    return float(raw) if raw else 0.0


def _per_config_summary(
    rows: list[dict[str, str]],
    config: str,
) -> dict[str, object]:
    matched = [row for row in rows if row.get("configuration") == config]
    if not matched:
        return {
            "available": False,
            "batches": 0,
            "iteration_count_median": 0,
            "mean_median_ms": None,
            "p95_median_ms": None,
            "max_rel_dev_mean": None,
            "max_rel_dev_p95": None,
        }

    means = [_safe_float(row.get("mean_ms")) for row in matched]
    p95s = [_safe_float(row.get("p95_ms")) for row in matched]
    ns = [_safe_float(row.get("iteration_count")) for row in matched]

    mean_mid = median(means)
    p95_mid = median(p95s)
    mean_max_dev = max((abs(v - mean_mid) / abs(mean_mid)) for v in means) if abs(mean_mid) > 1e-12 else 0.0
    p95_max_dev = max((abs(v - p95_mid) / abs(p95_mid)) for v in p95s) if abs(p95_mid) > 1e-12 else 0.0

    return {
        "available": True,
        "batches": len(matched),
        "iteration_count_median": int(median(ns)) if ns else 0,
        "mean_median_ms": mean_mid,
        "p95_median_ms": p95_mid,
        "max_rel_dev_mean": mean_max_dev,
        "max_rel_dev_p95": p95_max_dev,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate Apple/X-Wing contrast benchmark artifacts")
    parser.add_argument("--artifact-date", default=None, help="artifact date (YYYY-MM-DD)")
    parser.add_argument("--bench-csv", default=None, help="override contrast bench csv path")
    parser.add_argument("--rtt-csv", default=None, help="override contrast rtt csv path")
    parser.add_argument("--output", default=None, help="output json path")
    args = parser.parse_args()

    artifact_date = _resolve_date(args.artifact_date)
    root = Path(__file__).resolve().parent.parent

    bench_csv = Path(args.bench_csv) if args.bench_csv else root / "Artifacts" / f"handshake_bench_contrast_{artifact_date}.csv"
    rtt_csv = Path(args.rtt_csv) if args.rtt_csv else root / "Artifacts" / f"handshake_rtt_contrast_{artifact_date}.csv"
    output = Path(args.output) if args.output else root / "Artifacts" / f"apple_contrast_summary_{artifact_date}.json"

    bench_rows = _read_rows(bench_csv)
    rtt_rows = _read_rows(rtt_csv)

    report = {
        "artifact_date": artifact_date,
        "sources": {
            "bench_csv": str(bench_csv),
            "rtt_csv": str(rtt_csv),
            "bench_exists": bench_csv.exists(),
            "rtt_exists": rtt_csv.exists(),
        },
        "contrast_configs": CONTRAST_CONFIGS,
        "latency": {
            APPLE_PQC_CONFIG: _per_config_summary(bench_rows, APPLE_PQC_CONFIG),
            APPLE_XWING_CONFIG: _per_config_summary(bench_rows, APPLE_XWING_CONFIG),
        },
        "rtt": {
            APPLE_PQC_CONFIG: _per_config_summary(rtt_rows, APPLE_PQC_CONFIG),
            APPLE_XWING_CONFIG: _per_config_summary(rtt_rows, APPLE_XWING_CONFIG),
        },
    }

    report["available"] = any(
        report["latency"][cfg]["available"] and report["rtt"][cfg]["available"]
        for cfg in CONTRAST_CONFIGS
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {output}")
    print(f"available={1 if report['available'] else 0}")


if __name__ == "__main__":
    main()
