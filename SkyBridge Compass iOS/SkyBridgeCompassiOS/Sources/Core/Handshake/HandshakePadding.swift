//
// HandshakePadding.swift
// SkyBridgeCompassiOS
//
// Phase C1 (TDSC): Traffic analysis mitigations for handshake control channel
// - Optional padding of handshake frames to bucketed / fixed sizes
// - Padding is *outside* the cryptographic transcript (receiver unwraps before decode)
//

import Foundation

@available(iOS 17.0, *)
public enum HandshakePaddingMode: String, Sendable {
    case bucketed
    case fixed
}

@available(iOS 17.0, *)
public struct HandshakePaddingConfig: Sendable {
    public var enabled: Bool
    public var debugLog: Bool
    public var mode: HandshakePaddingMode
    public var fixedSizeBytes: Int
    public var bucketSizesBytes: [Int]

    public static func fromUserDefaults() -> HandshakePaddingConfig {
        let enabledKey = "sb_handshake_padding_enabled"
        let debugKey = "sb_handshake_padding_debug_log"
        let modeKey = "sb_handshake_padding_mode"
        let fixedKey = "sb_handshake_padding_fixed_size"

        let defaults = UserDefaults.standard
        // Optional fallback for sharing settings across extensions/app-group (if used later).
        let groupDefaults = UserDefaults(suiteName: "group.com.skybridge.compass")
        let enabled: Bool
        if defaults.object(forKey: enabledKey) == nil {
            enabled = true
        } else {
            enabled = defaults.bool(forKey: enabledKey)
        }

        let modeRaw = (defaults.string(forKey: modeKey) ?? HandshakePaddingMode.bucketed.rawValue)
        let mode = HandshakePaddingMode(rawValue: modeRaw) ?? .bucketed
        let fixedSize = defaults.integer(forKey: fixedKey)
        let envDebug = (ProcessInfo.processInfo.environment["SB_HANDSHAKE_PADDING_DEBUG_LOG"] == "1")
        let debugLog = defaults.bool(forKey: debugKey)
            || (groupDefaults?.bool(forKey: debugKey) ?? false)
            || envDebug

        return HandshakePaddingConfig(
            enabled: enabled,
            debugLog: debugLog,
            mode: mode,
            fixedSizeBytes: fixedSize,
            bucketSizesBytes: [256, 512, 1024, 2048, 4096, 8192, 16384]
        )
    }
}

@available(iOS 17.0, *)
public enum HandshakePadding {
    // "SBP1"
    private static let magic: [UInt8] = [0x53, 0x42, 0x50, 0x31]
    private static let headerLen = 4 + 4 // magic + u32 actualLen
    private static let configLogLock = NSLock()
    private static var didLogConfigHint = false

    private static func logConfigHintOnceIfNeeded(cfg: HandshakePaddingConfig) {
        guard cfg.enabled else { return }
        configLogLock.lock()
        defer { configLogLock.unlock() }
        guard !didLogConfigHint else { return }
        didLogConfigHint = true

        if cfg.debugLog {
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown.bundle"
            let msg = "🧪 HandshakePadding debug ON (bundle=\(bundleId), mode=\(cfg.mode.rawValue), fixed=\(cfg.fixedSizeBytes))"
            SkyBridgeLogger.shared.info(msg)
            print(msg)
        }
    }

    public static func wrapIfEnabled(_ payload: Data, label: String? = nil) -> Data {
        let cfg = HandshakePaddingConfig.fromUserDefaults()
        guard cfg.enabled else { return payload }
        logConfigHintOnceIfNeeded(cfg: cfg)

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
            let name = label ?? "handshake"
            let msg = "🧪 Padding[\(name)]: raw=\(payload.count)B -> padded=\(out.count)B (mode=\(cfg.mode.rawValue))"
            // 在某些控制台过滤下 debug 可能不可见，这里用 info 确保可见（仅在开关打开时）
            SkyBridgeLogger.shared.debug(msg)
            SkyBridgeLogger.shared.info(msg)
            print(msg)
        }

        return out
    }

    public static func unwrapIfNeeded(_ data: Data, label: String? = nil) -> Data {
        guard data.count >= headerLen else { return data }
        guard data.prefix(4).elementsEqual(magic) else { return data }

        let cfg = HandshakePaddingConfig.fromUserDefaults()
        logConfigHintOnceIfNeeded(cfg: cfg)

        let len = data.withUnsafeBytes { raw -> UInt32 in
            let base = raw.baseAddress!.advanced(by: 4)
            return base.load(as: UInt32.self).bigEndian
        }

        let actualLen = Int(len)
        guard actualLen >= 0, actualLen <= data.count - headerLen else { return data }
        let payload = data.subdata(in: headerLen..<(headerLen + actualLen))

        if cfg.debugLog {
            let name = label ?? "handshake"
            let msg = "🧪 Unwrap[\(name)]: total=\(data.count)B -> raw=\(payload.count)B"
            SkyBridgeLogger.shared.debug(msg)
            SkyBridgeLogger.shared.info(msg)
            print(msg)
        }

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


