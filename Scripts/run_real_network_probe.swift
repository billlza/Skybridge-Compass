#!/usr/bin/env swift
// Real-Network Probe (STUN RTT + NAT Mapping Behavior)
//
// Motivation (reviewer-facing):
// - Provide a lightweight, reproducible "real network" probe that can be run with a single Mac
//   across Wi‑Fi / tethering / different ISPs, without requiring a second macOS machine.
// - Captures: active path snapshot, local UDP endpoint, STUN-mapped endpoint(s), RTT stats, loss rate,
//   and a conservative NAT classification (noNAT / symmetric / unknown).
// - NAT classification is intentionally conservative to avoid over-claiming without RFC5780-capable STUN servers.
//
// Usage:
//   swift Scripts/run_real_network_probe.swift --label home_wifi --samples 50
//
// Optional:
//   --server stun.l.google.com:19302 --server stun.cloudflare.com:3478
//   --timeout-ms 1500 --out-dir Artifacts
//
// Outputs:
//   Artifacts/realnet_stun_samples_<stamp>_<label>.csv
//   Artifacts/realnet_stun_summary_<stamp>_<label>.csv
//
// Reproducibility:
//   To keep filenames stable across multi-run paper artifacts, you can pin <stamp> via:
//     ARTIFACT_DATE=YYYY-MM-DD (or SKYBRIDGE_ARTIFACT_DATE)
//   or pass:
//     --artifact-date YYYY-MM-DD
//
import Foundation
import Network
import Darwin
import Security

struct STUNServerSpec: Hashable, Sendable {
    let host: String
    let port: UInt16
}

struct ResolvedServer: Sendable {
    let spec: STUNServerSpec
    let ipv4: in_addr
    let ipString: String
}

struct Endpoint: Hashable, Sendable {
    let ip: String
    let port: UInt16
}

struct PathSnapshot: Sendable {
    let status: String
    let isExpensive: Bool
    let isConstrained: Bool
    let interfaceTypes: String
}

struct SampleRow: Sendable {
    let timestampISO8601: String
    let label: String
    let serverHost: String
    let serverIP: String
    let serverPort: UInt16
    let sampleIndex: Int
    let ok: Bool
    let rttMs: Double?
    let mappedIP: String?
    let mappedPort: UInt16?
    let error: String?
}

struct SummaryRow: Sendable {
    let timestampISO8601: String
    let label: String
    let pathStatus: String
    let pathInterfaceTypes: String
    let pathIsExpensive: Bool
    let pathIsConstrained: Bool
    let localIP: String
    let localPort: UInt16
    let natClassification: String
    let serverHost: String
    let serverIP: String
    let serverPort: UInt16
    let mappedMode: String
    let mappedUniqueCount: Int
    let samples: Int
    let okCount: Int
    let lossRate: Double
    let rttMeanMs: Double?
    let rttP50Ms: Double?
    let rttP95Ms: Double?
    let rttP99Ms: Double?
}

enum ProbeError: Error {
    case invalidArgument(String)
    case dnsResolutionFailed(String)
    case socketFailed(String)
    case connectFailed(String)
    case sendFailed(String)
    case recvFailed(String)
    case stunParseFailed(String)
    case noSamples
}

// MARK: - CLI parsing

struct Config {
    var label: String = "run"
    var servers: [STUNServerSpec] = [
        STUNServerSpec(host: "stun.l.google.com", port: 19302),
        STUNServerSpec(host: "stun.cloudflare.com", port: 3478),
    ]
    var samplesPerServer: Int = 50
    var timeoutMs: Int = 1500
    var outDir: String = "Artifacts"
    var artifactDate: String? = nil
}

