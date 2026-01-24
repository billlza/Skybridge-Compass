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

    public struct LabelStats: Sendable {
        public var wraps: UInt64 = 0
        public var unwraps: UInt64 = 0
        public var rawBytes: UInt64 = 0
        public var paddedBytes: UInt64 = 0
        public var bucketCounts: [Int: UInt64] = [:] // padded size -> count
    }

    private var labels: [String: LabelStats] = [:]
    private var lastFlushAt: Date = .distantPast
    private var pendingEvents: Int = 0
    private var didPrintPathHint: Bool = false

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

        var st = labels[label] ?? LabelStats()
        st.wraps += 1
        st.rawBytes += UInt64(max(0, rawBytes))
        st.paddedBytes += UInt64(max(0, paddedBytes))
        st.bucketCounts[paddedBytes, default: 0] += 1
        labels[label] = st

        pendingEvents += 1
        await maybeFlush(cfg: cfg)
    }

    public func recordUnwrap(label: String, totalBytes: Int, rawBytes: Int) async {
        let cfg = Config.fromUserDefaults()
        guard cfg.enabled else { return }

        var st = labels[label] ?? LabelStats()
        st.unwraps += 1
        st.rawBytes += UInt64(max(0, rawBytes))
        st.paddedBytes += UInt64(max(0, totalBytes))
        st.bucketCounts[totalBytes, default: 0] += 1
        labels[label] = st

        pendingEvents += 1
        await maybeFlush(cfg: cfg)
    }

    private func maybeFlush(cfg: Config) async {
        guard cfg.autoFlushEnabled else { return }
        guard pendingEvents >= cfg.flushEveryNEvents else { return }
        guard Date().timeIntervalSince(lastFlushAt) >= cfg.flushMinIntervalSeconds else { return }
        do { try await flushToCSV() } catch { }
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

        lastFlushAt = Date()
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


