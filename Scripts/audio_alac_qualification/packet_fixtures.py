"""Small raw ALAC counterexamples; no file parser, playback, or product path."""
import struct


def configuration(frames=8):
    return struct.pack('>IBBBBBBHIII', frames, 0, 16, 40, 10, 14, 1, 255, 0, 0, 48000)


def packed(bits):
    bits += '0' * (-len(bits) % 8)
    return int(bits, 2).to_bytes(len(bits) // 8, 'big')


def header(compressed):
    # Mono element, instance tag, reserved header, explicit frame count, no extra low byte.
    return '000' + '0000' + '0' * 12 + '1' + '00' + ('0' if compressed else '1') + f'{8:032b}'


def packets():
    samples = [0, 1, -1, 32767, -32768, 3, -5, 7]
    raw = packed(header(False) + ''.join(f'{value & 65535:016b}' for value in samples) + '111')
    # History 10 gives k=1 for the first zero and k=4 for the following zero run.
    # Predictor order 0, quantization 1; all 8 samples are zero. A run of 8 after the first
    # sample would exceed the declared packet. Older provider behavior clamps it to 7.
    prefix = header(True) + '0' * 16 + '0000' + '0001' + '000' + '00000' + '0'
    zeros = packed(prefix + '0' + '1000' + '111')
    overrun = packed(prefix + '0' + '1001' + '111')
    return {
        'valid-uncompressed': (raw, struct.pack('<8h', *samples)),
        'valid-compressed-zero': (zeros, bytes(16)),
        'invalid-zero-run-overflow': (overrun, None),
        'invalid-data-after-end': (raw + bytes(2), None),
        'invalid-empty-element': (packed('111'), None),
        'invalid-truncated-packet': (raw[:-5], None),
    }
