#!/usr/bin/env python3
import csv
from pathlib import Path

ARTIFACTS = Path("Artifacts")
OUT_PATH = Path("Docs/figures/fig_failure_histogram.svg")

FAULT_CLASSES = {
    "Drop/Timeout": {"drop", "delay_exceed_timeout", "concurrent_timeout"},
    "Corrupt/WrongSig": {"corrupt_header", "corrupt_payload", "wrong_signature"},
    "Ordering Benign": {"out_of_order", "duplicate", "delay_within_timeout"},
}


def latest_csv(prefix: str) -> Path:
    files = sorted(ARTIFACTS.glob(f"{prefix}_*.csv"))
    if not files:
        raise SystemExit(f"No {prefix}_*.csv found in Artifacts/")
    return files[-1]


def load_fault_rows(path: Path):
    rows = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            policy = row.get("policy", "default")
            rows.append({
                "policy": policy,
                "scenario": row["scenario"],
                "handshakeFailed": int(row.get("E_handshakeFailed", 0)),
                "cryptoDowngrade": int(row.get("E_cryptoDowngrade", 0)),
            })
    return rows


def load_policy_rows(path: Path):
    rows = {}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows[row["policy"]] = int(row.get("fallback_events", 0))
    return rows


def summarize_class(rows, policy, scenarios):
    total_failed = 0
    total_downgrade = 0
    for row in rows:
        if row["policy"] != policy:
            continue
        if row["scenario"] in scenarios:
            total_failed += row["handshakeFailed"]
            total_downgrade += row["cryptoDowngrade"]
    return total_failed, total_downgrade


def svg_bar_chart(data):
    width = 980
    height = 440
    margin = 80
    chart_width = width - margin * 2
    chart_height = height - margin * 2

    labels = list(data.keys())
    max_val = max(max(v) for v in data.values()) if data else 1
    max_val = max(max_val, 1)

    group_width = chart_width / len(labels)
    bar_width = group_width / 3

    def y_scale(value):
        return height - margin - (value / max_val) * chart_height

    elements = []
    elements.append(f'<rect width="100%" height="100%" fill="#ffffff"/>')
    elements.append(f'<line x1="{margin}" y1="{height - margin}" x2="{width - margin}" y2="{height - margin}" stroke="#111" stroke-width="1.5"/>')
    elements.append(f'<line x1="{margin}" y1="{margin}" x2="{margin}" y2="{height - margin}" stroke="#111" stroke-width="1.5"/>')

    ticks = 5
    for i in range(ticks + 1):
        value = max_val * i / ticks
        y = y_scale(value)
        elements.append(f'<line x1="{margin - 6}" y1="{y}" x2="{margin}" y2="{y}" stroke="#111" stroke-width="1"/>')
    elements.append(f'<text x="{margin - 10}" y="{y + 4}" text-anchor="end" font-size="12" fill="#333">{int(value)}</text>')

    for idx, label in enumerate(labels):
        base_x = margin + idx * group_width + bar_width / 2
        failed = data[label][0]
        downgrade = data[label][1]
        for j, (value, color) in enumerate([(failed, "#4e79a7"), (downgrade, "#f28e2b")]):
            x = base_x + j * (bar_width + 10)
            y = y_scale(value)
            bar_height = height - margin - y
            elements.append(f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" fill="{color}"/>')
        elements.append(f'<text x="{base_x + bar_width / 2}" y="{height - margin + 26}" text-anchor="middle" font-size="12" fill="#333">{label}</text>')

    legend_x = width - margin - 180
    legend_y = margin - 10
    elements.append(f'<rect x="{legend_x}" y="{legend_y}" width="12" height="12" fill="#4e79a7"/>')
    elements.append(f'<text x="{legend_x + 18}" y="{legend_y + 10}" font-size="12" fill="#333">E_handshakeFailed</text>')
    elements.append(f'<rect x="{legend_x}" y="{legend_y + 18}" width="12" height="12" fill="#f28e2b"/>')
    elements.append(f'<text x="{legend_x + 18}" y="{legend_y + 28}" font-size="12" fill="#333">E_cryptoDowngrade</text>')

    elements.append(f'<text x="{width / 2}" y="{margin - 34}" text-anchor="middle" font-size="16" fill="#111">Failure-Mode Histogram (Observability)</text>')
    elements.append(f'<text x="{width / 2}" y="{height - 18}" text-anchor="middle" font-size="12" fill="#333">Fault class</text>')
    elements.append(f'<text x="20" y="{height / 2}" text-anchor="middle" font-size="12" fill="#333" transform="rotate(-90 20 {height / 2})">Event count (n=1000 per scenario)</text>')

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        *elements,
        "</svg>",
    ]
    return "\n".join(svg)


def main():
    fault_path = latest_csv("fault_injection")
    policy_path = latest_csv("policy_downgrade")
    fault_rows = load_fault_rows(fault_path)
    policy_rows = load_policy_rows(policy_path)

    data = {}
    for label, scenarios in FAULT_CLASSES.items():
        failed, downgrade = summarize_class(fault_rows, "default", scenarios)
        data[label] = (failed, downgrade)

    data["PQC Unavailable"] = (0, policy_rows.get("default", 0))

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(svg_bar_chart(data), encoding="utf-8")
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
