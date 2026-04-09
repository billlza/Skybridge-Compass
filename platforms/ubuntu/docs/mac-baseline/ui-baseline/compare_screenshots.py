#!/usr/bin/env python3
"""Compare Ubuntu screenshots against Mac baseline screenshots.

Expected filenames are `<capture-id>.png` from capture-manifest.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image, ImageChops


@dataclass
class CaptureSpec:
    capture_id: str
    critical: bool
    page: str
    state: str
    theme: str
    locale: str


@dataclass
class CaptureResult:
    capture_id: str
    page: str
    state: str
    theme: str
    locale: str
    critical: bool
    status: str
    mismatch_ratio: float | None
    ubuntu_file: str
    mac_file: str
    diff_file: str | None
    note: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="UI pixel baseline diff (Ubuntu vs Mac)")
    parser.add_argument("--ubuntu-dir", required=True, help="Ubuntu screenshot directory")
    parser.add_argument("--mac-dir", required=True, help="Mac screenshot directory")
    parser.add_argument("--out-dir", required=True, help="Output report/diff directory")
    parser.add_argument(
        "--manifest",
        default="docs/mac-baseline/ui-baseline/capture-manifest.json",
        help="Capture manifest JSON",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.005,
        help="Pass threshold (default 0.005 = 0.5%%)",
    )
    parser.add_argument(
        "--hard-fail-threshold",
        type=float,
        default=0.01,
        help="Hard fail threshold (default 0.01 = 1.0%%)",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="Do not fail process when screenshots are missing",
    )
    parser.add_argument(
        "--flatten-alpha",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Composite both screenshots onto white before diffing (default: enabled)",
    )
    parser.add_argument(
        "--tolerance",
        type=int,
        default=8,
        help="Per-channel tolerance before a pixel counts as changed (default: 8)",
    )
    return parser.parse_args()


def load_manifest(path: Path) -> list[CaptureSpec]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    captures = raw.get("captures")
    if not isinstance(captures, list):
        raise ValueError("manifest must contain a 'captures' array")

    out: list[CaptureSpec] = []
    for item in captures:
        if not isinstance(item, dict) or "id" not in item:
            raise ValueError("each manifest item must be an object with an 'id'")
        out.append(
            CaptureSpec(
                capture_id=str(item["id"]),
                critical=bool(item.get("critical", False)),
                page=str(item.get("page", "")),
                state=str(item.get("state", "")),
                theme=str(item.get("theme", "")),
                locale=str(item.get("locale", "")),
            )
        )
    return out


def flatten_alpha(img: Image.Image) -> Image.Image:
    base = Image.new("RGBA", img.size, (255, 255, 255, 255))
    return Image.alpha_composite(base, img.convert("RGBA"))


def changed_pixel_ratio(
    img_a: Image.Image, img_b: Image.Image, *, flatten: bool, tolerance: int
) -> tuple[float, Image.Image]:
    if img_a.size != img_b.size:
        raise ValueError(f"size mismatch: {img_a.size} vs {img_b.size}")

    if flatten:
        a = flatten_alpha(img_a)
        b = flatten_alpha(img_b)
    else:
        a = img_a.convert("RGBA")
        b = img_b.convert("RGBA")
    diff = ImageChops.difference(a, b)

    channels = diff.split()
    if tolerance > 0:
        thresholded = [channel.point(lambda p: 255 if p > tolerance else 0) for channel in channels]
    else:
        thresholded = list(channels)
    any_diff = thresholded[0]
    for channel in thresholded[1:]:
        any_diff = ImageChops.lighter(any_diff, channel)

    histogram = any_diff.histogram()
    total_pixels = img_a.size[0] * img_a.size[1]
    unchanged = histogram[0]
    changed = total_pixels - unchanged
    ratio = changed / total_pixels if total_pixels else 0.0

    highlight_mask = any_diff.point(lambda p: 220 if p > 0 else 0)
    overlay = Image.new("RGBA", img_a.size, (255, 0, 0, 0))
    overlay.putalpha(highlight_mask)
    highlighted = Image.alpha_composite(a, overlay)

    return ratio, highlighted


def determine_status(ratio: float, critical: bool, threshold: float, hard_fail_threshold: float) -> str:
    if ratio > hard_fail_threshold:
        return "fail"
    if ratio > threshold:
        return "fail" if critical else "warn"
    return "pass"


def to_percentage(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:.3f}%"


def build_markdown_summary(
    results: list[CaptureResult],
    threshold: float,
    hard_fail_threshold: float,
    summary: dict[str, Any],
) -> str:
    lines: list[str] = []
    lines.append("# UI Baseline Diff Summary")
    lines.append("")
    lines.append(f"- Pass threshold: `{threshold * 100:.2f}%`")
    lines.append(f"- Hard fail threshold: `{hard_fail_threshold * 100:.2f}%`")
    if summary.get("flatten_alpha"):
        lines.append("- Alpha handling: `flattened onto white before diff`")
    lines.append(f"- Pixel tolerance: `{summary['tolerance']}`")
    lines.append(
        f"- Totals: `{summary['pass']}` pass, `{summary['warn']}` warn, `{summary['fail']}` fail, `{summary['missing']}` missing"
    )
    lines.append("")
    lines.append("| Capture | Page | State | Theme | Locale | Critical | Mismatch | Status | Note |")
    lines.append("|---|---|---|---|---|---:|---:|---|---|")
    for item in results:
        lines.append(
            "| {id} | {page} | {state} | {theme} | {locale} | {critical} | {mismatch} | {status} | {note} |".format(
                id=item.capture_id,
                page=item.page,
                state=item.state,
                theme=item.theme,
                locale=item.locale,
                critical="yes" if item.critical else "no",
                mismatch=to_percentage(item.mismatch_ratio),
                status=item.status,
                note=item.note or "",
            )
        )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    if args.allow_missing:
        print(
            "--allow-missing is ignored for the Ubuntu GTK baseline gate; missing captures remain blocking.",
            file=sys.stderr,
        )

    ubuntu_dir = Path(args.ubuntu_dir)
    mac_dir = Path(args.mac_dir)
    out_dir = Path(args.out_dir)
    manifest_path = Path(args.manifest)

    out_dir.mkdir(parents=True, exist_ok=True)
    diff_dir = out_dir / "diff"
    diff_dir.mkdir(parents=True, exist_ok=True)

    specs = load_manifest(manifest_path)

    results: list[CaptureResult] = []
    pass_count = warn_count = fail_count = missing_count = 0

    for spec in specs:
        ubuntu_file = ubuntu_dir / f"{spec.capture_id}.png"
        mac_file = mac_dir / f"{spec.capture_id}.png"

        if not ubuntu_file.exists() or not mac_file.exists():
            missing_count += 1
            note_parts: list[str] = []
            if not ubuntu_file.exists():
                note_parts.append("missing Ubuntu capture")
            if not mac_file.exists():
                note_parts.append("missing Mac baseline")
            results.append(
                CaptureResult(
                    capture_id=spec.capture_id,
                    page=spec.page,
                    state=spec.state,
                    theme=spec.theme,
                    locale=spec.locale,
                    critical=spec.critical,
                    status="missing",
                    mismatch_ratio=None,
                    ubuntu_file=str(ubuntu_file),
                    mac_file=str(mac_file),
                    diff_file=None,
                    note=", ".join(note_parts),
                )
            )
            continue

        try:
            ubuntu_img = Image.open(ubuntu_file)
            mac_img = Image.open(mac_file)
            ratio, highlighted = changed_pixel_ratio(
                ubuntu_img, mac_img, flatten=args.flatten_alpha, tolerance=args.tolerance
            )
            status = determine_status(ratio, spec.critical, args.threshold, args.hard_fail_threshold)
            diff_file = diff_dir / f"{spec.capture_id}.png"
            highlighted.save(diff_file)

            if status == "pass":
                pass_count += 1
            elif status == "warn":
                warn_count += 1
            else:
                fail_count += 1

            results.append(
                CaptureResult(
                    capture_id=spec.capture_id,
                    page=spec.page,
                    state=spec.state,
                    theme=spec.theme,
                    locale=spec.locale,
                    critical=spec.critical,
                    status=status,
                    mismatch_ratio=ratio,
                    ubuntu_file=str(ubuntu_file),
                    mac_file=str(mac_file),
                    diff_file=str(diff_file),
                    note=None,
                )
            )
        except Exception as exc:  # noqa: BLE001
            fail_count += 1
            results.append(
                CaptureResult(
                    capture_id=spec.capture_id,
                    page=spec.page,
                    state=spec.state,
                    theme=spec.theme,
                    locale=spec.locale,
                    critical=spec.critical,
                    status="fail",
                    mismatch_ratio=None,
                    ubuntu_file=str(ubuntu_file),
                    mac_file=str(mac_file),
                    diff_file=None,
                    note=f"compare error: {exc}",
                )
            )

    summary = {
        "capture_count": len(specs),
        "pass": pass_count,
        "warn": warn_count,
        "fail": fail_count,
        "missing": missing_count,
        "threshold": args.threshold,
        "hard_fail_threshold": args.hard_fail_threshold,
        "flatten_alpha": args.flatten_alpha,
        "tolerance": args.tolerance,
        "results": [item.__dict__ for item in results],
    }

    summary_path = out_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    markdown = build_markdown_summary(results, args.threshold, args.hard_fail_threshold, summary)
    markdown_path = out_dir / "summary.md"
    markdown_path.write_text(markdown, encoding="utf-8")

    has_blocking = fail_count > 0 or missing_count > 0
    if has_blocking:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
