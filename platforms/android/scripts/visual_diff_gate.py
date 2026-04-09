#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List

try:
    from PIL import Image, ImageChops, ImageOps
except Exception as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency: Pillow. Install with `python3 -m pip install pillow`.\n"
        f"Import error: {exc}"
    )


@dataclass
class DiffResult:
    file: str
    baseline_exists: bool
    actual_exists: bool
    passed: bool
    reason: str
    width: int = 0
    height: int = 0
    non_zero_pixels: int = 0
    non_zero_ratio: float = 0.0
    mean_delta: float = 0.0
    max_channel_delta: int = 0
    diff_image: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pixel diff gate for UI parity screenshots."
    )
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--actual-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--max-diff-ratio", type=float, default=0.0)
    parser.add_argument("--max-mean-delta", type=float, default=0.0)
    parser.add_argument("--max-channel-delta", type=int, default=0)
    parser.add_argument("--pixel-tolerance", type=int, default=0)
    parser.add_argument("--fail-on-missing-actual", action="store_true", default=True)
    parser.add_argument("--allow-extra-actual", action="store_true")
    return parser.parse_args()


def build_triptych(
    baseline_rgba: Image.Image,
    actual_rgba: Image.Image,
    diff_rgba: Image.Image,
) -> Image.Image:
    margin = 8
    width, height = baseline_rgba.size
    canvas = Image.new(
        "RGBA",
        (width * 3 + margin * 4, height + margin * 2),
        (16, 18, 24, 255),
    )
    canvas.paste(baseline_rgba, (margin, margin))
    canvas.paste(actual_rgba, (margin * 2 + width, margin))
    canvas.paste(diff_rgba, (margin * 3 + width * 2, margin))
    return canvas


def create_heatmap(actual_rgba: Image.Image, diff: Image.Image) -> Image.Image:
    gray = diff.convert("L")
    # Amplify to make tiny diffs visible in report artifacts.
    amplified = gray.point(lambda value: min(255, value * 8))
    overlay = Image.new("RGBA", actual_rgba.size, (255, 0, 0, 0))
    overlay.putalpha(amplified)
    return Image.alpha_composite(actual_rgba, overlay)


def compute_diff_metrics(diff: Image.Image, pixel_tolerance: int) -> tuple[int, float, float, int]:
    non_zero = 0
    max_delta = 0
    sum_delta = 0.0
    width, height = diff.size
    total = max(1, width * height)

    for r, g, b, a in diff.convert("RGBA").getdata():
        channel_delta = max(r, g, b, a)
        if channel_delta > pixel_tolerance:
            non_zero += 1
        if channel_delta > max_delta:
            max_delta = channel_delta
        sum_delta += (r + g + b) / 3.0

    return non_zero, non_zero / total, sum_delta / total, max_delta


def diff_one(
    baseline_path: Path,
    actual_path: Path,
    rel: Path,
    output_dir: Path,
    args: argparse.Namespace,
) -> DiffResult:
    if not actual_path.exists():
        return DiffResult(
            file=rel.as_posix(),
            baseline_exists=True,
            actual_exists=False,
            passed=not args.fail_on_missing_actual,
            reason="missing_actual",
        )

    with Image.open(baseline_path) as baseline_img, Image.open(actual_path) as actual_img:
        baseline_rgba = baseline_img.convert("RGBA")
        actual_rgba = actual_img.convert("RGBA")

        if baseline_rgba.size != actual_rgba.size:
            mismatch_report_path = output_dir / "diffs" / rel.parent / f"{rel.stem}_size_mismatch.png"
            mismatch_report_path.parent.mkdir(parents=True, exist_ok=True)
            panel = build_triptych(
                baseline_rgba,
                actual_rgba.resize(baseline_rgba.size),
                Image.new("RGBA", baseline_rgba.size, (255, 64, 64, 255)),
            )
            panel.save(mismatch_report_path)
            return DiffResult(
                file=rel.as_posix(),
                baseline_exists=True,
                actual_exists=True,
                passed=False,
                reason=f"size_mismatch:{baseline_rgba.size}!={actual_rgba.size}",
                width=baseline_rgba.size[0],
                height=baseline_rgba.size[1],
                diff_image=mismatch_report_path.relative_to(output_dir).as_posix(),
            )

        diff = ImageChops.difference(baseline_rgba, actual_rgba)
        non_zero, ratio, mean_delta, max_delta = compute_diff_metrics(diff, args.pixel_tolerance)
        passed = (
            ratio <= args.max_diff_ratio
            and mean_delta <= args.max_mean_delta
            and max_delta <= args.max_channel_delta
        )
        reason = "ok" if passed else "pixel_diff_exceeded"

        heatmap = create_heatmap(actual_rgba, diff)
        report_img = build_triptych(baseline_rgba, actual_rgba, heatmap)
        report_path = output_dir / "diffs" / rel.parent / f"{rel.stem}_diff.png"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_img.save(report_path)

        return DiffResult(
            file=rel.as_posix(),
            baseline_exists=True,
            actual_exists=True,
            passed=passed,
            reason=reason,
            width=baseline_rgba.size[0],
            height=baseline_rgba.size[1],
            non_zero_pixels=non_zero,
            non_zero_ratio=ratio,
            mean_delta=mean_delta,
            max_channel_delta=max_delta,
            diff_image=report_path.relative_to(output_dir).as_posix(),
        )


