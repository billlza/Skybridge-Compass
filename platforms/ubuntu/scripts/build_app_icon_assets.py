#!/usr/bin/env python3
"""Generate masked SkyBridge icon assets from a square SVG source."""

from __future__ import annotations

import argparse
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
DEFAULT_MASK_EXPONENT = 5.0
DEFAULT_MASK_SAMPLES = 256


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Build masked SVG/PNG app icon assets from a square SVG source."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=repo_root / "1764932992803-2.svg",
        help="Source square SVG",
    )
    parser.add_argument(
        "--radius",
        type=int,
        default=232,
        help="Rounded corner radius used only with --mask=rounded-rect",
    )
    parser.add_argument(
        "--mask",
        choices=("superellipse", "rounded-rect"),
        default="superellipse",
        help="Mask shape used to clip the source art",
    )
    parser.add_argument(
        "--exponent",
        type=float,
        default=DEFAULT_MASK_EXPONENT,
        help="Superellipse exponent; larger values approach a square while preserving smooth corners",
    )
    parser.add_argument(
        "--samples",
        type=int,
        default=DEFAULT_MASK_SAMPLES,
        help="Number of points used to approximate the superellipse clip path",
    )
    parser.add_argument(
        "--sizes",
        type=int,
        nargs="*",
        default=list(DEFAULT_SIZES),
        help="PNG sizes to render",
    )
    return parser.parse_args()


def ensure_tool(name: str) -> str:
    resolved = shutil.which(name)
    if not resolved:
        raise SystemExit(f"Missing required tool: {name}")
    return resolved


def extract_canvas_size(source_svg: str) -> tuple[float, float]:
    view_box_match = re.search(r'viewBox="([^"]+)"', source_svg)
    if view_box_match:
        parts = [float(item) for item in view_box_match.group(1).replace(",", " ").split()]
        if len(parts) == 4 and parts[2] > 0 and parts[3] > 0:
            return parts[2], parts[3]

    width_match = re.search(r'width="([0-9.]+)"', source_svg)
    height_match = re.search(r'height="([0-9.]+)"', source_svg)
    if width_match and height_match:
        return float(width_match.group(1)), float(height_match.group(1))

    return 1024.0, 1024.0


def format_svg_number(value: float) -> str:
    return f"{value:.3f}".rstrip("0").rstrip(".")


def build_superellipse_path(width: float, height: float, exponent: float, samples: int) -> str:
    if exponent <= 0:
        raise ValueError("superellipse exponent must be positive")
    if samples < 8:
        raise ValueError("superellipse sample count must be at least 8")

    radius_x = width / 2.0
    radius_y = height / 2.0
    center_x = radius_x
    center_y = radius_y
    power = 2.0 / exponent
    points: list[tuple[float, float]] = []

    for step in range(samples):
        theta = (2.0 * math.pi * step) / samples
        cos_theta = math.cos(theta)
        sin_theta = math.sin(theta)
        x = center_x + math.copysign(abs(cos_theta) ** power, cos_theta) * radius_x
        y = center_y + math.copysign(abs(sin_theta) ** power, sin_theta) * radius_y
        points.append((x, y))

    commands = [f"M {format_svg_number(points[0][0])} {format_svg_number(points[0][1])}"]
    commands.extend(
        f"L {format_svg_number(x)} {format_svg_number(y)}" for x, y in points[1:]
    )
    commands.append("Z")
    return " ".join(commands)


def build_mask_markup(
    source_svg: str,
    *,
    mask: str,
    radius: int,
    exponent: float,
    samples: int,
) -> str:
    width, height = extract_canvas_size(source_svg)
    if mask == "rounded-rect":
        return (
            f'<rect x="0" y="0" width="{format_svg_number(width)}" '
            f'height="{format_svg_number(height)}" rx="{radius}" ry="{radius}" />'
        )

    path = build_superellipse_path(width, height, exponent, samples)
    return f'<path d="{path}" />'


def wrap_svg_with_mask(source_svg: str, mask_markup: str) -> str:
    end_svg = source_svg.rfind("</svg>")
    if end_svg == -1:
        raise ValueError("source SVG is missing </svg>")

    defs_close = source_svg.find("</defs>")
    clip_def = (
        f'\n    <clipPath id="skybridge-rounded-mask">\n'
        f"      {mask_markup}\n"
        f"    </clipPath>\n"
    )

    if defs_close != -1:
        prefix = source_svg[:defs_close]
        body_start = defs_close + len("</defs>")
        prefix = prefix + clip_def + "  </defs>"
    else:
        svg_open = source_svg.find(">")
        if svg_open == -1:
            raise ValueError("source SVG is missing opening <svg> tag")
        prefix = source_svg[: svg_open + 1] + "\n  <defs>" + clip_def + "  </defs>"
        body_start = svg_open + 1

    body = source_svg[body_start:end_svg].strip()
    suffix = source_svg[end_svg:]
    return (
        prefix
        + '\n  <g clip-path="url(#skybridge-rounded-mask)">\n'
        + body
        + "\n  </g>\n"
        + suffix
    )


def render_png(rsvg_convert: str, svg_path: Path, png_path: Path, size: int) -> None:
    png_path.parent.mkdir(parents=True, exist_ok=True)
    with png_path.open("wb") as handle:
        subprocess.run(
            [rsvg_convert, "-w", str(size), "-h", str(size), str(svg_path)],
            check=True,
            stdout=handle,
        )


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    rsvg_convert = ensure_tool("rsvg-convert")

    source_svg = args.source.read_text(encoding="utf-8")
    mask_markup = build_mask_markup(
        source_svg,
        mask=args.mask,
        radius=args.radius,
        exponent=args.exponent,
        samples=args.samples,
    )
    masked_svg = wrap_svg_with_mask(source_svg, mask_markup)

    ui_icon_dir = repo_root / "skybridge-ui" / "assets" / "icons"
    packaging_root = repo_root / "packaging" / "linux" / "hicolor"
    ui_icon_dir.mkdir(parents=True, exist_ok=True)

    masked_svg_path = ui_icon_dir / "skybridge-app-icon-superellipse.svg"
    masked_svg_path.write_text(masked_svg, encoding="utf-8")
    legacy_svg_path = ui_icon_dir / "skybridge-app-icon-rounded.svg"
    legacy_svg_path.write_text(masked_svg, encoding="utf-8")

    packaging_svg_path = (
        packaging_root / "scalable" / "apps" / "com.skybridge.compass.ubuntu.svg"
    )
    packaging_svg_path.parent.mkdir(parents=True, exist_ok=True)
    packaging_svg_path.write_text(masked_svg, encoding="utf-8")

    for size in sorted(set(args.sizes)):
        render_png(
            rsvg_convert,
            masked_svg_path,
            ui_icon_dir / f"skybridge-app-icon-{size}.png",
            size,
        )
        render_png(
            rsvg_convert,
            masked_svg_path,
            packaging_root
            / f"{size}x{size}"
            / "apps"
            / "com.skybridge.compass.ubuntu.png",
            size,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
