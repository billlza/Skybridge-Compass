#!/usr/bin/env python3
import argparse
import binascii
import sys


def read_u16_le(data, offset):
    if offset + 2 > len(data):
        raise ValueError("Unexpected end of data while reading u16")
    return data[offset] | (data[offset + 1] << 8), offset + 2


def parse_message_a(data):
    offset = 0
    if len(data) < 5:
        raise ValueError("MessageA too short")
    version = data[offset]
    offset += 1
    supported_count, offset = read_u16_le(data, offset)
    offset += supported_count * 2
    keyshare_count, offset = read_u16_le(data, offset)
    for _ in range(keyshare_count):
        _, offset = read_u16_le(data, offset)  # suite id
        share_len, offset = read_u16_le(data, offset)
        offset += share_len
    offset += 32  # client nonce
    cap_len, offset = read_u16_le(data, offset)
    offset += cap_len
    policy_len, offset = read_u16_le(data, offset)
    offset += policy_len
    id_len, offset = read_u16_le(data, offset)
    offset += id_len
    transcript_end = offset
    sig_len, offset = read_u16_le(data, offset)
    offset += sig_len
    se_sig_len, offset = read_u16_le(data, offset)
    offset += se_sig_len
    if offset != len(data):
        raise ValueError(f"Trailing bytes in MessageA: {len(data) - offset}")
    return {
        "version": version,
        "transcript_end": transcript_end,
        "signature_len": sig_len,
        "secure_enclave_signature_len": se_sig_len,
    }


def parse_message_b(data):
    offset = 0
    if len(data) < 5:
        raise ValueError("MessageB too short")
    version = data[offset]
    offset += 1
    _, offset = read_u16_le(data, offset)  # suite id
    share_len, offset = read_u16_le(data, offset)
    offset += share_len
    offset += 32  # server nonce
    payload_len, offset = read_u16_le(data, offset)
    offset += payload_len
    id_len, offset = read_u16_le(data, offset)
    offset += id_len
    transcript_end = offset
    sig_len, offset = read_u16_le(data, offset)
    offset += sig_len
    se_sig_len, offset = read_u16_le(data, offset)
    offset += se_sig_len
    if offset != len(data):
        raise ValueError(f"Trailing bytes in MessageB: {len(data) - offset}")
    return {
        "version": version,
        "transcript_end": transcript_end,
        "signature_len": sig_len,
        "secure_enclave_signature_len": se_sig_len,
    }


def load_bytes(args):
    if args.hex:
        hex_str = args.hex.strip().replace("0x", "").replace(" ", "")
        return binascii.unhexlify(hex_str)
    if args.file:
        with open(args.file, "rb") as f:
            return f.read()
    return sys.stdin.buffer.read()


def main():
    parser = argparse.ArgumentParser(description="Wire-format sanity checker for MessageA/MessageB.")
    parser.add_argument("--type", choices=["messageA", "messageB"], required=True)
    parser.add_argument("--hex", help="Hex string for the message bytes.")
    parser.add_argument("--file", help="Binary file containing the message bytes.")
    parser.add_argument("--dump-transcript", action="store_true", help="Print transcript bytes as hex.")
    args = parser.parse_args()

    data = load_bytes(args)
    if args.type == "messageA":
        result = parse_message_a(data)
    else:
        result = parse_message_b(data)

    transcript = data[:result["transcript_end"]]
    print(f"type={args.type}")
    print(f"version={result['version']}")
    print(f"total_bytes={len(data)}")
    print(f"transcript_bytes={len(transcript)}")
    print(f"signature_len={result['signature_len']}")
    print(f"secure_enclave_signature_len={result['secure_enclave_signature_len']}")
    if args.dump_transcript:
        print(binascii.hexlify(transcript).decode("ascii"))


if __name__ == "__main__":
    main()