func parseArgs() throws -> Config {
    var config = Config()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--label":
            i += 1
            guard i < args.count else { throw ProbeError.invalidArgument("Missing value for --label") }
            config.label = sanitizeLabel(args[i])
        case "--artifact-date":
            i += 1
            guard i < args.count else { throw ProbeError.invalidArgument("Missing value for --artifact-date") }
            config.artifactDate = args[i].trimmingCharacters(in: .whitespacesAndNewlines)
        case "--server":
            i += 1
            guard i < args.count else { throw ProbeError.invalidArgument("Missing value for --server") }
            let spec = try parseServerSpec(args[i])
            config.servers.append(spec)
        case "--samples":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                throw ProbeError.invalidArgument("Invalid --samples (expected integer > 0)")
            }
            config.samplesPerServer = n
        case "--timeout-ms":
            i += 1
            guard i < args.count, let n = Int(args[i]), n >= 50 else {
                throw ProbeError.invalidArgument("Invalid --timeout-ms (expected integer >= 50)")
            }
            config.timeoutMs = n
        case "--out-dir":
            i += 1
            guard i < args.count else { throw ProbeError.invalidArgument("Missing value for --out-dir") }
            config.outDir = args[i]
        case "--help", "-h":
            printUsageAndExit()
        default:
            throw ProbeError.invalidArgument("Unknown argument: \(arg)")
        }
        i += 1
    }
    // Deduplicate while preserving order.
    var seen = Set<STUNServerSpec>()
    config.servers = config.servers.filter { seen.insert($0).inserted }
    if config.servers.isEmpty {
        throw ProbeError.invalidArgument("No STUN servers configured")
    }
    return config
}

func printUsageAndExit() -> Never {
    let text = """
    Usage:
      swift Scripts/run_real_network_probe.swift [options]

    Options:
      --label <name>           Tag this run (default: run)
      --artifact-date <date>   Pin output filename stamp (e.g., 2026-01-16). If omitted, uses ARTIFACT_DATE env or a timestamp.
      --server <host:port>     Add STUN server (repeatable)
      --samples <n>            Samples per server (default: 50)
      --timeout-ms <ms>        Per-sample recv timeout (default: 1500)
      --out-dir <dir>          Output directory (default: Artifacts)
      -h, --help               Show help

    Example:
      swift Scripts/run_real_network_probe.swift --label home_wifi --samples 30
      # Switch network (e.g., hotspot) and run again:
      swift Scripts/run_real_network_probe.swift --label phone_hotspot --samples 30
    """
    print(text)
    exit(0)
}

func sanitizeLabel(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "run" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return String(mapped.prefix(64))
}

func parseServerSpec(_ input: String) throws -> STUNServerSpec {
    let parts = input.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        throw ProbeError.invalidArgument("Invalid server spec '\(input)' (expected host:port)")
    }
    let host = String(parts[0])
    guard !host.isEmpty else { throw ProbeError.invalidArgument("Invalid server host in '\(input)'") }
    guard let port = UInt16(parts[1]) else { throw ProbeError.invalidArgument("Invalid server port in '\(input)'") }
    return STUNServerSpec(host: host, port: port)
}

// MARK: - Network path snapshot

func capturePathSnapshot(timeoutMs: Int = 800) -> PathSnapshot {
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "realnet.path.monitor")
    let semaphore = DispatchSemaphore(value: 0)
    var captured: NWPath?
    monitor.pathUpdateHandler = { path in
        captured = path
        semaphore.signal()
    }
    monitor.start(queue: queue)
    _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
    monitor.cancel()

    guard let path = captured else {
        return PathSnapshot(status: "unknown", isExpensive: false, isConstrained: false, interfaceTypes: "unknown")
    }

    let status: String
    switch path.status {
    case .satisfied: status = "satisfied"
    case .unsatisfied: status = "unsatisfied"
    case .requiresConnection: status = "requires_connection"
    @unknown default: status = "unknown"
    }

    let types: [(NWInterface.InterfaceType, String)] = [
        (.wiredEthernet, "ethernet"),
        (.wifi, "wifi"),
        (.cellular, "cellular"),
        (.other, "other"),
        (.loopback, "loopback"),
    ]
    let used = types.compactMap { (t, name) in
        path.usesInterfaceType(t) ? name : nil
    }
    let interfaceTypes = used.isEmpty ? "unknown" : used.joined(separator: "+")

    return PathSnapshot(
        status: status,
        isExpensive: path.isExpensive,
        isConstrained: path.isConstrained,
        interfaceTypes: interfaceTypes
    )
}

// MARK: - STUN (RFC 5389) minimal binding request/response

let stunMagicCookie: UInt32 = 0x2112A442

func makeTransactionId() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 12)
    let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if rc != errSecSuccess {
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    }
    return bytes
}

