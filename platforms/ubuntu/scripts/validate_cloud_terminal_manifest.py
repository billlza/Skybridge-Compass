#!/usr/bin/env python3
"""Validate the Ubuntu cloud-terminal golden manifest on a target host."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tomllib


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def dpkg_version(package: str) -> str:
    return run(["dpkg-query", "-W", "-f=${Version}", package])


def validate_prefix(label: str, actual: str, expected: str) -> None:
    if not actual.startswith(expected):
        raise SystemExit(f"{label}: expected prefix {expected!r}, got {actual!r}")


def validate_exact(label: str, actual: str, expected: str) -> None:
    if actual != expected:
        raise SystemExit(f"{label}: expected {expected!r}, got {actual!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        default="packaging/linux/cloud-terminal-golden-manifest.toml",
        help="Path to the golden manifest TOML file",
    )
    args = parser.parse_args()

    manifest_path = pathlib.Path(args.manifest)
    manifest = tomllib.loads(manifest_path.read_text())

    validate_exact("kernel.release", run(["uname", "-r"]), manifest["kernel"]["release"])

    packages = manifest["packages"]
    validate_prefix("gdm3", dpkg_version("gdm3"), packages["gdm3"])
    validate_prefix("gnome-shell", dpkg_version("gnome-shell"), packages["gnome-shell"])
    validate_exact("pipewire", dpkg_version("pipewire"), packages["pipewire"])
    validate_exact(
        "xdg-desktop-portal",
        dpkg_version("xdg-desktop-portal"),
        packages["xdg-desktop-portal"],
    )
    validate_exact("ffmpeg", dpkg_version("ffmpeg"), packages["ffmpeg"])

    validate_prefix(
        "nvidia_driver",
        run(
            [
                "nvidia-smi",
                "--query-gpu=driver_version",
                "--format=csv,noheader",
            ]
        ).splitlines()[0],
        manifest["runtime"]["nvidia_driver"],
    )

    print("cloud-terminal manifest ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

