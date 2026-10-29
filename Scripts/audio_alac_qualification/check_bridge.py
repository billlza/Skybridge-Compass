#!/usr/bin/env python3
"""Exercise the isolated C ABI with committed fixtures and packet/lifetime counterexamples.

The tiny ISO-BMFF extractor below is only for hash-locked, locally generated test fixtures.
It is not a product parser or validation path. No output device or app is used.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
from packet_fixtures import configuration, packets

READY, FRAME, COMPLETE = 0, 1, 2
INVALID_ARGUMENT, INVALID_SOURCE, CANCELLED, CODEC_ERROR = 100, 103, 104, 105
FRAME_COUNT_MISMATCH, SEQUENCE_ERROR = 108, 111
Byte = C.c_uint8
Cancelled = C.CFUNCTYPE(C.c_int, C.c_void_p)


class Source(C.Structure):
    _fields_ = [('configuration', Byte * 24), ('total_frames', C.c_uint64), ('packet_count', C.c_uint64)]


class Control(C.Structure):
    _fields_ = [('context', C.c_void_p), ('is_cancelled', Cancelled)]


class Result(C.Structure):
    _fields_ = [('status', C.c_int), ('codec_error', C.c_int32), ('packet_index', C.c_uint64),
                ('first_frame_index', C.c_uint64), ('frame_count', C.c_uint32), ('byte_count', C.c_size_t),
                ('decoded_frames', C.c_uint64), ('decoded_packets', C.c_uint64)]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixture_packets(data):
    def u32(at):
        return struct.unpack_from('>I', data, at)[0]

    def atoms(start, end):
        while start < end:
            size, kind = struct.unpack_from('>I4s', data, start)
            assert size >= 8 and start + size <= end
            yield kind, start, start + size
            start += size
        assert start == end

    start, end = 0, len(data)
    for kind in [b'moov', b'trak', b'mdia', b'minf', b'stbl']:
        found = [(a, b) for k, a, b in atoms(start, end) if k == kind]
        assert len(found) == 1
        start, end = found[0][0] + 8, found[0][1]
    table = {kind: (a + 8, b) for kind, a, b in atoms(start, end)}
    stsd = table[b'stsd'][0]
    assert u32(stsd + 4) == 1
    entry = stsd + 8
    assert data[entry + 4:entry + 8] == b'alac' and data[entry + 16:entry + 18] == bytes(2)
    cookies = [(a, b) for kind, a, b in atoms(entry + 36, entry + u32(entry)) if kind == b'alac']
    assert len(cookies) == 1 and cookies[0][1] - cookies[0][0] == 36
    cookie = data[cookies[0][0] + 12:cookies[0][1]]
    stts = table[b'stts'][0]
    durations = []
    for index in range(u32(stts + 4)):
        count, duration = struct.unpack_from('>II', data, stts + 8 + index * 8)
        durations.extend([duration] * count)
    stsz = table[b'stsz'][0]
    default, count = struct.unpack_from('>II', data, stsz + 4)
    sizes = [default] * count if default else [u32(stsz + 12 + index * 4) for index in range(count)]
    stco = table[b'stco'][0]
    offsets = [u32(stco + 8 + index * 4) for index in range(u32(stco + 4))]
    stsc = table[b'stsc'][0]
    mappings = [struct.unpack_from('>III', data, stsc + 8 + index * 12) for index in range(u32(stsc + 4))]
    result, index = [], 0
    for chunk, offset in enumerate(offsets, 1):
        mapping = [row for row in mappings if row[0] <= chunk][-1]
        assert mapping[2] == 1
        for _ in range(mapping[1]):
            size = sizes[index]
            assert offset + size <= len(data)
            result.append((data[offset:offset + size], durations[index]))
            index += 1
            offset += size
    assert index == len(sizes) == len(durations)
    return cookie, result


def main():
    if sys.flags.optimize:
        raise RuntimeError('qualification requires assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    lib = C.CDLL(str(args.library.resolve()))
    lib.sbalac_decoder_create.argtypes = [C.POINTER(Source), C.POINTER(C.c_void_p), C.POINTER(Result)]
    lib.sbalac_decoder_create.restype = C.c_int
    lib.sbalac_decoder_decode.argtypes = [C.c_void_p, C.POINTER(Control), C.c_uint64, C.c_uint64,
                                         C.POINTER(Byte), C.c_size_t, C.c_uint32,
                                         C.POINTER(Byte), C.c_size_t, C.POINTER(Result)]
    lib.sbalac_decoder_decode.restype = C.c_int
    lib.sbalac_decoder_finish.argtypes = [C.c_void_p, C.POINTER(Control), C.POINTER(Result)]
    lib.sbalac_decoder_finish.restype = C.c_int
    lib.sbalac_decoder_destroy.argtypes = [C.c_void_p]
    lib.sbalac_decoder_destroy.restype = None
    lib.sbalac_linked_version.restype = C.c_char_p
    lib.sbalac_provider_contract_version.restype = C.c_uint
    assert lib.sbalac_linked_version() == b'8.1.3'
    assert lib.sbalac_provider_contract_version() == 1
    rows = []
    receipt = {'scope': 'isolated macOS C ABI; no product, platform SDK, or playback acceptance',
               'librarySha256': digest(args.library.read_bytes()), 'cases': rows, 'status': 'running'}

    class Decoder:
        def __init__(self, cookie, frames, count, cancel_at=None):
            self.pointer = C.c_void_p()
            self.calls = 0
            self.cancel_at = cancel_at
            self.callback = Cancelled(self.cancel)
            self.control = Control(None, self.callback)
            self.description = Source((Byte * 24).from_buffer_copy(cookie), frames, count)
            result = Result()
            status = lib.sbalac_decoder_create(C.byref(self.description), C.byref(self.pointer), C.byref(result))
            assert status == result.status == READY and result.codec_error == 0, (status, result.codec_error)

        def cancel(self, _):
            self.calls += 1
            return int(self.cancel_at is not None and self.calls >= self.cancel_at)

        def decode(self, data, frames, packet_index=0, first_frame=0, capacity=None, control=True):
            width = (self.description.configuration[5] + 7) // 8
            if capacity is None:
                capacity = frames * width * self.description.configuration[9]
            output = (Byte * (capacity + 16))(*([0xA5] * (capacity + 16)))
            packet = (Byte * len(data)).from_buffer_copy(data)
            result = Result()
            status = lib.sbalac_decoder_decode(self.pointer, C.byref(self.control) if control else None,
                packet_index, first_frame, packet, len(data), frames, output, capacity, C.byref(result))
            assert result.status == status
            assert bytes(output[capacity:]) == bytes([0xA5] * 16), 'output canary changed'
            if status != FRAME:
                assert result.byte_count == result.frame_count == 0
            return status, bytes(output[:result.byte_count]), result

        def finish(self):
            result = Result()
            status = lib.sbalac_decoder_finish(self.pointer, C.byref(self.control), C.byref(result))
            assert result.status == status and result.byte_count == result.frame_count == 0
            return status, result

        def close(self):
            lib.sbalac_decoder_destroy(self.pointer)
            self.pointer = C.c_void_p()

    def rejected(name, operation, expected_status, frames=8, count=1, cancel_at=None,
                 cookie=None, committed_frames=0):
        decoder = Decoder(cookie if cookie is not None else configuration(), frames, count, cancel_at)
        try:
            observed = operation(decoder)
            assert observed == expected_status, (name, observed, expected_status)
            # Every terminal failure remains sticky; it cannot subsequently report completion.
            assert decoder.finish()[0] == expected_status
            status, _, result = decoder.decode(packets()['valid-uncompressed'][0], 8)
            assert status == expected_status
            assert result.decoded_frames == committed_frames
            if expected_status == CODEC_ERROR:
                assert result.codec_error < 0
            rows.append({'name': name, 'status': 'passed', 'rejection': observed,
                         'decodedFrames': result.decoded_frames, 'callbackCount': decoder.calls})
        finally:
            decoder.close()

    try:
        fixture_receipt = json.loads((args.fixtures / 'receipt.json').read_text())
        for case in fixture_receipt['cases']:
            name = case['name']
            encoded = (args.fixtures / 'fixtures' / (name + '.m4a')).read_bytes()
            reference = (args.fixtures / 'reference' / (name + '.s32le')).read_bytes()
            assert digest(encoded) == case['encodedSha256']
            assert digest(reference) == case['referenceSha256']
            cookie, indexed_packets = fixture_packets(encoded)
            assert sum(duration for _, duration in indexed_packets) == case['frames']
            decoder = Decoder(cookie, case['frames'], len(indexed_packets))
            try:
                decoded = bytearray()
                cursor = 0
                for index, (packet, duration) in enumerate(indexed_packets):
                    status, output, result = decoder.decode(packet, duration, index, cursor)
                    assert status == FRAME, (name, index, status, result.codec_error)
                    assert result.packet_index == index and result.first_frame_index == cursor
                    assert result.frame_count == duration and result.decoded_packets == index + 1
                    cursor += duration
                    assert result.decoded_frames == cursor
                    decoded.extend(output)
                assert decoder.finish()[0] == COMPLETE
                assert decoder.finish()[0] == COMPLETE
                width = (case['validBits'] + 7) // 8
                expected = b''.join(reference[i + 4 - width:i + 4] for i in range(0, len(reference), 4))
                assert decoded == expected, name
                rows.append({'name': name, 'status': 'passed', 'frames': cursor,
                             'packets': len(indexed_packets), 'pcmSha256': digest(decoded)})
            finally:
                decoder.close()
        for name, (packet, expected) in packets().items():
            if expected is None:
                rejected(name, lambda d, p=packet: d.decode(p, 8)[0], CODEC_ERROR)
            else:
                decoder = Decoder(configuration(), 8, 1)
                try:
                    status, output, _ = decoder.decode(packet, 8)
                    assert status == FRAME and output == expected and decoder.finish()[0] == COMPLETE
                    rows.append({'name': name, 'status': 'passed', 'pcmSha256': digest(output)})
                finally:
                    decoder.close()
        packet = packets()['valid-uncompressed'][0]
        rejected('wrong-packet-index', lambda d: d.decode(packet, 8, packet_index=1)[0], SEQUENCE_ERROR)
        rejected('wrong-frame-index', lambda d: d.decode(packet, 8, first_frame=1)[0], SEQUENCE_ERROR)
        rejected('container-frame-count-disagrees', lambda d: d.decode(packet, 7)[0], FRAME_COUNT_MISMATCH, frames=7)
        rejected('short-output-buffer', lambda d: d.decode(packet, 8, capacity=15)[0], INVALID_ARGUMENT)
        rejected('missing-call-authorization', lambda d: d.decode(packet, 8, control=False)[0], INVALID_ARGUMENT)
        rejected('empty-packet', lambda d: d.decode(b'', 8)[0], INVALID_ARGUMENT)
        rejected('finish-before-decode', lambda d: d.finish()[0], FRAME_COUNT_MISMATCH)
        rejected('cancel-before-codec', lambda d: d.decode(packet, 8)[0], CANCELLED, cancel_at=1)
        rejected('cancel-after-codec', lambda d: d.decode(packet, 8)[0], CANCELLED, cancel_at=2)
        rejected('cancel-before-publication', lambda d: d.decode(packet, 8)[0], CANCELLED, cancel_at=4)
        large_file = args.fixtures / 'fixtures' / (fixture_receipt['cases'][0]['name'] + '.m4a')
        large_cookie, large_packets = fixture_packets(large_file.read_bytes())
        first_packet, first_duration = large_packets[0]
        assert first_duration > 1024
        rejected('cancel-during-output-copy', lambda d: d.decode(first_packet, first_duration)[0],
                 CANCELLED, frames=first_duration, cookie=large_cookie, cancel_at=4)
        bounded_cookie = bytearray(configuration())
        bounded_cookie[12:16] = struct.pack('>I', len(packet) - 1)
        rejected('packet-exceeds-source-maximum', lambda d: d.decode(packet, 8)[0],
                 INVALID_ARGUMENT, cookie=bounded_cookie)

        def incomplete(decoder):
            assert decoder.decode(packet, 8)[0] == FRAME
            return decoder.finish()[0]
        rejected('missing-declared-tail', incomplete, FRAME_COUNT_MISMATCH, frames=9, count=2, committed_frames=8)

        def extra(decoder):
            assert decoder.decode(packet, 8)[0] == FRAME
            assert decoder.finish()[0] == COMPLETE
            return decoder.decode(packet, 8, 1, 8)[0]
        rejected('decode-after-completion', extra, SEQUENCE_ERROR, committed_frames=8)

        def revoked_finish(decoder):
            assert decoder.decode(packet, 8)[0] == FRAME
            decoder.cancel_at = decoder.calls + 1
            return decoder.finish()[0]
        rejected('revoked-before-finish', revoked_finish, CANCELLED, committed_frames=8)

        invalid_sources = [('zero-packets', configuration(), 8, 0), ('zero-total-frames', configuration(), 0, 1),
                           ('oversized-frame', configuration(65537), 8, 1), ('inconsistent-source-count', configuration(), 9, 1)]
        for name, index, value in [('unsupported-depth', 5, 15), ('unsupported-channels', 9, 3), ('unsupported-version', 4, 1)]:
            cookie = bytearray(configuration()); cookie[index] = value
            invalid_sources.append((name, cookie, 8, 1))
        cookie = bytearray(configuration())
        cookie[5], cookie[9], cookie[20:24] = 32, 2, struct.pack('>I', 1000000000)
        invalid_sources.append(('unrepresentable-pcm-byte-rate', cookie, 8, 1))
        for name, cookie, frames, count in invalid_sources:
            source = Source((Byte * 24).from_buffer_copy(cookie), frames, count)
            pointer = C.c_void_p()
            result = Result()
            observed = lib.sbalac_decoder_create(C.byref(source), C.byref(pointer), C.byref(result))
            if pointer.value:
                lib.sbalac_decoder_destroy(pointer)
            assert observed == result.status == INVALID_SOURCE and result.codec_error == 0 and not pointer.value, (name, observed)
            rows.append({'name': name, 'status': 'passed', 'rejection': observed})
        receipt['status'] = 'passed'
    except Exception as error:
        receipt['status'] = 'failed'
        receipt['failure'] = repr(error)
        raise
    finally:
        (args.evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'status': receipt['status'], 'cases': len(rows)}))


if __name__ == '__main__':
    main()
