#!/usr/bin/env python3
"""Build isolated decoder comparators, sequentially, with existing host development tools."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent
    files = [source / "NativeDecodeProbe.swift", source / "PacketDecodeProbe.c"]
    report = {"scope": "Host comparator builds only; no product libraries installed or vendored", "builds": []}
    (out / "builder.py").write_bytes(Path(__file__).read_bytes())
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "libavcodec", "libavformat", "libavutil"], text=True)
    (out / "library-versions.txt").write_bytes(subprocess.check_output(["pkg-config", "--modversion", "libavcodec", "libavformat", "libavutil"]))
    (out / "host.txt").write_bytes(subprocess.check_output(["sw_vers"]))
    commands = [["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-Xlinker", "-fatal_warnings",
                 str(files[0]), "-o", str(out / "native-probe")],
                ["xcrun", "clang", "-std=c17", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
                 str(files[1]), "-o", str(out / "strict-packet-probe")] + shlex.split(flags)]
    for index, (file, command) in enumerate(zip(files, commands)):
        original = file.read_bytes()
        (out / file.name).write_bytes(original)
        result = subprocess.run(command, capture_output=True, timeout=60)
        (out / f"{index}.stdout").write_bytes(result.stdout)
        (out / f"{index}.stderr").write_bytes(result.stderr)
        entry = {"argv": command, "exitCode": result.returncode,
                 "sourceSha256": hashlib.sha256(original).hexdigest(), "sourceUnchanged": file.read_bytes() == original}
        report["builds"].append(entry)
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
        if result.returncode or result.stderr or not entry["sourceUnchanged"]:
            raise RuntimeError("Comparator build failed, emitted diagnostics or its source changed; logs retained")
    libdir = Path(subprocess.check_output(["pkg-config", "--variable=libdir", "libavcodec"], text=True).strip())
    report["hostLibrarySha256"] = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in (libdir / name for name in ["libavcodec.dylib", "libavformat.dylib", "libavutil.dylib"])}
    (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Both isolated comparators built without diagnostics")


if __name__ == "__main__":
    main()
