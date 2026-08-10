import Foundation

public enum BonjourInteropProtocolContract {
    public enum AdvertisementPlatform: String, Codable, CaseIterable, Sendable {
        case macOS = "macos"
        case iOS = "ios"
        case iPadOS = "ipados"
        case android
        case windows
        case linux
    }

    public enum AdvertisementRole: String, Codable, Sendable {
        case control
        case dedicatedService
    }

    public enum AdvertisementError: Error, LocalizedError, Sendable, Equatable {
        case invalidDeviceId
        case invalidPubKeyFingerprint
        case invalidPlatform
        case fieldExceedsDNSServiceLimit(key: String, bytes: Int)
        case recordExceedsRecommendedSize(bytes: Int, maximum: Int)
        case recordExceedsParserSafetyLimit(bytes: Int, maximum: Int)
        case truncatedField
        case emptyField
        case malformedField
        case invalidUTF8
        case duplicateKey(String)
        case unsupportedVersion(String)
        case invalidVersion2FieldSet
        case invalidStrongOwnerAuthenticationFlag

        public var errorDescription: String? {
            switch self {
            case .invalidDeviceId:
                return "Bonjour advertisement deviceId is empty or malformed"
            case .invalidPubKeyFingerprint:
                return "Bonjour advertisement pubKeyFP must be 64 lowercase hexadecimal characters"
            case .invalidPlatform:
                return "Bonjour advertisement platform is empty or malformed"
            case .fieldExceedsDNSServiceLimit(let key, let bytes):
                return "Bonjour TXT field \(key) is \(bytes) bytes; one DNS-SD TXT entry cannot exceed 255 bytes"
            case .recordExceedsRecommendedSize(let bytes, let maximum):
                return "Bonjour TXT record is \(bytes) bytes; the SkyBridge discovery contract maximum is \(maximum) bytes"
            case .recordExceedsParserSafetyLimit(let bytes, let maximum):
                return "Bonjour TXT record is \(bytes) bytes; the parser safety maximum is \(maximum) bytes"
            case .truncatedField:
                return "Bonjour TXT record ends inside a length-delimited field"
            case .emptyField:
                return "Bonjour TXT record contains an empty field"
            case .malformedField:
                return "Bonjour TXT record contains a malformed key=value field"
            case .invalidUTF8:
                return "Bonjour TXT record contains a non-UTF-8 field"
            case .duplicateKey(let key):
                return "Bonjour TXT record repeats or case-collides on key \(key)"
            case .unsupportedVersion(let version):
                return "Bonjour TXT advertisement version \(version) is not supported"
            case .invalidVersion2FieldSet:
                return "Bonjour TXT version 2 contains missing, legacy, or unknown fields"
            case .invalidStrongOwnerAuthenticationFlag:
                return "Bonjour TXT control advertisement must carry hs_soa=1"
            }
        }
    }

    public struct Version2Advertisement: Sendable, Equatable {
        public let deviceId: String
        public let protocolPublicKeyFingerprint: String
        public let platform: AdvertisementPlatform
        public let role: AdvertisementRole

        public var canonicalFields: [String: String] {
            var result = [
                "version": advertisementVersion,
                "deviceId": deviceId,
                "pubKeyFP": protocolPublicKeyFingerprint,
                "platform": platform.rawValue
            ]
            if role == .control {
                result["hs_soa"] = "1"
            }
            return result
        }
    }

    /// The only Bonjour values allowed to influence the discovery runtime.
    ///
    /// Bonjour is not an authentication boundary: these values remain peer
    /// claims until the protocol handshake proves the advertised key. Keeping
    /// this projection narrow prevents legacy presentation, capability and
    /// route fields from being mistaken for authenticated product state.
    public struct DiscoveryProjection: Sendable, Equatable {
        public enum Generation: String, Sendable, Equatable {
            case version2
            case legacy
        }

        public let generation: Generation
        public let deviceId: String?
        public let protocolPublicKeyFingerprint: String?
        public let platform: AdvertisementPlatform?
        public let advertisesStrongOwnerAuthentication: Bool

        public init(
            generation: Generation,
            deviceId: String?,
            protocolPublicKeyFingerprint: String?,
            platform: AdvertisementPlatform?,
            advertisesStrongOwnerAuthentication: Bool
        ) {
            self.generation = generation
            self.deviceId = deviceId
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            self.platform = platform
            self.advertisesStrongOwnerAuthentication = advertisesStrongOwnerAuthentication
        }
    }

