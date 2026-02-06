import SwiftUI
import Network
import os

// MARK: - Real-network E2E networking (non-MainActor helper)

fileprivate func _realnetNsToMs(_ ns: UInt64?) -> Double? {
    guard let ns else { return nil }
    return Double(ns) / 1_000_000.0
}

fileprivate func _realnetFormatEndpoint(host: String, port: UInt16) -> String {
    // For IPv6 literals, use RFC 3986 bracket form to avoid ambiguity in CSV.
    // E.g., "[2409:...:4e09]:44444"
    if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) {
        return "[\(host)]:\(port)"
    }
    return "\(host):\(port)"
}

fileprivate struct RealNetE2EOneSampleResult: Sendable {
    let ok: Bool
    let connectMs: Double?
    let firstByteMs: Double?
    let totalMs: Double?
    let errorCode: String?
    let errorDetail: String?
}

fileprivate final class RealNetE2EState: @unchecked Sendable {
    struct Inner {
        var finished = false
        var cont: CheckedContinuation<RealNetE2EOneSampleResult, Never>?

        var connectNs: UInt64?
        var firstByteNs: UInt64?
        var totalNs: UInt64?
        var received = 0

        var ok = false
        var errCode: String?
        var errDetail: String?
    }

    private let lock: OSAllocatedUnfairLock<Inner>

    init(cont: CheckedContinuation<RealNetE2EOneSampleResult, Never>) {
        self.lock = OSAllocatedUnfairLock(initialState: Inner(cont: cont))
    }

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

    func isFinished() -> Bool {
        lock.withLock { $0.finished }
    }

    func markTotalAndOk(startNs: UInt64, ok: Bool) {
        lock.withLock { s in
            s.totalNs = DispatchTime.now().uptimeNanoseconds - startNs
            s.ok = ok
        }
    }

    func finish(code: String?, detail: String?) {
        let resume: (RealNetE2EOneSampleResult, CheckedContinuation<RealNetE2EOneSampleResult, Never>)? = lock.withLock { s in
            if s.finished { return nil }
            s.finished = true
            if let code { s.errCode = code }
            if let detail { s.errDetail = detail }

            let out = RealNetE2EOneSampleResult(
                ok: s.ok,
                connectMs: _realnetNsToMs(s.connectNs),
                firstByteMs: _realnetNsToMs(s.firstByteNs),
                totalMs: _realnetNsToMs(s.totalNs),
                errorCode: s.errCode,
                errorDetail: s.errDetail
            )
            guard let cont = s.cont else { return nil }
            s.cont = nil
            return (out, cont)
        }

        if let (out, cont) = resume {
            cont.resume(returning: out)
        }
    }
}

fileprivate func realnetOneClientSample(host: String, port: UInt16, payloadBytes: Int, timeoutMs: Int, idx: Int) async -> RealNetE2EOneSampleResult {
    let startNs = DispatchTime.now().uptimeNanoseconds
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

    return await withCheckedContinuation { cont in
        let state = RealNetE2EState(cont: cont)

        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                state.markConnected(startNs: startNs)

                // Request = 4B length prefix + payload
                var prefix = withUnsafeBytes(of: UInt32(payloadBytes).bigEndian) { Data($0) }
                prefix.append(Data(repeating: 0x5A, count: payloadBytes))

                conn.send(content: prefix, completion: .contentProcessed { sendErr in
                    if let sendErr {
                        state.markTotalAndOk(startNs: startNs, ok: false)
                        conn.cancel()
                        state.finish(code: "send_failed", detail: "\(sendErr)")
                        return
                    }

                    // Two-step receive (avoids recursion + Sendable warnings):
                    // 1) read 1 byte to measure TTFB
                    // 2) read the remaining bytes in one shot
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, recvErr in
                        if let recvErr {
                            state.markTotalAndOk(startNs: startNs, ok: false)
                            conn.cancel()
                            state.finish(code: "recv_failed", detail: "\(recvErr)")
                            return
                        }

                        if let data, !data.isEmpty {
                            state.noteFirstByteIfNeeded(startNs: startNs)
                            state.addReceived(data.count)
                        }

                        let got1 = state.received()
                        if got1 >= payloadBytes || isComplete {
                            let ok = (got1 >= payloadBytes)
                            state.markTotalAndOk(startNs: startNs, ok: ok)
                            conn.cancel()
                            if ok {
                                state.finish(code: nil, detail: nil)
                            } else {
                                state.finish(code: "short_read", detail: "received=\(got1) expected=\(payloadBytes)")
                            }
                            return
                        }

                        let remaining = payloadBytes - got1
                        conn.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data2, _, isComplete2, recvErr2 in
                            if let recvErr2 {
                                state.markTotalAndOk(startNs: startNs, ok: false)
                                conn.cancel()
                                state.finish(code: "recv_failed", detail: "\(recvErr2)")
                                return
                            }
                            if let data2, !data2.isEmpty {
                                state.addReceived(data2.count)
                            }

                            let got = state.received()
                            let ok = (got >= payloadBytes)
                            state.markTotalAndOk(startNs: startNs, ok: ok)
                            conn.cancel()
                            if ok {
                                state.finish(code: nil, detail: nil)
                            } else {
                                state.finish(code: "short_read", detail: "received=\(got) expected=\(payloadBytes) isComplete=\(isComplete2)")
                            }
                        }
                    }
                })

            case .failed(let e):
                state.markTotalAndOk(startNs: startNs, ok: false)
                conn.cancel()
                state.finish(code: "connect_failed", detail: "\(e)")
            default:
                break
            }
        }

        conn.start(queue: .global())

        // timeout guard
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            if state.isFinished() { return }
            state.markTotalAndOk(startNs: startNs, ok: false)
            conn.cancel()
            state.finish(code: "timeout", detail: "timeout_ms=\(timeoutMs)")
        }
    }
}

