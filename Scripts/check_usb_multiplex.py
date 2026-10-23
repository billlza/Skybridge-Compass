#!/usr/bin/env python3
"""Check the actual Swift native-byte/multiplex owners using bounded synthetic I/O."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true', help='Instrument the actual modules and tests with ThreadSanitizer')
    parser.add_argument('--control-frames', action='store_true', help='Also check the ordered native MAIN frame carrier')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    tests = [root / 'Tests/CSkyBridgeUSBHostTests' / name for name in ('USBMultiplexFixture.swift', 'USBHostMultiplexChecks.swift')]
    peer = root / 'Scripts/USBHostMultiplexInteropPeer.swift'
    paths = [root / 'Package.swift', Path(__file__).resolve(), *tests, peer]
    control_tests = root / 'Tests/CSkyBridgeUSBHostTests/USBHostControlFrameChecks.swift'
    if args.control_frames: paths.append(control_tests)
    for directory in ('SkyBridgeAppleTransport', 'SkyBridgeProtocolCore', 'CSkyBridgeUSBHost'):
        paths += [p for p in (root / 'Sources' / directory).rglob('*') if p.is_file()]
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    hashes = {str(p.relative_to(root)): digest(p) for p in paths}
    result = {'passed': False, 'physicalUSBQualified': False, 'threadSanitized': args.sanitize,
              'sourceSha256': hashes, 'stages': []}

    def save(): (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    def run(name, argv, timeout=600):
        began = time.monotonic()
        with (out / (name + '.stdout.log')).open('w') as stdout, (out / (name + '.stderr.log')).open('w') as stderr:
            process = subprocess.Popen(argv, cwd=root, stdout=stdout, stderr=stderr, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True; os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
                code = 124
        result['stages'].append({'name': name, 'argv': argv, 'exitCode': code, 'timedOut': timed_out,
                                 'elapsedSeconds': time.monotonic() - began})
        save()
        if code: raise SystemExit(f'{name} failed: {code}; {out}')

    try:
        build = ['xcrun', 'swift', 'build', '--target', 'SkyBridgeAppleTransport', '--jobs', '1',
                 '--disable-automatic-resolution', '-Xswiftc', '-warnings-as-errors']
        if args.sanitize: build += ['--sanitize', 'thread']
        run('module', build)
        products = (root / '.build/debug').resolve(strict=True)
        objects = [products / (name + '.o') for name in ('SkyBridgeAppleTransport', 'SkyBridgeProtocolCore', 'CSkyBridgeUSBHost')]
        for path in objects:
            if not path.is_file(): raise RuntimeError(f'Current module object missing: {path}')
            if args.sanitize and '__tsan_' not in subprocess.check_output(['nm', '-u', str(path)], text=True):
                raise RuntimeError(f'Actual module is not instrumented: {path}')
        result['objectsSha256'] = {str(p): digest(p) for p in objects}
        modulemap = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps/CSkyBridgeUSBHost.modulemap'
        binary = out / 'usb-multiplex-checks'
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
            '-Xlinker', '-fatal_warnings', '-I', str(products), '-Xcc', '-fmodule-map-file=' + str(modulemap),
            '-I', str(root / 'Sources/CSkyBridgeUSBHost/include'), *[str(p) for p in objects],
            '-framework', 'IOKit', '-framework', 'CoreFoundation']
        if args.sanitize: common += ['-sanitize=thread']
        run('test-build', [*common, *[str(p) for p in tests], '-o', str(binary)])
        result['binarySha256'] = digest(binary)
        run('test-run', [str(binary)], timeout=120)
        if args.control_frames:
            control_binary = out / 'usb-control-frame-checks'
            run('control-test-build', [*common, str(tests[0]), str(control_tests), '-o', str(control_binary)])
            result['controlBinarySha256'] = digest(control_binary)
            run('control-test-run', [str(control_binary)], timeout=120)
            result['controlFramesChecked'] = True
        peer_binary = out / 'swift-yamux-native-peer'
        run('peer-build', [*common, str(peer), '-o', str(peer_binary)])
        result['peerBinarySha256'] = digest(peer_binary)
        result['passed'] = True
    finally:
        result['changedSources'] = [p for p, h in hashes.items() if not (root / p).is_file() or digest(root / p) != h]
        if result['changedSources']: result['passed'] = False
        save()
    if not result['passed']: raise SystemExit('Source binding or checks failed')
    print(json.dumps({'passed': True, 'physicalUSBQualified': False, 'output': str(out)}))


if __name__ == '__main__':
    main()
