//
// TrafficPaddingStats.swift
// SkyBridgeCompassiOS
//
// Phase C3 (TDSC): Quantify traffic-analysis mitigations
// - Record padding/unwrap events (per-label)
// - Flush to CSV for paper plots / evaluation
//

import Foundation

@available(iOS 17.0, *)
public actor TrafficPaddingStats {
    public static let shared = TrafficPaddingStats()

    private enum Submission: Sendable {
        case wrap(label: String, rawBytes: Int, paddedBytes: Int)
        case unwrap(label: String, totalBytes: Int, rawBytes: Int)
    }

    private final class AdmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedEnabled = false
        private var refreshAfterUptime: TimeInterval = 0

        func isEnabled(load: () -> Bool) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            return lock.withLock {
                if now >= refreshAfterUptime {
                    cachedEnabled = load()
                    refreshAfterUptime = now + 1
                }
                return cachedEnabled
            }
        }

        func invalidate() {
            lock.withLock { refreshAfterUptime = 0 }
        }
    }

    private final class SubmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumPendingEvents = 256
        private var pending: [Submission] = []
        private var drainScheduled = false

        func enqueue(_ event: Submission) {
            let shouldSchedule = lock.withLock { () -> Bool in
                if pending.count < maximumPendingEvents {
                    pending.append(event)
                }
                guard !drainScheduled, !pending.isEmpty else { return false }
                drainScheduled = true
                return true
            }
            guard shouldSchedule else { return }
            Task { await drain() }
        }

        private func drain() async {
            while let batch = nextBatch() {
                for event in batch {
                    switch event {
                    case .wrap(let label, let rawBytes, let paddedBytes):
                        await TrafficPaddingStats.shared.recordWrap(
                            label: label,
                            rawBytes: rawBytes,
                            paddedBytes: paddedBytes
                        )
                    case .unwrap(let label, let totalBytes, let rawBytes):
                        await TrafficPaddingStats.shared.recordUnwrap(
                            label: label,
                            totalBytes: totalBytes,
                            rawBytes: rawBytes
                        )
                    }
                }
            }
        }

        private func nextBatch() -> [Submission]? {
            lock.withLock {
                guard !pending.isEmpty else {
                    drainScheduled = false
                    return nil
                }
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                return batch
            }
        }

        func waitUntilDrained() async {
            while lock.withLock({ drainScheduled || !pending.isEmpty }) {
                await Task.yield()
            }
        }
    }

    private static let admissionGate = AdmissionGate()
    private static let submissionGate = SubmissionGate()

    public static func submitWrap(label: String, rawBytes: Int, paddedBytes: Int) {
        guard admissionGate.isEnabled(load: { Config.fromUserDefaults().enabled }) else {
            return
        }
        submissionGate.enqueue(
            .wrap(label: label, rawBytes: rawBytes, paddedBytes: paddedBytes)
        )
    }

    public static func submitUnwrap(label: String, totalBytes: Int, rawBytes: Int) {
        guard admissionGate.isEnabled(load: { Config.fromUserDefaults().enabled }) else {
            return
        }
        submissionGate.enqueue(
            .unwrap(label: label, totalBytes: totalBytes, rawBytes: rawBytes)
        )
    }

    public static func refreshSubmissionAdmission() {
        admissionGate.invalidate()
    }

    public static func waitForPendingSubmissions() async {
        await submissionGate.waitUntilDrained()
    }

    public struct LabelStats: Sendable {
        public var wraps: UInt64 = 0
        public var unwraps: UInt64 = 0
        public var rawBytes: UInt64 = 0
        public var paddedBytes: UInt64 = 0
        public var bucketCounts: [Int: UInt64] = [:] // padded size -> count
    }

    private var labels: [String: LabelStats] = [:]
    private var lastFlushAttemptAt: Date = .distantPast
    private var pendingEvents: Int = 0
    private var didPrintPathHint: Bool = false
    private static let maximumTrackedLabels = 64
    private static let maximumTrackedLabelLength = 64

    private init() {}

    public struct Config: Sendable {
        public let enabled: Bool
        public let autoFlushEnabled: Bool
        public let flushMinIntervalSeconds: TimeInterval
        public let flushEveryNEvents: Int

        public static func fromUserDefaults() -> Config {
            let defaults = UserDefaults.standard
            let group = UserDefaults(suiteName: "group.com.skybridge.compass")

            func bool(_ key: String) -> Bool { defaults.bool(forKey: key) || (group?.bool(forKey: key) ?? false) }
            func int(_ key: String) -> Int { max(defaults.integer(forKey: key), group?.integer(forKey: key) ?? 0) }
            func double(_ key: String) -> Double {
                let a = defaults.object(forKey: key) as? Double ?? 0
                let b = group?.object(forKey: key) as? Double ?? 0
                return max(a, b)
            }

            let enabled = bool("sb_traffic_padding_stats_enabled")
            let autoFlushEnabled = (defaults.object(forKey: "sb_traffic_padding_stats_autoflush") == nil && (group?.object(forKey: "sb_traffic_padding_stats_autoflush") == nil))
                ? true
                : bool("sb_traffic_padding_stats_autoflush")

            let minInterval = double("sb_traffic_padding_stats_flush_min_interval")
            let flushMinIntervalSeconds = (minInterval > 0) ? minInterval : 2.0

            let everyN = int("sb_traffic_padding_stats_flush_every_n")
            let flushEveryNEvents = (everyN > 0) ? everyN : 25

            return Config(
                enabled: enabled,
                autoFlushEnabled: autoFlushEnabled,
                flushMinIntervalSeconds: flushMinIntervalSeconds,
                flushEveryNEvents: flushEveryNEvents
            )
        }
    }

    public func recordWrap(label: String, rawBytes: Int, paddedBytes: Int) async {
        let cfg = Config.fromUserDefaults()
        guard cfg.enabled else { return }

        let label = boundedLabel(label)
        var st = labels[label] ?? LabelStats()
        st.wraps += 1
        st.rawBytes += UInt64(max(0, rawBytes))
        st.paddedBytes += UInt64(max(0, paddedBytes))
        st.bucketCounts[Self.byteCountBucket(paddedBytes), default: 0] += 1
        labels[label] = st

        pendingEvents += 1
        await maybeFlush(cfg: cfg)
    }

    public func recordUnwrap(label: String, totalBytes: Int, rawBytes: Int) async {
        let cfg = Config.fromUserDefaults()
        guard cfg.enabled else { return }

        let label = boundedLabel(label)
        var st = labels[label] ?? LabelStats()
        st.unwraps += 1
        st.rawBytes += UInt64(max(0, rawBytes))
        st.paddedBytes += UInt64(max(0, totalBytes))
        st.bucketCounts[Self.byteCountBucket(totalBytes), default: 0] += 1
        labels[label] = st

        pendingEvents += 1
        await maybeFlush(cfg: cfg)
    }

    private func boundedLabel(_ label: String) -> String {
        let truncated = String(label.prefix(Self.maximumTrackedLabelLength))
        let candidate = truncated.isEmpty ? "traffic" : truncated
        if labels[candidate] != nil {
            return candidate
        }
        if labels.count < Self.maximumTrackedLabels - 1 { return candidate }
        return "other"
    }

    private nonisolated static func byteCountBucket(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        var upperBound = 256
        let maximumBucket = 8 * 1_024 * 1_024
        while upperBound < byteCount, upperBound < maximumBucket {
            upperBound *= 2
        }
        return min(upperBound, maximumBucket)
    }

    private func maybeFlush(cfg: Config) async {
        guard cfg.autoFlushEnabled else { return }
        guard pendingEvents >= cfg.flushEveryNEvents else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFlushAttemptAt) >= cfg.flushMinIntervalSeconds else { return }
        lastFlushAttemptAt = now
        do {
            try await flushToCSV()
        } catch {
            // Keep pendingEvents intact; lastFlushAttemptAt bounds retries and error-log volume.
            let diagnostic = error as NSError
            SkyBridgeLogger.shared.error(
                "Traffic padding statistics flush failed: domain=\(diagnostic.domain) code=\(diagnostic.code)"
            )
        }
    }

    public func flushToCSV() async throws {
        let url = try csvURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !didPrintPathHint {
            didPrintPathHint = true
            print("🧪 TrafficPaddingStats CSV: \(url.path)")
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("timestamp,label,wraps,unwraps,raw_bytes,padded_bytes,overhead_bytes,overhead_ratio,bucket_sizes")

        let sorted = labels.sorted { $0.key < $1.key }
        for (label, st) in sorted {
            let overhead = Int64(st.paddedBytes) - Int64(st.rawBytes)
            let ratio = (st.rawBytes > 0) ? (Double(st.paddedBytes) / Double(st.rawBytes)) : 0.0
            let bucketStr = st.bucketCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: "|")
            lines.append([
                ts,
                csvEscape(label),
                "\(st.wraps)",
                "\(st.unwraps)",
                "\(st.rawBytes)",
                "\(st.paddedBytes)",
                "\(overhead)",
                String(format: "%.4f", ratio),
                csvEscape(bucketStr)
            ].joined(separator: ","))
        }

        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        try data.write(to: url, options: [.atomic])

        lastFlushAttemptAt = Date()
        pendingEvents = 0
    }

    private func csvURL() throws -> URL {
        let base = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("TrafficPaddingStats.csv", isDirectory: false)
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
