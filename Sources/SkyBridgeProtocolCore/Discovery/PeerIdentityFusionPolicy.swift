import Foundation

/// 跨平台的「两条发现记录是否可以合并成同一台设备」判定。
///
/// ## 为什么需要这个类型
///
/// macOS 与 iOS 各自手写过一套设备去重逻辑，而两边的规则并不一致：
///
/// - iOS（`DeviceDiscoveryManager.shouldCoalesceDiscoveryDevices`）先比对持久设备身份，
///   两侧身份都存在且不同就直接拒绝合并，之后才看地址、型号、名称等佐证。
/// - macOS（`UnifiedOnlineDeviceManager.findSimilarDevice`）反过来：先按 MAC / 序列号 /
///   IPv4 / IPv6 无条件合并，身份判定排在后面，而且只覆盖「按名字匹配」的分支。
///
/// 后果就是同一个局域网里，iOS 能正常发现 Mac，Mac 却会把两台协议身份明确不同的对端
/// 揉进同一行——共用一个 IPv4（NAT 后、DHCP 回收、link-local 冲突都会造成）就足以触发。
/// 被吞掉的那一行从可见列表里消失，界面上只剩下过期的持久化行，于是全部显示为「离线」。
///
/// 这个类型是该判定的**唯一事实来源**。任何平台都必须通过它来回答这个问题，
/// 不允许再各自写一份——否则修好一端，另一端还会错。
public enum PeerIdentityFusionPolicy {

    /// 一条发现记录所携带的身份证据（调用方需先归一化）。
    public struct IdentityEvidence: Sendable, Equatable {
        /// 持久设备标识（形如 `id:<stable>`）。
        ///
        /// 只有真正的稳定身份才应填入。`host:` / `peer:` / `bonjour:` / IP 字面量
        /// 这类「路径端点」是可变的可达性信息，不是身份，必须传 `nil`。
        public let stableDeviceId: String?

        /// 归一化后的公钥指纹。
        public let publicKeyFingerprint: String?

        public init(stableDeviceId: String?, publicKeyFingerprint: String?) {
            self.stableDeviceId = stableDeviceId
            self.publicKeyFingerprint = publicKeyFingerprint
        }

        /// 这条记录是否携带任何协议级身份。
        public var hasProtocolIdentity: Bool {
            stableDeviceId != nil || publicKeyFingerprint != nil
        }
    }

    /// 两条记录的身份是否**互相矛盾**——即可以断定它们不是同一台设备。
    ///
    /// 只有在两侧都持有同一类身份证据、且取值不同时才成立。
    /// 一侧缺失身份不构成矛盾（那是「未知」，不是「不同」），此时允许靠佐证信号补全。
    public static func identitiesContradict(
        _ lhs: IdentityEvidence,
        _ rhs: IdentityEvidence
    ) -> Bool {
        if let lhsId = lhs.stableDeviceId,
           let rhsId = rhs.stableDeviceId,
           lhsId != rhsId {
            return true
        }
        if let lhsFingerprint = lhs.publicKeyFingerprint,
           let rhsFingerprint = rhs.publicKeyFingerprint,
           lhsFingerprint != rhsFingerprint {
            return true
        }
        return false
    }

    /// 是否允许用「佐证信号」（MAC / 序列号 / IPv4 / IPv6）把两条记录合并。
    ///
    /// 核心规则：**佐证信号只能用来补全身份，绝不能用来推翻身份。**
    ///
    /// 这些信号单独看都不足以证明同一性：
    /// - 同一个 IPv4 可能来自 DHCP 地址回收、同一台 NAT 之后的两台设备、link-local 冲突；
    /// - 同一个 MAC 可能来自随机化 MAC 的复用，或虚拟网卡；
    /// - 序列号在部分平台上是可为空、可伪造的自报字段。
    ///
    /// 所以一旦两侧持有明确且不同的协议身份，任何地址层面的巧合都不得触发合并。
    public static func mayFuseOnCorroboratingSignal(
        lhs: IdentityEvidence,
        rhs: IdentityEvidence
    ) -> Bool {
        !identitiesContradict(lhs, rhs)
    }

