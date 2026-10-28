#!/usr/bin/env python3
"""Freeze the C boundary, verify provider artifacts, and run matched native comparisons."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.flags.optimize:
        raise RuntimeError('qualification requires assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-build', type=Path, required=True)
    parser.add_argument('--strict-build', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    snapshot = out / 'source'
    snapshot.mkdir()
    (snapshot / 'include').mkdir()
    files = {f'Sources/CSkyBridgeALAC/{name}': name for name in [
        'SkyBridgeALACDecoder.c', 'include/SkyBridgeALACDecoder.h', 'source-lock.json',
        'ffmpeg-strict-errors.patch', 'ffmpeg-build-probes.patch']}
    files.update({f'Scripts/audio_alac_qualification/{name}': name for name in [
        'RawPacketProbe.c', 'check_bridge.py', 'packet_fixtures.py', 'build_provider.py', 'qualify_bridge.py']})
    hashes = {}
    for name, destination in files.items():
        shutil.copy2(ROOT / name, snapshot / destination)
        hashes[name] = sha(ROOT / name)
    lock = json.loads((snapshot / 'source-lock.json').read_text())
    providers, provider_libraries = {}, {}
    for name, build in [('baseline', args.baseline_build), ('strict', args.strict_build)]:
        receipt = json.loads((build / 'receipt.json').read_text())
        assert receipt['status'] == 'built' and receipt['version'] == lock['version']
        assert receipt['archiveSha256'] == lock['archiveSha256']
        assert receipt['components'] == ['CONFIG_ALAC_DECODER']
        assert receipt['baseline'] == (name == 'baseline')
        assert receipt['providerContract'] == (0 if name == 'baseline' else lock['providerContract'])
        assert 'removedEnvironmentOverrides' in receipt, 'use the isolated build recipe'
        sdk = Path(receipt['install'])
        providers[name] = sdk
        provider_libraries[name] = receipt['libraries']
        for library in receipt['libraries']:
            assert sha(Path(library['path'])) == library['sha256']
        header = next(item for item in lock['patch']['files'] if item['path'] == 'libavcodec/avcodec.h')
        assert sha(sdk / 'include/libavcodec/avcodec.h') == header['originalSha256' if name == 'baseline' else 'patchedSha256']
    env = os.environ.copy()
    # The qualification processes also need isolation, including dynamic loader overrides.
    variables = ['CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'LDFLAGS', 'PKG_CONFIG_PATH', 'SDKROOT',
                 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                 'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH',
                 'DYLD_FALLBACK_LIBRARY_PATH', 'MAKEFLAGS', 'CC', 'CXX', 'LD', 'AR',
                 'AS', 'NM', 'RANLIB', 'STRIP', 'PYTHONOPTIMIZE']
    removed = [name for name in variables if name in env]
    for name in variables:
        env.pop(name, None)
    commands = []

    def run(label, command, expected=0):
        argv = [str(value) for value in command]
        record = {'label': label, 'argv': argv, 'expectedExitCode': expected,
                  'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        commands.append(record)
        log = out / (label + '.log')
        with log.open('wb') as output:
            process = subprocess.Popen(argv, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = process.pid
            (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
            try:
                code = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                record['timedOut'] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    code = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    code = process.wait(timeout=10)
        record['exitCode'] = code
        (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        assert code == expected and not record.get('timedOut'), (label, code, str(log))
        return log.read_text()

    common = ['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', '-std=c17', '-Wall', '-Wextra',
              '-Werror', '-O2', '-arch', 'arm64', '-mmacosx-version-min=14.0']
    for name, sdk in providers.items():
        links = ['-L' + str(sdk / 'lib'), '-lavcodec', '-lavutil', '-Wl,-fatal_warnings',
                 '-Wl,-rpath,' + str(sdk / 'lib')]
        prefix = common + ['-I' + str(sdk / 'include')]
        run(name + '-raw-build', prefix + [snapshot / 'RawPacketProbe.c'] + links + ['-o', out / (name + '-raw-probe')])
        command = prefix + ['-dynamiclib', '-I' + str(snapshot / 'include'), snapshot / 'SkyBridgeALACDecoder.c'] + \
            links + ['-Wl,-install_name,@rpath/libSkyBridgeALAC.dylib', '-o', out / (name + '-bridge.dylib')]
        text = run(name + '-bridge-build', command, 1 if name == 'baseline' else 0)
        assert 'warning:' not in text
        if name == 'baseline':
            assert 'avcodec_alac_strict_errors_version' in text and 'Undefined symbols' in text
    sys.path.insert(0, str(snapshot))
    from packet_fixtures import configuration, packets
    (out / 'configuration.bin').write_bytes(configuration())
    observations = []
    for name, (packet, reference) in packets().items():
        path = out / (name + '.alacpacket')
        path.write_bytes(packet)
        for variant in providers:
            accepts = reference is not None or (variant == 'baseline' and name in [
                'invalid-zero-run-overflow', 'invalid-data-after-end'])
            text = run(variant + '-' + name, [out / (variant + '-raw-probe'), out / 'configuration.bin', path],
                       0 if accepts else 1)
            data = json.loads(next(line for line in text.splitlines() if line.startswith('{')))
            assert data['frameAccepted'] == accepts
            data.update(provider=variant, name=name, expectedValid=reference is not None)
            observations.append(data)
    run('bridge-contract', [sys.executable, snapshot / 'check_bridge.py', '--library', out / 'strict-bridge.dylib',
                           '--fixtures', args.fixtures.resolve(), '--evidence', out / 'contract'])
    contract = json.loads((out / 'contract/receipt.json').read_text())
    assert contract['status'] == 'passed'
    run('native-analysis', common + ['--analyze', '-I' + str(snapshot / 'include'),
        '-I' + str(providers['strict'] / 'include'), '-Xanalyzer', '-analyzer-output=plist',
        '-o', out / 'native-analysis.plist', snapshot / 'SkyBridgeALACDecoder.c'])
    diagnostics = plistlib.loads((out / 'native-analysis.plist').read_bytes())['diagnostics']
    assert not diagnostics
    assert all(sha(ROOT / name) == digest for name, digest in hashes.items())
    for libraries in provider_libraries.values():
        assert all(sha(Path(library['path'])) == library['sha256'] for library in libraries)
    result = {'scope': 'isolated macOS arm64 provider and C ABI; product and physical playback not accepted',
              'status': 'passed', 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'contractCases': len(contract['cases']), 'unmodifiedDecoderCounterexamples': 2,
              'stockProviderLinkRejected': True, 'staticAnalyzerDiagnostics': len(diagnostics),
              'removedEnvironmentOverrides': removed, 'providerLibraries': provider_libraries,
              'sourceHashes': hashes, 'sourceUnchanged': True, 'bridgeSha256': sha(out / 'strict-bridge.dylib'),
              'rawPacketObservations': observations}
    (out / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['status', 'contractCases', 'stockProviderLinkRejected',
                                                 'staticAnalyzerDiagnostics', 'sourceUnchanged']}))


if __name__ == '__main__':
    main()