    public enum DecodedAdvertisement: Sendable, Equatable {
        case version2(Version2Advertisement)
        case legacy(fields: [String: String])

        public var discoveryProjection: DiscoveryProjection {
            switch self {
            case .version2(let advertisement):
                return DiscoveryProjection(
                    generation: .version2,
                    deviceId: advertisement.deviceId,
                    protocolPublicKeyFingerprint: advertisement.protocolPublicKeyFingerprint,
                    platform: advertisement.platform,
                    advertisesStrongOwnerAuthentication: advertisement.role == .control
                )
            case .legacy(let fields):
                let normalizedFields = Dictionary(
                    uniqueKeysWithValues: fields.map { ($0.key.lowercased(), $0.value) }
                )
                let deviceId = firstLegacyValue(
                    in: normalizedFields,
                    aliases: deviceIdentityTXTKeys
                ).flatMap(normalizedDeviceId)
                let fingerprint = firstLegacyValue(
                    in: normalizedFields,
                    aliases: pubKeyFingerprintTXTKeys
                ).flatMap(normalizedPubKeyFingerprint)
                let platform = firstLegacyValue(
                    in: normalizedFields,
                    aliases: ["platform", "os"]
                )
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap(AdvertisementPlatform.init(rawValue:))

                return DiscoveryProjection(
                    generation: .legacy,
                    deviceId: deviceId,
                    protocolPublicKeyFingerprint: fingerprint,
                    platform: platform,
                    advertisesStrongOwnerAuthentication: false
                )
            }
        }

        private func firstLegacyValue(
            in normalizedFields: [String: String],
            aliases: [String]
        ) -> String? {
            for alias in aliases {
                if let value = normalizedFields[alias.lowercased()] {
                    return value
                }
            }
            return nil
        }
    }

