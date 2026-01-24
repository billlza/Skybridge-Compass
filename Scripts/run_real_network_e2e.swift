#!/usr/bin/env swift
// Real-Network End-to-End Micro-Study (TCP payload transfer)
//
// Goal (reviewer-facing):
// - Provide a lightweight, reproducible "real network" micro-study that measures:
//   connect latency + time-to-first-byte + time-to-completion for a handshake-sized payload.
// - Designed to run on two Macs (or a Mac + any machine that can run the server).
// - Outputs CSV artifacts that can be aggregated into a Supplementary table.
//
// This is NOT a full protocol deployment. It intentionally isolates the
// transport/path effects for a 12kB-class control payload and aligns with the
// paper's "external validity" discussion.
//
// Usage:
//   # Terminal A (server)
//   swift Scripts/run_real_network_e2e.swift server --bind 0.0.0.0:44444
//
//   # Terminal B (client)
//   ARTIFACT_DATE=2026-01-16 swift Scripts/run_real_network_e2e.swift client \\
//     --label home_wifi --connect <server_ip>:44444 --samples 50 --bytes 12195
//
// Outputs:
//   Artifacts/realnet_e2e_samples_<stamp>_<label>.csv
//   Artifacts/realnet_e2e_summary_<stamp>_<label>.csv
//
import Foundation
import Network
import os

enum Mode: String {
    case server
    case client
}

struct Config {
    var mode: Mode
    var label: String = "run"
    var artifactDate: String? = nil
    var outDir: String = "Artifacts"

    // server
    var bindHost: String = "0.0.0.0"
    var bindPort: UInt16 = 44444

    // client
    var connectHost: String = "127.0.0.1"
    var connectPort: UInt16 = 44444
    var samples: Int = 50
    var timeoutMs: Int = 4000
    /// Payload sizes to test (bytes). For paper runs, we recommend two sizes:
    /// - 827 B (Classic wire size)
    /// - 12,163 B (PQC wire size)
    var payloadBytesList: [Int] = [12_195]
}

enum CLIError: Error {
    case usage(String)
    case invalid(String)
}

func sanitizeLabel(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "run" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return String(mapped.prefix(64))
}

func parseHostPort(_ s: String) throws -> (String, UInt16) {
    // Support both:
    //   - host:port
    //   - [ipv6_literal]:port   (recommended for IPv6)
    if s.hasPrefix("[") {
        guard let close = s.firstIndex(of: "]") else { throw CLIError.invalid("Invalid IPv6 bracket form '\(s)'") }
        let host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]
        guard rest.hasPrefix(":") else { throw CLIError.invalid("Invalid host:port '\(s)'") }
        let portStr = String(rest.dropFirst())
        guard let port = UInt16(portStr) else { throw CLIError.invalid("Invalid port in '\(s)'") }
        return (host, port)
    }
    let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw CLIError.invalid("Invalid host:port '\(s)' (use [ipv6]:port for IPv6)") }
    let host = String(parts[0])
    guard let port = UInt16(parts[1]) else { throw CLIError.invalid("Invalid port in '\(s)'") }
    return (host, port)
}

func printUsageAndExit(_ msg: String? = nil) -> Never {
    if let msg { fputs("ERROR: \(msg)\n\n", stderr) }
    print("""
    Usage:
      swift Scripts/run_real_network_e2e.swift server [--bind <host:port>]
      swift Scripts/run_real_network_e2e.swift client --connect <host:port> [options]

    Common options:
      --label <name>            Tag this run (default: run)
      --artifact-date <date>    Pin output filename stamp (e.g., 2026-01-16). If omitted, uses ARTIFACT_DATE env or a timestamp.
      --out-dir <dir>           Output directory (default: Artifacts)

    Client options:
      --connect <host:port>     Server endpoint (required for client)
      --samples <n>             Number of independent connects (default: 50)
      --timeout-ms <ms>         Per-sample timeout (default: 4000)
      --bytes <n>               Payload size in bytes (repeatable)
      --bytes-list <a,b,c>      Comma-separated payload sizes

    Example (two-size paper run: classic + PQC):
      swift Scripts/run_real_network_e2e.swift server --bind 0.0.0.0:44444
      ARTIFACT_DATE=2026-01-16 swift Scripts/run_real_network_e2e.swift client --label home_wifi --connect 10.0.0.8:44444 --samples 50 --bytes 827 --bytes 12163
    """)
    exit(2)
}