    /// 是否允许**仅凭显示名称**（完全相同或包含关系）把两条记录合并。
    ///
    /// 名称是最弱的信号：用户会重名，厂商会用同一份默认名。
    /// 因此只要任意一侧已经拿到了协议身份，就不允许再退回到靠名字合并——
    /// 该用身份去判定，而不是猜。
    public static func mayFuseOnDisplayNameAlone(
        lhs: IdentityEvidence,
        rhs: IdentityEvidence
    ) -> Bool {
        !lhs.hasProtocolIdentity && !rhs.hasProtocolIdentity
    }

    // MARK: - 归一化
    //
    // 归一化必须和判定放在一起。否则两端各写一份「什么算稳定身份」，
    // 判定逻辑就算统一了，喂进去的输入还是不一样，divergence 只是换了个地方。

    /// 把任意标识串归一化成持久设备标识（形如 `id:<stable>`）；
    /// 如果它其实是「路径端点」而非身份，返回 `nil`。
    ///
    /// 被拒绝的前缀 `host:` / `peer:` / `bonjour:` / `recent:`，以及含 `@` 的实例名，
    /// 都是可达性信息：同一台设备换网段就会变，不同设备也可能撞上同一个值。
    /// IP 字面量同理——它是本次会话的地址，不是这台设备的身份。
    public static func normalizedStableDeviceId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let normalized = trimmed.lowercased()

        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            guard isPlausibleStableIdentifierPayload(payload) else { return nil }
            return "id:\(payload)"
        }

        if normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:")
            || normalized.contains("@") {
            return nil
        }

        guard isPlausibleStableIdentifierPayload(normalized) else { return nil }
        return "id:\(normalized)"
    }

    /// 一个标识载荷是否长得像稳定身份：足够长、无空白、仅含 ASCII 字母数字与 `-_.`，
    /// 且不是 IP 字面量。
    private static func isPlausibleStableIdentifierPayload(_ payload: String) -> Bool {
        guard payload.count >= 8 else { return false }
        guard !payload.contains(where: \.isWhitespace) else { return false }
        let characterSetIsValid = payload.allSatisfy { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || character == "-"
                    || character == "_"
                    || character == ".")
        }
        guard characterSetIsValid else { return false }
        return !isLiteralIPAddress(payload)
    }

    /// 纯字符串判定的 IP 字面量识别。
    /// 刻意不依赖 `Network`，让本文件保持零依赖，可以被任意平台目标直接编译。
    ///
    /// ⚠️ 这里必须与 iOS 侧 `PeerIdentityAliasResolver.isLiteralIPAddress` 判定一致，
    /// 否则「共享规则」名存实亡：同一个标识串，一端认作身份、另一端认作地址。
    /// iOS 那边用的是 `Network.IPv4Address(_:)`，而它接受 inet_aton 的整数写法——
    /// 实测 `"12345678"`、`"2130706433"`、`"0x7f000001"` 都会被解析成 IPv4。
    /// 所以这里也要把这些整数形式算作地址。
    ///
    /// 语义上「12345678 是个 IP」当然很勉强，但两端保持一致比谁更漂亮更重要；
    /// 而且往「更严格」的方向对齐是安全的：多判成地址 = 身份未知 = 允许靠佐证合并，
    /// 不会造成本次要修的那种「误判成身份不同而拒绝合并」。
    private static func isLiteralIPAddress(_ raw: String) -> Bool {
        let scoped = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        guard !scoped.isEmpty else { return false }

        if scoped.contains(":") {
            // IPv6：至少两个冒号分段，且每段都是十六进制（允许 `::` 压缩产生的空段）
            let segments = scoped.split(separator: ":", omittingEmptySubsequences: false)
            guard segments.count >= 3 else { return false }
            return segments.allSatisfy { segment in
                segment.isEmpty
                    || (segment.count <= 4 && segment.allSatisfy(\.isHexDigit))
            }
        }

        // inet_aton 的十六进制整数写法（0x7f000001）
        let lowered = scoped.lowercased()
        if lowered.hasPrefix("0x") {
            let payload = lowered.dropFirst(2)
            return !payload.isEmpty && payload.allSatisfy(\.isHexDigit)
        }

        // inet_aton 的十进制整数写法（2130706433 / 12345678）
        if scoped.allSatisfy(\.isNumber) {
            return true
        }

        // 常规点分四段
        let octets = scoped.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty
                && octet.allSatisfy(\.isNumber)
                && (UInt8(octet) != nil)
        }
    }
}
