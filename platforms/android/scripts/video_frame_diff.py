#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List

try:
    import numpy as np
    from PIL import Image, ImageFilter
except Exception as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency. Install with `python3 -m pip install pillow numpy`.\n"
        f"Import error: {exc}"
    )


@dataclass
class FrameDiffResult:
    index: int
    file: str
    passed: bool
    non_zero_ratio: float
    mean_delta: float
    max_channel_delta: int
    reason: str
    diff_image: str = ""


@dataclass
class TemporalMetrics:
    speed_index: float
    density_index: float
    opacity_index: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Frame-by-frame visual diff + temporal parity gate (speed/density/opacity)."
    )
    parser.add_argument("--baseline-video", required=True, type=Path)
    parser.add_argument("--actual-video", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--pixel-tolerance", type=int, default=0)
    parser.add_argument("--max-frame-diff-ratio", type=float, default=0.0)
    parser.add_argument("--max-frame-mean-delta", type=float, default=0.0)
    parser.add_argument("--max-frame-channel-delta", type=int, default=0)
    parser.add_argument("--max-frame-count-delta", type=int, default=0)
    parser.add_argument("--max-speed-delta", type=float, default=0.015)
    parser.add_argument("--max-density-delta", type=float, default=0.010)
    parser.add_argument("--max-opacity-delta", type=float, default=0.010)
    parser.add_argument("--max-diff-images", type=int, default=180)
    return parser.parse_args()


def run_ffmpeg_extract(video: Path, output_dir: Path, fps: int) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(video),
        "-vf",
        f"fps={max(1, fps)}",
        str(output_dir / "%06d.png"),
    ]
    subprocess.run(cmd, check=True)


def list_frames(frame_dir: Path) -> List[Path]:
    return sorted(path for path in frame_dir.glob("*.png") if path.is_file())


def open_rgb(path: Path, target_size: tuple[int, int] | None = None) -> Image.Image:
    img = Image.open(path).convert("RGB")
    if target_size and img.size != target_size:
        img = img.resize(target_size, Image.Resampling.LANCZOS)
    return img


def frame_metrics(
    baseline_arr: np.ndarray,
    actual_arr: np.ndarray,
    pixel_tolerance: int,
) -> tuple[float, float, int]:
    diff = np.abs(baseline_arr.astype(np.int16) - actual_arr.astype(np.int16)).astype(np.uint8)
    max_channel = np.max(diff, axis=2)
    non_zero_ratio = float(np.count_nonzero(max_channel > pixel_tolerance)) / float(max_channel.size)
    mean_delta = float(np.mean(diff))
    max_delta = int(np.max(max_channel))
    return non_zero_ratio, mean_delta, max_delta


def build_triptych(
    baseline_rgb: Image.Image,
    actual_rgb: Image.Image,
) -> Image.Image:
    baseline_arr = np.array(baseline_rgb, dtype=np.uint8)
    actual_arr = np.array(actual_rgb, dtype=np.uint8)
    diff = np.abs(baseline_arr.astype(np.int16) - actual_arr.astype(np.int16)).astype(np.uint8)
    max_channel = np.max(diff, axis=2)
    alpha = np.clip(max_channel.astype(np.int32) * 6, 0, 255).astype(np.uint8)

    overlay_rgba = np.zeros((actual_arr.shape[0], actual_arr.shape[1], 4), dtype=np.uint8)
    overlay_rgba[..., 0] = 255
    overlay_rgba[..., 3] = alpha

    actual_rgba = np.dstack([actual_arr, np.full(actual_arr.shape[:2], 255, dtype=np.uint8)])
    heatmap_rgba = actual_rgba.copy()
    blended_alpha = overlay_rgba[..., 3:4].astype(np.float32) / 255.0
    heatmap_rgba[..., :3] = (
        heatmap_rgba[..., :3].astype(np.float32) * (1.0 - blended_alpha)
        + overlay_rgba[..., :3].astype(np.float32) * blended_alpha
    ).astype(np.uint8)

    heatmap = Image.fromarray(heatmap_rgba, mode="RGBA").convert("RGB")

    margin = 8
    width, height = baseline_rgb.size
    canvas = Image.new("RGB", (width * 3 + margin * 4, height + margin * 2), (16, 18, 24))
    canvas.paste(baseline_rgb, (margin, margin))
    canvas.paste(actual_rgb, (margin * 2 + width, margin))
    canvas.paste(heatmap, (margin * 3 + width * 2, margin))
    return canvas


