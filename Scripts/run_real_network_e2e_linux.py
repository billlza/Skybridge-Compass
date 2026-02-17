#!/usr/bin/env python3
"""
Linux fallback for run_real_network_e2e.swift.

Implements the same minimal TCP request/response protocol and writes
compatible sample/summary CSV artifacts for kernel netem runs.
"""

from __future__ import annotations

import argparse
import csv
import os
import socket
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


MAX_BYTES = 512 * 1024


def sanitize_label(value: str) -> str:
    out = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in value.strip())
    if not out:
        return "run"
    return out[:64]


def stamp_for_filename(artifact_date: str | None) -> str:
    if artifact_date:
        return sanitize_label(artifact_date)
    env_date = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    if env_date:
        return sanitize_label(env_date)
    return time.strftime("%Y%m%d_%H%M%S", time.gmtime())


def parse_host_port(raw: str) -> tuple[str, int]:
    text = raw.strip()
    if text.startswith("["):
        end = text.find("]")
        if end < 0 or end + 2 > len(text) or text[end + 1] != ":":
            raise ValueError(f"invalid host:port: {raw}")
        host = text[1:end]
        port = int(text[end + 2 :])
        return host, port
    host, port_s = text.rsplit(":", 1)
    return host, int(port_s)


def percentile(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    s = sorted(xs)
    idx = int((len(s) - 1) * p)
    idx = max(0, min(len(s) - 1, idx))
    return s[idx]


def mean(xs: list[float]) -> float | None:
    if not xs:
        return None
    return sum(xs) / len(xs)


def fmt3(value: float | None) -> str:
    if value is None:
        return ""
    return f"{value:.3f}"


def recv_exact(conn: socket.socket, total: int) -> bytes:
    data = bytearray()
    while len(data) < total:
        chunk = conn.recv(min(65536, total - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def handle_connection(conn: socket.socket) -> None:
    try:
        conn.settimeout(10.0)
        prefix = recv_exact(conn, 4)
        if len(prefix) < 4:
            return
        requested = int.from_bytes(prefix, byteorder="big", signed=False)
        if requested <= 0 or requested > MAX_BYTES:
            payload = bytearray(prefix)
            while len(payload) < MAX_BYTES:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                payload.extend(chunk)
            requested = min(len(payload), MAX_BYTES)
            if requested <= 0:
                return
        else:
            body = recv_exact(conn, requested)
            if len(body) < requested:
                return

        remaining = requested
        buf = b"\xA5" * min(65536, requested)
        while remaining > 0:
            n = min(len(buf), remaining)
            conn.sendall(buf[:n])
            remaining -= n
    finally:
        try:
            conn.close()
        except OSError:
            pass


def run_server(bind: str) -> None:
    host, port = parse_host_port(bind)
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    if not infos:
        raise RuntimeError(f"unable to resolve bind endpoint: {bind}")

    af, socktype, proto, _, sockaddr = infos[0]
    srv = socket.socket(af, socktype, proto)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(sockaddr)
    srv.listen(128)
    print(f"[REALNET-E2E] Server ready on {host}:{port} (linux fallback)", flush=True)

    while True:
        conn, addr = srv.accept()
        print(f"[REALNET-E2E] accept from {addr}", flush=True)
        handle_connection(conn)


@dataclass
class Sample:
    idx: int
    payload_bytes: int
    ok: bool
    connect_ms: float | None
    first_byte_ms: float | None
    total_ms: float | None
    error_code: str | None
    error_detail: str | None


def one_sample(host: str, port: int, payload_bytes: int, timeout_ms: int, idx: int) -> Sample:
    start_ns = time.perf_counter_ns()
    connect_ms: float | None = None
    first_byte_ms: float | None = None
    total_ms: float | None = None
    err_code: str | None = None
    err_detail: str | None = None
    ok = False
    timeout_s = timeout_ms / 1000.0
    sock: socket.socket | None = None

    def since_start_ms() -> float:
        return (time.perf_counter_ns() - start_ns) / 1_000_000.0

    try:
        sock = socket.create_connection((host, port), timeout=timeout_s)
        connect_ms = since_start_ms()
        sock.settimeout(timeout_s)

        req = payload_bytes.to_bytes(4, byteorder="big") + (b"\x5A" * payload_bytes)
        sock.sendall(req)

        received = 0
        while received < payload_bytes:
            chunk = sock.recv(65536)
            if not chunk:
                break
            if first_byte_ms is None:
                first_byte_ms = since_start_ms()
            received += len(chunk)

        total_ms = since_start_ms()
        if received >= payload_bytes:
            ok = True
        else:
            err_code = "short_read"
            err_detail = f"received={received} expected={payload_bytes}"
    except socket.timeout:
        total_ms = since_start_ms()
        err_code = "timeout"
        err_detail = f"timeout_ms={timeout_ms}"
    except OSError as exc:
        total_ms = since_start_ms()
        if connect_ms is None:
            err_code = "connect_failed"
        else:
            err_code = "recv_failed"
        err_detail = str(exc)
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    return Sample(
        idx=idx,
        payload_bytes=payload_bytes,
        ok=ok,
        connect_ms=connect_ms,
        first_byte_ms=first_byte_ms,
        total_ms=total_ms,
        error_code=err_code,
        error_detail=err_detail,
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def remote_label(host: str, port: int) -> str:
    if ":" in host:
        return f"[{host}]:{port}"
    return f"{host}:{port}"


def write_samples_csv(path: Path, stamp: str, label: str, remote: str, samples: Iterable[Sample]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "stamp",
                "label",
                "remote",
                "payload_bytes",
                "idx",
                "ok",
                "connect_ms",
                "first_byte_ms",
                "total_ms",
                "error_code",
                "error_detail",
            ]
        )
        for s in samples:
            writer.writerow(
                [
                    stamp,
                    label,
                    remote,
                    s.payload_bytes,
                    s.idx,
                    1 if s.ok else 0,
                    fmt3(s.connect_ms),
                    fmt3(s.first_byte_ms),
                    fmt3(s.total_ms),
                    s.error_code or "",
                    (s.error_detail or "").replace(",", ";"),
                ]
            )


def write_summary_csv(path: Path, stamp: str, label: str, remote: str, by_payload: dict[int, list[Sample]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "stamp",
                "label",
                "remote",
                "payload_bytes",
                "samples",
                "ok_count",
                "ok_rate",
                "timeout_count",
                "timeout_rate",
                "connect_failed_count",
                "recv_failed_count",
                "short_read_count",
                "connect_mean_ms",
                "connect_p50_ms",
                "connect_p95_ms",
                "connect_p99_ms",
                "first_mean_ms",
                "first_p50_ms",
                "first_p95_ms",
                "first_p99_ms",
                "total_mean_ms",
                "total_p50_ms",
                "total_p95_ms",
                "total_p99_ms",
            ]
        )

        for payload_bytes in sorted(by_payload):
            group = by_payload[payload_bytes]
            total = len(group)
            ok = [s for s in group if s.ok]
            ok_count = len(ok)
            timeout_count = sum(1 for s in group if s.error_code == "timeout")
            connect_failed_count = sum(1 for s in group if s.error_code == "connect_failed")
            recv_failed_count = sum(1 for s in group if s.error_code == "recv_failed")
            short_read_count = sum(1 for s in group if s.error_code == "short_read")

            connect_ok = [s.connect_ms for s in ok if s.connect_ms is not None]
            first_ok = [s.first_byte_ms for s in ok if s.first_byte_ms is not None]
            total_ok = [s.total_ms for s in ok if s.total_ms is not None]

            writer.writerow(
                [
                    stamp,
                    label,
                    remote,
                    payload_bytes,
                    total,
                    ok_count,
                    f"{(ok_count / max(1, total)):.4f}",
                    timeout_count,
                    f"{(timeout_count / max(1, total)):.4f}",
                    connect_failed_count,
                    recv_failed_count,
                    short_read_count,
                    fmt3(mean(connect_ok)),
                    fmt3(percentile(connect_ok, 0.50)),
                    fmt3(percentile(connect_ok, 0.95)),
                    fmt3(percentile(connect_ok, 0.99)),
                    fmt3(mean(first_ok)),
                    fmt3(percentile(first_ok, 0.50)),
                    fmt3(percentile(first_ok, 0.95)),
                    fmt3(percentile(first_ok, 0.99)),
                    fmt3(mean(total_ok)),
                    fmt3(percentile(total_ok, 0.50)),
                    fmt3(percentile(total_ok, 0.95)),
                    fmt3(percentile(total_ok, 0.99)),
                ]
            )


def run_client(args: argparse.Namespace) -> None:
    stamp = stamp_for_filename(args.artifact_date)
    label = sanitize_label(args.label)
    out_dir = Path(args.out_dir)
    ensure_dir(out_dir)

    samples_path = out_dir / f"realnet_e2e_samples_{stamp}_{label}.csv"
    summary_path = out_dir / f"realnet_e2e_summary_{stamp}_{label}.csv"

    host, port = parse_host_port(args.connect)
    remote = remote_label(host, port)

    payloads: list[int] = []
    seen: set[int] = set()
    for value in args.bytes:
        if value > 0 and value not in seen:
            payloads.append(value)
            seen.add(value)
    if not payloads:
        payloads = [687, 12002]

    all_samples: list[Sample] = []
    by_payload: dict[int, list[Sample]] = defaultdict(list)

    for payload in payloads:
        print(f"[REALNET-E2E] payload={payload}B samples={args.samples}", flush=True)
        progress_step = max(1, min(10, args.samples))
        for i in range(args.samples):
            s = one_sample(host, port, payload, args.timeout_ms, i)
            all_samples.append(s)
            by_payload[payload].append(s)
            if (i + 1) % progress_step == 0:
                print(f"[REALNET-E2E] progress payload={payload}B {i + 1}/{args.samples}", flush=True)

    write_samples_csv(samples_path, stamp, label, remote, all_samples)
    write_summary_csv(summary_path, stamp, label, remote, by_payload)

    print(f"[REALNET-E2E] Samples: {samples_path}", flush=True)
    print(f"[REALNET-E2E] Summary: {summary_path}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Linux fallback for realnet e2e")
    sub = parser.add_subparsers(dest="mode", required=True)

    p_server = sub.add_parser("server")
    p_server.add_argument("--bind", default="0.0.0.0:44444")

    p_client = sub.add_parser("client")
    p_client.add_argument("--connect", required=True)
    p_client.add_argument("--label", default="run")
    p_client.add_argument("--artifact-date", default=None)
    p_client.add_argument("--out-dir", default="Artifacts")
    p_client.add_argument("--samples", type=int, default=50)
    p_client.add_argument("--timeout-ms", type=int, default=4000)
    p_client.add_argument("--bytes", type=int, action="append", default=[])
    p_client.add_argument("--bytes-list", default=None)

    args = parser.parse_args()

    if args.mode == "client" and args.bytes_list:
        for token in str(args.bytes_list).split(","):
            token = token.strip()
            if not token:
                continue
            try:
                value = int(token)
            except ValueError as exc:
                raise SystemExit(f"invalid --bytes-list token: {token}") from exc
            args.bytes.append(value)
    return args


def main() -> int:
    args = parse_args()
    if args.mode == "server":
        run_server(args.bind)
        return 0
    run_client(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
