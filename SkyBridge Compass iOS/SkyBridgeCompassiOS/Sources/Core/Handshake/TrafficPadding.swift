//
// TrafficPadding.swift
// SkyBridgeCompassiOS
//
// Phase C2 (TDSC): Traffic analysis mitigations for post-handshake traffic
// - Optional padding of *all* framed/control payloads to bucketed / fixed sizes
// - Receiver unwraps before decode/decrypt
//

import Foundation

@available(iOS 17.0, *)
public enum TrafficPaddingMode: String, Sendable {
    case bucketed
    case fixed
}

@available(iOS 17.0, *)
public struct TrafficPaddingConfig: Sendable {
    public var enabled: Bool
    public var debugLog: Bool
    public var mode: TrafficPaddingMode
    public var fixedSizeBytes: Int
    public var bucketSizesBytes: [Int]

    public static func fromUserDefaults() -> TrafficPaddingConfig {
        let enabledKey = "sb_traffic_padding_enabled"
        let debugKey = "sb_traffic_padding_debug_log"
        let modeKey = "sb_traffic_padding_mode"
        let fixedKey = "sb_traffic_padding_fixed_size"

        let defaults = UserDefaults.standard
        let groupDefaults = UserDefaults(suiteName: "group.com.skybridge.compass")

        let envEnabled = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_ENABLED"] == "1")
        let envDebug = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_DEBUG_LOG"] == "1")

        let enabled = defaults.bool(forKey: enabledKey)
            || (groupDefaults?.bool(forKey: enabledKey) ?? false)
            || envEnabled

        let modeRaw = defaults.string(forKey: modeKey)
            ?? (groupDefaults?.string(forKey: modeKey))
            ?? TrafficPaddingMode.bucketed.rawValue
        let mode = TrafficPaddingMode(rawValue: modeRaw) ?? .bucketed

        let fixedSize = max(
            defaults.integer(forKey: fixedKey),
            groupDefaults?.integer(forKey: fixedKey) ?? 0
        )

        let debugLog = defaults.bool(forKey: debugKey)
            || (groupDefaults?.bool(forKey: debugKey) ?? false)
            || envDebug

        return TrafficPaddingConfig(
            enabled: enabled,
            debugLog: debugLog,
            mode: mode,
            fixedSizeBytes: fixedSize,
            bucketSizesBytes: [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
        )
    }
}

@available(iOS 17.0, *)
public enum TrafficPadding {
    // "SBP2"
    private static let magic: [UInt8] = [0x53, 0x42, 0x50, 0x32]
    private static let headerLen = 4 + 4 // magic + u32 actualLen

    private static let configLogLock = NSLock()
    private nonisolated(unsafe) static var didLogConfigHint = false
    private static let enterLogLock = NSLock()
    private nonisolated(unsafe) static var didPrintEnterWrap = false
    private nonisolated(unsafe) static var didPrintEnterUnwrap = false

    private static func logConfigHintOnceIfNeeded(cfg: TrafficPaddingConfig) {
        configLogLock.lock()
        defer { configLogLock.unlock() }
        guard !didLogConfigHint else { return }
        didLogConfigHint = true

        // Always print a single diagnostic line (stdout), to avoid chasing Xcode/OSLog filters.
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let envEnabled = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_ENABLED"] == "1")
        let envDebug = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_DEBUG_LOG"] == "1")

        let defaults = UserDefaults.standard
        let group = UserDefaults(suiteName: "group.com.skybridge.compass")
        func obj(_ ud: UserDefaults?, _ key: String) -> String {
            guard let ud else { return "nil-suite" }
            if ud.object(forKey: key) == nil { return "nil" }
            return String(describing: ud.object(forKey: key)!)
        }

        let diag =
            "🧪 TrafficPadding DIAG bundle=\(bundleId) " +
            "cfg(enabled=\(cfg.enabled) debug=\(cfg.debugLog) mode=\(cfg.mode.rawValue) fixed=\(cfg.fixedSizeBytes)) " +
            "env(enabled=\(envEnabled) debug=\(envDebug)) " +
            "standard(enabled=\(obj(defaults, "sb_traffic_padding_enabled")) debug=\(obj(defaults, "sb_traffic_padding_debug_log"))) " +
            "group(enabled=\(obj(group, "sb_traffic_padding_enabled")) debug=\(obj(group, "sb_traffic_padding_debug_log")))"

        print(diag)
        SkyBridgeLogger.shared.info(diag)
    }

