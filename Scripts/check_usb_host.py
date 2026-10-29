#!/usr/bin/env python3
"""Serial native USB boundary checks. No connected-device transfers or product acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    inputs = [root / 'Package.swift', Path(__file__).resolve()]
    inputs += sorted((root / 'Sources/CSkyBridgeUSBHost').rglob('*'))
    inputs += sorted((root / 'Tests/CSkyBridgeUSBHostTests').rglob('*'))
    inputs += sorted((root / 'Sources/SkyBridgeAppleTransport').rglob('*.swift'))
    inputs += sorted((root / 'Sources/SkyBridgeProtocolCore').rglob('*.swift'))
    inputs = [path for path in inputs if path.is_file()]
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    manifest = {'sourceSha256': hashes, 'commands': [], 'passed': False, 'physicalDataAcceptance': False}

    def run(name, argv, timeout=90):
        began = time.monotonic()
        with (out / (name + '.stdout.log')).open('w') as stdout, (out / (name + '.stderr.log')).open('w') as stderr:
            process = subprocess.Popen(argv, cwd=root, stdout=stdout, stderr=stderr, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        manifest['commands'].append({'name': name, 'argv': argv, 'exitCode': code, 'timedOut': timed_out,
                                     'elapsedSeconds': time.monotonic() - began})
        (out / 'result.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if code:
            raise SystemExit(f'{name} failed ({code}); see {out}')

    run('package-build', ['xcrun', 'swift', 'build', '--target', 'CSkyBridgeUSBHost', '--jobs', '1',
                         '--disable-automatic-resolution'], timeout=600)
    sources = ['Sources/CSkyBridgeUSBHost/USBHost.c', 'Sources/CSkyBridgeUSBHost/USBHostNative.c',
               'Tests/CSkyBridgeUSBHostTests/USBHostTests.c']
    common = ['xcrun', 'clang', '-std=gnu23', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
              '-fno-omit-frame-pointer', '-I', 'Sources/CSkyBridgeUSBHost', *sources,
              '-framework', 'IOKit', '-framework', 'CoreFoundation', '-Wl,-fatal_warnings']
    for name, sanitizer in [('address-undefined', 'address,undefined'), ('thread', 'thread')]:
        binary = out / ('usb-host-tests-' + name)
        run(name + '-compile', [*common, '-fsanitize=' + sanitizer, '-o', str(binary)])
        run(name + '-tests', [str(binary)])
        manifest.setdefault('binarySha256', {})[binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    run('swift-module', ['xcrun', 'swift', 'build', '--target', 'SkyBridgeAppleTransport', '--jobs', '1',
                        '--disable-automatic-resolution', '--sanitize', 'thread', '-Xswiftc', '-warnings-as-errors'], timeout=600)
    products = (root / '.build/debug').resolve(strict=True)
    objects = [products / (name + '.o') for name in ['SkyBridgeAppleTransport', 'SkyBridgeProtocolCore', 'CSkyBridgeUSBHost']]
    modulemap = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps/CSkyBridgeUSBHost.modulemap'
    for path in [*objects, modulemap]:
        if not path.is_file():
            raise SystemExit(f'Current build input missing: {path}')
    manifest['buildObjectsSha256'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects}
    for path in objects:
        symbols = subprocess.check_output(['nm', '-u', str(path)], text=True)
        if '__tsan_' not in symbols:
            raise SystemExit(f'Thread sanitizer instrumentation absent: {path}')
    manifest['swiftModuleThreadSanitized'] = True
    binary = out / 'usb-host-swift-checks'
    run('swift-checks-compile', ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
        '-sanitize=thread', '-Xlinker', '-fatal_warnings', '-I', str(products), '-Xcc', '-fmodule-map-file=' + str(modulemap),
        '-I', str(root / 'Sources/CSkyBridgeUSBHost/include'), *[str(p) for p in objects],
        '-framework', 'IOKit', '-framework', 'CoreFoundation',
        'Tests/CSkyBridgeUSBHostTests/USBHostByteTransportChecks.swift', '-o', str(binary)])
    run('swift-checks-run', [str(binary)])
    manifest['binarySha256'][binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    changed = [p for p, digest in hashes.items() if hashlib.sha256((root / p).read_bytes()).hexdigest() != digest]
    manifest['changedSources'] = changed
    manifest['passed'] = not changed
    (out / 'result.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if changed:
        raise SystemExit('Sources changed while checking')
    print(json.dumps({'passed': True, 'physicalDataAcceptance': False, 'output': str(out)}))


if __name__ == '__main__':
    main()
