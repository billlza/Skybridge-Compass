#!/usr/bin/env python3

from __future__ import annotations

import argparse
import pathlib
import sys
import tomllib


def read_workspace_version(cargo_toml: pathlib.Path) -> str:
    payload = tomllib.loads(cargo_toml.read_text(encoding="utf-8"))
    try:
        return payload["workspace"]["package"]["version"]
    except KeyError as exc:
        raise SystemExit(f"failed to read workspace.package.version from {cargo_toml}: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Read the Rust workspace version.")
    parser.add_argument(
        "--cargo-toml",
        default=pathlib.Path(__file__).resolve().parents[1] / "Cargo.toml",
        type=pathlib.Path,
        help="Path to the workspace Cargo.toml",
    )
    parser.add_argument(
        "--expect-tag",
        help="Optional tag name that must equal skybridge-cli-v<workspace version>",
    )
    args = parser.parse_args()

    version = read_workspace_version(args.cargo_toml)
    if args.expect_tag:
        expected_tag = f"skybridge-cli-v{version}"
        if args.expect_tag != expected_tag:
            print(
                f"tag/version mismatch: got {args.expect_tag}, expected {expected_tag}",
                file=sys.stderr,
            )
            return 1

    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
