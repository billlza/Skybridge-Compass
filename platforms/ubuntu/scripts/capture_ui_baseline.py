#!/usr/bin/env python3
"""Build SkyBridge once, capture deterministic GTK UI fixtures, then diff them."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    docs_root = repo_root / "docs" / "mac-baseline" / "ui-baseline"
    parser = argparse.ArgumentParser(
        description="Capture Ubuntu UI fixtures and optionally compare against Mac baselines."
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=docs_root / "capture-manifest.json",
        help="Capture manifest JSON",
    )
    parser.add_argument(
        "--ubuntu-dir",
        type=Path,
        default=docs_root / "screenshots" / "ubuntu",
        help="Directory for generated Ubuntu screenshots",
    )
    parser.add_argument(
        "--mac-dir",
        type=Path,
        default=docs_root / "screenshots" / "mac",
        help="Directory containing Mac baseline screenshots",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=docs_root / "reports" / "latest",
        help="Directory for diff artifacts and summary files",
    )
    parser.add_argument(
        "--binary",
        type=Path,
        default=repo_root / "target" / "debug" / "skybridge-compass",
        help="Expected binary path after build",
    )
    parser.add_argument(
        "--profile",
        choices=("debug", "release"),
        default="debug",
        help="Cargo profile used for the capture binary",
    )
    parser.add_argument(
        "--capture-id",
        action="append",
        dest="capture_ids",
        default=[],
        help="Run only selected capture IDs (repeatable)",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Skip cargo build and reuse an existing binary",
    )
    parser.add_argument(
        "--skip-compare",
        action="store_true",
        help="Only capture screenshots; do not run compare_screenshots.py",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="Pass through to compare script so missing Mac baselines do not fail the run",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Per-capture timeout in seconds",
    )
    return parser.parse_args()


def load_manifest(path: Path) -> list[dict[str, str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    captures = raw.get("captures")
    if not isinstance(captures, list):
        raise ValueError("manifest must contain a 'captures' list")
    return [item for item in captures if isinstance(item, dict) and "id" in item]


def build_binary(repo_root: Path, profile: str) -> None:
    command = ["cargo", "build", "--bin", "skybridge-compass", "--all-features"]
    if profile == "release":
        command.append("--release")
    run(command, cwd=repo_root)


def capture_command(binary: Path) -> list[str]:
    if platform.system() == "Linux" and not os.environ.get("DISPLAY"):
        xvfb_run = shutil.which("xvfb-run")
        if xvfb_run:
            return [
                xvfb_run,
                "-a",
                "--server-args=-screen 0 1400x1000x24",
                str(binary),
            ]
    return [str(binary)]


def normalize_locale(locale: str) -> str:
    return f"{locale.replace('-', '_')}.UTF-8"


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=cwd, env=env, check=True, timeout=timeout)


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    inherited_reference_mode = os.environ.get("SKYBRIDGE_UI_CAPTURE_REFERENCE_MODE")
    if inherited_reference_mode and inherited_reference_mode != "render":
        print(
            "SKYBRIDGE_UI_CAPTURE_REFERENCE_MODE must be 'render' for GTK baseline gates.",
            file=sys.stderr,
        )
        return 2
    if args.allow_missing:
        print(
            "--allow-missing is disabled for the Ubuntu GTK UI gate; all manifest captures are required.",
            file=sys.stderr,
        )
        return 2
    manifest = load_manifest(args.manifest)
    if args.capture_ids:
        requested = set(args.capture_ids)
        manifest = [capture for capture in manifest if capture["id"] in requested]
    if not manifest:
        print("No captures selected.", file=sys.stderr)
        return 2

    binary = args.binary
    if args.profile == "release" and binary == repo_root / "target" / "debug" / "skybridge-compass":
        binary = repo_root / "target" / "release" / "skybridge-compass"

    args.ubuntu_dir.mkdir(parents=True, exist_ok=True)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    if not args.skip_build:
        build_binary(repo_root, args.profile)
    if not binary.exists():
        print(f"Binary not found: {binary}", file=sys.stderr)
        return 3

    base_env = os.environ.copy()
    base_env.setdefault("NO_AT_BRIDGE", "1")
    base_env.setdefault("GSETTINGS_BACKEND", "memory")
    base_env.setdefault("RUST_LOG", "error")
    base_env["SKYBRIDGE_UI_CAPTURE_REFERENCE_MODE"] = "render"
    base_env.setdefault("SKYBRIDGE_UI_CAPTURE_REFERENCE_DIR", str(args.mac_dir))

    for capture in manifest:
        capture_id = str(capture["id"])
        theme = str(capture.get("theme", "Light")).lower()
        locale = str(capture.get("locale", "en-US"))
        output_path = args.ubuntu_dir / f"{capture_id}.png"
        if output_path.exists():
            output_path.unlink()
        env = base_env.copy()
        env["SKYBRIDGE_UI_CAPTURE_ID"] = capture_id
        env["SKYBRIDGE_UI_CAPTURE_OUT"] = str(output_path)
        env["SKYBRIDGE_UI_CAPTURE_THEME"] = theme
        env["LANG"] = normalize_locale(locale)
        env["LC_ALL"] = normalize_locale(locale)
        run(
            capture_command(binary),
            cwd=repo_root,
            env=env,
            timeout=args.timeout,
        )
        if not output_path.exists():
            print(f"Capture missing: {output_path}", file=sys.stderr)
            return 4

    if args.skip_compare:
        return 0

    compare_command = [
        sys.executable,
        str(
            repo_root
            / "docs"
            / "mac-baseline"
            / "ui-baseline"
            / "compare_screenshots.py"
        ),
        "--ubuntu-dir",
        str(args.ubuntu_dir),
        "--mac-dir",
        str(args.mac_dir),
        "--out-dir",
        str(args.out_dir),
        "--manifest",
        str(args.manifest),
    ]
    run(compare_command, cwd=repo_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
