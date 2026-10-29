#!/usr/bin/env python3
"""Export generated ALAC files and exact packed integer references for repository tests.

Input is make_fixtures.py's verified receipt, not arbitrary user media. No decoder or output
device is opened here. The sample extremes are test data, not listening-test signals.
"""
import argparse
import hashlib
import json
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('fixture output must be new')
    receipt = json.loads((args.fixtures / 'receipt.json').read_text())
    expected = {f'{rate}-{channels}-s{bits}': (rate, channels, bits)
                for rate in [44100, 48000, 96000] for channels in [1, 2] for bits in [16, 20, 24, 32]}
    cases = receipt['cases']
    if len(cases) != len(expected) or {case['name'] for case in cases} != set(expected):
        raise ValueError('fixture matrix differs from the qualified 24-case profile')
    exported, files = [], {}
    for case in cases:
        name = case['name']
        rate, channels, bits = expected[name]  # Names come from the finite matrix, never an input path.
        frames = case['frames']
        if case['status'] != 'exact' or (case['rate'], case['channels'], case['validBits']) != expected[name] or \
                type(frames) is not int or not 0 < frames <= 100000:
            raise ValueError('unqualified fixture declarations: ' + name)
        encoded = (args.fixtures / 'fixtures' / (name + '.m4a')).read_bytes()
        reference = (args.fixtures / 'reference' / (name + '.s32le')).read_bytes()
        if not 0 < len(encoded) <= 4 * 1024 * 1024 or len(reference) != frames * channels * 4 or \
                digest(encoded) != case['encodedSha256'] or digest(reference) != case['referenceSha256'] or \
                case['decodedSha256'] != case['referenceSha256'] or case['decodedBytes'] != len(reference):
            raise ValueError('qualified source/reference bytes differ: ' + name)
        width = (bits + 7) // 8
        pcm = bytearray()
        for at in range(0, len(reference), 4):
            sample = int.from_bytes(reference[at:at + 4], 'little', signed=True)
            if sample & ((1 << (32 - bits)) - 1):
                raise ValueError('reference contains information below the declared precision: ' + name)
            pcm.extend(reference[at + 4 - width:at + 4])
        files[name + '.m4a'] = encoded
        files[name + '.pcm'] = pcm
        exported.append({'name': name, 'rate': rate, 'channels': channels, 'validBits': bits,
                         'frames': frames, 'encodedSha256': digest(encoded), 'pcmSha256': digest(pcm),
                         'fileBytes': len(encoded), 'pcmBytes': len(pcm)})
    args.output.mkdir(parents=True)
    for name, data in files.items():
        (args.output / name).write_bytes(data)
    manifest = {'schema': 'alac-decoder-v1',
                'scope': 'Generated integer-reference fixtures; no output-device acceptance', 'cases': exported}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'cases': len(exported), 'files': len(files) + 1,
                      'manifestSha256': digest((args.output / 'manifest.json').read_bytes())}))


if __name__ == '__main__':
    main()
