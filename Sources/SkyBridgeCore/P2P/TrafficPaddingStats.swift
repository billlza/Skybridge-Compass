//
// TrafficPaddingStats.swift
// SkyBridgeCore
//
// Phase C3 (TDSC): Quantify traffic-analysis mitigations
// - Record padding/unwrap events (per-label)
// - Flush to CSV for paper plots / evaluation
//

import Foundation

@available(macOS 14.0, iOS 17.0, *)
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

    // MARK: - Snapshot / Reset (for sensitivity experiments)

    /// Return a stable snapshot of current per-label statistics.
    public func snapshot() -> [String: LabelStats] {
        labels
    }

    /// Reset all collected stats (used by sensitivity study to run multiple policies in one process).
    public func reset() {
        labels.removeAll()
        pendingEvents = 0
        lastFlushAt = .distantPast
        // Keep didPrintPathHint as-is to avoid spam in normal runs.
    }

    // MARK: - Config

    public struct Config: Sendable {
        public let enabled: Bool
        public let autoFlushEnabled: Bool
        public let flushMinIntervalSeconds: TimeInterval
        public let flushEveryNEvents: Int

        public init(
            enabled: Bool,
            autoFlushEnabled: Bool,
            flushMinIntervalSeconds: TimeInterval,
            flushEveryNEvents: Int
        ) {
            self.enabled = enabled
            self.autoFlushEnabled = autoFlushEnabled
            self.flushMinIntervalSeconds = flushMinIntervalSeconds
            self.flushEveryNEvents = flushEveryNEvents
        }

        public static func fromUserDefaults() -> Config {
            let defaults = UserDefaults.standard
            let group = UserDefaults(suiteName: "group.com.skybridge.compass")

            func bool(_ key: String) -> Bool {
                defaults.bool(forKey: key) || (group?.bool(forKey: key) ?? false)
            }
            func int(_ key: String) -> Int {
                max(defaults.integer(forKey: key), group?.integer(forKey: key) ?? 0)
            }
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

    // MARK: - Record

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

    // MARK: - Flush

    private func maybeFlush(cfg: Config) async {
        guard cfg.autoFlushEnabled else { return }
        guard pendingEvents >= cfg.flushEveryNEvents else { return }
        guard Date().timeIntervalSince(lastFlushAt) >= cfg.flushMinIntervalSeconds else { return }
        do {
            try await flushToCSV()
        } catch {
            // avoid throwing from hot path; best-effort only
        }
    }

    public func flushToCSV() async throws {
        let url = try csvURL()
        try flush(to: url, printHintOnce: true, hintPrefix: "🧪 TrafficPaddingStats CSV")
    }

    /// Flush a copy into the repo-local `Artifacts/` folder (paper reproducibility pipeline).
    ///
    /// Output: `Artifacts/traffic_padding_YYYY-MM-DD.csv`
    /// This is intentionally aligned with other bench artifacts so `Scripts/make_tables.py`
    /// can select the latest file by prefix.
    public func flushToArtifactsCSV() async throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        // To avoid mixing datasets across dates (paper reproducibility), allow overriding the date suffix.
        // Use `ARTIFACT_DATE=YYYY-MM-DD` (or `SKYBRIDGE_ARTIFACT_DATE`) when running benches.
        let dateString: String = {
            if let v = ProcessInfo.processInfo.environment["ARTIFACT_DATE"], !v.isEmpty { return v }
            if let v = ProcessInfo.processInfo.environment["SKYBRIDGE_ARTIFACT_DATE"], !v.isEmpty { return v }
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            return dateFormatter.string(from: Date())
        }()

        let url = artifactsDir.appendingPathComponent("traffic_padding_\(dateString).csv")
        try flush(to: url, printHintOnce: false, hintPrefix: "🧪 TrafficPaddingStats Artifacts")
    }

    // MARK: - Internal flush helper

    private func flush(to url: URL, printHintOnce: Bool, hintPrefix: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if printHintOnce && !didPrintPathHint {
            didPrintPathHint = true
            print("\(hintPrefix): \(url.path)")
        } else if !printHintOnce {
            print("\(hintPrefix): \(url.path)")
        }

        let data = buildCSVSnapshot().data(using: .utf8) ?? Data()
        try data.write(to: url, options: [.atomic])

        lastFlushAt = Date()
        pendingEvents = 0
    }

    private func buildCSVSnapshot() -> String {
        // Build CSV snapshot
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

        return lines.joined(separator: "\n") + "\n"
    }

    private func csvURL() throws -> URL {
        let fm = FileManager.default
        #if os(iOS)
        let base = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
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


