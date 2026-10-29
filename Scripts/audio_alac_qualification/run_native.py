#!/usr/bin/env python3
"""Run a built native ALAC probe; retain exact comparisons and malformed-input observations."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--packet", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / "runner.py").write_bytes(Path(__file__).read_bytes())
    fixture = args.fixtures.resolve()
    cases = json.loads((fixture / "receipt.json").read_text())["cases"]
    report = {"scope": "Synthetic files through native read callbacks, no audio device or product session",
              "probeSha256": digest(args.probe.read_bytes()), "positive": [], "malformed": []}

    def run(case, source, group):
        name = case["name"]
        output = out / (name + ".pcm")
        command = [str(args.probe.resolve()), str(source), str(output), str(case["rate"]),
                   str(case["channels"]), str(case["validBits"]), str(case["frames"])]
        if args.packet:
            command.append("packet")
        value = {"name": name, "argv": command, "sourceSha256": digest(source.read_bytes())}
        try:
            result = subprocess.run(command, capture_output=True, timeout=20)
            (out / (name + ".stdout")).write_bytes(result.stdout)
            (out / (name + ".stderr")).write_bytes(result.stderr)
            value["exitCode"] = result.returncode
            value["diagnostics"] = bool(result.stderr)
            if result.returncode == 0:
                value["native"] = json.loads(result.stdout)
                value["pcmSha256"] = digest(output.read_bytes())
        except subprocess.TimeoutExpired as error:
            value["timeout"] = True
            (out / (name + ".stdout")).write_bytes(error.stdout or b"")
            (out / (name + ".stderr")).write_bytes(error.stderr or b"")
        value["sourceUnchanged"] = digest(source.read_bytes()) == value["sourceSha256"]
        value["probeUnchanged"] = digest(args.probe.read_bytes()) == report["probeSha256"]
        report[group].append(value)
        return value, output

    for case in cases:
        source = fixture / "fixtures" / (case["name"] + ".m4a")
        reference = (fixture / "reference" / (case["name"] + ".s32le")).read_bytes()
        if case["status"] != "exact" or digest(source.read_bytes()) != case["encodedSha256"] or digest(reference) != case["referenceSha256"]:
            raise ValueError("Fixture or independent reference identity differs")
        value, output = run(case, source, "positive")
        width = (case["validBits"] + 7) // 8
        expected = b"".join(reference[i + 4 - width:i + 4] for i in range(0, len(reference), 4))
        value["expectedPcmSha256"] = digest(expected)
        value["exact"] = value.get("exitCode") == 0 and not value["diagnostics"] and value["sourceUnchanged"] and value["probeUnchanged"] and output.read_bytes() == expected
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")

    case = next(value for value in cases if value["name"] == "48000-2-s24")
    source = (fixture / "fixtures" / (case["name"] + ".m4a")).read_bytes()
    packets = source.index(b"mdat") + 4
    first_config = source.index(b"alac")
    config = source.index(b"alac", first_config + 4) + 4
    unknown_bits = bytearray(source)
    unknown_bits[config + 9] = 31
    empty_packet = bytearray(source)
    empty_packet[packets] = 0xe0  # ALAC ID_END before the advertised first packet's samples.
    # Extended EOF is deliberately *not* accepted as proof of clean EOS. These cases are
    # observations; a decoder that returns PCM is reported, never relabelled as rejection.
    mutations = {"truncated-header": source[:64], "missing-last-byte": source[:-1],
                 "unsupported-precision": bytes(unknown_bits), "empty-first-packet": bytes(empty_packet)}
    for name, data in mutations.items():
        path = out / (name + ".m4a")
        path.write_bytes(data)
        value, _ = run(dict(case, name=name), path, "malformed")
        value["rejected"] = value.get("exitCode", 0) != 0 and value["sourceUnchanged"] and value["probeUnchanged"]
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
    exact = sum(value["exact"] for value in report["positive"])
    rejected = sum(value["rejected"] for value in report["malformed"])
    print(json.dumps({"exact": exact, "positive": len(cases), "malformedRejected": rejected,
                      "malformed": len(mutations), "noDevicePlayback": True}))
    return 0 if exact == len(cases) and rejected == len(mutations) else 1


if __name__ == "__main__":
    raise SystemExit(main())
