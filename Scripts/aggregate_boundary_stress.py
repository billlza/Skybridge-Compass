#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
from collections import defaultdict
from pathlib import Path


REQUIRED_COLUMNS = [
    "category",
    "scenario",
    "n_runs",
    "accept_rate",
    "fallback_violation_rate",
    "supersede_reason_accuracy",
    "forced_classic_edge_rate",
    "evidence_schema_pass_rate",
    "notes",
]

RATE_FIELDS = [
    "accept_rate",
    "fallback_violation_rate",
    "supersede_reason_accuracy",
    "forced_classic_edge_rate",
    "evidence_schema_pass_rate",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate boundary stress benchmark CSV into supplementary table")
    parser.add_argument("--artifact-date", required=True, help="Artifact date suffix (YYYY-MM-DD)")
    parser.add_argument(
        "--input",
        help="Input CSV path (default: Artifacts/boundary_stress_<artifact-date>.csv)",
    )
    parser.add_argument(
        "--out-tex",
        default="Docs/supp_tables/s25_boundary_stress_empirical.tex",
        help="Output TeX path",
    )
    parser.add_argument(
        "--out-json",
        help="Output summary JSON path (default: Artifacts/boundary_stress_summary_<artifact-date>.json)",
    )
    return parser.parse_args()


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise SystemExit(f"empty csv: {path}")
        missing = [c for c in REQUIRED_COLUMNS if c not in reader.fieldnames]
        if missing:
            raise SystemExit(f"missing required columns in {path}: {missing}")
        rows = list(reader)
    if not rows:
        raise SystemExit(f"no rows found in {path}")
    return rows


def parse_numeric_rows(rows: list[dict[str, str]]) -> list[dict[str, object]]:
    parsed: list[dict[str, object]] = []
    for idx, row in enumerate(rows, start=1):
        try:
            n_runs = int(row["n_runs"])
        except ValueError as exc:
            raise SystemExit(f"invalid n_runs at row {idx}: {row['n_runs']}") from exc
        if n_runs <= 0:
            raise SystemExit(f"n_runs must be > 0 at row {idx}")

        entry: dict[str, object] = {
            "category": row["category"].strip(),
            "scenario": row["scenario"].strip(),
            "notes": row["notes"].strip(),
            "n_runs": n_runs,
        }
        if not entry["category"] or not entry["scenario"]:
            raise SystemExit(f"category/scenario cannot be empty at row {idx}")

        for field in RATE_FIELDS:
            try:
                value = float(row[field])
            except ValueError as exc:
                raise SystemExit(f"invalid float in {field} at row {idx}: {row[field]}") from exc
            if value < 0 or value > 1:
                raise SystemExit(f"{field} must be within [0,1] at row {idx}: {value}")
            entry[field] = value
        parsed.append(entry)
    return parsed


def weighted_mean(entries: list[dict[str, object]], field: str) -> float:
    total_weight = sum(int(e["n_runs"]) for e in entries)
    if total_weight == 0:
        return 0.0
    weighted_sum = sum(float(e[field]) * int(e["n_runs"]) for e in entries)
    return weighted_sum / float(total_weight)


def aggregate(entries: list[dict[str, object]]) -> dict[str, object]:
    by_category: dict[str, list[dict[str, object]]] = defaultdict(list)
    for entry in entries:
        by_category[str(entry["category"])].append(entry)

    category_summaries: list[dict[str, object]] = []
    for category in sorted(by_category.keys()):
        group = by_category[category]
        summary = {
            "category": category,
            "scenario_count": len(group),
            "n_runs_total": sum(int(e["n_runs"]) for e in group),
        }
        for field in RATE_FIELDS:
            summary[field] = weighted_mean(group, field)
        category_summaries.append(summary)

    overall = {
        "category": "overall",
        "scenario_count": len(entries),
        "n_runs_total": sum(int(e["n_runs"]) for e in entries),
    }
    for field in RATE_FIELDS:
        overall[field] = weighted_mean(entries, field)

    return {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "categories": category_summaries,
        "overall": overall,
    }


def format_pct(value: float) -> str:
    return f"{value * 100.0:.2f}\\%"


def render_tex(artifact_date: str, summary: dict[str, object]) -> str:
    rows: list[str] = []
    category_map = {
        "input_perturbation": "Input perturbation",
        "concurrency_race": "Concurrency/race",
        "adversarial_network": "Adversarial network",
        "evidence_integrity": "Evidence integrity",
        "overall": "Overall",
    }

    categories = list(summary["categories"]) + [summary["overall"]]  # type: ignore[index]
    for item in categories:
        category_key = str(item["category"])  # type: ignore[index]
        label = category_map.get(category_key, category_key.replace("_", " ").title())
        rows.append(
            f"{label} & "
            f"{int(item['scenario_count'])} & "  # type: ignore[index]
            f"{int(item['n_runs_total'])} & "  # type: ignore[index]
            f"{format_pct(float(item['accept_rate']))} & "  # type: ignore[index]
            f"{format_pct(float(item['fallback_violation_rate']))} & "  # type: ignore[index]
            f"{format_pct(float(item['supersede_reason_accuracy']))} & "  # type: ignore[index]
            f"{format_pct(float(item['forced_classic_edge_rate']))} & "  # type: ignore[index]
            f"{format_pct(float(item['evidence_schema_pass_rate']))} \\\\"  # type: ignore[index]
        )

    return "\n".join(
        [
            r"\begin{table*}[!tp]",
            r"\centering",
            r"\scriptsize",
            (
                r"\caption{Empirical boundary-stress invariants (artifact date "
                + artifact_date
                + r"). Rates are objective machine-checked outcomes across the four gate classes: input perturbation, concurrency/race, adversarial network, and evidence integrity.}"
            ),
            r"\label{tab:supp-boundary-stress-empirical}",
            r"\begin{tabular}{@{}lrrrrrrrr@{}}",
            r"\toprule",
            r"Category & Scenarios & Runs & Accept rate & Fallback violation & Supersede reason accuracy & Forced classic edge & Evidence schema pass \\\\",
            r"\midrule",
            *rows,
            r"\bottomrule",
            r"\end{tabular}",
            r"\end{table*}",
            "",
        ]
    )


def main() -> int:
    args = parse_args()

    root = Path(__file__).resolve().parents[1]
    input_path = Path(args.input) if args.input else root / "Artifacts" / f"boundary_stress_{args.artifact_date}.csv"
    out_tex = Path(args.out_tex)
    if not out_tex.is_absolute():
        out_tex = root / out_tex
    out_json = Path(args.out_json) if args.out_json else root / "Artifacts" / f"boundary_stress_summary_{args.artifact_date}.json"
    if not out_json.is_absolute():
        out_json = root / out_json

    if not input_path.exists():
        raise SystemExit(f"input csv not found: {input_path}")

    rows = load_rows(input_path)
    parsed = parse_numeric_rows(rows)
    summary = aggregate(parsed)

    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    tex = render_tex(args.artifact_date, summary)
    out_tex.parent.mkdir(parents=True, exist_ok=True)
    out_tex.write_text(tex, encoding="utf-8")

    print(f"[boundary-stress] input={input_path}")
    print(f"[boundary-stress] wrote json={out_json}")
    print(f"[boundary-stress] wrote tex={out_tex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
