import Foundation

/// 判断「一条发现记录其实是本机自己的广播」的**唯一**跨平台规则。
///
/// 背景：Mac 与 iOS 都会浏览到自己广播的 `_skybridge._tcp`。历史上两端各写了一套自识别
/// 逻辑并逐渐分叉——iOS 坚持「只认稳定身份/回环，名称与平台不算身份」，而 macOS 后来又加了
/// 基于 hostname 的兜底。名称兜底是危险的：两台默认同名的设备会互相误吞、无法发现。
/// 这里把判定收敛成一份零依赖的共享实现，macOS 与 iOS 都必须走它，不允许再各留一套。
///
/// 判定只使用**身份级/物理级**信号：稳定 deviceId、协议公钥指纹、本机接口 IP/MAC、回环地址。
/// **刻意不使用显示名 / 平台标签**——它们是展示元数据,不是身份。
public enum SelfDeviceIdentityPolicy {

    /// 本机自身的身份材料。每个平台按自己能拿到的填；拿不到的留空即可（策略对空值安全）。
    public struct LocalIdentity: Sendable {
        public let stableDeviceId: String?
        public let protocolFingerprint: String?
        public let ipAddresses: Set<String>
        public let macAddresses: Set<String>

        public init(
            stableDeviceId: String? = nil,
            protocolFingerprint: String? = nil,
            ipAddresses: Set<String> = [],
            macAddresses: Set<String> = []
        ) {
            self.stableDeviceId = stableDeviceId
            self.protocolFingerprint = protocolFingerprint
            self.ipAddresses = ipAddresses
            self.macAddresses = macAddresses
        }
    }

    /// 一条候选发现记录携带的身份/地址材料。
    public struct CandidateIdentity: Sendable {
        public let stableDeviceId: String?
        public let protocolFingerprint: String?
        public let ipAddresses: Set<String>
        public let macAddresses: Set<String>
        public let hasLoopbackAddress: Bool

        public init(
            stableDeviceId: String? = nil,
            protocolFingerprint: String? = nil,
            ipAddresses: Set<String> = [],
            macAddresses: Set<String> = [],
            hasLoopbackAddress: Bool = false
        ) {
            self.stableDeviceId = stableDeviceId
            self.protocolFingerprint = protocolFingerprint
            self.ipAddresses = ipAddresses
            self.macAddresses = macAddresses
            self.hasLoopbackAddress = hasLoopbackAddress
        }
    }

    /// 候选记录是否其实就是本机自己。
    ///
    /// 命中任一即判为本机：
    /// 1. 稳定 deviceId 相等（大小写不敏感）
    /// 2. 协议公钥指纹相等（归一化后）
    /// 3. 回环地址
    /// 4. 本机物理网卡 MAC 命中
    /// 5. 解析地址落在本机接口地址集合内
    ///
    /// 名称/平台**不参与**判定：两台默认同名设备必须仍能互相发现。
    public static func isSelf(local: LocalIdentity, candidate: CandidateIdentity) -> Bool {
        // 1) 稳定 deviceId（大小写不敏感）
        if let localId = normalizedNonEmpty(local.stableDeviceId),
           let candidateId = normalizedNonEmpty(candidate.stableDeviceId),
           candidateId.caseInsensitiveCompare(localId) == .orderedSame {
            return true
        }

        // 2) 协议公钥指纹（trim + 小写后逐字相等）
        if let localFP = normalizedFingerprint(local.protocolFingerprint),
           let candidateFP = normalizedFingerprint(candidate.protocolFingerprint),
           localFP == candidateFP {
            return true
        }

        // 3) 回环地址（无稳定身份时的 iOS 既有口径）
        if candidate.hasLoopbackAddress {
            return true
        }

        // 4) 本机物理网卡 MAC 命中
        let localMACs = normalizedSet(local.macAddresses)
        if !localMACs.isEmpty,
           !normalizedSet(candidate.macAddresses).isDisjoint(with: localMACs) {
            return true
        }

        // 5) 解析地址落在本机接口地址集合内
        let localIPs = normalizedSet(local.ipAddresses)
        if !localIPs.isEmpty,
           !normalizedSet(candidate.ipAddresses).isDisjoint(with: localIPs) {
            return true
        }

        return false
    }

    // MARK: - Normalization

    private static func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let value = normalizedNonEmpty(raw)?.lowercased() else { return nil }
        return value
    }

    private static func normalizedSet(_ raw: Set<String>) -> Set<String> {
        Set(raw.compactMap { normalizedNonEmpty($0)?.lowercased() })
    }
}
