import Foundation

@available(iOS 17.0, *)
enum ProtocolDeviceIdentity {
    private static let protocolIdentityMirrorDefaultsKey = "SkyBridge.P2P.DeviceIdentity.DeviceID"
    private static let legacyDeviceDefaultsKey = "SkyBridge.DeviceId"

    static func stableDeviceId() -> String {
        if let explicit = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            mirrorDeviceIdToLegacyDefaultsIfNeeded(explicit)
            return explicit
        }

        if let protocolIdentity = UserDefaults.standard.string(forKey: protocolIdentityMirrorDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !protocolIdentity.isEmpty {
            mirrorDeviceIdToLegacyDefaultsIfNeeded(protocolIdentity)
            return protocolIdentity
        }

        if let legacyIdentity = UserDefaults.standard.string(forKey: legacyDeviceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyIdentity.isEmpty {
            UserDefaults.standard.set(legacyIdentity, forKey: protocolIdentityMirrorDefaultsKey)
            return legacyIdentity
        }

        let keychainIdentity: String
        do {
            keychainIdentity = try KeychainManager.shared.getOrGenerateDeviceIdStrict()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            SkyBridgeLogger.shared.error("❌ 协议设备 ID Keychain 加载失败，拒绝静默重建: \(error.localizedDescription)")
            return ""
        }
        if !keychainIdentity.isEmpty {
            UserDefaults.standard.set(keychainIdentity, forKey: protocolIdentityMirrorDefaultsKey)
            mirrorDeviceIdToLegacyDefaultsIfNeeded(keychainIdentity)
        }
        return keychainIdentity
    }

    static func stablePersistentDeviceId() -> String {
        let raw = stableDeviceId()
        return PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    static func mirrorDeviceIdToLegacyDefaultsIfNeeded(_ raw: String) {
        let deviceId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else { return }
        if UserDefaults.standard.string(forKey: legacyDeviceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) != deviceId {
            UserDefaults.standard.set(deviceId, forKey: legacyDeviceDefaultsKey)
        }
    }
}
