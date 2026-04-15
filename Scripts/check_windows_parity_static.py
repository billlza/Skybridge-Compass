#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


NAV_PATTERN = re.compile(r'\["(?P<key>[^"]+)"\]\s*=\s*new\("(?P<page>[^"]+)"')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Static checks for the Windows visual parity shell without requiring WinUI toolchains.")
    parser.add_argument(
        "--windows-root",
        type=Path,
        default=Path("/Users/bill/Desktop/SkyBridge Compass-win64/Skybridge-Compass/windows/Skybridge.WinClient"),
    )
    return parser.parse_args()


def ensure(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    args = parse_args()
    root = args.windows_root
    failures: list[str] = []

    app_xaml = root / "App.xaml"
    main_window_cs = root / "MainWindow.xaml.cs"
    generated_xaml = root / "VisualParity" / "GeneratedVisualParity.xaml"

    ensure(app_xaml.exists(), f"missing {app_xaml}", failures)
    ensure(main_window_cs.exists(), f"missing {main_window_cs}", failures)
    ensure(generated_xaml.exists(), f"missing {generated_xaml}", failures)

    if app_xaml.exists():
        app_text = app_xaml.read_text(encoding="utf-8")
        ensure(
            'ms-appx:///VisualParity/GeneratedVisualParity.xaml' in app_text,
            "App.xaml does not merge the generated parity dictionary",
            failures,
        )

    if main_window_cs.exists():
        cs_text = main_window_cs.read_text(encoding="utf-8")
        for match in NAV_PATTERN.finditer(cs_text):
            page = match.group("page")
            page_xaml = root / "Views" / f"{page}.xaml"
            page_cs = root / "Views" / f"{page}.xaml.cs"
            ensure(page_xaml.exists(), f"navigation target missing XAML: {page_xaml}", failures)
            ensure(page_cs.exists(), f"navigation target missing code-behind: {page_cs}", failures)

    for path in root.rglob("*.xaml"):
        text = path.read_text(encoding="utf-8")
        if re.search(r"<Grid\b[^>]*CornerRadius=", text):
            failures.append(f"unsupported Grid CornerRadius usage: {path}")

    if failures:
        print("Windows parity static check failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("Windows parity static check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
