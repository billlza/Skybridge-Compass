#!/usr/bin/env python3
"""Source-locked ALAC-only provider builds; no global install or application edit.

All inputs are offline files. The lock pins the official archive, detached signature, signing
key, build patch, decoder patch and licenses. --baseline omits only the decoder changes.
Default output is the existing macOS arm64 shared-library comparator. --apple-slice builds
static codec objects and the narrow dynamic C framework for one explicit Apple SDK/architecture.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import tarfile

from apple_framework import APPLE_SLICES, build_framework

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/CSkyBridgeALAC'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked(path, digest):
    if sha(path) != digest:
        raise ValueError(f'source hash differs: {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--signature', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--apple-slice', choices=sorted(APPLE_SLICES))
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('this build recipe requires a macOS arm64 host')
    if args.apple_slice and args.baseline:
        raise ValueError('Apple SDK frameworks require the qualified strict-error provider')
    work = args.work_dir.resolve()
    if any(c.isspace() for c in str(work)):
        raise ValueError('FFmpeg make requires a work directory without spaces')
    evidence = args.evidence.resolve()
    lock = json.loads((SOURCE / 'source-lock.json').read_text())
    contract_paths = [Path(__file__).resolve(), Path(__file__).with_name('apple_framework.py'),
                      SOURCE / 'source-lock.json', SOURCE / 'SkyBridgeALACDecoder.c',
                      SOURCE / 'include/SkyBridgeALACDecoder.h']
    contract_hashes = {path: sha(path) for path in contract_paths}
    for path, key in [(args.archive, 'archiveSha256'), (args.signature, 'signatureSha256'),
                      (args.key, 'signingKeySha256')]:
        checked(path, lock[key])
    for patch in [lock['buildPatch'], lock['patch']]:
        checked(SOURCE / patch['path'], patch['sha256'])
    # Refuse existing work/evidence paths; no cleanup or replacement of another run.
    if work.exists() or evidence.exists():
        raise ValueError('work and evidence directories must both be new')
    work.mkdir(parents=True)
    evidence.mkdir(parents=True)
    (evidence / 'source-lock.json').write_bytes((SOURCE / 'source-lock.json').read_bytes())
    (evidence / 'build_provider.py').write_bytes(Path(__file__).read_bytes())
    env = os.environ.copy()
    isolated_variables = ['CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'LDFLAGS', 'PKG_CONFIG_PATH', 'SDKROOT',
                          'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                          'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH',
                          'DYLD_FALLBACK_LIBRARY_PATH', 'MAKEFLAGS', 'CC', 'CXX', 'LD', 'AR',
                          'AS', 'NM', 'RANLIB', 'STRIP']
    removed_names = [key for key in isolated_variables if key in env]
    for key in isolated_variables:
        env.pop(key, None)
    (work / 'empty-pkgconfig').mkdir()
    env['PKG_CONFIG_LIBDIR'] = str(work / 'empty-pkgconfig')
    env['SOURCE_DATE_EPOCH'] = '1789951930'
    commands = []

    def run(label, argv, cwd=work, timeout=60):
        print(label, flush=True)
        record = {'label': label, 'argv': [str(x) for x in argv], 'cwd': str(cwd),
                  'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        commands.append(record)
        with (evidence / (label + '.log')).open('wb') as output:
            proc = subprocess.Popen(record['argv'], cwd=cwd, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = proc.pid
            (evidence / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record['timedOut'] = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    code = proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    code = proc.wait(timeout=10)
        record['exitCode'] = code
        record['endedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (evidence / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if code or record.get('timedOut'):
            raise RuntimeError(f'{label} failed; retained log: {evidence / (label + ".log")}')
        return (evidence / (label + '.log')).read_text()

    gpg = shutil.which('gpg')
    gpgv = shutil.which('gpgv')
    if not gpg or not gpgv:
        raise RuntimeError('GnuPG verification tools are required; nothing is installed automatically')
    key_home = work / 'key-verification'
    key_home.mkdir(mode=0o700)
    keyring = key_home / 'trustedkeys.gpg'
    run('keyring', [gpg, '--no-options', '--homedir', key_home, '--batch', '--dearmor',
                    '--output', keyring, args.key.resolve()])
    status = run('signature', [gpgv, '--homedir', key_home, '--keyring', keyring,
                              '--status-fd', '1', args.signature.resolve(), args.archive.resolve()])
    fingerprints = re.findall(r'^\[GNUPG:\] VALIDSIG ([A-F0-9]+) ', status, re.M)
    if fingerprints != [lock['signingKeyFingerprint']]:
        raise ValueError('signature did not match the pinned release signing key')
    prefix = 'ffmpeg-' + lock['version']
    with tarfile.open(args.archive, 'r:xz') as archive:
        members = archive.getmembers()
        if len(members) > 50000 or sum(member.size for member in members) > 300000000:
            raise ValueError('archive exceeds extraction bounds')
        for member in members:
            parts = Path(member.name).parts
            if not parts or parts[0] != prefix or '..' in parts or Path(member.name).is_absolute() or \
                    not (member.isdir() or member.isfile()) or member.size > 20000000 or member.mode & 0o7000:
                raise ValueError('archive contains an unsupported entry')
    run('extract', ['/usr/bin/tar', '-xf', args.archive.resolve(), '-C', work])
    source = work / prefix
    for name, digest in lock['licenses'].items():
        checked(source / name, digest)
    for label, patch in [('build-patch', lock['buildPatch'])] + ([] if args.baseline else [('decoder-patch', lock['patch'])]):
        for item in patch['files']:
            checked(source / item['path'], item['originalSha256'])
        run(label, ['/usr/bin/patch', '--batch', '-p1', '-i', SOURCE / patch['path']], cwd=source)
        for item in patch['files']:
            checked(source / item['path'], item['patchedSha256'])
        shutil.copy2(SOURCE / patch['path'], evidence / patch['path'])
    host_sdk = run('host-sdk', ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    profile = APPLE_SLICES[args.apple_slice] if args.apple_slice else APPLE_SLICES['macos-arm64']
    sdk = run('sdk', ['/usr/bin/xcrun', '--sdk', profile['sdk'], '--show-sdk-path']).strip()
    compiler = run('compiler-path', ['/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'clang']).strip()
    run('compiler-version', [compiler, '--version'])
    if any(c.isspace() for c in sdk):
        raise ValueError('this make recipe requires an SDK path without spaces')
    target_flags = f"-target {profile['target']} -isysroot {sdk}"
    host_flags = f'-arch arm64 -isysroot {host_sdk} -mmacosx-version-min=14.0'
    objects = work / 'objects'
    objects.mkdir()
    install = work / 'install'
    flags = [f'--prefix={install}', '--disable-everything', '--disable-autodetect', '--disable-programs',
             '--disable-doc', '--disable-avformat', '--disable-avdevice', '--disable-avfilter',
             '--disable-swscale', '--disable-swresample', '--disable-network', '--disable-gpl',
             '--disable-nonfree', '--disable-version3', '--enable-decoder=alac',
             '--enable-static' if args.apple_slice else '--enable-shared',
             '--disable-shared' if args.apple_slice else '--disable-static',
             '--disable-asm', '--enable-pic', '--disable-debug', '--optflags=-O2',
             '--install-name-dir=@rpath', '--arch=' + profile['configure_arch'], '--target-os=darwin', f'--cc={compiler}',
             f'--host-cc={compiler}',
             f'--host-cflags=-Werror {host_flags}',
             f'--host-ldflags=-Wl,-fatal_warnings {host_flags}',
             f'--extra-cflags=-Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 -ffile-prefix-map={work}=skybridge-alac-build {target_flags}',
             f'--extra-ldflags=-Wl,-fatal_warnings {target_flags}']
    if profile['platform'] != 'macos' or profile['arch'] != 'arm64':
        flags.append('--enable-cross-compile')
    run('configure', ['/bin/sh', source / 'configure'] + flags, cwd=objects, timeout=240)
    run('build', ['/usr/bin/make', '-j1'], cwd=objects, timeout=600)
    run('install', ['/usr/bin/make', '-j1', 'install'], cwd=objects, timeout=120)
    config = (objects / 'config.h').read_text() + (objects / 'config_components.h').read_text()
    components = re.findall(r'^#define (CONFIG_\w+_(?:DECODER|ENCODER|DEMUXER|MUXER|PROTOCOL|FILTER|PARSER|BSF|INDEV|OUTDEV|HWACCEL)) 1$', config, re.M)
    if components != ['CONFIG_ALAC_DECODER']:
        raise ValueError('unexpected provider components: ' + repr(components))
    for name in ['NETWORK', 'GPL', 'NONFREE', 'VERSION3', 'AVFORMAT', 'AVDEVICE', 'AVFILTER', 'SWRESAMPLE', 'SWSCALE']:
        if not re.search(r'^#define CONFIG_' + name + r' 0$', config, re.M):
            raise ValueError('disabled component was not confirmed: ' + name)
    libraries = []
    framework = None
    if args.apple_slice:
        archives = sorted((install / 'lib').glob('*.a'))
        if [path.name for path in archives] != ['libavcodec.a', 'libavutil.a']:
            raise ValueError('expected avcodec and avutil archives only')
        for library in archives:
            architectures = run(library.name + '-architecture', ['/usr/bin/lipo', '-archs', library]).strip()
            if architectures != profile['arch']:
                raise ValueError('unexpected archive architecture: ' + architectures)
            libraries.append({'path': str(library), 'sha256': sha(library), 'architectures': [architectures]})
        framework = build_framework(SOURCE, install, work, evidence, compiler, sdk, profile, run)
    for library in ([] if args.apple_slice else sorted({path.resolve() for path in (install / 'lib').glob('*.dylib')})):
        loads = run(library.name + '-loads', ['/usr/bin/otool', '-L', library])
        dependencies = [line.strip().split(' (compatibility version', 1)[0] for line in loads.splitlines()[1:]]
        allowed = {'@rpath/libavcodec.62.dylib', '@rpath/libavutil.60.dylib', '/usr/lib/libSystem.B.dylib'}
        if set(dependencies) - allowed:
            raise ValueError('unreviewed dynamic dependency: ' + repr(dependencies))
        architectures = run(library.name + '-architecture', ['/usr/bin/lipo', '-archs', library]).strip()
        if architectures != 'arm64':
            raise ValueError('unexpected architecture: ' + architectures)
        libraries.append({'path': str(library), 'sha256': sha(library), 'dependencies': dependencies})
    if len(libraries) != 2:
        raise ValueError('expected avcodec and avutil libraries only')
    license_dir = install / 'share/licenses/skybridge-alac'
    license_dir.mkdir(parents=True)
    for name in lock['licenses']:
        shutil.copy2(source / name, license_dir / name)
    for name in ['config.h', 'config_components.h']:
        shutil.copy2(objects / name, evidence / name)
    shutil.copy2(objects / 'ffbuild/config.mak', evidence / 'config.mak')
    if any(sha(path) != value for path, value in contract_hashes.items()):
        raise ValueError('build recipe or C boundary changed during the build')
    (evidence / 'source-input-hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)): h for p, h in contract_hashes.items()}, indent=2) + '\n')
    receipt = {'status': 'built', 'scope': 'Apple SDK slice only; no device acceptance' if args.apple_slice else 'macOS arm64 provider only; no product or device acceptance',
               'baseline': args.baseline, 'providerContract': 0 if args.baseline else lock['providerContract'],
               'version': lock['version'], 'archiveSha256': lock['archiveSha256'], 'source': str(source),
               'removedEnvironmentOverrides': removed_names,
               'install': str(install), 'components': components, 'libraries': libraries,
               'appleSlice': args.apple_slice, 'framework': framework}
    (evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt), flush=True)


if __name__ == '__main__':
    main()