func buildBindingRequest(transactionId: [UInt8]) -> [UInt8] {
    precondition(transactionId.count == 12)
    var msg = [UInt8]()
    msg.reserveCapacity(20)

    func appendU16(_ v: UInt16) { msg.append(UInt8(v >> 8)); msg.append(UInt8(v & 0xFF)) }
    func appendU32(_ v: UInt32) { msg.append(UInt8((v >> 24) & 0xFF)); msg.append(UInt8((v >> 16) & 0xFF)); msg.append(UInt8((v >> 8) & 0xFF)); msg.append(UInt8(v & 0xFF)) }

    appendU16(0x0001) // Binding Request
    appendU16(0x0000) // length = 0
    appendU32(stunMagicCookie)
    msg.append(contentsOf: transactionId)
    return msg
}

func parseBindingResponse(_ data: [UInt8], expectedTransactionId: [UInt8]) throws -> Endpoint {
    guard data.count >= 20 else { throw ProbeError.stunParseFailed("short response") }
    let msgType = (UInt16(data[0]) << 8) | UInt16(data[1])
    guard msgType == 0x0101 else { throw ProbeError.stunParseFailed("unexpected type 0x\(String(msgType, radix: 16))") }
    let msgLen = (UInt16(data[2]) << 8) | UInt16(data[3])
    let cookie = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 8) | UInt32(data[7])
    guard cookie == stunMagicCookie else { throw ProbeError.stunParseFailed("bad cookie") }
    let tid = Array(data[8..<20])
    guard tid == expectedTransactionId else { throw ProbeError.stunParseFailed("transaction id mismatch") }

    let end = min(data.count, 20 + Int(msgLen))
    var offset = 20
    while offset + 4 <= end {
        let attrType = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        let attrLen = (UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3])
        offset += 4
        let next = offset + Int(attrLen)
        guard next <= end else { break }

        // XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001)
        if attrType == 0x0020 || attrType == 0x0001 {
            if let ep = parseAddressAttribute(Array(data[offset..<next]), xor: attrType == 0x0020) {
                return ep
            }
        }

        // 32-bit padding
        offset = (next + 3) & ~3
    }
    throw ProbeError.stunParseFailed("no mapped address")
}

func parseAddressAttribute(_ attr: [UInt8], xor: Bool) -> Endpoint? {
    // Format: 0:0x00, 1:family (0x01 IPv4), 2-3:port, 4-7:address
    guard attr.count >= 8 else { return nil }
    guard attr[1] == 0x01 else { return nil } // IPv4 only

    var port = (UInt16(attr[2]) << 8) | UInt16(attr[3])
    var addr = (UInt32(attr[4]) << 24) | (UInt32(attr[5]) << 16) | (UInt32(attr[6]) << 8) | UInt32(attr[7])

    if xor {
        port ^= UInt16((stunMagicCookie >> 16) & 0xFFFF)
        addr ^= stunMagicCookie
    }

    let ipBytes: [UInt8] = [
        UInt8((addr >> 24) & 0xFF),
        UInt8((addr >> 16) & 0xFF),
        UInt8((addr >> 8) & 0xFF),
        UInt8(addr & 0xFF),
    ]
    let ip = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"
    return Endpoint(ip: ip, port: port)
}

// MARK: - DNS + socket helpers

func resolveIPv4(_ server: STUNServerSpec) throws -> ResolvedServer {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_protocol = IPPROTO_UDP

    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(server.host, nil, &hints, &res)
    guard rc == 0, let list = res else {
        throw ProbeError.dnsResolutionFailed("getaddrinfo(\(server.host)) failed: \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(list) }

    // Pick the first IPv4 entry.
    var p: UnsafeMutablePointer<addrinfo>? = list
    while let cur = p {
        if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
            var ipv4 = sa.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let _ = inet_ntop(AF_INET, &ipv4, &buf, socklen_t(INET_ADDRSTRLEN))
            let ipString = String(cString: buf)
            return ResolvedServer(spec: server, ipv4: ipv4, ipString: ipString)
        }
        p = cur.pointee.ai_next
    }

    throw ProbeError.dnsResolutionFailed("No IPv4 address for \(server.host)")
}

func setRecvTimeout(sock: Int32, timeoutMs: Int) throws {
    var tv = timeval(
        tv_sec: timeoutMs / 1000,
        tv_usec: Int32((timeoutMs % 1000) * 1000)
    )
    let rc = withUnsafePointer(to: &tv) { ptr in
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
    }
    guard rc == 0 else {
        throw ProbeError.socketFailed("setsockopt(SO_RCVTIMEO) failed: errno=\(errno)")
    }
}

func connectUDP(sock: Int32, server: ResolvedServer) throws {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = server.spec.port.bigEndian
    addr.sin_addr = server.ipv4
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else {
        throw ProbeError.connectFailed("connect(\(server.spec.host):\(server.spec.port)) failed: errno=\(errno)")
    }
}

func localEndpoint(sock: Int32) throws -> Endpoint {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            getsockname(sock, saPtr, &len)
        }
    }
    guard rc == 0 else { throw ProbeError.socketFailed("getsockname failed: errno=\(errno)") }
    var ipv4 = addr.sin_addr
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let _ = inet_ntop(AF_INET, &ipv4, &buf, socklen_t(INET_ADDRSTRLEN))
    let ipString = String(cString: buf)
    let port = UInt16(bigEndian: addr.sin_port)
    return Endpoint(ip: ipString, port: port)
}

