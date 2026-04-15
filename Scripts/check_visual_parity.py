#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover - dependency error path
    raise SystemExit(
        "Pillow is required for Scripts/check_visual_parity.py. Install it with `python3 -m pip install pillow`."
    ) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare macOS and Windows UI baseline screenshots with optional masks.")
    parser.add_argument("--manifest", type=Path, default=Path("Docs/mac-baseline/ui-baseline/capture-manifest.json"))
    parser.add_argument("--mac-dir", type=Path, default=Path("Docs/mac-baseline/ui-baseline/screenshots/mac"))
    parser.add_argument("--windows-dir", type=Path, required=True)
    parser.add_argument("--mask-file", type=Path, default=Path("Docs/mac-baseline/ui-baseline/diff-masks.json"))
    parser.add_argument("--threshold", type=float, default=0.0, help="Allowed mismatch ratio after masking.")
    return parser.parse_args()


def load_manifest(path: Path) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))["captures"]


def load_masks(path: Path) -> dict[str, list[list[int]]]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def apply_masks(mask_image: Image.Image, rectangles: list[list[int]]) -> None:
    for rect in rectangles:
        if len(rect) != 4:
            continue
        x, y, width, height = rect
        for px in range(x, x + width):
            for py in range(y, y + height):
                if 0 <= px < mask_image.width and 0 <= py < mask_image.height:
                    mask_image.putpixel((px, py), 255)


def mismatch_ratio(left_path: Path, right_path: Path, rectangles: list[list[int]]) -> float:
    left = Image.open(left_path).convert("RGBA")
    right = Image.open(right_path).convert("RGBA")

    if left.size != right.size:
        raise ValueError(f"Image size mismatch: {left_path.name} -> {left.size} vs {right.size}")

    mask = Image.new("L", left.size, 0)
    apply_masks(mask, rectangles)

    left_pixels = left.load()
    right_pixels = right.load()
    mask_pixels = mask.load()

    diff_pixels = 0
    total_pixels = 0

    for y in range(left.height):
        for x in range(left.width):
            if mask_pixels[x, y] == 255:
                continue
            total_pixels += 1
            if left_pixels[x, y] != right_pixels[x, y]:
                diff_pixels += 1

    if total_pixels == 0:
        return 0.0

    return diff_pixels / total_pixels


def main() -> int:
    args = parse_args()
    captures = load_manifest(args.manifest)
    masks = load_masks(args.mask_file)

    failures: list[str] = []
    for capture in captures:
        capture_id = capture["id"]
        mac_path = args.mac_dir / f"{capture_id}.png"
        windows_path = args.windows_dir / f"{capture_id}.png"

        if not mac_path.exists():
            failures.append(f"{capture_id}: missing mac baseline {mac_path}")
            continue
        if not windows_path.exists():
            failures.append(f"{capture_id}: missing windows baseline {windows_path}")
            continue

        ratio = mismatch_ratio(mac_path, windows_path, masks.get(capture_id, []))
        print(f"{capture_id}: mismatch_ratio={ratio:.6f}")
        if ratio > args.threshold:
            failures.append(f"{capture_id}: mismatch_ratio {ratio:.6f} > threshold {args.threshold:.6f}")

    if failures:
        print("\nVisual parity check failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("\nVisual parity check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
