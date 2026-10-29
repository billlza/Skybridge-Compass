#!/usr/bin/env python3
"""Assemble verified ALAC Apple slices and source/notices into a new staged candidate.

Each slice must have been produced by audio_alac_qualification/build_provider.py with the
current locked inputs. This command does not replace Vendor artifacts, sign an app, or release.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
FAMILY = 'alac'
LOCK = ROOT / 'Config/native-dependencies.lock.json'
SOURCE = ROOT / 'Sources/CSkyBridgeALAC'
RECIPES = ROOT / 'Scripts/audio_alac_qualification'


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError('cannot load build helper: ' + str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage_macos_framework(source, destination):
    """Package the qualified bytes using macOS's versioned framework layout.

    The thin qualification frameworks use a flat layout. That is valid for iOS,
    but Xcode rejects it when embedding a dynamic framework in a macOS app.
    Keep the public library path and all code bytes unchanged through symlinks.
    """
    version = destination / 'Versions/A'
    shutil.copytree(source, version)
    resources = version / 'Resources'
    resources.mkdir()
    (version / 'Info.plist').rename(resources / 'Info.plist')
    (destination / 'Versions/Current').symlink_to('A', target_is_directory=True)
    for name in ['CSkyBridgeALAC', 'Headers', 'Modules', 'Resources']:
        (destination / name).symlink_to('Versions/Current/' + name,
                                       target_is_directory=(version / name).is_dir())
    return destination


def build_inputs(provenance):
    """Exact recipe inputs used to prepare and check the named native-dependency lock family."""
    return {
        'source_lock_sha256': sha(SOURCE / 'source-lock.json'),
        'provider_recipe_sha256': sha(RECIPES / 'build_provider.py'),
        'framework_recipe_sha256': sha(RECIPES / 'apple_framework.py'),
        'bridge_sha256': sha(SOURCE / 'SkyBridgeALACDecoder.c'),
        'bridge_header_sha256': sha(SOURCE / 'include/SkyBridgeALACDecoder.h'),
        'architectures': 'macos-arm64,ios-arm64,ios-simulator-arm64,ios-simulator-x86_64',
        'macos_deployment_target': '14.0', 'ios_deployment_target': '17.0',
        'ios_sdk': provenance.run('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
        'ios_simulator_sdk': provenance.run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'),
        'linkage': 'dynamic-framework-with-private-codec-objects', 'codec': 'alac-only',
        'native_exports': 'six-sbalac-entry-points', 'werror': 'true', 'build_jobs': '1',
    }


def compare_release(checkout, archive, lock):
    if sha(archive) != lock['archiveSha256']:
        raise ValueError('release archive differs from the source lock')
    tracked = set(subprocess.run(['git', '-C', str(checkout), 'ls-files', '-z'],
                                 check=True, capture_output=True).stdout.decode().split('\0'))
    tracked.discard('')
    seen, compared, generated = set(), 0, []
    with tarfile.open(archive, 'r:xz') as contents:
        for member in contents.getmembers():
            if member.isdir():
                continue
            parts = Path(member.name).parts
            if not member.isfile() or not parts or parts[0] != 'ffmpeg-' + lock['version'] or \
                    '..' in parts or Path(member.name).is_absolute():
                raise ValueError('unsupported release archive member')
            relative = '/'.join(parts[1:])
            seen.add(relative)
            stream = contents.extractfile(member)
            if stream is None:
                raise ValueError('missing archive data: ' + relative)
            data = stream.read()
            if relative in tracked:
                if (checkout / relative).is_symlink() or (checkout / relative).read_bytes() != data:
                    raise ValueError('Git and signed release content differ: ' + relative)
                compared += 1
            elif relative == 'VERSION' and data == (lock['version'] + '\n').encode():
                generated.append(relative)
            else:
                raise ValueError('unreviewed release-only file: ' + relative)
    missing = sorted(tracked - seen)
    if compared != 10115 or any(Path(name).name not in {'.gitignore', '.gitattributes'} for name in missing):
        raise ValueError('release/Git inventory differs from the qualified 8.1.3 source')
    return {'comparedFiles': compared, 'gitOnly': missing, 'archiveOnlyGenerated': generated}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-checkout', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--signature', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--slice-receipt', action='append', required=True, help='profile=build-receipt-directory')
    parser.add_argument('--output', type=Path, required=True, help='New candidate directory; no live artifact replacement')
    args = parser.parse_args()
    provenance = load_module('native_vendor_provenance', ROOT / 'Scripts/native_vendor_provenance.py')
    apple = load_module('alac_apple_framework', RECIPES / 'apple_framework.py')
    family, _ = provenance.load_locked_family(LOCK, ROOT, FAMILY)
    source_lock = provenance.read_json_object(SOURCE / 'source-lock.json', 'ALAC source lock')
    inputs = build_inputs(provenance)
    source = source_lock['gitSource']
    checkout = args.source_checkout.resolve(strict=True)
    source_spec = '|'.join([source[k] for k in ['name', 'version', 'ref', 'commit', 'repository']] + [str(checkout)])
    actual_source = provenance.parse_source(source_spec)
    provenance.assert_matches_locked_family(FAMILY, [actual_source], inputs, provenance.toolchain_record(), family)
    if actual_source != source:
        raise ValueError('source lock and Git checkout differ')
    comparison = compare_release(checkout, args.archive, source_lock)
    if sha(args.signature) != source_lock['signatureSha256'] or sha(args.key) != source_lock['signingKeySha256']:
        raise ValueError('release signature/key differ from the source lock')
    receipts = {}
    for raw in args.slice_receipt:
        profile, separator, directory = raw.partition('=')
        if not separator or profile in receipts or profile not in apple.APPLE_SLICES:
            raise ValueError('unknown or duplicated SDK slice')
        receipts[profile] = Path(directory).resolve(strict=True)
    if set(receipts) != set(apple.APPLE_SLICES):
        raise ValueError('all four Apple SDK/architecture slices are required')
    contract_paths = [RECIPES / 'build_provider.py', RECIPES / 'apple_framework.py',
                      SOURCE / 'source-lock.json', SOURCE / 'SkyBridgeALACDecoder.c',
                      SOURCE / 'include/SkyBridgeALACDecoder.h']
    expected_hashes = {str(p.relative_to(ROOT)): sha(p) for p in contract_paths}
    unchanged_paths = contract_paths + [LOCK, Path(__file__).resolve(), ROOT / 'Scripts/native_vendor_provenance.py']
    before = {p: sha(p) for p in unchanged_paths}
    frameworks, slice_hashes = {}, {}
    for profile, directory in receipts.items():
        record = provenance.read_json_object(directory / 'receipt.json', 'SDK slice receipt')
        if record['status'] != 'built' or record['baseline'] or record['appleSlice'] != profile or \
                record['version'] != source_lock['version'] or record['providerContract'] != source_lock['providerContract'] or \
                record['archiveSha256'] != source_lock['archiveSha256'] or record['components'] != ['CONFIG_ALAC_DECODER'] or \
                record['framework']['profile'] != apple.APPLE_SLICES[profile]:
            raise ValueError('unqualified SDK slice receipt: ' + profile)
        if provenance.read_json_object(directory / 'source-input-hashes.json', 'slice inputs') != expected_hashes:
            raise ValueError('SDK slice was built from different source/recipe inputs: ' + profile)
        if (directory / 'sdk.log').read_text().strip() != provenance.run('xcrun', '--sdk', apple.APPLE_SLICES[profile]['sdk'], '--show-sdk-path'):
            raise ValueError('SDK selection changed since slice build: ' + profile)
        framework = Path(record['framework']['path']).resolve(strict=True)
        binary = framework / 'CSkyBridgeALAC'
        if sha(binary) != record['framework']['binarySha256'] or \
                sha(framework / 'Headers/SkyBridgeALACDecoder.h') != expected_hashes['Sources/CSkyBridgeALAC/include/SkyBridgeALACDecoder.h']:
            raise ValueError('SDK framework bytes changed: ' + profile)
        if provenance.native_binary_kind(binary) != 'dylib':
            raise ValueError('SDK framework is not a supported dynamic library')
        actual = provenance.dylib_metadata(binary, framework, recorded_path='CSkyBridgeALAC')
        expected = apple.APPLE_SLICES[profile]
        if actual['architectures'] != [expected['arch']] or actual['platforms'] != [expected['platform']] or \
                actual['deployment_targets'] != [expected['minimum']] or \
                set(actual['dependencies']) != {'@rpath/CSkyBridgeALAC.framework/CSkyBridgeALAC', '/usr/lib/libSystem.B.dylib'}:
            raise ValueError('SDK framework platform or dependencies differ: ' + profile)
        frameworks[profile] = framework
        slice_hashes[profile] = record['framework']['binarySha256']
    output = args.output.absolute()
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ValueError('candidate output must be new and its parent must exist')
    output.mkdir()
    logs = output / 'logs'; logs.mkdir()
    commands = []
    env = os.environ.copy()
    for key in ['SDKROOT', 'CPATH', 'LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH']:
        env.pop(key, None)

    def run(label, argv):
        command = [str(item) for item in argv]
        with (logs / (label + '.log')).open('wb') as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        commands.append({'label': label, 'argv': command, 'exitCode': result.returncode})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError('packaging step failed: ' + label)
        return (logs / (label + '.log')).read_text()

    gpg, gpgv = shutil.which('gpg'), shutil.which('gpgv')
    if not gpg or not gpgv:
        raise ValueError('GnuPG verification tools are required; nothing is installed automatically')
    key_home = output / 'signature-verification'; key_home.mkdir(mode=0o700)
    keyring = key_home / 'trustedkeys.gpg'
    run('keyring', [gpg, '--no-options', '--homedir', key_home, '--batch', '--dearmor', '--output', keyring, args.key.resolve()])
    signature_status = run('signature', [gpgv, '--homedir', key_home, '--keyring', keyring, '--status-fd', '1', args.signature.resolve(), args.archive.resolve()])
    if re.findall(r'^\[GNUPG:\] VALIDSIG ([A-F0-9]+) ', signature_status, re.M) != [source_lock['signingKeyFingerprint']]:
        raise ValueError('release signature did not verify against the pinned primary key')
    frameworks['macos-arm64'] = stage_macos_framework(frameworks['macos-arm64'],
        output / 'macos/CSkyBridgeALAC.framework')
    combined = output / 'combined/CSkyBridgeALAC.framework'
    shutil.copytree(frameworks['ios-simulator-arm64'], combined)
    for path in ['Headers/SkyBridgeALACDecoder.h', 'Modules/module.modulemap', 'Info.plist']:
        if (frameworks['ios-simulator-arm64'] / path).read_bytes() != (frameworks['ios-simulator-x86_64'] / path).read_bytes():
            raise ValueError('simulator framework declarations differ')
    run('simulator-lipo', ['/usr/bin/lipo', '-create', frameworks['ios-simulator-arm64'] / 'CSkyBridgeALAC',
        frameworks['ios-simulator-x86_64'] / 'CSkyBridgeALAC', '-output', combined / 'CSkyBridgeALAC'])
    candidate = output / 'candidate'; vendor = candidate / 'Sources/Vendor'; vendor.mkdir(parents=True)
    sdk = vendor / 'alac.xcframework'
    run('xcframework', ['/usr/bin/xcrun', 'xcodebuild', '-create-xcframework',
        '-framework', frameworks['macos-arm64'], '-framework', frameworks['ios-arm64'],
        '-framework', combined, '-output', sdk])
    libraries = plistlib.loads((sdk / 'Info.plist').read_bytes())['AvailableLibraries']
    if len(libraries) != 3:
        raise ValueError('XCFramework platform inventory differs')
    checked_slices = {}
    for library in libraries:
        binary = provenance.safe_repository_path(library['LibraryIdentifier'] + '/' + library['BinaryPath'], sdk, 'XCFramework binary')
        for architecture in library['SupportedArchitectures']:
            platform = library['SupportedPlatform']
            variant = library.get('SupportedPlatformVariant')
            if variant is not None:
                if variant != 'simulator':
                    raise ValueError('unsupported XCFramework platform variant')
                platform += '-simulator'
            profile = platform + '-' + architecture
            if profile not in slice_hashes or profile in checked_slices:
                raise ValueError('unexpected or duplicated final SDK slice')
            thin = binary
            if len(library['SupportedArchitectures']) > 1:
                thin = output / ('verified-' + profile)
                run('verify-' + profile, ['/usr/bin/lipo', binary, '-thin', architecture, '-output', thin])
            if sha(thin) != slice_hashes[profile] or sha(frameworks[profile] / 'CSkyBridgeALAC') != slice_hashes[profile]:
                raise ValueError('final SDK slice bytes differ from the qualified input: ' + profile)
            checked_slices[profile] = sha(thin)
    if checked_slices != slice_hashes:
        raise ValueError('final SDK omitted a qualified slice')
    licenses = vendor / 'NativeLicenses/alac'; licenses.mkdir(parents=True)
    with tarfile.open(args.archive, 'r:xz') as archive:
        for name, expected in source_lock['licenses'].items():
            stream = archive.extractfile('ffmpeg-' + source_lock['version'] + '/' + name)
            if stream is None:
                raise ValueError('missing license: ' + name)
            data = stream.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError('license differs: ' + name)
            (licenses / name).write_bytes(data)
    distribution = vendor / 'NativeSources/alac'; distribution.mkdir(parents=True)
    shutil.copy2(args.archive, distribution / args.archive.name)
    shutil.copy2(args.signature, distribution / args.signature.name)
    shutil.copy2(args.key, distribution / args.key.name)
    for original in contract_paths + [SOURCE / source_lock['patch']['path'], SOURCE / source_lock['buildPatch']['path']]:
        destination = distribution / original.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(original, destination)
    (licenses / 'NOTICE.txt').write_text('SkyBridge ALAC decoder uses FFmpeg 8.1.3 with the source-locked strict-error and build patches.\n'
        'Only ALAC decoding is enabled; GPL, nonfree and version-3 configurations are disabled.\n'
        'See COPYING.LGPLv2.1 and LICENSE.md. The exact upstream archive, patches, bridge sources and\n'
        'slice build scripts accompany this SDK under Sources/Vendor/NativeSources/alac.\n'
        'The framework is dynamically linked and exposes only the six sbalac C entry points.\n'
        'SDK qualification is not an application-release or output-device acceptance claim.\n')
    (distribution / 'source-comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
    for original in [LOCK, Path(__file__).resolve(), ROOT / 'Scripts/native_vendor_provenance.py']:
        destination = candidate / original.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(original, destination)
    record = provenance.create_record(argparse.Namespace(repository_root=str(ROOT), family=FAMILY,
        source=[source_spec], build_input=[key + '=' + value for key, value in inputs.items()], lock=str(LOCK),
        artifact_root=['xcframework|' + str(sdk) + '|Sources/Vendor/alac.xcframework',
                       'licenses|' + str(licenses) + '|Sources/Vendor/NativeLicenses/alac',
                       'source|' + str(distribution) + '|Sources/Vendor/NativeSources/alac'], recipe=str(Path(__file__).resolve())))
    record_path = vendor / 'alac.provenance.json'; provenance.write_atomic_json(record_path, record)
    provenance.verify_record(record_path, candidate, candidate / 'Config/native-dependencies.lock.json')
    if any(sha(path) != value for path, value in before.items()):
        raise ValueError('packaging inputs changed during assembly')
    receipt = {'status': 'staged_and_verified', 'candidate': str(candidate), 'sourceComparison': comparison,
               'macosFrameworkLayout': 'versioned',
               'qualifiedSliceHashes': checked_slices,
               'provenance': str(record_path), 'scope': 'Apple SDK package only; no product registration, application signing, publication or device acceptance'}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
