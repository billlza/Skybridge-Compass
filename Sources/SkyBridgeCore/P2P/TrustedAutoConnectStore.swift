import Foundation
import Combine

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

    /// 当前已开启随航自动连接的设备公钥指纹集合（内存缓存，写入时持久化）。
    /// 以 `TrustRecord.pubKeyFP`（稳定的密码学公钥指纹）为键，避免设备 id 轮换导致开关失配。
    @Published public private(set) var enabledFingerprints: Set<String>

    private init() {
        let map = store.load() ?? [:]
        enabledFingerprints = Set(map.filter { $0.value }.keys)
    }

    /// 该设备（按公钥指纹）是否允许随航自动连接（默认 false）。
    public func allowsAutoConnect(fingerprint: String) -> Bool {
        !fingerprint.isEmpty && enabledFingerprints.contains(fingerprint)
    }

    /// 设置该设备（按公钥指纹）的随航自动连接开关并持久化。
    public func setAllowAutoConnect(_ allow: Bool, fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        if allow {
            guard !enabledFingerprints.contains(fingerprint) else { return }
            enabledFingerprints.insert(fingerprint)
        } else {
            guard enabledFingerprints.contains(fingerprint) else { return }
            enabledFingerprints.remove(fingerprint)
        }
        persist()
    }

    private func persist() {
        let map = Dictionary(uniqueKeysWithValues: enabledFingerprints.map { ($0, true) })
        try? store.save(map)
    }
}