def write_report(results: List[DiffResult], output_dir: Path, args: argparse.Namespace) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    failed = [item for item in results if not item.passed]
    summary = {
        "total": len(results),
        "passed": len(results) - len(failed),
        "failed": len(failed),
        "thresholds": {
            "max_diff_ratio": args.max_diff_ratio,
            "max_mean_delta": args.max_mean_delta,
            "max_channel_delta": args.max_channel_delta,
            "pixel_tolerance": args.pixel_tolerance,
        },
        "results": [asdict(item) for item in results],
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    lines = [
        "# UI Screenshot Diff Report",
        "",
        f"- Total: {summary['total']}",
        f"- Passed: {summary['passed']}",
        f"- Failed: {summary['failed']}",
        "",
        "## Thresholds",
        "",
        f"- max_diff_ratio: `{args.max_diff_ratio}`",
        f"- max_mean_delta: `{args.max_mean_delta}`",
        f"- max_channel_delta: `{args.max_channel_delta}`",
        f"- pixel_tolerance: `{args.pixel_tolerance}`",
        "",
        "## Per-file Results",
        "",
    ]
    for item in results:
        status = "✅" if item.passed else "❌"
        lines.append(
            f"- {status} `{item.file}` | reason={item.reason} | "
            f"ratio={item.non_zero_ratio:.6f} | mean={item.mean_delta:.4f} | max={item.max_channel_delta}"
        )
        if item.diff_image:
            lines.append(f"  - diff image: `{item.diff_image}`")
    (output_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    args = parse_args()
    baseline_dir = args.baseline_dir
    actual_dir = args.actual_dir
    output_dir = args.output_dir

    if not baseline_dir.exists():
        raise SystemExit(f"baseline dir not found: {baseline_dir}")
    if not actual_dir.exists():
        raise SystemExit(f"actual dir not found: {actual_dir}")

    baseline_files = sorted(
        [path for path in baseline_dir.rglob("*.png") if path.is_file()]
    )
    if not baseline_files:
        raise SystemExit(f"no baseline PNG files found under: {baseline_dir}")

    results: List[DiffResult] = []
    for baseline in baseline_files:
        rel = baseline.relative_to(baseline_dir)
        actual = actual_dir / rel
        result = diff_one(baseline, actual, rel, output_dir, args)
        results.append(result)

    if not args.allow_extra_actual:
        baseline_rel_set = {path.relative_to(baseline_dir).as_posix() for path in baseline_files}
        actual_rel_set = {
            path.relative_to(actual_dir).as_posix()
            for path in actual_dir.rglob("*.png")
            if path.is_file()
        }
        extras = sorted(actual_rel_set - baseline_rel_set)
        for extra in extras:
            results.append(
                DiffResult(
                    file=extra,
                    baseline_exists=False,
                    actual_exists=True,
                    passed=False,
                    reason="unexpected_actual",
                )
            )

    write_report(results, output_dir, args)
    failed_count = sum(1 for item in results if not item.passed)
    if failed_count > 0:
        print(f"Diff gate FAILED: {failed_count} file(s) out of tolerance")
        print(f"See report: {output_dir / 'report.md'}")
        return 1

    print("Diff gate PASSED")
    print(f"Report: {output_dir / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
