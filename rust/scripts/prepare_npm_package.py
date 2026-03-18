#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import pathlib
import shutil


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage the npm wrapper package for publishing.")
    parser.add_argument("--source-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()

    if args.output_dir.exists():
        shutil.rmtree(args.output_dir)
    shutil.copytree(args.source_dir, args.output_dir)

    package_json_path = args.output_dir / "package.json"
    package_json = json.loads(package_json_path.read_text(encoding="utf-8"))
    package_json["version"] = args.version
    package_json_path.write_text(json.dumps(package_json, indent=2) + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