func sendBindingAndReceive(sock: Int32) throws -> (mapped: Endpoint, rttMs: Double) {
    let tid = makeTransactionId()
    let msg = buildBindingRequest(transactionId: tid)

    let start = DispatchTime.now().uptimeNanoseconds
    let sent = msg.withUnsafeBytes { buf -> ssize_t in
        Darwin.send(sock, buf.baseAddress, buf.count, 0)
    }
    guard sent == msg.count else {
        throw ProbeError.sendFailed("send failed: errno=\(errno)")
    }

    var buffer = [UInt8](repeating: 0, count: 2048)
    let received = buffer.withUnsafeMutableBytes { buf -> ssize_t in
        Darwin.recv(sock, buf.baseAddress, buf.count, 0)
    }
    if received <= 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
            throw ProbeError.recvFailed("timeout")
        }
        throw ProbeError.recvFailed("recv failed: errno=\(errno)")
    }
    buffer.removeSubrange(Int(received)..<buffer.count)

    let end = DispatchTime.now().uptimeNanoseconds
    let rttMs = Double(end - start) / 1_000_000.0
    let mapped = try parseBindingResponse(buffer, expectedTransactionId: tid)
    return (mapped: mapped, rttMs: rttMs)
}

// MARK: - Stats helpers

func mean(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    return xs.reduce(0, +) / Double(xs.count)
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let sorted = xs.sorted()
    let clamped = max(0.0, min(1.0, p))
    let idx = Int((Double(sorted.count - 1)) * clamped)
    return sorted[idx]
}

func modeEndpoint(_ endpoints: [Endpoint]) -> (value: Endpoint?, uniqueCount: Int) {
    guard !endpoints.isEmpty else { return (nil, 0) }
    var counts: [Endpoint: Int] = [:]
    counts.reserveCapacity(endpoints.count)
    for e in endpoints { counts[e, default: 0] += 1 }
    let uniqueCount = counts.count
    let mode = counts.max { $0.value < $1.value }?.key
    return (mode, uniqueCount)
}

// MARK: - CSV

