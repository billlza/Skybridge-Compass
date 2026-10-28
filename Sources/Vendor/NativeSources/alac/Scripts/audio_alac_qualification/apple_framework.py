"""Narrow C ABI framework assembly for the source-locked Apple ALAC provider recipe."""
import hashlib
import plistlib
import re
import shutil

APPLE_SLICES = {
    'macos-arm64': {'sdk': 'macosx', 'arch': 'arm64', 'configure_arch': 'aarch64',
                    'target': 'arm64-apple-macos14.0', 'platform': 'macos', 'platform_id': '1',
                    'minimum': '14.0', 'supported_platform': 'MacOSX'},
    'ios-arm64': {'sdk': 'iphoneos', 'arch': 'arm64', 'configure_arch': 'aarch64',
                  'target': 'arm64-apple-ios17.0', 'platform': 'ios', 'platform_id': '2',
                  'minimum': '17.0', 'supported_platform': 'iPhoneOS'},
    'ios-simulator-arm64': {'sdk': 'iphonesimulator', 'arch': 'arm64', 'configure_arch': 'aarch64',
                            'target': 'arm64-apple-ios17.0-simulator', 'platform': 'ios-simulator',
                            'platform_id': '7', 'minimum': '17.0', 'supported_platform': 'iPhoneSimulator'},
    'ios-simulator-x86_64': {'sdk': 'iphonesimulator', 'arch': 'x86_64', 'configure_arch': 'x86_64',
                             'target': 'x86_64-apple-ios17.0-simulator', 'platform': 'ios-simulator',
                             'platform_id': '7', 'minimum': '17.0', 'supported_platform': 'iPhoneSimulator'},
}


def build_framework(source, install, work, evidence, compiler, sdk, profile, run):
    name = 'CSkyBridgeALAC'
    framework = work / 'framework' / (name + '.framework')
    (framework / 'Headers').mkdir(parents=True)
    (framework / 'Modules').mkdir()
    header = source / 'include/SkyBridgeALACDecoder.h'
    shutil.copy2(header, framework / 'Headers' / header.name)
    (framework / 'Modules/module.modulemap').write_text('framework module CSkyBridgeALAC {\n'
        '    umbrella header "SkyBridgeALACDecoder.h"\n    export *\n    module * { export * }\n}\n')
    info = {'CFBundleIdentifier': 'com.skybridge.native.alac', 'CFBundleExecutable': name,
            'CFBundleName': name, 'CFBundlePackageType': 'FMWK', 'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1',
            'CFBundleSupportedPlatforms': [profile['supported_platform']]}
    info['LSMinimumSystemVersion' if profile['platform'] == 'macos' else 'MinimumOSVersion'] = profile['minimum']
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    exports = sorted(set(re.findall(r'\b(sbalac_\w+)\(', header.read_text())))
    if len(exports) != 6:
        raise ValueError('C ABI inventory differs from the reviewed six entry points')
    export_list = work / 'framework-exports.txt'
    export_list.write_text(''.join('_' + symbol + '\n' for symbol in exports))
    binary = framework / name
    install_name = '@rpath/' + name + '.framework/' + name
    run('framework-link', [compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-Wpedantic',
        '-O2', '-fstack-protector-strong', '-D_FORTIFY_SOURCE=2', '-target', profile['target'],
        '-ffile-prefix-map=' + str(source) + '=skybridge/Sources/CSkyBridgeALAC',
        '-ffile-prefix-map=' + str(work) + '=skybridge-alac-build',
        '-isysroot', sdk, '-dynamiclib', '-Wl,-fatal_warnings', '-Wl,-dead_strip',
        '-Wl,-exported_symbols_list,' + str(export_list), '-Wl,-install_name,' + install_name,
        '-Wl,-compatibility_version,1.0', '-Wl,-current_version,1.0', '-I', source / 'include',
        '-I', install / 'include', source / 'SkyBridgeALACDecoder.c',
        install / 'lib/libavcodec.a', install / 'lib/libavutil.a', '-o', binary], timeout=120)
    symbols = run('framework-exports', ['/usr/bin/nm', '-gU', binary])
    actual_exports = sorted(line.split()[-1] for line in symbols.splitlines() if line.strip())
    if actual_exports != ['_' + symbol for symbol in exports]:
        raise ValueError('framework exports symbols outside its C ABI: ' + repr(actual_exports))
    loads = run('framework-loads', ['/usr/bin/otool', '-L', binary])
    dependencies = [line.strip().split(' (compatibility version', 1)[0] for line in loads.splitlines()[1:]]
    if set(dependencies) != {install_name, '/usr/lib/libSystem.B.dylib'}:
        raise ValueError('unreviewed framework dynamic dependencies: ' + repr(dependencies))
    if run('framework-architecture', ['/usr/bin/lipo', '-archs', binary]).strip() != profile['arch']:
        raise ValueError('framework architecture differs')
    load_commands = run('framework-platform', ['/usr/bin/otool', '-l', binary])
    platforms = re.findall(r'^\s*platform\s+(\S+)\s*$', load_commands, re.M)
    minima = re.findall(r'^\s*minos\s+(\S+)\s*$', load_commands, re.M)
    if platforms != [profile['platform_id']] or minima != [profile['minimum']]:
        raise ValueError('framework platform/deployment differs: ' + repr((platforms, minima)))
    return {'path': str(framework), 'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'exports': exports, 'dependencies': dependencies, 'profile': profile}