def overlay_map(frame_rgb: Image.Image) -> np.ndarray:
    gray = frame_rgb.convert("L")
    blur = gray.filter(ImageFilter.GaussianBlur(radius=12))
    gray_arr = np.array(gray, dtype=np.float32)
    blur_arr = np.array(blur, dtype=np.float32)
    return np.abs(gray_arr - blur_arr)


def temporal_metrics(frames: List[Path], target_size: tuple[int, int] | None = None) -> TemporalMetrics:
    if not frames:
        return TemporalMetrics(speed_index=0.0, density_index=0.0, opacity_index=0.0)

    speed_sum = 0.0
    density_sum = 0.0
    opacity_sum = 0.0
    motion_count = 0
    prev_overlay: np.ndarray | None = None

    for frame_path in frames:
        frame = open_rgb(frame_path, target_size=target_size)
        overlay = overlay_map(frame)
        density_sum += float(np.count_nonzero(overlay > 18.0)) / float(overlay.size)
        opacity_sum += float(np.mean(overlay) / 255.0)

        if prev_overlay is not None:
            speed_sum += float(np.mean(np.abs(overlay - prev_overlay)) / 255.0)
            motion_count += 1
        prev_overlay = overlay

    frame_count = float(len(frames))
    return TemporalMetrics(
        speed_index=speed_sum / float(max(1, motion_count)),
        density_index=density_sum / frame_count,
        opacity_index=opacity_sum / frame_count,
    )


