#!/usr/bin/env python3
"""
Generate Fig. 9: Handshake Message Size Breakdown
Updated 2026-01-10 to distinguish liboqs vs CryptoKit PQC providers
Updated 2026-01-11 to add hatch patterns for grayscale accessibility
"""
import csv
from pathlib import Path

CSV_PATH = Path("Artifacts")
OUT_PATH = Path("figures/fig_message_size_breakdown.svg")

COLORS = {
    "signature": "#E76F51",
    "keyshare": "#2A9D8F",
    "identity": "#264653",
    "overhead": "#E9C46A",
}

# Hatch patterns for grayscale/print accessibility
HATCHES = {
    "signature": "hatch-diagonal",      # /// diagonal lines
    "keyshare": "hatch-crosshatch",     # Cross-hatch pattern
    "identity": "hatch-dots",           # dots
    "overhead": "hatch-horizontal",     # --- horizontal lines
}

def svg_patterns():
    """Define SVG hatch patterns for grayscale accessibility"""
    return '''
  <defs>
    <!-- Diagonal lines for Signature -->
    <pattern id="hatch-diagonal" patternUnits="userSpaceOnUse" width="8" height="8" patternTransform="rotate(45)">
      <line x1="0" y1="0" x2="0" y2="8" stroke="#000" stroke-width="1.5" stroke-opacity="0.4"/>
    </pattern>
    <!-- Cross hatch for KeyShare -->
    <pattern id="hatch-crosshatch" patternUnits="userSpaceOnUse" width="8" height="8">
      <line x1="0" y1="0" x2="8" y2="8" stroke="#000" stroke-width="1" stroke-opacity="0.35"/>
      <line x1="8" y1="0" x2="0" y2="8" stroke="#000" stroke-width="1" stroke-opacity="0.35"/>
    </pattern>
    <!-- Dots for Identity -->
    <pattern id="hatch-dots" patternUnits="userSpaceOnUse" width="6" height="6">
      <circle cx="3" cy="3" r="1.2" fill="#fff" fill-opacity="0.5"/>
    </pattern>
    <!-- Horizontal lines for Overhead -->
    <pattern id="hatch-horizontal" patternUnits="userSpaceOnUse" width="6" height="6">
      <line x1="0" y1="3" x2="6" y2="3" stroke="#000" stroke-width="1" stroke-opacity="0.3"/>
    </pattern>
  </defs>
'''

# 6 bars: Classic A/B, PQC-liboqs A/B, PQC-CryptoKit A/B
LABELS = [
    "MessageA.Classic",
    "MessageB.Classic",
    "MessageA.PQC (liboqs)",
    "MessageB.PQC (liboqs)",
    "MessageA.PQC (CryptoKit)",
    "MessageB.PQC (CryptoKit)",
]

