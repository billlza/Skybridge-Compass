#!/usr/bin/env python3
"""Qualify native ALAC encoding against deterministic PCM with an independent decoder.

No device is opened and neither afconvert nor FFmpeg is a product dependency.
Every attempted case, including unsupported/failed encodes, stays in the receipt.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def samples(bits, channels, frames):
    packed = bytearray()
    canonical = bytearray()
    width = (bits + 7) // 8
    edges = [0, 1, -1, (1 << (bits - 1)) - 1, -(1 << (bits - 1)), 3, -5, 7]
    for frame in range(frames):
        for channel in range(channels):
            sample = ((frame * 1664525 + channel * 1013904223 + 31) ^ (frame << 7)) & ((1 << bits) - 1)
            sample -= 1 << (bits - 1)
            if frame < len(edges):
                sample = edges[(frame + channel) % len(edges)]
            packed.extend((sample << (width * 8 - bits)).to_bytes(width, "little", signed=True))
            canonical.extend(struct.pack("<i", sample << (32 - bits)))
    return bytes(packed), bytes(canonical)


def wave(pcm, rate, channels, bits):
    width = (bits + 7) // 8
    fmt = struct.pack("<HHIIHHHHI", 0xfffe, channels, rate, rate * channels * width,
                      channels * width, width * 8, 22, bits, 4 if channels == 1 else 3)
    fmt += bytes.fromhex("0100000000001000800000aa00389b71")
    body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt
    body += b"data" + struct.pack("<I", len(pcm)) + pcm + (b"\0" if len(pcm) % 2 else b"")
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / "sources").mkdir()
    (out / "fixtures").mkdir()
    (out / "reference").mkdir()
    receipt = {"scope": "ALAC encoder and independent integer decoder, no output device", "cases": []}
    (out / "generator.py").write_bytes(Path(__file__).read_bytes())
    version = subprocess.run([str(args.ffmpeg), "-version"], capture_output=True, timeout=15)
    (out / "ffmpeg-version.txt").write_bytes(version.stdout + version.stderr)
    if version.returncode:
        raise RuntimeError("FFmpeg version check failed")
    for rate in [44100, 48000, 96000]:
        for channels in [1, 2]:
            for bits, flag in [(16, 1), (20, 2), (24, 3), (32, 4)]:
                name = f"{rate}-{channels}-s{bits}"
                frames = rate // 10 + 17  # Includes a partial last packet and nonzero tails.
                pcm, canonical = samples(bits, channels, frames)
                source = out / "sources" / (name + ".wav")
                encoded = out / "fixtures" / (name + ".m4a")
                reference = out / "reference" / (name + ".s32le")
                source.write_bytes(wave(pcm, rate, channels, bits))
                reference.write_bytes(canonical)
                case = {"name": name, "rate": rate, "channels": channels, "validBits": bits,
                        "frames": frames, "referenceSha256": digest(canonical), "commands": []}
                receipt["cases"].append(case)
                commands = [["/usr/bin/afconvert", "-f", "m4af", "-d", f"alac/{flag}", str(source), str(encoded)],
                            [str(args.ffmpeg), "-nostdin", "-v", "error", "-i", str(encoded), "-map", "0:a:0",
                             "-c:a", "pcm_s32le", "-f", "s32le", "-"]]
                for index, command in enumerate(commands):
                    try:
                        result = subprocess.run(command, capture_output=True, timeout=30)
                    except subprocess.TimeoutExpired as error:
                        case["status"] = "timeout"
                        (out / f"{name}-{index}.stderr").write_bytes(error.stderr or b"")
                        break
                    case["commands"].append({"argv": command, "exitCode": result.returncode})
                    (out / f"{name}-{index}.stderr").write_bytes(result.stderr)
                    if result.returncode or result.stderr:
                        case["status"] = "encoder-failed" if index == 0 else "decoder-failed"
                        break
                    if index == 1:
                        case["encodedSha256"] = digest(encoded.read_bytes())
                        case["decodedSha256"] = digest(result.stdout)
                        case["decodedBytes"] = len(result.stdout)
                        case["status"] = "exact" if result.stdout == canonical else "sample-mismatch"
                (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    failures = [case["name"] for case in receipt["cases"] if case["status"] != "exact"]
    print(json.dumps({"exact": len(receipt["cases"]) - len(failures), "failures": failures}))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