    public static func wrapIfEnabled(_ payload: Data, label: String? = nil) -> Data {
        enterLogLock.lock()
        if !didPrintEnterWrap {
            didPrintEnterWrap = true
            print("🧪 ENTER TrafficPadding.wrapIfEnabled label=\(label ?? "traffic") bytes=\(payload.count)")
        }
        enterLogLock.unlock()

        let cfg = TrafficPaddingConfig.fromUserDefaults()
        logConfigHintOnceIfNeeded(cfg: cfg)
        guard cfg.enabled else { return payload }

        let minLen = headerLen + payload.count
        let targetLen: Int
        switch cfg.mode {
        case .fixed:
            targetLen = max(minLen, cfg.fixedSizeBytes > 0 ? cfg.fixedSizeBytes : minLen)
        case .bucketed:
            targetLen = cfg.bucketSizesBytes.first(where: { $0 >= minLen }) ?? minLen
        }

        let out = wrap(payload: payload, totalLen: max(minLen, targetLen))

        if cfg.debugLog {
            let name = label ?? "traffic"
            let msg = "🧪 TrafficPadding[\(name)]: raw=\(payload.count)B -> padded=\(out.count)B (mode=\(cfg.mode.rawValue))"
            SkyBridgeLogger.shared.info(msg)
            print(msg)
        }

        // Phase C3: stats (best-effort, non-blocking)
        Task { await TrafficPaddingStats.shared.recordWrap(label: label ?? "traffic", rawBytes: payload.count, paddedBytes: out.count) }

        return out
    }

    public static func unwrapIfNeeded(_ data: Data, label: String? = nil) -> Data {
        guard data.count >= headerLen else { return data }
        guard data.prefix(4).elementsEqual(magic) else { return data }

        enterLogLock.lock()
        if !didPrintEnterUnwrap {
            didPrintEnterUnwrap = true
            print("🧪 ENTER TrafficPadding.unwrapIfNeeded label=\(label ?? "traffic") bytes=\(data.count)")
        }
        enterLogLock.unlock()

        let cfg = TrafficPaddingConfig.fromUserDefaults()
        logConfigHintOnceIfNeeded(cfg: cfg)

        let len = data.withUnsafeBytes { raw -> UInt32 in
            let base = raw.baseAddress!.advanced(by: 4)
            return base.load(as: UInt32.self).bigEndian
        }

        let actualLen = Int(len)
        guard actualLen >= 0, actualLen <= data.count - headerLen else { return data }
        let payload = data.subdata(in: headerLen..<(headerLen + actualLen))

        if cfg.debugLog {
            let name = label ?? "traffic"
            let msg = "🧪 TrafficUnwrap[\(name)]: total=\(data.count)B -> raw=\(payload.count)B"
            SkyBridgeLogger.shared.info(msg)
            print(msg)
        }

        // Phase C3: stats (best-effort, non-blocking)
        Task { await TrafficPaddingStats.shared.recordUnwrap(label: label ?? "traffic", totalBytes: data.count, rawBytes: payload.count) }

        return payload
    }

    private static func wrap(payload: Data, totalLen: Int) -> Data {
        var out = Data()
        out.reserveCapacity(totalLen)
        out.append(contentsOf: magic)
        var lenBE = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &lenBE, count: 4))
        out.append(payload)

        let padCount = max(0, totalLen - out.count)
        if padCount > 0 {
            out.append(randomBytes(count: padCount))
        }
        return out
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}


