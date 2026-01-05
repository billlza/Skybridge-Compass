#!/usr/bin/env python3
import csv
from pathlib import Path

ARTIFACTS = Path("Artifacts")
OUT_PATH = Path("Docs/figures/fig_handshake_latency.svg")

CONFIG_ORDER = [
    "Classic (X25519 + Ed25519)",
    "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
    "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
]

COLORS = {
    "p50": "#2E86AB",
    "p95": "#F6C85F",
    "p99": "#F5703C",
}


def latest_csv():
    files = sorted(ARTIFACTS.glob("handshake_bench_*.csv"))
    if not files:
        raise SystemExit("No handshake_bench_*.csv found in Artifacts/")
    return files[-1]


def load_aggregate(path: Path):
    buckets = {name: {"p50": [], "p95": [], "p99": []} for name in CONFIG_ORDER}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            config = row["configuration"]
            if config not in buckets:
                continue
            buckets[config]["p50"].append(float(row["p50_ms"]))
            buckets[config]["p95"].append(float(row["p95_ms"]))
            buckets[config]["p99"].append(float(row["p99_ms"]))
    aggregates = {}
    for config, values in buckets.items():
        if not values["p50"]:
            raise SystemExit(f"Missing data for {config}")
        aggregates[config] = {
            "p50": sum(values["p50"]) / len(values["p50"]),
            "p95": sum(values["p95"]) / len(values["p95"]),
            "p99": sum(values["p99"]) / len(values["p99"]),
        }
    return aggregates


def svg_bar_chart(aggregates):
    width = 840
    height = 440
    margin = 70
    chart_width = width - margin * 2
    chart_height = height - margin * 2

    max_val = max(aggregates[name]["p99"] for name in CONFIG_ORDER)
    max_val = max(max_val, 1.0)

    group_count = len(CONFIG_ORDER)
    group_width = chart_width / group_count
    bar_width = group_width / 4

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
        elements.append(f'<text x="{margin - 10}" y="{y + 4}" text-anchor="end" font-size="11" fill="#333">{value:.1f}</text>')

    for idx, name in enumerate(CONFIG_ORDER):
        base_x = margin + idx * group_width + bar_width
        for j, key in enumerate(["p50", "p95", "p99"]):
            value = aggregates[name][key]
            x = base_x + j * (bar_width + 8)
            y = y_scale(value)
            bar_height = height - margin - y
            elements.append(f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" fill="{COLORS[key]}"/>')
        short_name = name.split(" (")[0]
        elements.append(f'<text x="{base_x + bar_width}" y="{height - margin + 24}" text-anchor="middle" font-size="12" fill="#333">{short_name}</text>')

    legend_x = width - margin - 140
    legend_y = margin - 10
    for i, key in enumerate(["p50", "p95", "p99"]):
        y = legend_y + i * 18
        elements.append(f'<rect x="{legend_x}" y="{y}" width="12" height="12" fill="{COLORS[key]}"/>')
        elements.append(f'<text x="{legend_x + 18}" y="{y + 10}" font-size="11" fill="#333">{key}</text>')

    elements.append(f'<text x="{width / 2}" y="{margin - 30}" text-anchor="middle" font-size="15" fill="#111">Handshake Latency Percentiles (ms)</text>')

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        *elements,
        "</svg>",
    ]
    return "\n".join(svg)


def main():
    csv_path = latest_csv()
    aggregates = load_aggregate(csv_path)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(svg_bar_chart(aggregates), encoding="utf-8")
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
