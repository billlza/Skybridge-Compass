import Foundation
#if os(iOS)
import UIKit
#endif

struct CrossNetworkWebRTCLocalDeviceDescriptor: Sendable, Equatable {
    let deviceName: String?
    let modelName: String?
    let platform: String
    let osVersion: String

    static func current(
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> CrossNetworkWebRTCLocalDeviceDescriptor {
        CrossNetworkWebRTCLocalDeviceDescriptor(
            deviceName: currentDeviceName(),
            modelName: currentModelName(),
            platform: currentPlatform(),
            osVersion: osVersion
        )
    }

    private static func currentDeviceName() -> String? {
        #if os(macOS)
        return Host.current().localizedName
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return nil
        #endif
    }

    private static func currentModelName() -> String? {
        #if os(macOS)
        return "Mac"
        #elseif os(iOS)
        return UIDevice.current.model
        #else
        return nil
        #endif
    }

    private static func currentPlatform() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "unknown"
        #endif
    }
}

enum CrossNetworkWebRTCLocalAppMessageFactory {
    static func heartbeatMessage(
        deviceId: String,
        remoteVideoFormats: [String],
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
            remoteVideoFormats: remoteVideoFormats
        ))
    }

    static func pairingIdentityExchangePayload(
        deviceId: String,
        kemPublicKeys: [KEMPublicKeyInfo],
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]?,
        remoteVideoFormats: [String],
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
            remoteVideoFormats: remoteVideoFormats,
            sentAt: sentAt
        )
    }
}
