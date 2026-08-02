import Foundation
import Network
import SkyBridgeProtocolCore

enum BonjourInteropContract {
    typealias Core = BonjourInteropProtocolContract
    typealias AdvertisementPlatform = Core.AdvertisementPlatform
    typealias AdvertisementRole = Core.AdvertisementRole

    static let controlServiceType = Core.controlServiceType
    static let fileTransferServiceType = Core.fileTransferServiceType
    static let remoteControlServiceType = Core.remoteControlServiceType
    static let legacyFileTransferServiceType = Core.legacyFileTransferServiceType
    static let legacyRemoteControlServiceType = Core.legacyRemoteControlServiceType
    static let companionLinkServiceType = Core.companionLinkServiceType
    static let legacyQuicPrimaryServiceType = Core.legacyQuicPrimaryServiceType

    static let defaultDiscoveryServiceTypes = Core.defaultDiscoveryServiceTypes
    static let windowsCompatibilityDiscoveryServiceTypes = Core.windowsCompatibilityDiscoveryServiceTypes

    static let classicResumeCapability = Core.classicResumeCapability

    static let basePrimaryCapabilities = Core.basePrimaryCapabilities

    static let primaryCapabilities = Core.primaryCapabilities

    static let fileTransferCapabilities = Core.fileTransferCapabilities

    static let remoteControlCapabilities = Core.remoteControlCapabilities

    static let remoteVideoFormatTXTKeys = Core.remoteVideoFormatTXTKeys
    static let fileTransferPortTXTKeys = Core.fileTransferPortTXTKeys
    static let remoteControlPortTXTKeys = Core.remoteControlPortTXTKeys
    static let pubKeyFingerprintTXTKeys = Core.pubKeyFingerprintTXTKeys
    static let deviceIdentityTXTKeys = Core.deviceIdentityTXTKeys
    static let pubKeyFingerprintPattern = Core.pubKeyFingerprintPattern
    static let advertisementVersion = Core.advertisementVersion
    static let canonicalAdvertisementTXTKeys = Core.canonicalAdvertisementTXTKeys
    static let maximumRecommendedTXTRecordWireBytes = Core.maximumRecommendedTXTRecordWireBytes

    static let supportedRemoteVideoFormatTokens = Core.supportedRemoteVideoFormatTokens

    static func normalizedRemoteVideoFormats<S: Sequence>(_ formats: S) -> [String] where S.Element == String {
        Core.normalizedRemoteVideoFormats(formats)
    }

    static func normalizedRemoteVideoFormats(from raw: String?) -> [String] {
        Core.normalizedRemoteVideoFormats(from: raw)
    }

    static func normalizedPubKeyFingerprint(_ raw: String?) -> String? {
        Core.normalizedPubKeyFingerprint(raw)
    }

    static func isValidPubKeyFingerprint(_ value: String) -> Bool {
        Core.isValidPubKeyFingerprint(value)
    }

    static func isValidDNSServiceType(_ value: String) -> Bool {
        Core.isValidDNSServiceType(value)
    }

    static func advertisementRole(
        for serviceType: String
    ) -> AdvertisementRole? {
        switch serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case controlServiceType, legacyQuicPrimaryServiceType:
            return .control
        case fileTransferServiceType,
             remoteControlServiceType,
             legacyFileTransferServiceType,
             legacyRemoteControlServiceType:
            return .dedicatedService
        default:
            return nil
        }
    }

    static func discoveryProjection(
        _ record: NWTXTRecord,
        serviceType: String
    ) throws -> Core.DiscoveryProjection? {
        guard let role = advertisementRole(for: serviceType) else { return nil }
        return try decodeAdvertisement(record, role: role).discoveryProjection
    }

    static func discoveryProjection(
        _ rawTXTData: Data,
        serviceType: String
    ) throws -> Core.DiscoveryProjection? {
        guard let role = advertisementRole(for: serviceType) else { return nil }
        return try Core.decodeAdvertisement(rawTXTData, role: role).discoveryProjection
    }

    static func decodeAdvertisement(
        _ record: NWTXTRecord,
        role: AdvertisementRole
    ) throws -> Core.DecodedAdvertisement {
        try Core.decodeAdvertisement(record.data, role: role)
    }

    static func canonicalAdvertisementFields(
        deviceId: String,
        pubKeyFingerprint: String,
        platform: AdvertisementPlatform,
        role: AdvertisementRole
    ) throws -> [String: String] {
        try Core.canonicalAdvertisementFields(
            deviceId: deviceId,
            pubKeyFingerprint: pubKeyFingerprint,
            platform: platform,
            role: role
        )
    }

    static func makeCanonicalAdvertisementTXT(
        deviceId: String,
        pubKeyFingerprint: String,
        platform: AdvertisementPlatform,
        role: AdvertisementRole
    ) throws -> NWTXTRecord {
        var record = NWTXTRecord()
        attach(
            try canonicalAdvertisementFields(
                deviceId: deviceId,
                pubKeyFingerprint: pubKeyFingerprint,
                platform: platform,
                role: role
            ),
            to: &record
        )
        return record
    }

    static func makeCanonicalAdvertisementData(
        deviceId: String,
        pubKeyFingerprint: String,
        platform: AdvertisementPlatform,
        role: AdvertisementRole
    ) throws -> [String: Data] {
        var record: [String: Data] = [:]
        attach(
            try canonicalAdvertisementFields(
                deviceId: deviceId,
                pubKeyFingerprint: pubKeyFingerprint,
                platform: platform,
                role: role
            ),
            to: &record
        )
        return record
    }

    private static func attach(_ fields: [String: String], to record: inout NWTXTRecord) {
        for (key, value) in fields {
            record[key] = value
        }
    }

    private static func attach(_ fields: [String: String], to record: inout [String: Data]) {
        for (key, value) in fields {
            record[key] = Data(value.utf8)
        }
    }
}

struct CanonicalBonjourAdvertisementIdentity: Sendable, Equatable {
    let deviceId: String
    let protocolPublicKeyFingerprint: String
}

enum CanonicalBonjourAdvertisementIdentityProvider {
    static func current(allowCreateDeviceId: Bool) async throws
        -> CanonicalBonjourAdvertisementIdentity {
        let deviceIdentity = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: allowCreateDeviceId)
        let protocolIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let binding = try ProtocolIdentityBinding(
            deviceId: deviceIdentity.deviceId,
            protocolSigningAlgorithm: protocolIdentity.algorithm,
            protocolPublicKeyBytes: protocolIdentity.publicKey
        )
        return CanonicalBonjourAdvertisementIdentity(
            deviceId: binding.deviceId,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
        )
    }
}