func stampForFilename(artifactDate: String?) -> String {
    if let d = artifactDate, !d.isEmpty { return sanitizeLabel(d) }
    let env = ProcessInfo.processInfo.environment
    if let v = env["ARTIFACT_DATE"], !v.isEmpty { return sanitizeLabel(v) }
    if let v = env["SKYBRIDGE_ARTIFACT_DATE"], !v.isEmpty { return sanitizeLabel(v) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let idx = Int(Double(s.count - 1) * p)
    return s[max(0, min(idx, s.count - 1))]
}

func mean(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    return xs.reduce(0.0, +) / Double(xs.count)
}

struct Sample: Sendable {
    let idx: Int
    let payloadBytes: Int
    let ok: Bool
    let connectMs: Double?
    let firstByteMs: Double?
    let totalMs: Double?
    let errorCode: String?
    let errorDetail: String?
}

final class TCPResponder {
    /// Server will respond with the same payload size the client requests.
    /// Client request format:
    ///   [4B big-endian length L] + [L bytes payload]
    /// For backwards compatibility, if the first 4 bytes do not decode to a
    /// reasonable length, the server will fall back to using the total received
    /// byte count as L.
    private let maxBytes: Int = 512 * 1024

    func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { st in
            if case .failed = st { connection.cancel() }
        }
        connection.start(queue: .global())
        var buffer = Data()

        func recvMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if error != nil {
                    connection.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if buffer.count > self.maxBytes {
                        connection.cancel()
                        return
                    }
                }

                // Determine requested length.
                var requested: Int? = nil
                if buffer.count >= 4 {
                    let len = buffer.prefix(4).withUnsafeBytes { ptr -> UInt32 in
                        ptr.load(as: UInt32.self).bigEndian
                    }
                    let L = Int(len)
                    if L > 0 && L <= self.maxBytes && buffer.count >= 4 + L {
                        requested = L
                    }
                }

                // Back-compat: if client doesn't use length prefix, treat first request as payload itself.
                if requested == nil && isComplete && buffer.count > 0 {
                    requested = min(buffer.count, self.maxBytes)
                }
                // Also allow a best-effort path: if we already received at least 4 bytes and
                // the prefix length is sane, but the payload isn't complete yet, keep reading.

                if let L = requested {
                    let resp = Data(repeating: 0xA5, count: L)
                    connection.send(content: resp, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }

                if isComplete {
                    connection.cancel()
                    return
                }
                recvMore()
            }
        }
        recvMore()
    }
}

func runServer(config: Config) async throws {
    let params = NWParameters.tcp
    let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.bindPort)!)
    listener.newConnectionHandler = { conn in
        // Helpful for cross-NAT debugging: confirms whether inbound SYNs reach the Mac.
        print("[REALNET-E2E] accept from \(conn.endpoint)")
        TCPResponder().handle(connection: conn)
    }
    listener.stateUpdateHandler = { st in
        switch st {
        case .ready:
            print("[REALNET-E2E] Server ready on \(config.bindHost):\(config.bindPort) (length-prefixed request; replies with requested size)")
        case .failed(let err):
            fputs("[REALNET-E2E] Server failed: \(err)\n", stderr)
            exit(1)
        default:
            break
        }
    }
    listener.start(queue: .global())
    // Keep running.
    try await Task.sleep(for: .seconds(365 * 24 * 60 * 60))
}

