#!/usr/bin/env python3
"""Wrap macOS-exclusive SkyBridgeCore sources in `#if os(macOS)`.

Used during the iOS/SkyBridgeCore unification: SkyBridgeCore must compile for iOS so it can be the
single shared core, and the macOS host-only layers (screen capture, display enumeration, IOKit
metrics, MetalFX, CoreWLAN, ServiceManagement, AppKit UI) are excluded rather than ported.

Idempotent: files already starting with `#if os(macOS)` are left untouched.
"""
import os
import sys

BASE = "Sources/SkyBridgeCore/"
HEADER = (
    "// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /\n"
    "// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).\n"
    "// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as\n"
    "// well. No behaviour changes on macOS.\n"
    "#if os(macOS)\n"
)


def wrap(relative_path: str) -> str:
    path = BASE + relative_path
    if not os.path.exists(path):
        return f"MISSING {relative_path}"
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if text.lstrip().startswith("#if os(macOS)"):
        return f"skip   {relative_path}"
    if not text.endswith("\n"):
        text += "\n"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(HEADER + text + "#endif\n")
    return f"wrap   {relative_path}"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    for argument in sys.argv[1:]:
        print(wrap(argument))
