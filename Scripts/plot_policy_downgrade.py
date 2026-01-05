#!/usr/bin/env python3
import csv
from pathlib import Path

CSV_PATH = Path("Artifacts")
OUT_PATH = Path("Docs/figures/fig_policy_downgrade.svg")


def latest_csv():
    files = sorted(CSV_PATH.glob("policy_downgrade_*.csv"))
    if not files:
        raise SystemExit("No policy_downgrade_*.csv found in Artifacts/")
    return files[-1]


def load_rows(path: Path):
    rows = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "policy": row["policy"],
                "iterations": int(row["iterations"]),
                "classic_attempts": int(row.get("classic_attempts", 0)),
                "fallback_events": int(row["fallback_events"]),
            })
    return rows


def svg_bar_chart(rows):
    width = 720
    height = 360
    margin = 70
    bar_width = 160
    gap = 90

    normalized = []
    for row in rows:
        iterations = max(row["iterations"], 1)
        scale = 1000 / iterations
        normalized.append({
            **row,
            "fallback_per_1000": row["fallback_events"] * scale,
        })

    max_val = max((row["fallback_per_1000"] for row in normalized), default=1)
    max_val = max(max_val, 1)
    chart_height = height - margin * 2

    def y_scale(value):
        return height - margin - (value / max_val) * chart_height

    elements = []
    elements.append('<rect width="100%" height="100%" fill="#ffffff"/>')
    elements.append(f'<line x1="{margin}" y1="{height - margin}" x2="{width - margin}" y2="{height - margin}" stroke="#222" stroke-width="1.5"/>')
    elements.append(f'<line x1="{margin}" y1="{margin}" x2="{margin}" y2="{height - margin}" stroke="#222" stroke-width="1.5"/>')

    ticks = 5
    for i in range(ticks + 1):
        value = max_val * i / ticks
        y = y_scale(value)
        elements.append(f'<line x1="{margin - 6}" y1="{y}" x2="{margin}" y2="{y}" stroke="#222" stroke-width="1"/>')
        elements.append(f'<text x="{margin - 10}" y="{y + 4}" text-anchor="end" font-size="12" fill="#333">{value:.0f}</text>')

    for i, row in enumerate(normalized):
        x = margin + i * (bar_width + gap) + 20
        y = y_scale(row["fallback_per_1000"])
        bar_height = height - margin - y
        color = "#E76F51" if row["fallback_per_1000"] > 0 else "#2A9D8F"
        elements.append(f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" fill="{color}" />')

        iterations = max(row["iterations"], 1)
        p = row["fallback_events"] / iterations
        stderr = (p * (1 - p) / iterations) ** 0.5
        ci = 1.96 * stderr * 1000
        if ci > 0:
            y_err_top = y_scale(row["fallback_per_1000"] + ci)
            y_err_bottom = y_scale(max(row["fallback_per_1000"] - ci, 0))
            x_mid = x + bar_width / 2
            elements.append(f'<line x1="{x_mid}" y1="{y_err_top}" x2="{x_mid}" y2="{y_err_bottom}" stroke="#111" stroke-width="1.5"/>')
            elements.append(f'<line x1="{x_mid - 6}" y1="{y_err_top}" x2="{x_mid + 6}" y2="{y_err_top}" stroke="#111" stroke-width="1.5"/>')
            elements.append(f'<line x1="{x_mid - 6}" y1="{y_err_bottom}" x2="{x_mid + 6}" y2="{y_err_bottom}" stroke="#111" stroke-width="1.5"/>')

        elements.append(f'<text x="{x + bar_width / 2}" y="{height - margin + 22}" text-anchor="middle" font-size="12" fill="#222">{row["policy"]}</text>')
        elements.append(f'<text x="{x + bar_width / 2}" y="{y - 8}" text-anchor="middle" font-size="11" fill="#222">{row["fallback_per_1000"]:.0f}</text>')

    elements.append(f'<text x="{width / 2}" y="{margin - 34}" text-anchor="middle" font-size="16" fill="#111">Fallback Rate per 1000 Runs (95% CI)</text>')
    elements.append(f'<text x="{width / 2}" y="{height - 18}" text-anchor="middle" font-size="12" fill="#333">Policy</text>')
    elements.append(f'<text x="18" y="{height / 2}" text-anchor="middle" font-size="12" fill="#333" transform="rotate(-90 18 {height / 2})">Fallback events per 1000 runs</text>')

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        *elements,
        "</svg>",
    ]
    return "\n".join(svg)


def main():
    csv_path = latest_csv()
    rows = load_rows(csv_path)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(svg_bar_chart(rows), encoding="utf-8")
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
