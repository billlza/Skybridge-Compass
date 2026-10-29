import Foundation

/// 「账号设备列表里的这一行」与「附近 Bonjour 发现到的这台设备」是不是同一台机器。
///
/// 两个身份来源的 id 形状不同：注册表存的是**原始**稳定 deviceId（客户端注册时提交的那个），
/// 发现侧 `DiscoveredDevice.id` 则是 `PeerIdentityAliasResolver` 规范化后带 `id:` 前缀的形式。
/// 直接字符串比较永远不成立，「局域网可达 / 连接设备」入口就永远不会出现，用户只能退回连接码。
/// 因此两边都必须先过同一个解析器。
///
/// 指纹是安全前提而不是锦上添花：只有 deviceId 相同不足以把连接入口放出来，
/// 必须同时满足「发现侧已验证的协议指纹」与注册表记录的指纹相等（都缺省时一律不匹配）。
enum AccountDeviceLANMatch {
    static func matches(
        accountDeviceId: String,
        accountFingerprint: String,
        discoveredDeviceId: String,
        discoveredFingerprint: String?
    ) -> Bool {
        guard let target = PeerIdentityAliasResolver.persistentDeviceId(from: accountDeviceId),
              let candidate = PeerIdentityAliasResolver.persistentDeviceId(from: discoveredDeviceId),
              target == candidate else {
            return false
        }
        let expected = accountFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty,
              let discoveredFingerprint,
              case let observed = discoveredFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !observed.isEmpty else {
            return false
        }
        return observed == expected
    }
}
