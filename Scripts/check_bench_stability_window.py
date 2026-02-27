#!/usr/bin/env python3
import argparse
import csv
import json
import os
from pathlib import Path
from statistics import median

from bench_profiles import STABILITY_TRACKED_CONFIGS, gate_configs


def _read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _group_complete_batches(
    rows: list[dict[str, str]], required_configs: list[str]
) -> list[dict[str, dict[str, str]]]:
    required = set(required_configs)
    filtered = [row for row in rows if row.get("configuration") in required]

    batches: list[dict[str, dict[str, str]]] = []
    current: dict[str, dict[str, str]] = {}
    for row in filtered:
        config = row["configuration"]
        if config in current:
            batches.append(current)
            current = {}
        current[config] = row
    if current:
        batches.append(current)

    return [batch for batch in batches if required.issubset(set(batch.keys()))]


def _safe_float(raw: str) -> float:
    return float(raw) if raw else 0.0


def _metric_report(
    batches: list[dict[str, dict[str, str]]],
    configs: list[str],
    gate_configs: set[str],
    field: str,
    threshold: float,
) -> tuple[dict[str, dict[str, object]], bool]:
    details: dict[str, dict[str, object]] = {}
    stable = True

    for config in configs:
        values = [_safe_float(batch[config].get(field, "")) for batch in batches if config in batch]
        if not values:
            missing_is_failure = config in gate_configs
            details[config] = {
                "values": [],
                "median": None,
                "max_relative_deviation": None,
                "stable": not missing_is_failure,
            }
            if missing_is_failure:
                stable = False
            continue

        mid = median(values)
        if abs(mid) < 1e-12:
            rel_devs = [0.0 for _ in values]
        else:
            rel_devs = [abs(value - mid) / abs(mid) for value in values]
        max_rel = max(rel_devs) if rel_devs else 0.0
        is_stable = max_rel <= threshold
        if config in gate_configs and not is_stable:
            stable = False

        details[config] = {
            "values": values,
            "median": mid,
            "max_relative_deviation": max_rel,
            "stable": is_stable,
        }

    return details, stable


