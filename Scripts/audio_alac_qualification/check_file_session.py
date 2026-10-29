#!/usr/bin/env python3
"""Run real held-file ALAC/FLAC owners and validated PCM readers in an isolated snapshot.

Uses production source and pinned SDK bytes, with no hardware output or replacement codec.
The receipt records actual XCTest results; an empty Swift Testing run is not acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    package = output / 'package'
    package.mkdir()
    inputs = {}

    def copy(source: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            for child in sorted(source.rglob('*')):
                if child.is_file():
                    copy(child, destination / child.relative_to(source))
        else:
            if source.is_symlink():
                raise ValueError(f'Unexpected symlink input: {source}')
            inputs[str(source.relative_to(root))] = digest(source)
            shutil.copy2(source, destination)
            if digest(destination) != inputs[str(source.relative_to(root))]:
                raise ValueError(f'Copy changed input: {source}')

    for name in ['AudioStreamingWire', 'AudioAlacFile', 'AudioFlacFile', 'AudioBluetoothAttachment',
                 'AudioBluetoothHandshake', 'AudioBluetoothRecordCipher']:
        copy(root / f'Sources/SkyBridgeProtocolCore/Audio/{name}.swift', package / f'Sources/SkyBridgeProtocolCore/{name}.swift')
    copy(root / 'Sources/SkyBridgeProtocolCore/RemoteConnection/PreparedOutboundFileReadSession.swift',
         package / 'Sources/SkyBridgeProtocolCore/PreparedOutboundFileReadSession.swift')
    for name in ['AudioIndexedAlacFile', 'AudioAlacPCMDecoder', 'AudioValidatedAlacFile',
                 'AudioFlacPCMDecoder', 'AudioValidatedFlacFile', 'AudioValidatedPCMReadSession']:
        copy(root / f'Sources/SkyBridgeAudioFile/{name}.swift', package / f'Sources/SkyBridgeAudioFile/{name}.swift')
    test_names = ['AudioAlacFileTests', 'AudioIndexedAlacFileTests', 'AudioAlacPCMDecoderTests',
                  'AudioValidatedAlacFileTests', 'AudioFlacPCMDecoderTests', 'AudioValidatedFlacFileTests']
    for name in test_names:
        copy(root / f'Tests/SkyBridgeCoreTests/{name}.swift', package / f'Tests/AudioFileChecks/{name}.swift')
    resources = ['alac-m4a-metadata-v1.json', 'alac-packet-index-v1.json', 'alac-decoder-v1', 'flac-decoder-v1']
    for name in resources:
        copy(root / f'Tests/SkyBridgeCoreTests/Fixtures/AudioStreaming/{name}', package / f'Tests/AudioFileChecks/Fixtures/{name}')
    copy(root / 'Sources/CSkyBridgeFLAC', package / 'Sources/CSkyBridgeFLAC')
    for name in ['alac', 'libflac']:
        copy(root / f'Sources/Vendor/{name}.xcframework', package / f'Vendor/{name}.xcframework')
    resource_entries = ', '.join(f'.copy("Fixtures/{name}")' for name in resources)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])]
let package = Package(name: "SkyBridgeLosslessFileChecks", platforms: [.macOS(.v14)], targets: [
 .binaryTarget(name: "CSkyBridgeALAC", path: "Vendor/alac.xcframework"),
 .binaryTarget(name: "libflac", path: "Vendor/libflac.xcframework"),
 .target(name: "CSkyBridgeFLAC", dependencies: ["libflac"], publicHeadersPath: "include",
   cSettings: [.unsafeFlags(["-std=gnu23", "-Wall", "-Wextra", "-Werror", "-pedantic"])]),
 .target(name: "SkyBridgeProtocolCore", swiftSettings: strict),
 .target(name: "SkyBridgeAudioFile", dependencies: ["SkyBridgeProtocolCore", "CSkyBridgeALAC", "CSkyBridgeFLAC"], swiftSettings: strict),
 .testTarget(name: "AudioFileChecks", dependencies: ["SkyBridgeProtocolCore", "SkyBridgeAudioFile"], resources: ['''
                                        + resource_entries + '''], swiftSettings: strict)
])
''')
    inputs[str(Path(__file__).resolve().relative_to(root))] = digest(Path(__file__))
    (output / 'source-hashes.json').write_text(json.dumps(inputs, indent=2, sort_keys=True) + '\n')
    removed = sorted(key for key in os.environ if key.startswith(('DYLD_', 'SWIFT_')) or key in
                     {'SDKROOT', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                      'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS'})
    environment = {key: value for key, value in os.environ.items() if key not in removed}
    command = ['/usr/bin/xcrun', '--sdk', 'macosx', 'swift', 'test', '--package-path', str(package), '-j', '1']
    (output / 'command.json').write_text(json.dumps({'argv': command, 'removedEnvironmentVariables': removed}, indent=2) + '\n')
    timed_out = False
    with (output / 'run.log').open('wb') as log:
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            import signal
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
    log = (output / 'run.log').read_text(errors='replace')
    passed = re.findall(r"Test Case '-\[([^\]]+)\]' passed", log)
    expected = sum(len(re.findall(r'\bfunc test\w+\(', (root / f'Tests/SkyBridgeCoreTests/{name}.swift').read_text())) for name in test_names)
    warnings = [line for line in log.splitlines() if re.search(r'\bwarning:', line)]
    unchanged = all((root / name).is_file() and digest(root / name) == value for name, value in inputs.items())
    result = {'exitCode': code, 'timedOut': timed_out, 'sourceUnchanged': unchanged,
              'expectedXCTestMethods': expected, 'passedXCTestMethods': passed, 'warnings': warnings,
              'scope': 'Production held-file owners and bounded PCM reads; no output device, phone session, or app launch.'}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'passedXCTestMethods'} | {'passedCount': len(passed)}, indent=2))
    return 0 if code == 0 and not timed_out and unchanged and len(passed) == expected and not warnings else 1


if __name__ == '__main__':
    sys.exit(main())
