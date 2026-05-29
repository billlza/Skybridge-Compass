import Foundation

struct CrossNetworkWebRTCLocalDeviceDescriptor: Sendable, Equatable {
    let deviceName: String?
    let modelName: String?
    let platform: String
    let osVersion: String

    static func current(
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> CrossNetworkWebRTCLocalDeviceDescriptor {
        let snapshot = LocalDevicePresentation.current(osVersion: osVersion)
        return CrossNetworkWebRTCLocalDeviceDescriptor(
            deviceName: snapshot.deviceName,
            modelName: snapshot.modelName,
            platform: snapshot.platformName,
            osVersion: snapshot.osVersion
        )
    }
}

enum CrossNetworkWebRTCLocalAppMessageFactory {
    static func heartbeatMessage(
        deviceId: String,
        remoteVideoFormats: [String],
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        sentAt: Date = Date(),
        descriptor: CrossNetworkWebRTCLocalDeviceDescriptor = .current()
    ) -> AppMessage {
        AppMessage.heartbeat(.init(
            sentAt: sentAt,
            deviceId: deviceId,
            deviceName: descriptor.deviceName,
            modelName: descriptor.modelName,
            platform: descriptor.platform,
            osVersion: descriptor.osVersion,
            chip: nil,
            accountDisplayName: accountDisplayName,
            nebulaId: nebulaId,
            remoteVideoFormats: remoteVideoFormats
        ))
    }

    static func pairingIdentityExchangePayload(
        deviceId: String,
        kemPublicKeys: [KEMPublicKeyInfo],
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]?,
        remoteVideoFormats: [String],
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        sentAt: Date = Date(),
        descriptor: CrossNetworkWebRTCLocalDeviceDescriptor = .current()
    ) -> AppMessage.PairingIdentityExchangePayload {
        AppMessage.PairingIdentityExchangePayload(
            deviceId: deviceId,
            kemPublicKeys: kemPublicKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys,
            deviceName: descriptor.deviceName,
            modelName: descriptor.modelName,
            platform: descriptor.platform,
            osVersion: descriptor.osVersion,
            chip: nil,
            accountDisplayName: accountDisplayName,
            nebulaId: nebulaId,
            remoteVideoFormats: remoteVideoFormats,
            sentAt: sentAt
        )
    }
}