func oneClientSample(host: String, port: UInt16, payloadBytes: Int, timeoutMs: Int, idx: Int) async -> Sample {
    let start = DispatchTime.now().uptimeNanoseconds
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

    func nsToMs(_ ns: UInt64?) -> Double? {
        guard let ns else { return nil }
        return Double(ns) / 1_000_000.0
    }

    return await withCheckedContinuation { cont in
        // Swift 6: NWConnection callbacks may execute concurrently.
        // Avoid mutating captured locals inside callbacks by storing all sample
        // state in a locked object.
        final class State: @unchecked Sendable {
            struct Inner {
                var finished = false
                var connectNs: UInt64?
                var firstByteNs: UInt64?
                var totalNs: UInt64?
                var ok = false
                var errCode: String?
                var errDetail: String?
                var received = 0
            }

            private let lock = OSAllocatedUnfairLock(initialState: Inner())

            func markConnected(startNs: UInt64) {
                lock.withLock { s in
                    if s.connectNs == nil {
                        s.connectNs = DispatchTime.now().uptimeNanoseconds - startNs
                    }
                }
            }

            func noteFirstByteIfNeeded(startNs: UInt64) {
                lock.withLock { s in
                    if s.firstByteNs == nil {
                        s.firstByteNs = DispatchTime.now().uptimeNanoseconds - startNs
                    }
                }
            }

            func addReceived(_ n: Int) {
                lock.withLock { s in
                    s.received += n
                }
            }

            func received() -> Int {
                lock.withLock { $0.received }
            }

            func markTotalAndOk(startNs: UInt64, ok: Bool) {
                lock.withLock { s in
                    s.totalNs = DispatchTime.now().uptimeNanoseconds - startNs
                    s.ok = ok
                }
            }

            func isFinished() -> Bool {
                lock.withLock { $0.finished }
            }

            func tryFinish(idx: Int, payloadBytes: Int, nsToMs: (UInt64?) -> Double?, code: String?, detail: String?) -> Sample? {
                lock.withLock { s in
                    if s.finished { return nil }
                    s.finished = true
                    if let code { s.errCode = code }
                    if let detail { s.errDetail = detail }
                    return Sample(
                        idx: idx,
                        payloadBytes: payloadBytes,
                        ok: s.ok,
                        connectMs: nsToMs(s.connectNs),
                        firstByteMs: nsToMs(s.firstByteNs),
                        totalMs: nsToMs(s.totalNs),
                        errorCode: s.errCode,
                        errorDetail: s.errDetail
                    )
                }
            }
        }

        let state = State()

        func finish(_ code: String? = nil, _ detail: String? = nil) {
            if let out = state.tryFinish(idx: idx, payloadBytes: payloadBytes, nsToMs: nsToMs, code: code, detail: detail) {
                cont.resume(returning: out)
            }
        }

        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                state.markConnected(startNs: start)

                // Request format: [4B length] + [payload]
                var req = withUnsafeBytes(of: UInt32(payloadBytes).bigEndian) { Data($0) }
                req.append(Data(repeating: 0x5A, count: payloadBytes))

                conn.send(content: req, completion: .contentProcessed { sendErr in
                    if let sendErr {
                        state.markTotalAndOk(startNs: start, ok: false)
                        conn.cancel()
                        finish("send_failed", "\(sendErr)")
                        return
                    }

                    func recvMore() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, recvErr in
                            if let recvErr {
                                state.markTotalAndOk(startNs: start, ok: false)
                                conn.cancel()
                                finish("recv_failed", "\(recvErr)")
                                return
                            }
                            if let data, !data.isEmpty {
                                state.noteFirstByteIfNeeded(startNs: start)
                                state.addReceived(data.count)
                            }
                            let received = state.received()
                            if received >= payloadBytes || isComplete {
                                let ok = (received >= payloadBytes)
                                state.markTotalAndOk(startNs: start, ok: ok)
                                conn.cancel()
                                if ok {
                                    finish()
                                } else {
                                    finish("short_read", "received=\(received) expected=\(payloadBytes)")
                                }
                                return
                            }
                            recvMore()
                        }
                    }
                    recvMore()
                })
            case .failed(let e):
                state.markTotalAndOk(startNs: start, ok: false)
                conn.cancel()
                finish("connect_failed", "\(e)")
            default:
                break
            }
        }

        conn.start(queue: .global())

        // timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            if state.isFinished() { return }
            state.markTotalAndOk(startNs: start, ok: false)
            conn.cancel()
            finish("timeout", "timeout_ms=\(timeoutMs)")
        }
    }
}

