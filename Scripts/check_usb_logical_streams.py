#!/usr/bin/env python3
"""Build the real shared module, its focused XCTest suite and local interop peer.

Uses the selected Xcode SDK and Swift build backend. No device, account or USB
interface is opened. Every subprocess is serial and every output directory new.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    test = root / "Tests/SkyBridgeCoreTests/USBLogicalStreamProtocolTests.swift"
    peer = root / "Scripts/USBLogicalStreamInteropPeer.swift"
    paths = sorted((root / "Sources/SkyBridgeProtocolCore").rglob("*.swift"))
    paths += [root / "Package.swift", test, peer, Path(__file__).resolve()]
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    sources = {str(path.relative_to(root)): digest(path) for path in paths}
    stages = []

    def run(name, command):
        stage = output / name
        stage.mkdir()
        started = time.monotonic()
        metadata = {"argv": [str(x) for x in command], "cwd": str(root),
                    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        (stage / "command.json").write_text(json.dumps(metadata, indent=2) + "\n")
        with (stage / "stdout.log").open("w") as stdout, (stage / "stderr.log").open("w") as stderr:
            process = subprocess.Popen(command, cwd=root, stdout=stdout, stderr=stderr, start_new_session=True)
            (stage / "process.json").write_text(json.dumps({"pid": process.pid}) + "\n")
            timed_out = False
            try:
                code = process.wait(timeout=1200)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        receipt = {"stage": name, "exitCode": code, "timedOut": timed_out,
                   "elapsedSeconds": time.monotonic() - started}
        stages.append(receipt)
        (stage / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if code:
            raise RuntimeError(f"{name} failed; inspect {stage}")

    success = False
    try:
        run("shared-module", ["xcrun", "swift", "build", "--target", "SkyBridgeProtocolCore", "--jobs", "1",
                              "--disable-automatic-resolution", "-Xswiftc", "-warnings-as-errors"])
        products = (root / ".build/debug").resolve(strict=True)
        aggregate = products / "SkyBridgeProtocolCore.o"
        module = products / "SkyBridgeProtocolCore.swiftmodule"
        if not aggregate.is_file() or not module.is_dir():
            raise RuntimeError("Expected current Swift build module and aggregate object are absent")
        # A legacy .a can coexist in Products without being rebuilt by this backend.
        # Use the completed target's aggregate object, never an older archive by name.
        symbols = subprocess.check_output(["nm", "-g", str(aggregate)], text=True)
        symbols = subprocess.check_output(["xcrun", "swift-demangle"], input=symbols, text=True)
        if "USBLogicalStreamProtocol" not in symbols or "USBLogicalStreamWire" not in symbols:
            raise RuntimeError("Completed module object does not contain the current USB types")
        xcode = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        developer = xcode / "Platforms/MacOSX.platform/Developer"
        frameworks = developer / "Library/Frameworks"
        swift_support = developer / "usr/lib"
        names = re.findall(r"^    func (test\w+)\(", test.read_text(), re.MULTILINE)
        if not names or len(names) != len(set(names)):
            raise RuntimeError("Test discovery source is empty or ambiguous")
        runner = output / "UnitTestMain.swift"
        runner.write_text("""import Foundation
import XCTest
@main struct USBUnitTestMain {
    static func main() throws {
        let suite = USBLogicalStreamProtocolTests.defaultTestSuite
        guard suite.testCaseCount == COUNT else { throw NSError(domain: "USB test discovery", code: 1) }
        suite.run()
        guard let result = suite.testRun, result.executionCount == COUNT else {
            throw NSError(domain: "USB test execution", code: 2)
        }
        var data = try JSONSerialization.data(withJSONObject: ["tests": result.executionCount,
            "failures": result.totalFailureCount, "succeeded": result.hasSucceeded], options: [.sortedKeys])
        data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
        exit(result.hasSucceeded ? 0 : 1)
    }
}
""".replace("COUNT", str(len(names))))
        common = ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                  "-Xlinker", "-fatal_warnings", "-I", str(products), str(aggregate)]
        unit = output / "usb-protocol-tests"
        run("unit-build", [*common, "-I", str(swift_support), "-L", str(swift_support), "-lXCTestSwiftSupport",
                           "-F", str(frameworks), "-framework", "XCTest", "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                           "-Xlinker", "-rpath", "-Xlinker", str(swift_support), str(test), str(runner), "-o", str(unit)])
        run("unit-run", [str(unit)])
        run("peer-build", [*common, "-module-name", "USBLogicalStreamInteropPeer", str(peer), "-o", str(output / "swift-yamux-peer")])
        manifest = {"sourceSha256": sources, "aggregateObjectSha256": digest(aggregate), "tests": names,
                    "binarySha256": {name: digest(output / name) for name in ["usb-protocol-tests", "swift-yamux-peer"]}}
        (output / "inputs-and-products.json").write_text(json.dumps(manifest, indent=2) + "\n")
        success = True
    finally:
        changed = [name for name, expected in sources.items() if not (root / name).is_file() or digest(root / name) != expected]
        success = success and not changed
        (output / "result.json").write_text(json.dumps({"success": success, "stages": stages, "changedSources": changed,
                                                        "physicalUSBQualified": False}, indent=2) + "\n")
        if changed:
            raise RuntimeError("Sources changed during verification")
    print(json.dumps({"success": success, "testCases": len(names), "output": str(output)}))


if __name__ == "__main__":
    main()
