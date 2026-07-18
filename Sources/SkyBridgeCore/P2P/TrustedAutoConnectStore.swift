import Foundation
import Combine
import OSLog

public enum TrustedAutoConnectStoreError: LocalizedError {
    case persistenceUnavailable

    public var errorDescription: String? {
        "自动连接偏好存储不可用；为安全起见未应用更改"
    }
}

/// 逐设备「允许随航自动连接」开关的持久化存储（opt-in，默认 false）。
///
/// 设计要点：
/// - 故意使用独立侧存储，而**不是**给 `TrustRecord` 加字段——`TrustRecord` 是带签名的记录、且用合成 Codable，
///   新增非可选字段会在解码旧记录失败时被 `try?` 静默吞掉，导致整张信任表丢失。
/// - 该开关只是「在已具备的密码学信任之上，额外允许后台自动连接」的用户偏好，是信任的**子集**，
///   绝不绕过握手/信任校验（连接仍需 PQC 握手 + TrustRecord 解析成功才算 .authenticated）。
@available(macOS 14.0, *)
@MainActor
public final class TrustedAutoConnectStore: ObservableObject {
    public static let shared = TrustedAutoConnectStore()

    private let store = CodablePersistenceStore<[String: Bool]>(
        location: .protectedApplicationSupport(path: "P2P/trusted-auto-connect.json")
    )
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "TrustedAutoConnect")
    private var loadFailed = false

    /// 当前已开启随航自动连接的设备公钥指纹集合（内存缓存，写入时持久化）。
    /// 以 `TrustRecord.pubKeyFP`（稳定的密码学公钥指纹）为键，避免设备 id 轮换导致开关失配。
    @Published public private(set) var enabledFingerprints: Set<String>

    private init() {
        do {
            let map = try store.loadOrThrow() ?? [:]
            enabledFingerprints = Set(map.filter { $0.value }.keys.map(Self.normalizedFingerprint))
        } catch {
            enabledFingerprints = []
            loadFailed = true
            logger.error(
                "Trusted auto-connect preferences unavailable; defaults remain disabled: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// 该设备（按公钥指纹）是否允许随航自动连接（默认 false）。
    public func allowsAutoConnect(fingerprint: String) -> Bool {
        let normalized = Self.normalizedFingerprint(fingerprint)
        return !normalized.isEmpty && enabledFingerprints.contains(normalized)
    }

    /// 设置该设备（按公钥指纹）的随航自动连接开关并持久化。
    public func setAllowAutoConnect(_ allow: Bool, fingerprint: String) throws {
        let fingerprint = Self.normalizedFingerprint(fingerprint)
        guard !fingerprint.isEmpty else { return }
        if allow, loadFailed {
            throw TrustedAutoConnectStoreError.persistenceUnavailable
        }
        let previous = enabledFingerprints
        if allow {
            guard !enabledFingerprints.contains(fingerprint) else { return }
            enabledFingerprints.insert(fingerprint)
        } else {
            enabledFingerprints.remove(fingerprint)
        }
        do {
            try persist()
            loadFailed = false
        } catch {
            enabledFingerprints = previous
            logger.error("Failed to persist trusted auto-connect preference: \(error.localizedDescription, privacy: .private)")
            throw TrustedAutoConnectStoreError.persistenceUnavailable
        }
    }

    /// Disables auto-connect for every forgotten cryptographic identity. This
    /// is intentionally durable and rollback-safe before trust evidence is
    /// removed by the higher-level forget transaction.
    public func clearAutoConnect(fingerprints: [String]) throws {
        let normalized = Set(fingerprints.map(Self.normalizedFingerprint).filter { !$0.isEmpty })
        let previous = enabledFingerprints
        enabledFingerprints.subtract(normalized)
        do {
            try persist()
            loadFailed = false
        } catch {
            enabledFingerprints = previous
            logger.error("Failed to clear trusted auto-connect preferences: \(error.localizedDescription, privacy: .private)")
            throw TrustedAutoConnectStoreError.persistenceUnavailable
        }
    }

    private func persist() throws {
        let map = Dictionary(uniqueKeysWithValues: enabledFingerprints.map { ($0, true) })
        try store.save(map)
    }

    private nonisolated static func normalizedFingerprint(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