func csvEscape(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func writeCSV(path: String, header: String, rows: [String]) throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    var content = header + "\n"
    content.reserveCapacity(header.count + 1 + rows.reduce(0) { $0 + $1.count + 1 })
    for r in rows { content.append(r); content.append("\n") }
    try content.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Main

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func timestampForFilename() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

func stampForFilename(config: Config) -> String {
    // Prefer explicit CLI, then env, then timestamp.
    if let d = config.artifactDate, !d.isEmpty { return sanitizeLabel(d) }
    let env = ProcessInfo.processInfo.environment
    if let v = env["ARTIFACT_DATE"], !v.isEmpty { return sanitizeLabel(v) }
    if let v = env["SKYBRIDGE_ARTIFACT_DATE"], !v.isEmpty { return sanitizeLabel(v) }
    return timestampForFilename()
}

func classifyNAT(local: Endpoint, mappedByServer: [STUNServerSpec: Endpoint]) -> String {
    if mappedByServer.values.contains(local) {
        return "no_nat"
    }
    let mapped = Array(mappedByServer.values)
    guard mapped.count >= 2 else {
        return "unknown"
    }
    // Conservative: if mapping differs across destinations, it's symmetric (destination-dependent mapping).
    if Set(mapped).count > 1 {
        return "symmetric"
    }
    // Endpoint-independent mapping could still be restricted/port-restricted/full cone; avoid over-claiming.
    return "unknown"
}

do {
    let config = try parseArgs()
    let timestampISO = isoFormatter.string(from: Date())
    let stamp = stampForFilename(config: config)
    let label = config.label

    let outDir = config.outDir
    let samplesPath = "\(outDir)/realnet_stun_samples_\(stamp)_\(label).csv"
    let summaryPath = "\(outDir)/realnet_stun_summary_\(stamp)_\(label).csv"

    let pathSnap = capturePathSnapshot()

    var resolved: [ResolvedServer] = []
    resolved.reserveCapacity(config.servers.count)
    for s in config.servers {
        do {
            resolved.append(try resolveIPv4(s))
        } catch {
            fputs("[REALNET] Warning: \(error)\n", stderr)
        }
    }
    guard !resolved.isEmpty else { throw ProbeError.noSamples }

    let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard sock >= 0 else { throw ProbeError.socketFailed("socket failed: errno=\(errno)") }
    defer { Darwin.close(sock) }
    try setRecvTimeout(sock: sock, timeoutMs: config.timeoutMs)

    // Bind to ephemeral port early to keep a stable local port across all destination probes.
    var bindAddr = sockaddr_in()
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = 0
    bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
    let bindRC = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindRC == 0 else { throw ProbeError.socketFailed("bind failed: errno=\(errno)") }

    // Probe each server using the same socket / local port.
    var sampleRows: [SampleRow] = []
    sampleRows.reserveCapacity(resolved.count * config.samplesPerServer)

    var perServerRTT: [STUNServerSpec: [Double]] = [:]
    var perServerMapped: [STUNServerSpec: [Endpoint]] = [:]
    var mappedModeByServer: [STUNServerSpec: Endpoint] = [:]
    var mappedByServer: [STUNServerSpec: Endpoint] = [:]

    var local: Endpoint? = nil

    for server in resolved {
        try connectUDP(sock: sock, server: server)
        if local == nil {
            local = try localEndpoint(sock: sock)
        }

        var rtts: [Double] = []
        rtts.reserveCapacity(config.samplesPerServer)
        var mappedEndpoints: [Endpoint] = []
        mappedEndpoints.reserveCapacity(config.samplesPerServer)

        for idx in 0..<config.samplesPerServer {
            do {
                let (mapped, rttMs) = try sendBindingAndReceive(sock: sock)
                rtts.append(rttMs)
                mappedEndpoints.append(mapped)
                sampleRows.append(SampleRow(
                    timestampISO8601: timestampISO,
                    label: label,
                    serverHost: server.spec.host,
                    serverIP: server.ipString,
                    serverPort: server.spec.port,
                    sampleIndex: idx,
                    ok: true,
                    rttMs: rttMs,
                    mappedIP: mapped.ip,
                    mappedPort: mapped.port,
                    error: nil
                ))
            } catch {
                sampleRows.append(SampleRow(
                    timestampISO8601: timestampISO,
                    label: label,
                    serverHost: server.spec.host,
                    serverIP: server.ipString,
                    serverPort: server.spec.port,
                    sampleIndex: idx,
                    ok: false,
                    rttMs: nil,
                    mappedIP: nil,
                    mappedPort: nil,
                    error: String(describing: error)
                ))
            }
        }

        perServerRTT[server.spec] = rtts
        perServerMapped[server.spec] = mappedEndpoints

        let mode = modeEndpoint(mappedEndpoints)
        if let mappedMode = mode.value {
            mappedModeByServer[server.spec] = mappedMode
            mappedByServer[server.spec] = mappedMode
        }
    }

    guard let localEndpointValue = local else { throw ProbeError.noSamples }
    let natClass = classifyNAT(local: localEndpointValue, mappedByServer: mappedByServer)

    // Write samples CSV.
    let sampleHeader = [
        "timestamp",
        "label",
        "server_host",
        "server_ip",
        "server_port",
        "sample_index",
        "ok",
        "rtt_ms",
        "mapped_ip",
        "mapped_port",
        "error",
    ].joined(separator: ",")

    let sampleCSVRows = sampleRows.map { row in
        [
            csvEscape(row.timestampISO8601),
            csvEscape(row.label),
            csvEscape(row.serverHost),
            csvEscape(row.serverIP),
            String(row.serverPort),
            String(row.sampleIndex),
            row.ok ? "1" : "0",
            row.rttMs.map { String(format: "%.3f", $0) } ?? "",
            row.mappedIP.map(csvEscape) ?? "",
            row.mappedPort.map(String.init) ?? "",
            row.error.map(csvEscape) ?? "",
        ].joined(separator: ",")
    }
    try writeCSV(path: samplesPath, header: sampleHeader, rows: sampleCSVRows)

    // Write summary CSV (one row per server).
    let summaryHeader = [
        "timestamp",
        "label",
        "path_status",
        "path_interface_types",
        "path_is_expensive",
        "path_is_constrained",
        "local_ip",
        "local_port",
        "nat_classification",
        "server_host",
        "server_ip",
        "server_port",
        "mapped_mode",
        "mapped_unique_count",
        "samples",
        "ok_count",
        "loss_rate",
        "rtt_mean_ms",
        "rtt_p50_ms",
        "rtt_p95_ms",
        "rtt_p99_ms",
    ].joined(separator: ",")

    var summaryRows: [String] = []
    summaryRows.reserveCapacity(resolved.count)

    for server in resolved {
        let rtts = perServerRTT[server.spec] ?? []
        let mapped = perServerMapped[server.spec] ?? []
        let okCount = rtts.count
        let lossRate = 1.0 - (Double(okCount) / Double(config.samplesPerServer))
        let mode = modeEndpoint(mapped)
        let mappedMode = mode.value.map { "\($0.ip):\($0.port)" } ?? ""

        let summary = SummaryRow(
            timestampISO8601: timestampISO,
            label: label,
            pathStatus: pathSnap.status,
            pathInterfaceTypes: pathSnap.interfaceTypes,
            pathIsExpensive: pathSnap.isExpensive,
            pathIsConstrained: pathSnap.isConstrained,
            localIP: localEndpointValue.ip,
            localPort: localEndpointValue.port,
            natClassification: natClass,
            serverHost: server.spec.host,
            serverIP: server.ipString,
            serverPort: server.spec.port,
            mappedMode: mappedMode,
            mappedUniqueCount: mode.uniqueCount,
            samples: config.samplesPerServer,
            okCount: okCount,
            lossRate: lossRate,
            rttMeanMs: mean(rtts),
            rttP50Ms: percentile(rtts, 0.50),
            rttP95Ms: percentile(rtts, 0.95),
            rttP99Ms: percentile(rtts, 0.99)
        )

        summaryRows.append([
            csvEscape(summary.timestampISO8601),
            csvEscape(summary.label),
            csvEscape(summary.pathStatus),
            csvEscape(summary.pathInterfaceTypes),
            summary.pathIsExpensive ? "1" : "0",
            summary.pathIsConstrained ? "1" : "0",
            csvEscape(summary.localIP),
            String(summary.localPort),
            csvEscape(summary.natClassification),
            csvEscape(summary.serverHost),
            csvEscape(summary.serverIP),
            String(summary.serverPort),
            csvEscape(summary.mappedMode),
            String(summary.mappedUniqueCount),
            String(summary.samples),
            String(summary.okCount),
            String(format: "%.4f", summary.lossRate),
            summary.rttMeanMs.map { String(format: "%.3f", $0) } ?? "",
            summary.rttP50Ms.map { String(format: "%.3f", $0) } ?? "",
            summary.rttP95Ms.map { String(format: "%.3f", $0) } ?? "",
            summary.rttP99Ms.map { String(format: "%.3f", $0) } ?? "",
        ].joined(separator: ","))
    }
    try writeCSV(path: summaryPath, header: summaryHeader, rows: summaryRows)

    print("[REALNET] Path: status=\(pathSnap.status) types=\(pathSnap.interfaceTypes) expensive=\(pathSnap.isExpensive) constrained=\(pathSnap.isConstrained)")
    print("[REALNET] Local UDP endpoint: \(localEndpointValue.ip):\(localEndpointValue.port)")
    print("[REALNET] NAT classification (conservative): \(natClass)")
    print("[REALNET] Samples: \(samplesPath)")
    print("[REALNET] Summary: \(summaryPath)")
} catch {
    fputs("[REALNET] ERROR: \(error)\n", stderr)
    exit(1)
}
