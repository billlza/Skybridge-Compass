#!/usr/bin/env python3
"""Serial AOA startup boundary checks; never selects a connected physical device."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import os
import signal

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--swift', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
sources = ['Sources/CSkyBridgeUSBHost/USBAccessory.c', 'Sources/CSkyBridgeUSBHost/USBAccessoryNative.c',
           'Tests/CSkyBridgeUSBHostTests/USBAccessoryTests.c']
inputs = sources + ['Sources/CSkyBridgeUSBHost/USBAccessoryInternal.h', 'Sources/CSkyBridgeUSBHost/USBHostInternal.h',
                   'Sources/CSkyBridgeUSBHost/include/SkyBridgeUSBHost.h', 'Scripts/check_usb_accessory.py']
if a.swift:
    inputs += ['Package.swift', 'Tests/CSkyBridgeUSBHostTests/USBAccessoryPreparationChecks.swift']
    inputs += [str(f.relative_to(root)) for folder in ['Sources/SkyBridgeAppleTransport', 'Sources/SkyBridgeProtocolCore', 'Sources/CSkyBridgeUSBHost']
               for f in sorted((root / folder).rglob('*')) if f.is_file()]
r = {'sourceSha256': {f: hashlib.sha256((root / f).read_bytes()).hexdigest() for f in inputs},
     'stages': [], 'passed': False, 'physicalDeviceSelected': False}
flags = ['xcrun', 'clang', '-std=gnu23', '-Wall', '-Wextra', '-Werror', '-g', '-O1', '-fno-omit-frame-pointer',
         '-I', 'Sources/CSkyBridgeUSBHost', *sources, '-framework', 'IOKit', '-framework', 'CoreFoundation', '-Wl,-fatal_warnings']

def run(stage, argv, timeout=60):
    with (out / (stage + '.stdout.log')).open('w') as stdout, (out / (stage + '.stderr.log')).open('w') as stderr:
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
    r['stages'].append({'name': stage, 'argv': argv, 'exitCode': code, 'timedOut': timed_out})
    if code:
        raise SystemExit(f'{stage} failed; see {out}')

try:
    for name, sanitizer in [('address-undefined', 'address,undefined'), ('thread', 'thread')]:
        binary = out / ('usb-accessory-' + name)
        for stage, argv in [(name + '-build', [*flags, '-fsanitize=' + sanitizer, '-o', str(binary)]),
                            (name + '-run', [str(binary)])]:
            run(stage, argv)
        r.setdefault('binarySha256', {})[binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    if a.swift:
        run('swift-module', ['xcrun', 'swift', 'build', '--target', 'SkyBridgeAppleTransport', '--jobs', '1',
            '--disable-automatic-resolution', '--sanitize', 'thread', '-Xswiftc', '-warnings-as-errors'], timeout=600)
        products = (root / '.build/debug').resolve(strict=True)
        objects = [products / (name + '.o') for name in ['SkyBridgeAppleTransport', 'SkyBridgeProtocolCore', 'CSkyBridgeUSBHost']]
        for f in objects:
            if '__tsan_' not in subprocess.check_output(['nm', '-u', str(f)], text=True):
                raise SystemExit(f'Sanitizer absent in {f}')
        r['moduleObjectsSha256'] = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in objects}
        modulemap = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps/CSkyBridgeUSBHost.modulemap'
        binary = out / 'usb-accessory-swift-checks'
        run('swift-build', ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library', '-sanitize=thread',
            '-Xlinker', '-fatal_warnings', '-I', str(products), '-Xcc', '-fmodule-map-file=' + str(modulemap),
            '-I', str(root / 'Sources/CSkyBridgeUSBHost/include'), *[str(f) for f in objects], '-framework', 'IOKit',
            '-framework', 'CoreFoundation', 'Tests/CSkyBridgeUSBHostTests/USBAccessoryPreparationChecks.swift', '-o', str(binary)])
        run('swift-run', [str(binary)])
        r['binarySha256'][binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    r['changedSources'] = [f for f, h in r['sourceSha256'].items() if hashlib.sha256((root / f).read_bytes()).hexdigest() != h]
    r['passed'] = not r['changedSources']
    if not r['passed']:
        raise SystemExit('Sources changed during the checks')
finally:
    (out / 'result.json').write_text(json.dumps(r, indent=2) + '\n')
print(json.dumps({'passed': r['passed'], 'physicalDeviceSelected': False}))