    /// Apple recommends keeping Bonjour TXT payloads around 100–200 bytes. This
    /// is a protocol limit for SkyBridge advertisements, not a truncation target:
    /// an identity that cannot fit is rejected before anything is published.
    public static let maximumRecommendedTXTRecordWireBytes = 200
    public static let maximumAcceptedTXTRecordWireBytes = 1_300
    public static let advertisementVersion = "2"
    public static let minimumDeviceIdLength = 16
    public static let maximumDeviceIdLength = 128
    private static let allowedDeviceIdScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"
    )
    public static let canonicalBaseAdvertisementTXTKeys = [
        "version",
        "deviceId",
        "pubKeyFP",
        "platform"
    ]
    public static let controlAdditionalAdvertisementTXTKeys = ["hs_soa"]
    public static let canonicalAdvertisementTXTKeys =
        canonicalBaseAdvertisementTXTKeys + controlAdditionalAdvertisementTXTKeys

    public static let legacyQuicPrimaryServiceType = "_skybridge._udp"
    public static let controlServiceType = "_skybridge._tcp"
    /// Version-2 dedicated service names use DNS-SD application labels no
    /// longer than 15 bytes. The version-1 labels exceeded that protocol limit
    /// and therefore could never be treated as reliable registration targets.
    public static let fileTransferServiceType = "_skybridge-xfer._tcp"
    public static let remoteControlServiceType = "_skybridge-rd._tcp"
    public static let legacyFileTransferServiceType = "_skybridge-transfer._tcp"
    public static let legacyRemoteControlServiceType = "_skybridge-remote._tcp"
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
        remoteControlServiceType,
        legacyFileTransferServiceType,
        legacyRemoteControlServiceType
    ]

    public static let legacyDedicatedServiceTypes = [
        legacyFileTransferServiceType,
        legacyRemoteControlServiceType
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

    /// Builds the complete version-2 discovery payload. DNS-SD service type and
    /// SRV data already carry capability and port ownership, while authenticated
    /// handshakes carry mutable presentation and codec metadata.
    public static func canonicalAdvertisementFields(
        deviceId: String,
        pubKeyFingerprint: String,
        platform: AdvertisementPlatform,
        role: AdvertisementRole
    ) throws -> [String: String] {
        guard normalizedDeviceId(deviceId) == deviceId else {
            throw AdvertisementError.invalidDeviceId
        }
        guard let fingerprint = normalizedPubKeyFingerprint(pubKeyFingerprint) else {
            throw AdvertisementError.invalidPubKeyFingerprint
        }
        var fields = [
            "version": advertisementVersion,
            "deviceId": deviceId,
            "pubKeyFP": fingerprint,
            "platform": platform.rawValue
        ]
        if role == .control {
            fields["hs_soa"] = "1"
        }
        try validateAdvertisementWireSize(fields)
        return fields
    }

    /// Encodes the canonical DNS-SD TXT wire representation shared by every
    /// Apple publisher and the Android interoperability contract.
    ///
    /// TXT dictionaries are deliberately not exposed at this boundary because
    /// their hash-table iteration order is process-randomized. Keys are sorted
    /// by their unsigned raw UTF-8 bytes before length-prefixed fields are
    /// appended, matching Android's canonical unsigned-key ordering.
    public static func canonicalAdvertisementWireData(
        deviceId: String,
        pubKeyFingerprint: String,
        platform: AdvertisementPlatform,
        role: AdvertisementRole
    ) throws -> Data {
        let fields = try canonicalAdvertisementFields(
            deviceId: deviceId,
            pubKeyFingerprint: pubKeyFingerprint,
            platform: platform,
            role: role
        )
        var data = Data()
        for (key, value) in fields.sorted(by: canonicalRawKeyOrder) {
            let keyBytes = Array(key.utf8)
            let valueBytes = Array(value.utf8)
            let fieldByteCount = keyBytes.count + 1 + valueBytes.count
            guard fieldByteCount <= Int(UInt8.max) else {
                throw AdvertisementError.fieldExceedsDNSServiceLimit(
                    key: key,
                    bytes: fieldByteCount
                )
            }
            data.append(UInt8(fieldByteCount))
            data.append(contentsOf: keyBytes)
            data.append(0x3D)
            data.append(contentsOf: valueBytes)
        }
        return data
    }

    /// Returns the DNS-SD TXT wire size, including the one-byte length prefix for
    /// every `key=value` entry. It intentionally does not depend on Network.framework.
    public static func txtRecordWireSize(_ fields: [String: String]) throws -> Int {
        var total = 0
        for (key, value) in fields {
            let entryBytes = key.utf8.count + 1 + value.utf8.count
            guard entryBytes <= UInt8.max else {
                throw AdvertisementError.fieldExceedsDNSServiceLimit(
                    key: key,
                    bytes: entryBytes
                )
            }
            total += 1 + entryBytes
        }
        return total
    }

    public static func validateAdvertisementWireSize(_ fields: [String: String]) throws {
        let bytes = try txtRecordWireSize(fields)
        guard bytes <= maximumRecommendedTXTRecordWireBytes else {
            throw AdvertisementError.recordExceedsRecommendedSize(
                bytes: bytes,
                maximum: maximumRecommendedTXTRecordWireBytes
            )
        }
    }

    private static func canonicalRawKeyOrder(
        _ lhs: Dictionary<String, String>.Element,
        _ rhs: Dictionary<String, String>.Element
    ) -> Bool {
        lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
    }

    /// Decodes raw DNS-SD TXT bytes without first collapsing them into a
    /// dictionary, so duplicate and case-colliding keys cannot bypass v2 checks.
    /// A record declaring version 2 is never retried through legacy aliases.
    public static func decodeAdvertisement(
        _ data: Data,
        role: AdvertisementRole
    ) throws -> DecodedAdvertisement {
        // Bound work before parsing. The 200-byte version-2 budget below is a
        // canonical protocol rule; this larger ceiling is the parser safety
        // boundary shared by legacy and malformed/versioned input.
        guard data.count <= maximumAcceptedTXTRecordWireBytes else {
            throw AdvertisementError.recordExceedsParserSafetyLimit(
                bytes: data.count,
                maximum: maximumAcceptedTXTRecordWireBytes
            )
        }
        let fields = try decodeRawFields(data)
        // Key casing is part of the canonical v2 schema, but it must not be a
        // downgrade oracle. Classify a case-variant Version=2 as v2 first, then
        // reject the non-canonical field set below.
        guard let version = fields.first(where: {
            $0.key.lowercased() == "version"
        })?.value else {
            return .legacy(fields: fields)
        }

        guard version == advertisementVersion else {
            guard ["1", "1.0", "1.0.0"].contains(version) else {
                throw AdvertisementError.unsupportedVersion(version)
            }
            return .legacy(fields: fields)
        }

        let expectedKeys = Set(
            canonicalBaseAdvertisementTXTKeys
                + (role == .control ? controlAdditionalAdvertisementTXTKeys : [])
        )
        guard Set(fields.keys) == expectedKeys,
              let deviceId = fields["deviceId"],
              let fingerprint = fields["pubKeyFP"],
              let platformRaw = fields["platform"],
              let platform = AdvertisementPlatform(rawValue: platformRaw) else {
            throw AdvertisementError.invalidVersion2FieldSet
        }
        guard data.count <= maximumRecommendedTXTRecordWireBytes else {
            throw AdvertisementError.recordExceedsRecommendedSize(
                bytes: data.count,
                maximum: maximumRecommendedTXTRecordWireBytes
            )
        }
        if role == .control, fields["hs_soa"] != "1" {
            throw AdvertisementError.invalidStrongOwnerAuthenticationFlag
        }

        let canonicalFields = try canonicalAdvertisementFields(
            deviceId: deviceId,
            pubKeyFingerprint: fingerprint,
            platform: platform,
            role: role
        )
        guard canonicalFields == fields else {
            throw AdvertisementError.invalidVersion2FieldSet
        }
        return .version2(Version2Advertisement(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: fingerprint,
            platform: platform,
            role: role
        ))
    }

    private static func decodeRawFields(_ data: Data) throws -> [String: String] {
        var fields: [String: String] = [:]
        var normalizedKeys = Set<String>()
        var index = data.startIndex

        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard length > 0 else {
                throw AdvertisementError.emptyField
            }
            guard data.distance(from: index, to: data.endIndex) >= length else {
                throw AdvertisementError.truncatedField
            }
            let fieldEnd = data.index(index, offsetBy: length)
            let fieldData = data[index..<fieldEnd]
            index = fieldEnd

            guard let field = String(data: fieldData, encoding: .utf8) else {
                throw AdvertisementError.invalidUTF8
            }
            guard let separator = field.firstIndex(of: "="),
                  separator != field.startIndex else {
                throw AdvertisementError.malformedField
            }
            let key = String(field[..<separator])
            let value = String(field[field.index(after: separator)...])
            guard !value.isEmpty,
                  key.utf8.count <= 63,
                  key.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII
                          && scalar.value >= 0x21
                          && scalar.value <= 0x7e
                          && scalar != "="
                  }) else {
                throw AdvertisementError.malformedField
            }
            let normalizedKey = key.lowercased()
            guard normalizedKeys.insert(normalizedKey).inserted else {
                throw AdvertisementError.duplicateKey(key)
            }
            fields[key] = value
        }
        return fields
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

    public static func normalizedDeviceId(_ raw: String?) -> String? {
        guard let value = raw,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              (minimumDeviceIdLength...maximumDeviceIdLength).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && allowedDeviceIdScalars.contains(scalar)
              }) else {
            return nil
        }
        return value
    }

    public static func isValidPubKeyFingerprint(_ value: String) -> Bool {
        normalizedPubKeyFingerprint(value) != nil
    }

    /// Validates the `_application._tcp` / `_application._udp` shape used by
    /// Apple DNS-SD APIs. `application` is intentionally bounded by UTF-8 bytes,
    /// not grapheme count, because it is a DNS label on the wire.
    public static func isValidDNSServiceType(_ raw: String) -> Bool {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("_") else {
            return false
        }
        let transportSuffix: String
        if raw.hasSuffix("._tcp") {
            transportSuffix = "._tcp"
        } else if raw.hasSuffix("._udp") {
            transportSuffix = "._udp"
        } else {
            return false
        }

        let labelStart = raw.index(after: raw.startIndex)
        let labelEnd = raw.index(raw.endIndex, offsetBy: -transportSuffix.count)
        guard labelStart < labelEnd else { return false }
        let label = raw[labelStart..<labelEnd]
        guard (1...15).contains(label.utf8.count),
              label.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && ((scalar.value >= 0x41 && scalar.value <= 0x5a)
                          || (scalar.value >= 0x61 && scalar.value <= 0x7a)
                          || (scalar.value >= 0x30 && scalar.value <= 0x39)
                          || scalar.value == 0x2d)
              }),
              let first = label.unicodeScalars.first,
              let last = label.unicodeScalars.last,
              first.value != 0x2d,
              last.value != 0x2d,
              label.unicodeScalars.contains(where: { scalar in
                  (scalar.value >= 0x41 && scalar.value <= 0x5a)
                      || (scalar.value >= 0x61 && scalar.value <= 0x7a)
              }) else {
            return false
        }
        return true
    }

}
