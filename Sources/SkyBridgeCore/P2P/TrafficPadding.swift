//
// TrafficPadding.swift
// SkyBridgeCore
//
// Phase C2 (TDSC): Traffic analysis mitigations for post-handshake traffic
// - Optional padding of *all* framed/control payloads to bucketed / fixed sizes
// - Receiver unwraps before decode/decrypt
//

import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
public enum TrafficPaddingMode: String, Sendable {
    case bucketed
    case fixed
}

@available(macOS 14.0, iOS 17.0, *)
public struct TrafficPaddingConfig: Sendable {
    public var enabled: Bool
    public var debugLog: Bool
    public var mode: TrafficPaddingMode
    public var fixedSizeBytes: Int
    public var bucketSizesBytes: [Int]

    public init(
        enabled: Bool,
        debugLog: Bool,
        mode: TrafficPaddingMode,
        fixedSizeBytes: Int,
        bucketSizesBytes: [Int]
    ) {
        self.enabled = enabled
        self.debugLog = debugLog
        self.mode = mode
        self.fixedSizeBytes = fixedSizeBytes
        self.bucketSizesBytes = bucketSizesBytes
    }

    public static func fromUserDefaults() -> TrafficPaddingConfig {
        let enabledKey = "sb_traffic_padding_enabled"
        let debugKey = "sb_traffic_padding_debug_log"
        let modeKey = "sb_traffic_padding_mode"
        let fixedKey = "sb_traffic_padding_fixed_size"
        let bucketCapKey = "sb_traffic_padding_bucket_cap_bytes"

        let defaults = UserDefaults.standard
        let groupDefaults = UserDefaults(suiteName: "group.com.skybridge.compass")

        let envEnabled = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_ENABLED"] == "1")
        let envDebug = (ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_DEBUG_LOG"] == "1")
        let envCapBytes = Int(ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_BUCKET_CAP_BYTES"] ?? "")
        let envCapKiB = Int(ProcessInfo.processInfo.environment["SB_TRAFFIC_PADDING_BUCKET_CAP_KIB"] ?? "")

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

        // Bucket cap (sensitivity study): default 64KiB; allow override to 128KiB / 256KiB.
        // If payload exceeds the cap, bucketed mode becomes "no further padding" (privacy/overhead tradeoff).
        let capFromUD = max(
            defaults.integer(forKey: bucketCapKey),
            groupDefaults?.integer(forKey: bucketCapKey) ?? 0
        )
        // Normalize before multiplying so an extreme environment value cannot
        // overflow Int. Values above the documented 1 MiB ceiling are
        // deliberately saturated to that ceiling.
        let normalizedEnvCapKiB = min(max(envCapKiB ?? 0, 0), 1_024)
        let capFromEnv = max(envCapBytes ?? 0, normalizedEnvCapKiB * 1_024)
        let cap = max(256, max(capFromUD, capFromEnv, 65536))
        let capClamped = min(cap, 1024 * 1024) // hard ceiling: 1 MiB to prevent accidental blowups

        // Generate power-of-two buckets up to cap.
        var buckets: [Int] = []
        var s = 256
        while s < capClamped {
            buckets.append(s)
            s *= 2
        }
        buckets.append(max(s, capClamped))

        return TrafficPaddingConfig(
            enabled: enabled,
            debugLog: debugLog,
            mode: mode,
            fixedSizeBytes: fixedSize,
            bucketSizesBytes: buckets
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum TrafficPadding {
    // "SBP2"
    private static let magic: [UInt8] = [0x53, 0x42, 0x50, 0x32]
    private static let headerLen = 4 + 4 // magic + u32 actualLen
    /// Matches the existing WebRTC receive-frame ceiling on both platforms.
    /// Callers must never emit a padded payload that its peer will reject.
    public static let maximumWebRTCOutputByteCount =
        WebRTCFramedPayloadPolicy.maximumPayloadByteCount

    private static let configLogLock = NSLock()
    private nonisolated(unsafe) static var didLogConfigHint = false
    private static let enterLogLock = NSLock()
    private nonisolated(unsafe) static var didPrintEnterWrap = false
    private nonisolated(unsafe) static var didPrintEnterUnwrap = false

    private static func shouldEmitDiagnostics(cfg: TrafficPaddingConfig) -> Bool {
        // Default OFF (especially for Release): this was too noisy and hid real security/connection events.
        // Enable explicitly via either:
        // - SB_TRAFFIC_PADDING_DEBUG_LOG=1 (existing)
        // - SKYBRIDGE_LOG_TRAFFIC_PADDING=1 (new umbrella switch)
        let envDiag = (ProcessInfo.processInfo.environment["SKYBRIDGE_LOG_TRAFFIC_PADDING"] == "1")
        return cfg.debugLog || envDiag
    }

    private static func logConfigHintOnceIfNeeded(cfg: TrafficPaddingConfig) {
        configLogLock.lock()
        defer { configLogLock.unlock() }
        guard !didLogConfigHint else { return }
        didLogConfigHint = true

        // Only emit diagnostics when explicitly enabled.
        guard shouldEmitDiagnostics(cfg: cfg) else { return }

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

        SkyBridgeLogger.p2p.info("\(diag, privacy: .public)")

        if !cfg.enabled {
            let hint = "🧪 Enable SBP2: defaults write group.com.skybridge.compass sb_traffic_padding_enabled -bool true  (or env SB_TRAFFIC_PADDING_ENABLED=1)"
            SkyBridgeLogger.p2p.info("\(hint, privacy: .public)")
        }
    }

    public static func wrapIfEnabled(
        _ payload: Data,
        label: String? = nil,
        maximumOutputByteCount: Int = maximumWebRTCOutputByteCount
    ) throws -> Data {
        let cfg = TrafficPaddingConfig.fromUserDefaults()
        if shouldEmitDiagnostics(cfg: cfg) {
            enterLogLock.lock()
            if !didPrintEnterWrap {
                didPrintEnterWrap = true
                SkyBridgeLogger.p2p.info("🧪 ENTER TrafficPadding.wrapIfEnabled label=\(label ?? "traffic", privacy: .public) bytes=\(payload.count, privacy: .public)")
            }
            enterLogLock.unlock()
        }
        logConfigHintOnceIfNeeded(cfg: cfg)
        return try wrapIfEnabled(
            payload,
            configuration: cfg,
            label: label,
            maximumOutputByteCount: maximumOutputByteCount
        )
    }

    public static func wrapIfEnabled(
        _ payload: Data,
        configuration cfg: TrafficPaddingConfig,
        label: String? = nil,
        maximumOutputByteCount: Int = maximumWebRTCOutputByteCount
    ) throws -> Data {
        let target: BoundedPaddingEnvelopePolicy.Target = switch cfg.mode {
        case .fixed:
            .fixed(cfg.fixedSizeBytes)
        case .bucketed:
            .bucketed(cfg.bucketSizesBytes)
        }
        let plan = try BoundedPaddingEnvelopePolicy.plan(
            payloadByteCount: payload.count,
            headerByteCount: headerLen,
            enabled: cfg.enabled,
            target: target,
            maximumOutputByteCount: maximumOutputByteCount
        )
        guard plan.shouldWrap else { return payload }

        let out = wrap(payload: payload, totalLen: plan.totalByteCount)

        if shouldEmitDiagnostics(cfg: cfg) {
            let name = label ?? "traffic"
            let msg = "🧪 TrafficPadding[\(name)]: raw=\(payload.count)B -> padded=\(out.count)B (mode=\(cfg.mode.rawValue))"
            SkyBridgeLogger.p2p.info("\(msg, privacy: .public)")
        }

        TrafficPaddingStats.submitWrap(
            label: label ?? "traffic",
            rawBytes: payload.count,
            paddedBytes: out.count
        )

        return out
    }

    /// Applies SBP2 while enforcing the compatibility control-frame ceiling
    /// before any padding allocation occurs.
    public static func wrapForP2PControlFrame(
        _ payload: Data,
        label: String? = nil
    ) throws -> Data {
        let cfg = TrafficPaddingConfig.fromUserDefaults()
        logConfigHintOnceIfNeeded(cfg: cfg)
        return try wrapForP2PControlFrame(
            payload,
            configuration: cfg,
            label: label
        )
    }

    public static func wrapForP2PControlFrame(
        _ payload: Data,
        configuration cfg: TrafficPaddingConfig,
        label: String? = nil
    ) throws -> Data {
        guard cfg.enabled else {
            try P2PControlFramePolicy.validateBodyByteCount(payload.count)
            return payload
        }

        let minimumResult = payload.count.addingReportingOverflow(headerLen)
        guard !minimumResult.overflow else {
            throw P2PControlFramePolicyError.byteCountOverflow
        }
        let minimumLength = minimumResult.partialValue
        try P2PControlFramePolicy.validateBodyByteCount(minimumLength)

        let targetLength: Int
        switch cfg.mode {
        case .fixed:
            if cfg.fixedSizeBytes > 0 {
                guard cfg.fixedSizeBytes <= P2PControlFramePolicy.maximumBodyByteCount else {
                    throw P2PControlFramePolicyError.invalidPaddingTarget(
                        actual: cfg.fixedSizeBytes,
                        maximum: P2PControlFramePolicy.maximumBodyByteCount
                    )
                }
                guard minimumLength <= cfg.fixedSizeBytes else {
                    throw P2PControlFramePolicyError.payloadExceedsFixedPaddingTarget(
                        required: minimumLength,
                        configured: cfg.fixedSizeBytes
                    )
                }
                targetLength = cfg.fixedSizeBytes
            } else {
                targetLength = minimumLength
            }
        case .bucketed:
            targetLength = cfg.bucketSizesBytes.first(where: { $0 >= minimumLength })
                ?? minimumLength
        }

        try P2PControlFramePolicy.validateBodyByteCount(targetLength)
        let output = wrap(payload: payload, totalLen: targetLength)
        try P2PControlFramePolicy.validateBodyByteCount(output.count)

        if shouldEmitDiagnostics(cfg: cfg) {
            SkyBridgeLogger.p2p.info(
                "🧪 TrafficPadding[\(label ?? "traffic", privacy: .public)]: raw=\(payload.count, privacy: .public)B -> padded=\(output.count, privacy: .public)B (mode=\(cfg.mode.rawValue, privacy: .public))"
            )
        }
        TrafficPaddingStats.submitWrap(
            label: label ?? "traffic",
            rawBytes: payload.count,
            paddedBytes: output.count
        )
        return output
    }

    public static func unwrapIfNeeded(_ data: Data, label: String? = nil) -> Data {
        guard data.count >= headerLen else { return data }
        guard data.prefix(4).elementsEqual(magic) else { return data }

        let cfg = TrafficPaddingConfig.fromUserDefaults()
        if shouldEmitDiagnostics(cfg: cfg) {
            enterLogLock.lock()
            if !didPrintEnterUnwrap {
                didPrintEnterUnwrap = true
                SkyBridgeLogger.p2p.info("🧪 ENTER TrafficPadding.unwrapIfNeeded label=\(label ?? "traffic", privacy: .public) bytes=\(data.count, privacy: .public)")
            }
            enterLogLock.unlock()
        }
        logConfigHintOnceIfNeeded(cfg: cfg)

        let len = data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
        }

        let actualLen = Int(len)
        guard actualLen >= 0, actualLen <= data.count - headerLen else { return data }
        // Traffic payloads can be large, so avoid rebasing/copying the whole
        // input merely to use integer offsets. Build a real Collection range
        // relative to the slice's startIndex and copy only the unwrapped body.
        let payloadStart = data.index(data.startIndex, offsetBy: headerLen)
        let payloadEnd = data.index(payloadStart, offsetBy: actualLen)
        let payload = Data(data[payloadStart..<payloadEnd])

        if shouldEmitDiagnostics(cfg: cfg) {
            let name = label ?? "traffic"
            let msg = "🧪 TrafficUnwrap[\(name)]: total=\(data.count)B -> raw=\(payload.count)B"
            SkyBridgeLogger.p2p.info("\(msg, privacy: .public)")
        }

        TrafficPaddingStats.submitUnwrap(
            label: label ?? "traffic",
            totalBytes: data.count,
            rawBytes: payload.count
        )

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