func runClient(config: Config) async throws {
    let stamp = stampForFilename(artifactDate: config.artifactDate)
    let label = sanitizeLabel(config.label)
    let outDir = config.outDir

    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let samplesPath = "\(outDir)/realnet_e2e_samples_\(stamp)_\(label).csv"
    let summaryPath = "\(outDir)/realnet_e2e_summary_\(stamp)_\(label).csv"

    var samples: [Sample] = []
    samples.reserveCapacity(config.samples * max(1, config.payloadBytesList.count))

    for payloadBytes in config.payloadBytesList {
        print("[REALNET-E2E] payload=\(payloadBytes)B samples=\(config.samples)")
        for i in 0..<config.samples {
            let s = await oneClientSample(
                host: config.connectHost,
                port: config.connectPort,
                payloadBytes: payloadBytes,
                timeoutMs: config.timeoutMs,
                idx: i
            )
            samples.append(s)
            if (i + 1) % max(1, min(10, config.samples)) == 0 {
                print("[REALNET-E2E] progress payload=\(payloadBytes)B \(i+1)/\(config.samples)")
            }
        }
    }

    // Write samples CSV
    let header = "stamp,label,remote,payload_bytes,idx,ok,connect_ms,first_byte_ms,total_ms,error_code,error_detail\n"
    var lines: [String] = []
    lines.reserveCapacity(samples.count)
    let remote: String
    if config.connectHost.contains(":") {
        remote = "[\(config.connectHost)]:\(config.connectPort)"
    } else {
        remote = "\(config.connectHost):\(config.connectPort)"
    }
    for s in samples {
        let row = [
            stamp,
            label,
            remote,
            "\(s.payloadBytes)",
            "\(s.idx)",
            s.ok ? "1" : "0",
            s.connectMs.map { String(format: "%.3f", $0) } ?? "",
            s.firstByteMs.map { String(format: "%.3f", $0) } ?? "",
            s.totalMs.map { String(format: "%.3f", $0) } ?? "",
            s.errorCode ?? "",
            (s.errorDetail ?? "").replacingOccurrences(of: ",", with: ";")
        ].joined(separator: ",")
        lines.append(row)
    }
    try (header + lines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: samplesPath), atomically: true, encoding: .utf8)

    func fmt(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "" }

    // Summary (one row per payload size)
    let summaryHeader = "stamp,label,remote,payload_bytes,samples,ok_count,ok_rate,timeout_count,timeout_rate,connect_failed_count,recv_failed_count,short_read_count,connect_mean_ms,connect_p50_ms,connect_p95_ms,first_mean_ms,first_p50_ms,first_p95_ms,total_mean_ms,total_p50_ms,total_p95_ms\n"
    var summaryLines: [String] = []
    for payloadBytes in config.payloadBytesList {
        let group = samples.filter { $0.payloadBytes == payloadBytes }
        let okCount = group.filter { $0.ok }.count
        let okRate = Double(okCount) / Double(max(1, group.count))
        let timeoutCount = group.filter { $0.errorCode == "timeout" }.count
        let timeoutRate = Double(timeoutCount) / Double(max(1, group.count))
        let connectFailCount = group.filter { $0.errorCode == "connect_failed" }.count
        let recvFailCount = group.filter { $0.errorCode == "recv_failed" }.count
        let shortReadCount = group.filter { $0.errorCode == "short_read" }.count

        let connectOK = group.compactMap { $0.ok ? $0.connectMs : nil }
        let firstOK = group.compactMap { $0.ok ? $0.firstByteMs : nil }
        let totalOK = group.compactMap { $0.ok ? $0.totalMs : nil }

        let row = [
            stamp, label, remote, "\(payloadBytes)",
            "\(group.count)", "\(okCount)", String(format: "%.4f", okRate),
            "\(timeoutCount)", String(format: "%.4f", timeoutRate),
            "\(connectFailCount)", "\(recvFailCount)", "\(shortReadCount)",
            fmt(mean(connectOK)), fmt(percentile(connectOK, 0.50)), fmt(percentile(connectOK, 0.95)),
            fmt(mean(firstOK)), fmt(percentile(firstOK, 0.50)), fmt(percentile(firstOK, 0.95)),
            fmt(mean(totalOK)), fmt(percentile(totalOK, 0.50)), fmt(percentile(totalOK, 0.95)),
        ].joined(separator: ",")
        summaryLines.append(row)
    }
    try (summaryHeader + summaryLines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: summaryPath), atomically: true, encoding: .utf8)

    print("[REALNET-E2E] Samples: \(samplesPath)")
    print("[REALNET-E2E] Summary: \(summaryPath)")
}

