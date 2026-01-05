#!/usr/bin/env python3
import csv
from pathlib import Path

CSV_PATH = Path("Artifacts")
OUT_PATH = Path("Docs/figures/fig_message_size_breakdown.svg")

COLORS = {
    "signature": "#E76F51",
    "keyshare": "#2A9D8F",
    "identity": "#264653",
    "overhead": "#E9C46A",
}

LABELS = [
    "MessageA.Classic",
    "MessageB.Classic",
    "MessageA.PQC",
    "MessageB.PQC",
]


def latest_csv():
    files = sorted(CSV_PATH.glob("message_sizes_*.csv"))
    if not files:
        raise SystemExit("No message_sizes_*.csv found in Artifacts/")
    return files[-1]


def load_rows(path: Path):
    rows = {}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = row["message"]
            rows[label] = {
                "total": int(row["total_bytes"]),
                "signature": int(row["signature_bytes"]),
                "keyshare": int(row["keyshare_bytes"]),
                "identity": int(row["identity_bytes"]),
                "overhead": int(row["overhead_bytes"]),
            }
    return rows


def svg_bar_chart(rows):
    width = 1200
    height = 600
    margin = 120
    bar_width = 120
    gap = 60

    max_total = max(rows[label]["total"] for label in LABELS)
    chart_height = height - margin * 2

    def y_scale(value):
        return height - margin - (value / max_total) * chart_height

    elements = []

    # Axes
    elements.append(f'<rect width="100%" height="100%" fill="#ffffff"/>')
    elements.append(f'<line x1="{margin}" y1="{height - margin}" x2="{width - margin}" y2="{height - margin}" stroke="#222" stroke-width="1.5"/>')
    elements.append(f'<line x1="{margin}" y1="{margin}" x2="{margin}" y2="{height - margin}" stroke="#222" stroke-width="1.5"/>')

    ticks = 5
    for i in range(ticks + 1):
        value = max_total * i / ticks
        y = y_scale(value)
        elements.append(f'<line x1="{margin - 6}" y1="{y}" x2="{margin}" y2="{y}" stroke="#222" stroke-width="1"/>')
        elements.append(f'<text x="{margin - 10}" y="{y + 4}" text-anchor="end" font-size="12" fill="#333">{int(value)}</text>')

    # Bars
    for i, label in enumerate(LABELS):
        x = margin + i * (bar_width + gap) + 20
        y = height - margin
        stack_order = ["keyshare", "signature", "identity", "overhead"]
        for key in stack_order:
            value = rows[label][key]
            h = (value / max_total) * chart_height
            y -= h
            color = COLORS[key]
            elements.append(
                f'<rect x="{x}" y="{y}" width="{bar_width}" height="{h}" fill="{color}" />'
            )
        # label
        elements.append(
            f'<text x="{x + bar_width / 2}" y="{height - margin + 24}" text-anchor="middle" font-size="12" fill="#222">{label}</text>'
        )
        label_y = max(y - 12, margin + 36)
        elements.append(
            f'<text x="{x + bar_width / 2}" y="{label_y}" text-anchor="middle" font-size="10" fill="#222">{rows[label]["total"]}B</text>'
        )

    # Legend
    legend_x = width - margin - 160
    legend_y = margin + 20
    legend_items = [
        ("keyshare", "KeyShare"),
        ("signature", "Signature"),
        ("identity", "Identity"),
        ("overhead", "Overhead"),
    ]
    for idx, (key, title) in enumerate(legend_items):
        ly = legend_y + idx * 18
        elements.append(f'<rect x="{legend_x}" y="{ly}" width="12" height="12" fill="{COLORS[key]}" />')
        elements.append(f'<text x="{legend_x + 18}" y="{ly + 10}" font-size="12" fill="#222">{title}</text>')

    elements.append(f'<text x="{width / 2}" y="{margin - 46}" text-anchor="middle" font-size="16" fill="#111">Handshake Message Size Breakdown</text>')
    elements.append(f'<text x="{width / 2}" y="{height - 18}" text-anchor="middle" font-size="12" fill="#333">Message type</text>')
    elements.append(f'<text x="20" y="{height / 2}" text-anchor="middle" font-size="12" fill="#333" transform="rotate(-90 20 {height / 2})">Bytes</text>')

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        *elements,
        "</svg>",
    ]
    return "\n".join(svg)


def main():
    csv_path = latest_csv()
    rows = load_rows(csv_path)
    for label in LABELS:
        if label not in rows:
            raise SystemExit(f"Missing row: {label}")
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(svg_bar_chart(rows), encoding="utf-8")
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