def write_report(
    output_dir: Path,
    frame_results: List[FrameDiffResult],
    baseline_temporal: TemporalMetrics,
    actual_temporal: TemporalMetrics,
    summary: dict,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "summary.json").write_text(
        json.dumps(
            {
                "summary": summary,
                "baseline_temporal": asdict(baseline_temporal),
                "actual_temporal": asdict(actual_temporal),
                "frame_results": [asdict(item) for item in frame_results],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    lines = [
        "# Video Frame Diff Report",
        "",
        "## Summary",
        f"- total_frames_compared: `{summary['frames_compared']}`",
        f"- failed_frames: `{summary['failed_frames']}`",
        f"- baseline_frames: `{summary['baseline_frames']}`",
        f"- actual_frames: `{summary['actual_frames']}`",
        f"- frame_count_delta: `{summary['frame_count_delta']}`",
        f"- gate_result: `{'PASS' if summary['passed'] else 'FAIL'}`",
        "",
        "## Temporal Metrics (Speed / Density / Opacity)",
        "",
        f"- baseline.speed_index: `{baseline_temporal.speed_index:.6f}`",
        f"- actual.speed_index: `{actual_temporal.speed_index:.6f}`",
        f"- delta.speed_index: `{summary['speed_delta']:.6f}`",
        f"- baseline.density_index: `{baseline_temporal.density_index:.6f}`",
        f"- actual.density_index: `{actual_temporal.density_index:.6f}`",
        f"- delta.density_index: `{summary['density_delta']:.6f}`",
        f"- baseline.opacity_index: `{baseline_temporal.opacity_index:.6f}`",
        f"- actual.opacity_index: `{actual_temporal.opacity_index:.6f}`",
        f"- delta.opacity_index: `{summary['opacity_delta']:.6f}`",
        "",
        "## Failed Frames",
        "",
    ]
    failed = [item for item in frame_results if not item.passed]
    if not failed:
        lines.append("- none")
    else:
        for item in failed[:200]:
            lines.append(
                f"- frame `{item.index:06d}` | ratio={item.non_zero_ratio:.6f} | "
                f"mean={item.mean_delta:.4f} | max={item.max_channel_delta} | reason={item.reason}"
            )
            if item.diff_image:
                lines.append(f"  - diff_image: `{item.diff_image}`")

    (output_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    args = parse_args()

    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg not found in PATH")
    if not args.baseline_video.exists():
        raise SystemExit(f"baseline video not found: {args.baseline_video}")
    if not args.actual_video.exists():
        raise SystemExit(f"actual video not found: {args.actual_video}")

    output_dir = args.output_dir
    baseline_frame_dir = output_dir / "frames" / "baseline"
    actual_frame_dir = output_dir / "frames" / "actual"
    diff_dir = output_dir / "diffs"

    if output_dir.exists():
        shutil.rmtree(output_dir)
    diff_dir.mkdir(parents=True, exist_ok=True)

    run_ffmpeg_extract(args.baseline_video, baseline_frame_dir, args.fps)
    run_ffmpeg_extract(args.actual_video, actual_frame_dir, args.fps)

    baseline_frames = list_frames(baseline_frame_dir)
    actual_frames = list_frames(actual_frame_dir)

    if not baseline_frames or not actual_frames:
        raise SystemExit("failed to extract frames from one or both videos")

    frames_compared = min(len(baseline_frames), len(actual_frames))
    frame_count_delta = abs(len(baseline_frames) - len(actual_frames))

    baseline_size = open_rgb(baseline_frames[0]).size

    frame_results: List[FrameDiffResult] = []
    failed_frames = 0
    diff_written = 0

    for index in range(frames_compared):
        baseline_img = open_rgb(baseline_frames[index], target_size=baseline_size)
        actual_img = open_rgb(actual_frames[index], target_size=baseline_size)
        baseline_arr = np.array(baseline_img, dtype=np.uint8)
        actual_arr = np.array(actual_img, dtype=np.uint8)

        ratio, mean_delta, max_delta = frame_metrics(
            baseline_arr=baseline_arr,
            actual_arr=actual_arr,
            pixel_tolerance=args.pixel_tolerance,
        )

        passed = (
            ratio <= args.max_frame_diff_ratio
            and mean_delta <= args.max_frame_mean_delta
            and max_delta <= args.max_frame_channel_delta
        )
        reason = "ok" if passed else "frame_diff_exceeded"
        diff_image_rel = ""

        if not passed:
            failed_frames += 1
            if diff_written < args.max_diff_images:
                triptych = build_triptych(baseline_img, actual_img)
                diff_path = diff_dir / f"frame_{index + 1:06d}_diff.png"
                triptych.save(diff_path)
                diff_image_rel = diff_path.relative_to(output_dir).as_posix()
                diff_written += 1

        frame_results.append(
            FrameDiffResult(
                index=index + 1,
                file=baseline_frames[index].name,
                passed=passed,
                non_zero_ratio=ratio,
                mean_delta=mean_delta,
                max_channel_delta=max_delta,
                reason=reason,
                diff_image=diff_image_rel,
            )
        )

    baseline_temporal = temporal_metrics(
        baseline_frames[:frames_compared],
        target_size=baseline_size,
    )
    actual_temporal = temporal_metrics(
        actual_frames[:frames_compared],
        target_size=baseline_size,
    )

    speed_delta = abs(actual_temporal.speed_index - baseline_temporal.speed_index)
    density_delta = abs(actual_temporal.density_index - baseline_temporal.density_index)
    opacity_delta = abs(actual_temporal.opacity_index - baseline_temporal.opacity_index)

    temporal_passed = (
        speed_delta <= args.max_speed_delta
        and density_delta <= args.max_density_delta
        and opacity_delta <= args.max_opacity_delta
    )
    frame_passed = (failed_frames == 0) and (frame_count_delta <= args.max_frame_count_delta)
    passed = frame_passed and temporal_passed

    summary = {
        "passed": passed,
        "frames_compared": frames_compared,
        "failed_frames": failed_frames,
        "baseline_frames": len(baseline_frames),
        "actual_frames": len(actual_frames),
        "frame_count_delta": frame_count_delta,
        "speed_delta": speed_delta,
        "density_delta": density_delta,
        "opacity_delta": opacity_delta,
        "thresholds": {
            "max_frame_diff_ratio": args.max_frame_diff_ratio,
            "max_frame_mean_delta": args.max_frame_mean_delta,
            "max_frame_channel_delta": args.max_frame_channel_delta,
            "pixel_tolerance": args.pixel_tolerance,
            "max_frame_count_delta": args.max_frame_count_delta,
            "max_speed_delta": args.max_speed_delta,
            "max_density_delta": args.max_density_delta,
            "max_opacity_delta": args.max_opacity_delta,
        },
    }

    write_report(
        output_dir=output_dir,
        frame_results=frame_results,
        baseline_temporal=baseline_temporal,
        actual_temporal=actual_temporal,
        summary=summary,
    )

    if passed:
        print("Video frame diff gate PASSED")
        print(f"Report: {output_dir / 'report.md'}")
        return 0

    print("Video frame diff gate FAILED")
    print(f"Report: {output_dir / 'report.md'}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
