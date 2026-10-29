#!/usr/bin/env python3
"""Export independent packet-table expectations from the retained, hash-checked ALAC fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.evidence.exists():
        raise ValueError('use new output and evidence paths')
    args.evidence.mkdir(parents=True)
    commands, vectors = [], []
    version = subprocess.run([str(args.ffprobe), '-version'], capture_output=True, timeout=10, check=True)
    (args.evidence / 'ffprobe-version.txt').write_bytes(version.stdout + version.stderr)
    receipt = json.loads((args.fixtures / 'receipt.json').read_text())
    for case in receipt['cases']:
        name = case['name']
        if not re.fullmatch(r'\d+-[12]-s(?:16|20|24|32)', name) or case['status'] != 'exact':
            raise ValueError('fixture is not a qualified integer-reference case')
        source = args.fixtures / 'fixtures' / (name + '.m4a')
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != case['encodedSha256']:
            raise ValueError('fixture hash differs')
        argv = [str(args.ffprobe), '-v', 'warning', '-protocol_whitelist', 'file', '-f', 'mov',
                '-select_streams', 'a', '-show_entries', 'stream=codec_name,time_base:packet=pos,size,duration',
                '-of', 'json', str(source.resolve())]
        process = subprocess.run(argv, capture_output=True, timeout=30)
        (args.evidence / (name + '.json')).write_bytes(process.stdout)
        (args.evidence / (name + '.stderr')).write_bytes(process.stderr)
        commands.append({'argv': argv, 'exitCode': process.returncode})
        (args.evidence / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if process.returncode or process.stderr:
            raise RuntimeError('packet reference probe failed or reported a diagnostic: ' + name)
        result = json.loads(process.stdout)
        if result['streams'] != [{'codec_name': 'alac', 'time_base': '1/' + str(case['rate'])}]:
            raise ValueError('unexpected reference stream declaration')
        first_frame, packets = 0, []
        for index, packet in enumerate(result['packets']):
            offset, length, frames = int(packet['pos']), int(packet['size']), int(packet['duration'])
            if offset < 0 or not 0 < length <= len(data) - offset or not 0 < frames <= 65536:
                raise ValueError('reference packet outside expected bounds')
            packets.append({'index': index, 'offset': offset, 'length': length,
                            'firstFrameIndex': first_frame, 'frames': frames})
            first_frame += frames
        if first_frame != case['frames'] or source.read_bytes() != data:
            raise ValueError('reference totals or source identity differ')
        vectors.append({'name': name, 'sourceSha256': case['encodedSha256'], 'packets': packets})
    args.output.write_text(json.dumps({'schema': 'alac-packet-index-v1',
        'scope': 'Independent packet offsets/sizes/durations for valid fixtures; not a decoder or playback witness',
        'vectors': vectors}, indent=2) + '\n')
    print(json.dumps({'vectors': len(vectors), 'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