/// Real-network end-to-end micro-study client (iOS/iPadOS).
/// Connects to a macOS server and measures connect/first-byte/total time for
/// two payload sizes: Classic (827 B) vs PQC (12,163 B).
@available(iOS 17.0, *)
struct RealNetworkE2EBenchView: View {
    @State private var label: String = "home_wifi"
    @State private var serverHost: String = "10.0.0.8"
    @State private var serverPort: String = "44444"
    @State private var artifactDate: String = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }()
    @State private var samples: String = "50"
    @State private var timeoutMs: String = "4000"

    @State private var isRunning: Bool = false
    @State private var progressText: String = ""
    @State private var lastError: String? = nil

    @State private var samplesFileURL: URL? = nil
    @State private var summaryFileURL: URL? = nil

    // Fixed payload sizes (paper-aligned)
    private let payloads: [Int] = [827, 12_163]

    var body: some View {
        List {
            Section("配置") {
                TextField("Label（如 home_wifi / phone_hotspot）", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("ARTIFACT_DATE（YYYY-MM-DD）", text: $artifactDate)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Server IP", text: $serverHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Port", text: $serverPort)
                    .keyboardType(.numberPad)

                TextField("Samples（每个 payload）", text: $samples)
                    .keyboardType(.numberPad)

                TextField("Timeout (ms)", text: $timeoutMs)
                    .keyboardType(.numberPad)

                HStack {
                    Text("Payload sizes")
                    Spacer()
                    Text("827 B / 12,163 B")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Section("运行") {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if isRunning { ProgressView().padding(.trailing, 8) }
                        Text(isRunning ? "运行中…" : "开始测试")
                    }
                }
                .disabled(isRunning)

                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            Section("导出") {
                if let samplesFileURL {
                    ShareLink(item: samplesFileURL) {
                        Label("导出 samples CSV", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("samples CSV：未生成")
                        .foregroundColor(.secondary)
                }

                if let summaryFileURL {
                    ShareLink(item: summaryFileURL) {
                        Label("导出 summary CSV", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("summary CSV：未生成")
                        .foregroundColor(.secondary)
                }

                Text("建议通过 AirDrop 导出到 Mac，并放入仓库的 Artifacts/ 目录，再运行 python3 Scripts/aggregate_realnet.py 生成 Supplementary 表。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("RealNet E2E")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Run

    private func run() async {
        lastError = nil
        samplesFileURL = nil
        summaryFileURL = nil
        progressText = ""
        isRunning = true
        defer { isRunning = false }

        let lbl = sanitize(label)
        guard let port = UInt16(serverPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            lastError = "Invalid port"
            return
        }
        guard let nSamples = Int(samples.trimmingCharacters(in: .whitespacesAndNewlines)), nSamples > 0 else {
            lastError = "Invalid samples"
            return
        }
        guard let toMs = Int(timeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)), toMs >= 50 else {
            lastError = "Invalid timeout"
            return
        }

        let stamp = sanitize(artifactDate)
        let remote = _realnetFormatEndpoint(host: serverHost, port: port)

        var allSamples: [SampleRow] = []
        allSamples.reserveCapacity(payloads.count * nSamples)

        var summaryRows: [SummaryRow] = []
        summaryRows.reserveCapacity(payloads.count)

        for payload in payloads {
            progressText = "payload=\(payload)B, running \(nSamples) samples…"
            var rows: [SampleRow] = []
            rows.reserveCapacity(nSamples)

            for i in 0..<nSamples {
                let s = await oneClientSample(host: serverHost, port: port, payloadBytes: payload, timeoutMs: toMs, idx: i)
                let row = SampleRow(
                    stamp: stamp,
                    label: lbl,
                    remote: remote,
                    payloadBytes: payload,
                    idx: i,
                    ok: s.ok,
                    connectMs: s.connectMs,
                    firstByteMs: s.firstByteMs,
                    totalMs: s.totalMs,
                    errorCode: s.errorCode,
                    errorDetail: s.errorDetail
                )
                rows.append(row)
                allSamples.append(row)
                if (i + 1) % max(1, min(10, nSamples)) == 0 {
                    progressText = "payload=\(payload)B, progress \(i+1)/\(nSamples)"
                }
            }

            summaryRows.append(SummaryRow.from(samples: rows, stamp: stamp, label: lbl, remote: remote, payloadBytes: payload))
        }

        do {
            let (samplesURL, summaryURL) = try writeArtifacts(stamp: stamp, label: lbl, samples: allSamples, summaries: summaryRows)
            samplesFileURL = samplesURL
            summaryFileURL = summaryURL
            progressText = "完成：已生成 CSV，可导出"
        } catch {
            lastError = "Write CSV failed: \(error.localizedDescription)"
        }
    }

    // MARK: - CSV

    private func writeArtifacts(stamp: String, label: String, samples: [SampleRow], summaries: [SummaryRow]) throws -> (URL, URL) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let samplesURL = dir.appendingPathComponent("realnet_e2e_samples_\(stamp)_\(label).csv")
        let summaryURL = dir.appendingPathComponent("realnet_e2e_summary_\(stamp)_\(label).csv")

        var lines: [String] = []
        lines.reserveCapacity(samples.count + 1)
        lines.append("stamp,label,remote,payload_bytes,idx,ok,connect_ms,first_byte_ms,total_ms,error_code,error_detail")
        for r in samples {
            lines.append(r.csvRow)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: samplesURL, atomically: true, encoding: .utf8)

        var sLines: [String] = []
        sLines.reserveCapacity(summaries.count + 1)
        sLines.append("stamp,label,remote,payload_bytes,samples,ok_count,ok_rate,timeout_count,timeout_rate,connect_failed_count,recv_failed_count,short_read_count,connect_mean_ms,connect_p50_ms,connect_p95_ms,first_mean_ms,first_p50_ms,first_p95_ms,total_mean_ms,total_p50_ms,total_p95_ms")
        for r in summaries {
            sLines.append(r.csvRow)
        }
        try (sLines.joined(separator: "\n") + "\n").write(to: summaryURL, atomically: true, encoding: .utf8)

        return (samplesURL, summaryURL)
    }

    // MARK: - Networking
    private typealias OneSampleResult = RealNetE2EOneSampleResult

    private func oneClientSample(host: String, port: UInt16, payloadBytes: Int, timeoutMs: Int, idx: Int) async -> OneSampleResult {
        await realnetOneClientSample(host: host, port: port, payloadBytes: payloadBytes, timeoutMs: timeoutMs, idx: idx)
    }

    // MARK: - Types

    private struct SampleRow: Sendable {
        let stamp: String
        let label: String
        let remote: String
        let payloadBytes: Int
        let idx: Int
        let ok: Bool
        let connectMs: Double?
        let firstByteMs: Double?
        let totalMs: Double?
        let errorCode: String?
        let errorDetail: String?

        var csvRow: String {
            [
                stamp,
                label,
                remote,
                "\(payloadBytes)",
                "\(idx)",
                ok ? "1" : "0",
                RealNetworkE2EBenchView.fmt(connectMs),
                RealNetworkE2EBenchView.fmt(firstByteMs),
                RealNetworkE2EBenchView.fmt(totalMs),
                errorCode ?? "",
                (errorDetail ?? "").replacingOccurrences(of: ",", with: ";")
            ].joined(separator: ",")
        }
    }

    private struct SummaryRow: Sendable {
        let stamp: String
        let label: String
        let remote: String
        let payloadBytes: Int
        let samples: Int
        let okCount: Int
        let okRate: Double
        let timeoutCount: Int
        let timeoutRate: Double
        let connectFailedCount: Int
        let recvFailedCount: Int
        let shortReadCount: Int
        let connectMean: Double?
        let connectP50: Double?
        let connectP95: Double?
        let firstMean: Double?
        let firstP50: Double?
        let firstP95: Double?
        let totalMean: Double?
        let totalP50: Double?
        let totalP95: Double?

        static func from(samples rows: [SampleRow], stamp: String, label: String, remote: String, payloadBytes: Int) -> SummaryRow {
            let okRows = rows.filter { $0.ok }
            let okCount = okRows.count
            let okRate = Double(okCount) / Double(max(1, rows.count))
            let timeoutCount = rows.filter { $0.errorCode == "timeout" }.count
            let timeoutRate = Double(timeoutCount) / Double(max(1, rows.count))
            let connectFailedCount = rows.filter { $0.errorCode == "connect_failed" }.count
            let recvFailedCount = rows.filter { $0.errorCode == "recv_failed" }.count
            let shortReadCount = rows.filter { $0.errorCode == "short_read" }.count

            let connect = okRows.compactMap { $0.connectMs }
            let first = okRows.compactMap { $0.firstByteMs }
            let total = okRows.compactMap { $0.totalMs }

            return SummaryRow(
                stamp: stamp,
                label: label,
                remote: remote,
                payloadBytes: payloadBytes,
                samples: rows.count,
                okCount: okCount,
                okRate: okRate,
                timeoutCount: timeoutCount,
                timeoutRate: timeoutRate,
                connectFailedCount: connectFailedCount,
                recvFailedCount: recvFailedCount,
                shortReadCount: shortReadCount,
                connectMean: RealNetworkE2EBenchView.mean(connect),
                connectP50: RealNetworkE2EBenchView.percentile(connect, 0.50),
                connectP95: RealNetworkE2EBenchView.percentile(connect, 0.95),
                firstMean: RealNetworkE2EBenchView.mean(first),
                firstP50: RealNetworkE2EBenchView.percentile(first, 0.50),
                firstP95: RealNetworkE2EBenchView.percentile(first, 0.95),
                totalMean: RealNetworkE2EBenchView.mean(total),
                totalP50: RealNetworkE2EBenchView.percentile(total, 0.50),
                totalP95: RealNetworkE2EBenchView.percentile(total, 0.95)
            )
        }

        var csvRow: String {
            [
                stamp, label, remote, "\(payloadBytes)",
                "\(samples)", "\(okCount)", String(format: "%.4f", okRate),
                "\(timeoutCount)", String(format: "%.4f", timeoutRate),
                "\(connectFailedCount)", "\(recvFailedCount)", "\(shortReadCount)",
                RealNetworkE2EBenchView.fmt(connectMean), RealNetworkE2EBenchView.fmt(connectP50), RealNetworkE2EBenchView.fmt(connectP95),
                RealNetworkE2EBenchView.fmt(firstMean), RealNetworkE2EBenchView.fmt(firstP50), RealNetworkE2EBenchView.fmt(firstP95),
                RealNetworkE2EBenchView.fmt(totalMean), RealNetworkE2EBenchView.fmt(totalP50), RealNetworkE2EBenchView.fmt(totalP95)
            ].joined(separator: ",")
        }
    }

    private func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "run" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped.prefix(64))
    }

    nonisolated private static func fmt(_ x: Double?) -> String {
        guard let x else { return "" }
        return String(format: "%.3f", x)
    }

    nonisolated private static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    nonisolated private static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let idx = Int(Double(s.count - 1) * p)
        return s[max(0, min(idx, s.count - 1))]
    }
}

