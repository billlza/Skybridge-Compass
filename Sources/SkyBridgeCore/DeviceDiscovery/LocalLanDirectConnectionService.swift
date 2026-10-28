import Foundation
import SkyBridgeProtocolCore

#if os(macOS)

public enum LocalLanDirectConnectionError: Error, LocalizedError {
    case listenerUnavailable
    case identityNotCompatible
    case noLocalAddress
    case routeChanged

    public var errorDescription: String? {
        switch self {
        case .listenerUnavailable: "本机连接服务尚未就绪，请稍后刷新。"
        case .identityNotCompatible: "当前设备身份暂不支持此直连配对方式。"
        case .noLocalAddress: "未找到可用的本地网络地址。"
        case .routeChanged: "本机连接信息已变化，请刷新后重新复制。"
        }
    }
}

/// Exports the currently bound MAIN listener and existing committed identity only.
/// It never starts a listener, creates a key, or changes pairing/account state.
@available(macOS 14.0, *)
public enum LocalLanDirectConnectionService {
    public static func connectionOptions() async throws -> [LanDirectConnectionInfo] {
        let before = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: BonjourInteropContract.controlServiceType)
        guard before.isConnectable, let port = before.port else { throw LocalLanDirectConnectionError.listenerUnavailable }
        let active = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let pairing = try await CommittedLocalProtocolIdentitySnapshot.loadPreferred(matching: [.mlDSA65, .ed25519])
        guard let pairing, active.algorithm == pairing.algorithm, active.publicKey == pairing.publicKey,
              active.protection == pairing.protection else { throw LocalLanDirectConnectionError.identityNotCompatible }
        let identity = try await CanonicalBonjourAdvertisementIdentityProvider.current(allowCreateDeviceId: false)
        let binding = try ProtocolIdentityBinding(deviceId: identity.deviceId,
            protocolSigningAlgorithm: active.algorithm, protocolPublicKeyBytes: active.publicKey)
        guard identity.protocolPublicKeyFingerprint == binding.protocolPublicKeyFingerprint else {
            throw LocalLanDirectConnectionError.routeChanged
        }
        try Task.checkCancellation()
        let addresses = LANAddressRoutabilityPolicy.routableAddresses(
            from: LocalNetworkAdvertisementAddressProvider.routableLANAddresses(), limit: 32)
        guard !addresses.isEmpty else { throw LocalLanDirectConnectionError.noLocalAddress }
        let options = try addresses.map { address in
            try LanDirectConnectionInfo(host: address, port: port, deviceId: identity.deviceId,
                protocolFingerprint: identity.protocolPublicKeyFingerprint,
                deviceName: LocalDevicePresentation.currentProtocolMetadata().deviceName ?? "Mac", platform: "macos")
        }
        let after = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: BonjourInteropContract.controlServiceType)
        guard before == after else { throw LocalLanDirectConnectionError.routeChanged }
        try Task.checkCancellation()
        return options
    }

    /// Re-read live state at copy time; a stale selection cannot silently copy a different route.
    public static func textForCurrentOption(_ selected: LanDirectConnectionInfo) async throws -> String {
        let current = try await connectionOptions()
        guard current.contains(selected) else { throw LocalLanDirectConnectionError.routeChanged }
        return try LanDirectConnectionInfoCodec.encode(selected)
    }
}
#endif
