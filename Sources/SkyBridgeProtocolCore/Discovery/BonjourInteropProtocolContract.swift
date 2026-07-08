import Foundation

public enum BonjourInteropProtocolContract {
    public static let legacyQuicPrimaryServiceType = "_skybridge._udp"
    public static let controlServiceType = "_skybridge._tcp"
    public static let fileTransferServiceType = "_skybridge-transfer._tcp"
    public static let remoteControlServiceType = "_skybridge-remote._tcp"
    public static let companionLinkServiceType = "_companion-link._tcp"

    public static let defaultDiscoveryServiceTypes = [
        controlServiceType,
        fileTransferServiceType,
        remoteControlServiceType
    ]

    public static let windowsCompatibilityDiscoveryServiceTypes = [
        legacyQuicPrimaryServiceType,
        controlServiceType,
        fileTransferServiceType,
        remoteControlServiceType
    ]

    public static let classicResumeCapability = "classic_resume"

    public static let basePrimaryCapabilities = [
        "clipboard",
        "clipboard_sync"
    ]

    public static let fileTransferCapabilities = [
        "file",
        "file_transfer",
        classicResumeCapability
    ]

    public static let remoteControlCapabilities = [
        "screen_sharing",
        "remote_desktop",
        "rdview",
        "remote_control",
        "rdcontrol"
    ]

    public static let primaryCapabilities = fileTransferCapabilities
        + remoteControlCapabilities
        + basePrimaryCapabilities

    public static let remoteVideoFormatTXTKeys = [
        "remoteVideoFormats",
        "remote_video_formats",
        "remoteformats",
        "remotevideoformats",
        "remotevideformats"
    ]

    public static let fileTransferPortTXTKeys = [
        "transferPort",
        "fileTransferPort",
        "file_transfer_port",
        "port"
    ]

    public static let remoteControlPortTXTKeys = [
        "remotePort",
        "remoteControlPort",
        "remote_port",
        "port"
    ]

    public static let pubKeyFingerprintTXTKeys = [
        "pubKeyFP",
        "pubKeyFp",
        "pub_key_fp",
        "identityFingerprint",
        "publicKeyFingerprint"
    ]

    public static let deviceIdentityTXTKeys = [
        "deviceId",
        "id",
        "deviceID",
        "device_id",
        "uuid",
        "uniqueId",
        "unique_id"
    ]

    public static let pubKeyFingerprintPattern = "^[0-9a-f]{64}$"

    public static let supportedRemoteVideoFormatTokens = [
        "jpeg",
        "h264",
        "hevc"
    ]

    public static var primaryCapabilitiesTXTValue: String {
        primaryCapabilities.joined(separator: ",")
    }

    public static var basePrimaryCapabilitiesTXTValue: String {
        basePrimaryCapabilities.joined(separator: ",")
    }

    public static var fileTransferCapabilitiesTXTValue: String {
        fileTransferCapabilities.joined(separator: ",")
    }

    public static var remoteControlCapabilitiesTXTValue: String {
        remoteControlCapabilities.joined(separator: ",")
    }

    public static func normalizedRemoteVideoFormats<S: Sequence>(_ formats: S) -> [String] where S.Element == String {
        let allowed = Set(supportedRemoteVideoFormatTokens)
        var seen = Set<String>()
        var normalized: [String] = []
        for raw in formats {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowed.contains(token), seen.insert(token).inserted else { continue }
            normalized.append(token)
        }
        return normalized
    }

    public static func normalizedRemoteVideoFormats(from raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return normalizedRemoteVideoFormats(raw.split(separator: ",").map(String.init))
    }

    public static func normalizedPubKeyFingerprint(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    public static func isValidPubKeyFingerprint(_ value: String) -> Bool {
        normalizedPubKeyFingerprint(value) != nil
    }

    public static func primaryCapabilities(
        transferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> [String] {
        var capabilities = basePrimaryCapabilities
        if let transferPort, transferPort > 0 {
            capabilities.append(contentsOf: fileTransferCapabilities)
        }
        if let remoteControlPort, remoteControlPort > 0 {
            capabilities.append(contentsOf: remoteControlCapabilities)
        }

        var seen = Set<String>()
        return capabilities.filter { seen.insert($0).inserted }
    }

    public static func primaryCapabilitiesTXTValue(
        transferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> String {
        primaryCapabilities(
            transferPort: transferPort,
            remoteControlPort: remoteControlPort
        ).joined(separator: ",")
    }

    public static func primaryAdvertisementFields<S: Sequence>(
        transferPort: UInt16?,
        remoteControlPort: UInt16?,
        remoteVideoFormats: S
    ) -> [String: String] where S.Element == String {
        var fields: [String: String] = [
            "capabilities": primaryCapabilitiesTXTValue(
                transferPort: transferPort,
                remoteControlPort: remoteControlPort
            )
        ]
        if let transferPort, transferPort > 0 {
            let port = String(transferPort)
            fields["transferPort"] = port
            fields["fileTransferPort"] = port
            fields["file_transfer_port"] = port
        }
        if let remoteControlPort, remoteControlPort > 0 {
            let port = String(remoteControlPort)
            fields["remotePort"] = port
            fields["remoteControlPort"] = port
            fields["remote_port"] = port
            fields.merge(remoteVideoFormatFields(remoteVideoFormats), uniquingKeysWith: { current, _ in current })
        }
        return fields
    }

    public static func fileTransferAdvertisementFields(port: UInt16) -> [String: String] {
        let portValue = String(port)
        return [
            "capabilities": fileTransferCapabilitiesTXTValue,
            "transferPort": portValue,
            "fileTransferPort": portValue,
            "file_transfer_port": portValue,
            "port": portValue
        ]
    }

    public static func remoteControlAdvertisementFields<S: Sequence>(
        port: UInt16,
        remoteVideoFormats: S
    ) -> [String: String] where S.Element == String {
        let portValue = String(port)
        var fields: [String: String] = [
            "capabilities": remoteControlCapabilitiesTXTValue,
            "remotePort": portValue,
            "remoteControlPort": portValue,
            "remote_port": portValue,
            "port": portValue
        ]
        fields.merge(remoteVideoFormatFields(remoteVideoFormats), uniquingKeysWith: { current, _ in current })
        return fields
    }

    public static func remoteVideoFormatFields<S: Sequence>(_ formats: S) -> [String: String] where S.Element == String {
        let value = normalizedRemoteVideoFormats(formats).joined(separator: ",")
        guard !value.isEmpty else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: remoteVideoFormatTXTKeys.map { ($0, value) })
    }
}
