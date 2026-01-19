#!/usr/bin/env python3
import argparse
import csv
import struct
from collections import defaultdict


DLT_NULL = 0
DLT_LOOP = 108
DLT_RAW = 101
AF_INET = 2
AF_INET6 = 24


def parse_args():
    parser = argparse.ArgumentParser(description="Parse baseline pcap and compute wire bytes.")
    parser.add_argument("--pcap", required=True, help="pcap capture file")
    parser.add_argument("--timings", required=True, help="baseline timings CSV")
    parser.add_argument("--output", required=True, help="output CSV with per-iteration wire bytes")
    parser.add_argument("--summary-output", help="output CSV with per-protocol summary")
    parser.add_argument("--margin-ms", type=float, default=2.0, help="time window margin in ms")
    return parser.parse_args()


def read_pcap(path):
    packets = []
    with open(path, "rb") as f:
        header = f.read(24)
        if len(header) < 24:
            raise ValueError("pcap header too short")
        magic = header[:4]
        if magic == b"\xd4\xc3\xb2\xa1":
            endian = "<"
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian = ">"
        else:
            raise ValueError("unsupported pcap magic")
        _, _, _, _, _, _, linktype = struct.unpack(endian + "IHHIIII", header)

        while True:
            pkt_hdr = f.read(16)
            if len(pkt_hdr) < 16:
                break
            ts_sec, ts_usec, incl_len, orig_len = struct.unpack(endian + "IIII", pkt_hdr)
            data = f.read(incl_len)
            if len(data) < incl_len:
                break
            timestamp = ts_sec + (ts_usec / 1_000_000.0)
            pkt_info = parse_packet(linktype, data, orig_len)
            if pkt_info is None:
                continue
            src_port, dst_port = pkt_info
            packets.append((timestamp, orig_len, src_port, dst_port))
    return packets


def parse_packet(linktype, data, orig_len):
    if linktype in (DLT_NULL, DLT_LOOP):
        if len(data) < 4:
            return None
        af = struct.unpack("<I", data[:4])[0]
        payload = data[4:]
    elif linktype == DLT_RAW:
        af = AF_INET
        payload = data
    else:
        return None

    if af == AF_INET:
        return parse_ipv4(payload)
    if af == AF_INET6:
        return parse_ipv6(payload)
    return None


def parse_ipv4(data):
    if len(data) < 20:
        return None
    ihl = (data[0] & 0x0F) * 4
    if len(data) < ihl + 4:
        return None
    proto = data[9]
    if proto not in (6, 17):
        return None
    ports = data[ihl:ihl + 4]
    src_port, dst_port = struct.unpack("!HH", ports)
    return src_port, dst_port


def parse_ipv6(data):
    if len(data) < 40:
        return None
    next_header = data[6]
    if next_header not in (6, 17):
        return None
    ports = data[40:44]
    if len(ports) < 4:
        return None
    src_port, dst_port = struct.unpack("!HH", ports)
    return src_port, dst_port


def parse_timings(path):
    rows = []
    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ports = []
            for part in row["ports"].replace(";", ",").split(","):
                part = part.strip()
                if not part:
                    continue
                ports.append(int(part))
            rows.append({
                "protocol": row["protocol"],
                "iteration": int(row["iteration"]),
                "start": float(row["start_epoch"]),
                "end": float(row["end_epoch"]),
                "duration_ms": float(row["duration_ms"]),
                "ports": ports
            })
    return rows


def percentile(values, p):
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    idx = int((len(sorted_vals) - 1) * p)
    return sorted_vals[idx]


def main():
    args = parse_args()
    packets = read_pcap(args.pcap)
    timings = parse_timings(args.timings)
    margin = args.margin_ms / 1000.0

    output_rows = []
    by_protocol = defaultdict(list)
    by_protocol_wire = defaultdict(list)

    for row in timings:
        start = row["start"] - margin
        end = row["end"] + margin
        ports = set(row["ports"])
        wire_bytes = 0
        packet_count = 0
        for ts, length, src_port, dst_port in packets:
            if ts < start or ts > end:
                continue
            if src_port in ports or dst_port in ports:
                wire_bytes += length
                packet_count += 1
        output_rows.append({
            "protocol": row["protocol"],
            "iteration": row["iteration"],
            "ports": ";".join(str(p) for p in row["ports"]),
            "wire_bytes": wire_bytes,
            "packet_count": packet_count
        })
        by_protocol[row["protocol"]].append(row["duration_ms"])
        by_protocol_wire[row["protocol"]].append(wire_bytes)

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["protocol", "iteration", "ports", "wire_bytes", "packet_count"]
        )
        writer.writeheader()
        writer.writerows(output_rows)

    if args.summary_output:
        summary_rows = []
        for protocol, durations in by_protocol.items():
            wire_values = by_protocol_wire.get(protocol, [])
            summary_rows.append({
                "protocol": protocol,
                "n": len(durations),
                "latency_mean_ms": sum(durations) / len(durations) if durations else 0.0,
                "latency_p50_ms": percentile(durations, 0.50),
                "latency_p95_ms": percentile(durations, 0.95),
                "wire_mean_bytes": sum(wire_values) / len(wire_values) if wire_values else 0.0,
                "wire_p50_bytes": percentile(wire_values, 0.50),
                "wire_p95_bytes": percentile(wire_values, 0.95)
            })
        with open(args.summary_output, "w", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "protocol",
                    "n",
                    "latency_mean_ms",
                    "latency_p50_ms",
                    "latency_p95_ms",
                    "wire_mean_bytes",
                    "wire_p50_bytes",
                    "wire_p95_bytes"
                ]
            )
            writer.writeheader()
            writer.writerows(summary_rows)


if __name__ == "__main__":
    main()