# Shorter display labels for the chart
DISPLAY_LABELS = [
    "MsgA\nClassic",
    "MsgB\nClassic",
    "MsgA\nliboqs",
    "MsgB\nliboqs",
    "MsgA\nCryptoKit",
    "MsgB\nCryptoKit",
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
    width = 1000
    height = 550
    margin_left = 80
    margin_right = 140
    margin_top = 70
    margin_bottom = 80
    bar_width = 90
    gap = 30
    group_gap = 50

    max_total = max(rows[label]["total"] for label in LABELS)
    chart_height = height - margin_top - margin_bottom

    def y_scale(value):
        return height - margin_bottom - (value / max_total) * chart_height

    elements = []

    # Background
    elements.append('<rect width="100%" height="100%" fill="#ffffff"/>')

    # Axes
    elements.append(f'<line x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - margin_right}" y2="{height - margin_bottom}" stroke="#222" stroke-width="1.5"/>')
    elements.append(f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{height - margin_bottom}" stroke="#222" stroke-width="1.5"/>')

    # Y-axis ticks
    ticks = 5
    for i in range(ticks + 1):
        value = max_total * i / ticks
        y = y_scale(value)
        elements.append(f'<line x1="{margin_left - 6}" y1="{y}" x2="{margin_left}" y2="{y}" stroke="#222" stroke-width="1"/>')
        elements.append(f'<text x="{margin_left - 10}" y="{y + 4}" text-anchor="end" font-size="11" fill="#333">{int(value)}</text>')

    # Group separators and labels
    group_positions = [
        (0, 2, "Classic"),
        (2, 4, "PQC (liboqs)"),
        (4, 6, "PQC (CryptoKit)"),
    ]

    # Bars
    for i, label in enumerate(LABELS):
        # Calculate x position with group gaps
        group_idx = i // 2
        x = margin_left + 20 + i * (bar_width + gap) + group_idx * group_gap

        y = height - margin_bottom
        stack_order = ["keyshare", "signature", "identity", "overhead"]
        segment_positions = {}  # Store positions for value labels

        for key in stack_order:
            value = rows[label][key]
            h = (value / max_total) * chart_height
            y -= h
            color = COLORS[key]
            hatch = HATCHES[key]

            # Draw colored fill
            elements.append(
                f'<rect x="{x}" y="{y}" width="{bar_width}" height="{h}" fill="{color}" />'
            )
            # Draw hatch pattern overlay
            elements.append(
                f'<rect x="{x}" y="{y}" width="{bar_width}" height="{h}" fill="url(#{hatch})" />'
            )
            # Draw border for clarity
            elements.append(
                f'<rect x="{x}" y="{y}" width="{bar_width}" height="{h}" fill="none" stroke="#333" stroke-width="0.5" />'
            )

            # Store segment position for value labels (only for large segments)
            segment_positions[key] = {"y": y, "h": h, "value": value}

        # Add value labels for Signature and KeyShare (the two largest segments)
        for key in ["signature", "keyshare"]:
            seg = segment_positions[key]
            if seg["h"] > 25:  # Only label if segment is tall enough
                label_y = seg["y"] + seg["h"] / 2 + 4
                # Use white text on dark backgrounds, black on light
                text_color = "#fff" if key in ["keyshare", "identity"] else "#000"
                elements.append(
                    f'<text x="{x + bar_width / 2}" y="{label_y}" text-anchor="middle" '
                    f'font-size="9" font-weight="bold" fill="{text_color}">{seg["value"]}</text>'
                )

        # Total value label on top
        label_y = max(y - 8, margin_top + 20)
        elements.append(
            f'<text x="{x + bar_width / 2}" y="{label_y}" text-anchor="middle" font-size="10" font-weight="bold" fill="#222">{rows[label]["total"]}B</text>'
        )

    # X-axis group labels
    for start, end, group_name in group_positions:
        group_idx = start // 2
        x_start = margin_left + 20 + start * (bar_width + gap) + group_idx * group_gap
        x_end = margin_left + 20 + (end - 1) * (bar_width + gap) + bar_width + group_idx * group_gap
        x_mid = (x_start + x_end) / 2

        # MessageA / MessageB labels
        elements.append(
            f'<text x="{x_start + bar_width / 2}" y="{height - margin_bottom + 18}" text-anchor="middle" font-size="10" fill="#222">MsgA</text>'
        )
        elements.append(
            f'<text x="{x_start + bar_width + gap + bar_width / 2}" y="{height - margin_bottom + 18}" text-anchor="middle" font-size="10" fill="#222">MsgB</text>'
        )
        # Group name
        elements.append(
            f'<text x="{x_mid}" y="{height - margin_bottom + 35}" text-anchor="middle" font-size="11" font-weight="bold" fill="#333">{group_name}</text>'
        )
        # Group bracket line
        elements.append(
            f'<line x1="{x_start}" y1="{height - margin_bottom + 22}" x2="{x_end}" y2="{height - margin_bottom + 22}" stroke="#666" stroke-width="1"/>'
        )

    # Legend
    legend_x = width - margin_right + 10
    legend_y = margin_top + 30
    legend_items = [
        ("keyshare", "KeyShare"),
        ("signature", "Signature"),
        ("identity", "Identity"),
        ("overhead", "Overhead"),
    ]
    for idx, (key, title) in enumerate(legend_items):
        ly = legend_y + idx * 24
        # Draw color fill
        elements.append(f'<rect x="{legend_x}" y="{ly}" width="16" height="16" fill="{COLORS[key]}" />')
        # Draw hatch pattern overlay
        elements.append(f'<rect x="{legend_x}" y="{ly}" width="16" height="16" fill="url(#{HATCHES[key]})" />')
        # Draw border
        elements.append(f'<rect x="{legend_x}" y="{ly}" width="16" height="16" fill="none" stroke="#333" stroke-width="0.5" />')
        elements.append(f'<text x="{legend_x + 22}" y="{ly + 12}" font-size="11" fill="#222">{title}</text>')

    # Title
    elements.append(f'<text x="{(margin_left + width - margin_right) / 2}" y="{margin_top - 30}" text-anchor="middle" font-size="14" font-weight="bold" fill="#111">Handshake Message Size Breakdown</text>')

    # Y-axis label
    elements.append(f'<text x="20" y="{(margin_top + height - margin_bottom) / 2}" text-anchor="middle" font-size="11" fill="#333" transform="rotate(-90 20 {(margin_top + height - margin_bottom) / 2})">Bytes</text>')

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        svg_patterns(),  # Add hatch pattern definitions
        *elements,
        "</svg>",
    ]
    return "\n".join(svg)


def main():
    csv_path = latest_csv()
    print(f"Using CSV: {csv_path}")
    rows = load_rows(csv_path)
    for label in LABELS:
        if label not in rows:
            raise SystemExit(f"Missing row: {label}")
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(svg_bar_chart(rows), encoding="utf-8")
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