func parseArgs() -> Config {
    let args = CommandLine.arguments
    guard args.count >= 2, let mode = Mode(rawValue: args[1]) else {
        printUsageAndExit("Missing mode (server/client)")
    }
    var cfg = Config(mode: mode)
    var i = 2
    while i < args.count {
        let a = args[i]
        switch a {
        case "--label":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --label") }
            cfg.label = args[i]
        case "--artifact-date":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --artifact-date") }
            cfg.artifactDate = args[i]
        case "--out-dir":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --out-dir") }
            cfg.outDir = args[i]
        case "--bind":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --bind") }
            let (h, p) = try! parseHostPort(args[i])
            cfg.bindHost = h; cfg.bindPort = p
        case "--connect":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --connect") }
            let (h, p) = try! parseHostPort(args[i])
            cfg.connectHost = h; cfg.connectPort = p
        case "--samples":
            i += 1; guard i < args.count, let n = Int(args[i]), n > 0 else { printUsageAndExit("Invalid --samples") }
            cfg.samples = n
        case "--timeout-ms":
            i += 1; guard i < args.count, let n = Int(args[i]), n >= 50 else { printUsageAndExit("Invalid --timeout-ms") }
            cfg.timeoutMs = n
        case "--bytes":
            i += 1; guard i < args.count, let n = Int(args[i]), n > 0 else { printUsageAndExit("Invalid --bytes") }
            cfg.payloadBytesList.append(n)
        case "--bytes-list":
            i += 1; guard i < args.count else { printUsageAndExit("Missing value for --bytes-list") }
            let parts = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let parsed = parts.compactMap { Int($0) }.filter { $0 > 0 }
            if parsed.isEmpty { printUsageAndExit("Invalid --bytes-list (expected comma-separated ints)") }
            cfg.payloadBytesList.append(contentsOf: parsed)
        case "--help", "-h":
            printUsageAndExit(nil)
        default:
            printUsageAndExit("Unknown argument: \(a)")
        }
        i += 1
    }
    // If user didn't specify bytes explicitly, default is 12,195 B.
    // If they did specify, `payloadBytesList` may contain the default; dedupe + preserve order.
    var seen = Set<Int>()
    cfg.payloadBytesList = cfg.payloadBytesList.filter { seen.insert($0).inserted }
    if cfg.mode == .client {
        // client requires explicit connect host:port
        // (defaults exist, but for paper runs we want explicitness; keep permissive here)
    }
    return cfg
}

let cfg = parseArgs()
switch cfg.mode {
case .server:
    do {
        // runServer starts a listener and then blocks.
        try await runServer(config: cfg)
    } catch {
        fputs("[REALNET-E2E] ERROR: \(error)\n", stderr)
        exit(1)
    }
case .client:
    Task {
        do {
            try await runClient(config: cfg)
            exit(0)
        } catch {
            fputs("[REALNET-E2E] ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}


