import Foundation
import Network
import SkyBridgeProtocolCore

enum BonjourInteropContract {
    private typealias Core = BonjourInteropProtocolContract

    static let controlServiceType = Core.controlServiceType
    static let fileTransferServiceType = Core.fileTransferServiceType
    static let remoteControlServiceType = Core.remoteControlServiceType
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

    static let supportedRemoteVideoFormatTokens = Core.supportedRemoteVideoFormatTokens

    static var primaryCapabilitiesTXTValue: String {
        Core.primaryCapabilitiesTXTValue
    }

    static var basePrimaryCapabilitiesTXTValue: String {
        Core.basePrimaryCapabilitiesTXTValue
    }

    static var fileTransferCapabilitiesTXTValue: String {
        Core.fileTransferCapabilitiesTXTValue
    }

    static var remoteControlCapabilitiesTXTValue: String {
        Core.remoteControlCapabilitiesTXTValue
    }

    static func supportedRemoteVideoFormatsTXTValue() -> String {
        WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats().joined(separator: ",")
    }

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

    static func primaryCapabilities(
        transferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> [String] {
        Core.primaryCapabilities(transferPort: transferPort, remoteControlPort: remoteControlPort)
    }

    static func primaryCapabilitiesTXTValue(
        transferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> String {
        Core.primaryCapabilitiesTXTValue(transferPort: transferPort, remoteControlPort: remoteControlPort)
    }

    static func attachPrimaryAdvertisementTXT(
        to record: inout NWTXTRecord,
        transferPort: UInt16?,
        remoteControlPort: UInt16?
    ) {
        attach(
            Core.primaryAdvertisementFields(
                transferPort: transferPort,
                remoteControlPort: remoteControlPort,
                remoteVideoFormats: supportedRemoteVideoFormats()
            ),
            to: &record
        )
    }

    static func attachFileTransferAdvertisementTXT(to record: inout NWTXTRecord, port: UInt16) {
        attach(Core.fileTransferAdvertisementFields(port: port), to: &record)
    }

    static func attachFileTransferAdvertisementTXT(to record: inout [String: Data], port: UInt16) {
        attach(Core.fileTransferAdvertisementFields(port: port), to: &record)
    }

    static func attachRemoteControlAdvertisementTXT(to record: inout NWTXTRecord, port: UInt16) {
        attach(
            Core.remoteControlAdvertisementFields(
                port: port,
                remoteVideoFormats: supportedRemoteVideoFormats()
            ),
            to: &record
        )
    }

    static func attachRemoteControlAdvertisementTXT(to record: inout [String: Data], port: UInt16) {
        attach(
            Core.remoteControlAdvertisementFields(
                port: port,
                remoteVideoFormats: supportedRemoteVideoFormats()
            ),
            to: &record
        )
    }

    static func attachRemoteVideoFormatTXT(to record: inout NWTXTRecord) {
        attach(Core.remoteVideoFormatFields(supportedRemoteVideoFormats()), to: &record)
    }

    static func attachRemoteVideoFormatTXT(to record: inout [String: Data]) {
        attach(Core.remoteVideoFormatFields(supportedRemoteVideoFormats()), to: &record)
    }

    private static func supportedRemoteVideoFormats() -> [String] {
        WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats()
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