def _resolve_date(value: str | None) -> str:
    if value:
        return value
    env_value = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    if env_value:
        return env_value.strip()
    raise SystemExit("ARTIFACT_DATE is required (arg or env)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Check intra-run benchmark stability window")
    parser.add_argument("--artifact-date", default=None, help="artifact date (YYYY-MM-DD)")
    parser.add_argument("--bench-csv", default=None, help="override handshake bench csv path")
    parser.add_argument("--rtt-csv", default=None, help="override handshake rtt csv path")
    parser.add_argument("--threshold", type=float, default=0.07, help="max relative deviation")
    parser.add_argument(
        "--tail-threshold",
        type=float,
        default=(
            float(os.environ["SKYBRIDGE_BENCH_STABILITY_TAIL_THRESHOLD"])
            if "SKYBRIDGE_BENCH_STABILITY_TAIL_THRESHOLD" in os.environ
            else None
        ),
        help="max relative deviation for tail metrics (p95); defaults to 2x --threshold",
    )
    parser.add_argument("--min-batches", type=int, default=3, help="minimum complete batches required")
    parser.add_argument("--require-apple", choices=["0", "1"], default=os.environ.get("SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE", "0"))
    parser.add_argument("--output", default=None, help="output json path")
    args = parser.parse_args()

    artifact_date = _resolve_date(args.artifact_date)
    root = Path(__file__).resolve().parent.parent

    bench_csv = Path(args.bench_csv) if args.bench_csv else root / "Artifacts" / f"handshake_bench_{artifact_date}.csv"
    rtt_csv = Path(args.rtt_csv) if args.rtt_csv else root / "Artifacts" / f"handshake_rtt_{artifact_date}.csv"
    output = Path(args.output) if args.output else root / "Artifacts" / f"bench_stability_window_{artifact_date}.json"

    if not bench_csv.exists():
        raise SystemExit(f"missing bench csv: {bench_csv}")
    if not rtt_csv.exists():
        raise SystemExit(f"missing rtt csv: {rtt_csv}")
    if args.min_batches < 1:
        raise SystemExit("--min-batches must be >= 1")
    if args.threshold <= 0:
        raise SystemExit("--threshold must be > 0")
    tail_threshold = (
        float(args.tail_threshold)
        if args.tail_threshold is not None
        else max(args.threshold, args.threshold * 2.0)
    )
    if tail_threshold <= 0:
        raise SystemExit("--tail-threshold must be > 0")

    require_apple = args.require_apple == "1"
    active_gate_configs = gate_configs(require_apple=require_apple)
    gate_config_set = set(active_gate_configs)

    bench_rows = _read_rows(bench_csv)
    rtt_rows = _read_rows(rtt_csv)

    bench_batches = _group_complete_batches(bench_rows, active_gate_configs)
    rtt_batches = _group_complete_batches(rtt_rows, active_gate_configs)

    complete_batches = min(len(bench_batches), len(rtt_batches))
    bench_batches = bench_batches[-complete_batches:] if complete_batches > 0 else []
    rtt_batches = rtt_batches[-complete_batches:] if complete_batches > 0 else []

    sufficient_batches = complete_batches >= args.min_batches

    latency_mean, stable_latency_mean = _metric_report(bench_batches, STABILITY_TRACKED_CONFIGS, gate_config_set, "mean_ms", args.threshold)
    latency_p95, stable_latency_p95 = _metric_report(bench_batches, STABILITY_TRACKED_CONFIGS, gate_config_set, "p95_ms", tail_threshold)
    rtt_mean, stable_rtt_mean = _metric_report(rtt_batches, STABILITY_TRACKED_CONFIGS, gate_config_set, "mean_ms", args.threshold)
    rtt_p95, stable_rtt_p95 = _metric_report(rtt_batches, STABILITY_TRACKED_CONFIGS, gate_config_set, "p95_ms", tail_threshold)

    overall_stable = (
        sufficient_batches
        and stable_latency_mean
        and stable_latency_p95
        and stable_rtt_mean
        and stable_rtt_p95
    )

    top_unstable_metrics: list[dict[str, object]] = []
    metric_groups = {
        "latency_mean": latency_mean,
        "latency_p95": latency_p95,
        "rtt_mean": rtt_mean,
        "rtt_p95": rtt_p95,
    }
    for metric_name, group in metric_groups.items():
        for config, detail in group.items():
            if detail.get("stable", False):
                continue
            deviation = detail.get("max_relative_deviation")
            score = float(deviation) if deviation is not None else 1.0
            top_unstable_metrics.append(
                {
                    "metric": metric_name,
                    "configuration": config,
                    "max_relative_deviation": deviation,
                    "max_relative_deviation_pct": score * 100.0,
                }
            )
    top_unstable_metrics.sort(
        key=lambda item: float(item["max_relative_deviation"]) if item["max_relative_deviation"] is not None else 1.0,
        reverse=True,
    )

    report = {
        "artifact_date": artifact_date,
        "require_apple": require_apple,
        "gate_configs": active_gate_configs,
        "threshold": args.threshold,
        "tail_threshold": tail_threshold,
        "min_batches": args.min_batches,
        "complete_batches": complete_batches,
        "sufficient_batches": sufficient_batches,
        "overall_stable": overall_stable,
        "metrics": {
            "latency_mean": latency_mean,
            "latency_p95": latency_p95,
            "rtt_mean": rtt_mean,
            "rtt_p95": rtt_p95,
        },
        "top_unstable_metrics": top_unstable_metrics,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if overall_stable:
        print(
            "stable: true "
            f"(batches={complete_batches}, threshold={args.threshold:.4f}, tail_threshold={tail_threshold:.4f})"
        )
        print(f"report={output}")
        raise SystemExit(0)

    if not sufficient_batches:
        print(f"stable: false (insufficient complete batches: {complete_batches} < {args.min_batches})")
    else:
        print(
            "stable: false "
            f"(threshold={args.threshold:.4f}, tail_threshold={tail_threshold:.4f}, batches={complete_batches})"
        )
    if top_unstable_metrics:
        worst = top_unstable_metrics[0]
        print(
            "worst_unstable="
            f"{worst['metric']}|{worst['configuration']}|{float(worst['max_relative_deviation_pct']):.2f}%"
        )
    print(f"report={output}")
    raise SystemExit(10)


if __name__ == "__main__":
    main()
