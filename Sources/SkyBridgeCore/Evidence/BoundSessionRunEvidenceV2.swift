import CryptoKit
import Foundation

enum BoundSessionRunEvidenceV2Error: Error, LocalizedError, Sendable, Equatable {
    case invalidText(String)
    case invalidIdentifier(String)
    case invalidEndpointIdentifier
    case invalidTimestamp(String)
    case invalidCollection(String)
    case duplicateValue(String)
    case invalidEndpointOrder
    case invalidRelativePath
    case excludedArtifactKind(BoundSessionEvidenceArtifactKindV2)
    case invalidFieldLength(name: String, actual: Int)
    case zeroField(String)
    case invalidDirection(String)
    case duplicateDirectionEvidence(String)
    case signerIdentityMismatch
    case invalidEncodedSize(name: String, actual: Int, expected: Int)
    case invalidIdentityPublicKeyLength(Int)
    case invalidStatementHeader

    var errorDescription: String? {
        switch self {
        case .invalidText(let name):
            "RunEvidenceV2 contains invalid text for \(name)"
        case .invalidIdentifier(let name):
            "RunEvidenceV2 contains a noncanonical identifier for \(name)"
        case .invalidEndpointIdentifier:
            "RunEvidenceV2 endpoint identifier is not canonical ASCII"
        case .invalidTimestamp(let name):
            "RunEvidenceV2 \(name) is not a real canonical UTC timestamp"
        case .invalidCollection(let name):
            "RunEvidenceV2 contains an invalid collection for \(name)"
        case .duplicateValue(let name):
            "RunEvidenceV2 contains a duplicate \(name)"
        case .invalidEndpointOrder:
            "RunEvidenceV2 endpoints must be distinct and ordered initiator then responder"
        case .invalidRelativePath:
            "RunEvidenceV2 artifact path is not a canonical relative POSIX path"
        case .excludedArtifactKind(let kind):
            "RunEvidenceV2 claim closure cannot contain post-signature artifact kind \(kind.rawValue)"
        case .invalidFieldLength(let name, let actual):
            "RunEvidenceV2 \(name) must be exactly 32 bytes, got \(actual)"
        case .zeroField(let name):
            "RunEvidenceV2 \(name) must not be all zero"
        case .invalidDirection(let reason):
            "RunEvidenceV2 direction is invalid: \(reason)"
        case .duplicateDirectionEvidence(let name):
            "RunEvidenceV2 direction slots reuse \(name)"
        case .signerIdentityMismatch:
            "RunEvidenceV2 signer is not one of the two authenticated identities"
        case .invalidEncodedSize(let name, let actual, let expected):
            "RunEvidenceV2 \(name) has \(actual) bytes instead of \(expected)"
        case .invalidIdentityPublicKeyLength(let length):
            "RunEvidenceV2 ML-DSA-65 public key has invalid length \(length)"
        case .invalidStatementHeader:
            "RunEvidenceV2 signature input is not one exact canonical V2 statement"
        }
    }
}

enum BoundSessionEvidenceEndpointRoleV2: String, Sendable, Equatable {
    case initiator
    case responder
}

enum BoundSessionEvidencePlatformV2: String, Sendable, Equatable {
    case android
    case ios
    case macos
    case windows
    case linux
}

enum BoundSessionEvidenceDeviceClassV2: String, Sendable, Equatable {
    case phone
    case tablet
    case computer
}

enum BoundSessionEvidenceExecutionEnvironmentV2: String, Sendable, Equatable {
    case physicalDevice = "physical_device"
    case simulator
    case emulator
    case virtualMachine = "virtual_machine"
    case container
}

enum BoundSessionEvidenceClassV2: String, Sendable, Equatable {
    case diagnostic
    case sourceCapability = "source_capability"
    case physicalProductInterop = "physical_product_interop"
}

enum BoundSessionEvidenceClaimIDV2: String, Sendable, Equatable {
    case applePhysicalE2E = "BS-APPLE-PHYSICAL-E2E"
    case fileDurableReceipt = "BS-FILE-DURABLE-RECEIPT"
    case nonAppleInterop = "BS-NONAPPLE-INTEROP"
}

enum BoundSessionEvidenceUnsupportedFeatureV2: String, Sendable, Equatable {
    case messages
    case remoteDesktop = "remote_desktop"
}

enum BoundSessionEvidenceArtifactKindV2: String, Sendable, Equatable {
    case preregistration
    case sourceFreeze = "source_freeze"
    case buildRecord = "build_record"
    case sourceTreeManifest = "source_tree_manifest"
    case binary
    case deviceRecord = "device_record"
    case iceObservation = "ice_observation"
    case boundSessionReport = "bound_session_report"
    case messageA = "message_a"
    case messageB = "message_b"
    case finished
    case grantReady = "grant_ready"
    case fileTransferRecord = "file_transfer_record"
    case fileSource = "file_source"
    case fileReceiver = "file_receiver"
    case durableCommit = "durable_commit"
    case effectReceiptWire = "effect_receipt_wire"
    case receiptVerification = "receipt_verification"
    case authorityAcceptance = "authority_acceptance"
    case trustSnapshot = "trust_snapshot"
    case cleanupRecord = "cleanup_record"
    case sourceSnapshotArchive = "source_snapshot_archive"
    case wireAuthenticationAcceptance = "wire_authentication_acceptance"
    case eventJournal = "event_journal"
    case runEvidenceStatement = "run_evidence_statement"
    case runEvidenceSignature = "run_evidence_signature"
    case identityRegistry = "identity_registry"
    case offlineVerifierBinary = "offline_verifier_binary"
    case offlineVerifierResult = "offline_verifier_result"

    fileprivate var isExcludedFromClaimCriticalClosure: Bool {
        switch self {
        case .runEvidenceStatement, .runEvidenceSignature, .identityRegistry,
            .offlineVerifierBinary, .offlineVerifierResult:
            true
        default:
            false
        }
    }
}

struct BoundSessionEvidenceEndpointDescriptorV2: Sendable, Equatable {
    let identifier: String
    let role: BoundSessionEvidenceEndpointRoleV2
    let platform: BoundSessionEvidencePlatformV2
    let deviceClass: BoundSessionEvidenceDeviceClassV2
    let executionEnvironment: BoundSessionEvidenceExecutionEnvironmentV2
    let devicePseudonymSHA256: Data
}

struct BoundSessionEvidenceUnsupportedClaimV2: Sendable, Equatable {
    let feature: BoundSessionEvidenceUnsupportedFeatureV2
    let reason: String
}

struct BoundSessionEvidenceArtifactDescriptorV2: Sendable, Equatable {
    let identifier: String
    let kind: BoundSessionEvidenceArtifactKindV2
    let relativePath: String
    let sha256: Data
    let sizeBytes: UInt64
    let mediaType: String
}

struct BoundSessionEvidenceCleanupProjectionV2: Sendable, Equatable {
    let ownershipVerified: Bool
    let sessionTerminated: Bool
    let foreignResourcesTouched: Bool
}

struct BoundSessionClaimCriticalClosureInputV2: Sendable, Equatable {
    let evidenceIdentifier: String
    let evidenceClass: BoundSessionEvidenceClassV2
    let claimEligible: Bool
    let relatedClaimIDs: [BoundSessionEvidenceClaimIDV2]
    let claimedClaimIDs: [BoundSessionEvidenceClaimIDV2]
    let runStartedAt: String
    let runCompletedAt: String
    let cleanup: BoundSessionEvidenceCleanupProjectionV2
    let endpoints: [BoundSessionEvidenceEndpointDescriptorV2]
    let unsupportedClaims: [BoundSessionEvidenceUnsupportedClaimV2]
    let limitations: [String]
    let preSignatureArtifacts: [BoundSessionEvidenceArtifactDescriptorV2]
}

/// A structured closure encoder is the only constructor for this digest.
/// There is deliberately no initializer that accepts an opaque digest.
struct BoundSessionEncodedClaimCriticalClosureV2: Sendable, Equatable {
    let exactBytes: Data
    let sha256: Data

    fileprivate init(exactBytes: Data, sha256: Data) {
        self.exactBytes = exactBytes
        self.sha256 = sha256
    }
}

enum BoundSessionClaimCriticalClosureEncoderV2 {
    static let contractIdentifier = "policy-purpose-bound-session/experiment-evidence/v2"
    static let productScope = "bidirectional_file_transfer_v2"
    static let maximumEncodedByteCount = 2 * 1_024 * 1_024

    private static let digestDomain = Data("bound-session/claim-critical-closure/v2".utf8)
    private static let maximumArtifactCount = 256
    private static let maximumLimitationCount = 32

    static func encode(
        _ input: BoundSessionClaimCriticalClosureInputV2
    ) throws -> BoundSessionEncodedClaimCriticalClosureV2 {
        try requireIdentifier(input.evidenceIdentifier, name: "evidence identifier")
        try requireTimestamp(input.runStartedAt, name: "run start")
        try requireTimestamp(input.runCompletedAt, name: "run completion")
        guard input.runStartedAt <= input.runCompletedAt else {
            throw BoundSessionRunEvidenceV2Error.invalidTimestamp("run interval")
        }

        let relatedClaims = try sortedUniqueRawValues(
            input.relatedClaimIDs,
            maximum: 3,
            name: "related claim ID"
        )
        let claimedClaims = try sortedUniqueRawValues(
            input.claimedClaimIDs,
            maximum: 3,
            name: "claimed claim ID"
        )
        let endpoints = try validatedEndpoints(input.endpoints)
        let unsupportedClaims = try validatedUnsupportedClaims(input.unsupportedClaims)
        let limitations = try sortedUniqueText(
            input.limitations,
            minimum: 1,
            maximum: maximumLimitationCount,
            byteLimit: 4_096,
            name: "limitation"
        )
        let artifacts = try validatedArtifacts(input.preSignatureArtifacts)

        var body = Data()
        appendBigEndian(UInt32(2), to: &body)
        try appendText(contractIdentifier, maximumBytes: 128, name: "contract identifier", to: &body)
        try appendText(input.evidenceIdentifier, maximumBytes: 128, name: "evidence identifier", to: &body)
        try appendText(input.evidenceClass.rawValue, maximumBytes: 64, name: "evidence class", to: &body)
        try appendText(productScope, maximumBytes: 64, name: "product scope", to: &body)
        appendBigEndian(input.claimEligible ? UInt32(1) : UInt32(0), to: &body)
        try appendTextSet(relatedClaims, maximumBytes: 64, name: "related claim ID", to: &body)
        try appendTextSet(claimedClaims, maximumBytes: 64, name: "claimed claim ID", to: &body)
        try appendText(input.runStartedAt, maximumBytes: 20, name: "run start", to: &body)
        try appendText(input.runCompletedAt, maximumBytes: 20, name: "run completion", to: &body)
        appendBigEndian(cleanupBits(input.cleanup), to: &body)

        appendBigEndian(UInt32(endpoints.count), to: &body)
        for endpoint in endpoints {
            try appendText(endpoint.identifier, maximumBytes: 128, name: "endpoint identifier", to: &body)
            try appendText(endpoint.role.rawValue, maximumBytes: 16, name: "endpoint role", to: &body)
            try appendText(endpoint.platform.rawValue, maximumBytes: 16, name: "platform", to: &body)
            try appendText(endpoint.deviceClass.rawValue, maximumBytes: 16, name: "device class", to: &body)
            try appendText(
                endpoint.executionEnvironment.rawValue,
                maximumBytes: 32,
                name: "execution environment",
                to: &body
            )
            body.append(endpoint.devicePseudonymSHA256)
        }

        appendBigEndian(UInt32(unsupportedClaims.count), to: &body)
        for unsupported in unsupportedClaims {
            try appendText(unsupported.feature.rawValue, maximumBytes: 32, name: "unsupported feature", to: &body)
            try appendText("not_claimed", maximumBytes: 32, name: "unsupported status", to: &body)
            try appendText(unsupported.reason, maximumBytes: 4_096, name: "unsupported reason", to: &body)
        }
        try appendTextSet(limitations, maximumBytes: 4_096, name: "limitation", to: &body)

        appendBigEndian(UInt32(artifacts.count), to: &body)
        for artifact in artifacts {
            try appendText(artifact.identifier, maximumBytes: 128, name: "artifact identifier", to: &body)
            try appendText(artifact.kind.rawValue, maximumBytes: 64, name: "artifact kind", to: &body)
            try appendText(artifact.relativePath, maximumBytes: 1_024, name: "artifact path", to: &body)
            body.append(artifact.sha256)
            appendBigEndian(artifact.sizeBytes, to: &body)
            try appendText(artifact.mediaType, maximumBytes: 256, name: "artifact media type", to: &body)
        }

        guard let encodedSize = UInt32(exactly: 16 + body.count),
            encodedSize <= UInt32(maximumEncodedByteCount)
        else {
            throw BoundSessionRunEvidenceV2Error.invalidEncodedSize(
                name: "claim-critical closure",
                actual: 16 + body.count,
                expected: maximumEncodedByteCount
            )
        }
        var encoded = Data("BSCLMV2\0".utf8)
        appendBigEndian(UInt32(2), to: &encoded)
        appendBigEndian(encodedSize, to: &encoded)
        encoded.append(body)
        guard encoded.count == Int(encodedSize) else {
            throw BoundSessionRunEvidenceV2Error.invalidEncodedSize(
                name: "claim-critical closure",
                actual: encoded.count,
                expected: Int(encodedSize)
            )
        }
        var digestInput = digestDomain
        digestInput.append(encoded)
        return BoundSessionEncodedClaimCriticalClosureV2(
            exactBytes: encoded,
            sha256: Data(SHA256.hash(data: digestInput))
        )
    }

    private static func validatedEndpoints(
        _ endpoints: [BoundSessionEvidenceEndpointDescriptorV2]
    ) throws -> [BoundSessionEvidenceEndpointDescriptorV2] {
        guard endpoints.count == 2,
            endpoints[0].role == .initiator,
            endpoints[1].role == .responder,
            endpoints[0].identifier != endpoints[1].identifier,
            endpoints[0].devicePseudonymSHA256 != endpoints[1].devicePseudonymSHA256
        else {
            throw BoundSessionRunEvidenceV2Error.invalidEndpointOrder
        }
        for endpoint in endpoints {
            try requireIdentifier(endpoint.identifier, name: "endpoint identifier")
            try requireNonzeroHash(endpoint.devicePseudonymSHA256, name: "device pseudonym")
        }
        return endpoints
    }

    private static func validatedUnsupportedClaims(
        _ claims: [BoundSessionEvidenceUnsupportedClaimV2]
    ) throws -> [BoundSessionEvidenceUnsupportedClaimV2] {
        guard claims.count == 2,
            Set(claims.map(\.feature.rawValue)).count == 2
        else {
            throw BoundSessionRunEvidenceV2Error.invalidCollection("unsupported claims")
        }
        for claim in claims {
            try requireSafeText(claim.reason, maximumBytes: 4_096, name: "unsupported reason")
        }
        return claims.sorted { utf8Less($0.feature.rawValue, $1.feature.rawValue) }
    }

    private static func validatedArtifacts(
        _ artifacts: [BoundSessionEvidenceArtifactDescriptorV2]
    ) throws -> [BoundSessionEvidenceArtifactDescriptorV2] {
        guard (1...maximumArtifactCount).contains(artifacts.count) else {
            throw BoundSessionRunEvidenceV2Error.invalidCollection("pre-signature artifacts")
        }
        guard Set(artifacts.map(\.identifier)).count == artifacts.count else {
            throw BoundSessionRunEvidenceV2Error.duplicateValue("artifact identifier")
        }
        for artifact in artifacts {
            try requireIdentifier(artifact.identifier, name: "artifact identifier")
            guard !artifact.kind.isExcludedFromClaimCriticalClosure else {
                throw BoundSessionRunEvidenceV2Error.excludedArtifactKind(artifact.kind)
            }
            try requireCanonicalRelativePath(artifact.relativePath)
            try requireNonzeroHash(artifact.sha256, name: "artifact SHA-256")
            try requireSafeText(artifact.mediaType, maximumBytes: 256, name: "artifact media type")
        }
        return artifacts.sorted { utf8Less($0.identifier, $1.identifier) }
    }

    private static func sortedUniqueRawValues<Value: RawRepresentable>(
        _ values: [Value],
        maximum: Int,
        name: String
    ) throws -> [String] where Value.RawValue == String {
        guard values.count <= maximum else {
            throw BoundSessionRunEvidenceV2Error.invalidCollection(name)
        }
        let rawValues = values.map(\.rawValue)
        guard Set(rawValues).count == rawValues.count else {
            throw BoundSessionRunEvidenceV2Error.duplicateValue(name)
        }
        return rawValues.sorted(by: utf8Less)
    }

    private static func sortedUniqueText(
        _ values: [String],
        minimum: Int,
        maximum: Int,
        byteLimit: Int,
        name: String
    ) throws -> [String] {
        guard (minimum...maximum).contains(values.count) else {
            throw BoundSessionRunEvidenceV2Error.invalidCollection(name)
        }
        guard Set(values).count == values.count else {
            throw BoundSessionRunEvidenceV2Error.duplicateValue(name)
        }
        for value in values {
            try requireSafeText(value, maximumBytes: byteLimit, name: name)
        }
        return values.sorted(by: utf8Less)
    }

    private static func cleanupBits(_ cleanup: BoundSessionEvidenceCleanupProjectionV2) -> UInt32 {
        var bits = UInt32(0)
        if cleanup.ownershipVerified { bits |= 1 << 0 }
        if cleanup.sessionTerminated { bits |= 1 << 1 }
        if cleanup.foreignResourcesTouched { bits |= 1 << 2 }
        return bits
    }

    private static func appendTextSet(
        _ values: [String],
        maximumBytes: Int,
        name: String,
        to data: inout Data
    ) throws {
        appendBigEndian(UInt32(values.count), to: &data)
        for value in values {
            try appendText(value, maximumBytes: maximumBytes, name: name, to: &data)
        }
    }

    private static func appendText(
        _ value: String,
        maximumBytes: Int,
        name: String,
        to data: inout Data
    ) throws {
        try requireSafeText(value, maximumBytes: maximumBytes, name: name)
        let bytes = Data(value.utf8)
        guard let length = UInt32(exactly: bytes.count) else {
            throw BoundSessionRunEvidenceV2Error.invalidText(name)
        }
        appendBigEndian(length, to: &data)
        data.append(bytes)
    }

    private static func requireIdentifier(_ value: String, name: String) throws {
        try requireSafeText(value, maximumBytes: 128, name: name)
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw BoundSessionRunEvidenceV2Error.invalidIdentifier(name)
        }
        guard (0x61...0x7A).contains(bytes[0]) || (0x30...0x39).contains(bytes[0]) else {
            throw BoundSessionRunEvidenceV2Error.invalidIdentifier(name)
        }
        var previousWasSeparator = false
        for byte in bytes {
            let isAlphanumeric = (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            let isSeparator = byte == 0x2D || byte == 0x5F
            guard isAlphanumeric || isSeparator,
                !(isSeparator && previousWasSeparator)
            else {
                throw BoundSessionRunEvidenceV2Error.invalidIdentifier(name)
            }
            previousWasSeparator = isSeparator
        }
        guard !previousWasSeparator else {
            throw BoundSessionRunEvidenceV2Error.invalidIdentifier(name)
        }
    }

    private static func requireSafeText(
        _ value: String,
        maximumBytes: Int,
        name: String
    ) throws {
        guard !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            value.utf8.count <= maximumBytes,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw BoundSessionRunEvidenceV2Error.invalidText(name)
        }
    }

    private static func requireTimestamp(_ value: String, name: String) throws {
        let bytes = Array(value.utf8)
        let digitIndexes = Set([0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18])
        guard bytes.count == 20,
            bytes[0] == 0x32,
            bytes[1] == 0x30,
            bytes[4] == 0x2D,
            bytes[7] == 0x2D,
            bytes[10] == 0x54,
            bytes[13] == 0x3A,
            bytes[16] == 0x3A,
            bytes[19] == 0x5A,
            digitIndexes.allSatisfy({ (0x30...0x39).contains(bytes[$0]) })
        else {
            throw BoundSessionRunEvidenceV2Error.invalidTimestamp(name)
        }
        let year = decimal(bytes, 0, 4)
        let month = decimal(bytes, 5, 2)
        let day = decimal(bytes, 8, 2)
        let hour = decimal(bytes, 11, 2)
        let minute = decimal(bytes, 14, 2)
        let second = decimal(bytes, 17, 2)
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            throw BoundSessionRunEvidenceV2Error.invalidTimestamp(name)
        }
        calendar.timeZone = utc
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else {
            throw BoundSessionRunEvidenceV2Error.invalidTimestamp(name)
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
            roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second
        else {
            throw BoundSessionRunEvidenceV2Error.invalidTimestamp(name)
        }
    }

    private static func decimal(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        bytes[offset..<(offset + count)].reduce(0) { ($0 * 10) + Int($1 - 0x30) }
    }

    private static func requireCanonicalRelativePath(_ value: String) throws {
        try requireSafeText(value, maximumBytes: 1_024, name: "artifact path")
        guard !value.hasPrefix("/"), !value.contains("\\") else {
            throw BoundSessionRunEvidenceV2Error.invalidRelativePath
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw BoundSessionRunEvidenceV2Error.invalidRelativePath
        }
    }

    private static func requireNonzeroHash(_ value: Data, name: String) throws {
        guard value.count == 32 else {
            throw BoundSessionRunEvidenceV2Error.invalidFieldLength(name: name, actual: value.count)
        }
        guard value.contains(where: { $0 != 0 }) else {
            throw BoundSessionRunEvidenceV2Error.zeroField(name)
        }
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func appendBigEndian<Integer: FixedWidthInteger>(
        _ value: Integer,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

struct BoundSessionEncodedIdentityRegistryV2: Sendable, Equatable {
    let exactBytes: Data
    let endpointIdentifierDigest: Data
    let identityFingerprint: Data

    fileprivate init(
        exactBytes: Data,
        endpointIdentifierDigest: Data,
        identityFingerprint: Data
    ) {
        self.exactBytes = exactBytes
        self.endpointIdentifierDigest = endpointIdentifierDigest
        self.identityFingerprint = identityFingerprint
    }
}

enum BoundSessionIdentityRegistryEncoderV2 {
    static let encodedByteCount = 2_064
    static let publicKeyByteCount = 1_952

    static func encode(
        endpointIdentifier: String,
        publicVerificationKey: Data
    ) throws -> BoundSessionEncodedIdentityRegistryV2 {
        guard publicVerificationKey.count == publicKeyByteCount else {
            throw BoundSessionRunEvidenceV2Error.invalidIdentityPublicKeyLength(publicVerificationKey.count)
        }
        guard publicVerificationKey.contains(where: { $0 != 0 }) else {
            throw BoundSessionRunEvidenceV2Error.zeroField("ML-DSA-65 public key")
        }
        let endpointDigest = try BoundSessionRunStatementEncoderV2.endpointIdentifierDigest(endpointIdentifier)
        let fingerprint = identityFingerprint(publicKey: publicVerificationKey)
        var encoded = Data("BSREGV2\0".utf8)
        appendBigEndian(UInt32(2), to: &encoded)
        appendBigEndian(UInt32(encodedByteCount), to: &encoded)
        encoded.append(endpointDigest)
        encoded.append(fingerprint)
        encoded.append(publicVerificationKey)
        encoded.append(Data(repeating: 0, count: 32))
        guard encoded.count == encodedByteCount else {
            throw BoundSessionRunEvidenceV2Error.invalidEncodedSize(
                name: "identity registry",
                actual: encoded.count,
                expected: encodedByteCount
            )
        }
        return BoundSessionEncodedIdentityRegistryV2(
            exactBytes: encoded,
            endpointIdentifierDigest: endpointDigest,
            identityFingerprint: fingerprint
        )
    }

    static func identityFingerprint(publicKey: Data) -> Data {
        var input = Data()
        appendLittleEndian(UInt16(9), to: &input)
        input.append(Data("ML-DSA-65".utf8))
        appendLittleEndian(UInt32(publicKey.count), to: &input)
        input.append(publicKey)
        return Data(SHA256.hash(data: input))
    }

    private static func appendBigEndian<Integer: FixedWidthInteger>(
        _ value: Integer,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func appendLittleEndian<Integer: FixedWidthInteger>(
        _ value: Integer,
        to data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

enum BoundSessionEvidenceDirectionV2: UInt32, Sendable, Hashable {
    case initiatorToResponder = 1
    case responderToInitiator = 2
}

struct BoundSessionDirectionEvidenceV2: Sendable, Equatable {
    let direction: BoundSessionEvidenceDirectionV2
    let peerSessionID: Data
    let contextDigest: Data
    let transcriptDigest: Data
    let sharedGrantID: Data
    let bilateralReadyDigest: Data
    let policySHA3Digest: Data
    let policyRootKeyFingerprint: Data
    let wireDecisionDigest: Data
    let recipientKEMPublicKeyDigest: Data
    let initiatorIdentityFingerprint: Data
    let responderIdentityFingerprint: Data
    let messageAWireSHA256: Data
    let messageBWireSHA256: Data
    let transferID: Data
    let fileContentSHA256: Data
    let authorityOperationID: Data
    let durableFileEffectDigest: Data
    let effectReceiptWireSHA256: Data
    let positiveFileByteCount: UInt64
}

struct BoundSessionRunStatementInputV2: Sendable, Equatable {
    let signerRegistry: BoundSessionEncodedIdentityRegistryV2
    let runBindingSHA256: Data
    let transportBindingSHA256: Data
    let researchSourceFreezeArtifactSHA256: Data
    let claimCriticalClosure: BoundSessionEncodedClaimCriticalClosureV2
    let signerProductSourceIdentitySHA256: Data
    let signerProductBinarySHA256: Data
    let signerDevicePseudonymSHA256: Data
    let signerJournalInstanceSHA256: Data
    let signerJournalFinalEventSHA256: Data
    let initiatorToResponder: BoundSessionDirectionEvidenceV2
    let responderToInitiator: BoundSessionDirectionEvidenceV2
}

enum BoundSessionRunStatementEncoderV2 {
    static let encodedByteCount = 1_552
    static let directionByteCount = 592

    private static let signatureDomain = Data("bound-session/run-evidence-signature/v2".utf8)
    private static let endpointDomain = Data("bound-session/evidence-endpoint-id/v1".utf8)

    static func encode(_ input: BoundSessionRunStatementInputV2) throws -> Data {
        let globalFields = [
            ("run binding", input.runBindingSHA256),
            ("transport binding", input.transportBindingSHA256),
            ("research source freeze", input.researchSourceFreezeArtifactSHA256),
            ("claim-critical closure", input.claimCriticalClosure.sha256),
            ("product source identity", input.signerProductSourceIdentitySHA256),
            ("product binary", input.signerProductBinarySHA256),
            ("device pseudonym", input.signerDevicePseudonymSHA256),
            ("journal instance", input.signerJournalInstanceSHA256),
            ("journal final event", input.signerJournalFinalEventSHA256),
        ]
        try requireNonzeroHash(input.signerRegistry.endpointIdentifierDigest, name: "signer endpoint digest")
        try requireNonzeroHash(input.signerRegistry.identityFingerprint, name: "signer identity fingerprint")
        for (name, field) in globalFields {
            try requireNonzeroHash(field, name: name)
        }
        try validateDirectionPair(
            input.initiatorToResponder,
            input.responderToInitiator,
            signerIdentityFingerprint: input.signerRegistry.identityFingerprint
        )

        var encoded = Data("BSRUNV2\0".utf8)
        appendBigEndian(UInt32(2), to: &encoded)
        appendBigEndian(UInt32(encodedByteCount), to: &encoded)
        encoded.append(input.signerRegistry.endpointIdentifierDigest)
        encoded.append(input.signerRegistry.identityFingerprint)
        for (_, field) in globalFields {
            encoded.append(field)
        }
        encoded.append(try encodeDirection(input.initiatorToResponder))
        encoded.append(try encodeDirection(input.responderToInitiator))
        guard encoded.count == encodedByteCount else {
            throw BoundSessionRunEvidenceV2Error.invalidEncodedSize(
                name: "run statement",
                actual: encoded.count,
                expected: encodedByteCount
            )
        }
        return encoded
    }

    static func signaturePreimage(for statement: Data) throws -> Data {
        guard statement.count == encodedByteCount,
            statement.prefix(8) == Data("BSRUNV2\0".utf8),
            readBigEndianUInt32(statement, at: 8) == 2,
            readBigEndianUInt32(statement, at: 12) == UInt32(encodedByteCount)
        else {
            throw BoundSessionRunEvidenceV2Error.invalidStatementHeader
        }
        var input = signatureDomain
        input.append(statement)
        return Data(SHA256.hash(data: input))
    }

    static func endpointIdentifierDigest(_ identifier: String) throws -> Data {
        let bytes = Array(identifier.utf8)
        guard (1...64).contains(bytes.count),
            let first = bytes.first,
            isASCIILetter(first),
            bytes.allSatisfy(isEndpointIdentifierByte)
        else {
            throw BoundSessionRunEvidenceV2Error.invalidEndpointIdentifier
        }
        var input = endpointDomain
        appendBigEndian(UInt32(bytes.count), to: &input)
        input.append(contentsOf: bytes)
        return Data(SHA256.hash(data: input))
    }

    private static func encodeDirection(_ direction: BoundSessionDirectionEvidenceV2) throws -> Data {
        let fields = directionFields(direction)
        for (name, field) in fields {
            try requireNonzeroHash(field, name: name)
        }
        guard direction.positiveFileByteCount > 0 else {
            throw BoundSessionRunEvidenceV2Error.invalidDirection("file byte count is zero")
        }
        var encoded = Data()
        appendBigEndian(direction.direction.rawValue, to: &encoded)
        appendBigEndian(UInt32(0), to: &encoded)
        for (_, field) in fields {
            encoded.append(field)
        }
        appendBigEndian(direction.positiveFileByteCount, to: &encoded)
        guard encoded.count == directionByteCount else {
            throw BoundSessionRunEvidenceV2Error.invalidEncodedSize(
                name: "direction slot",
                actual: encoded.count,
                expected: directionByteCount
            )
        }
        return encoded
    }

    private static func validateDirectionPair(
        _ forward: BoundSessionDirectionEvidenceV2,
        _ reverse: BoundSessionDirectionEvidenceV2,
        signerIdentityFingerprint: Data
    ) throws {
        guard forward.direction == .initiatorToResponder,
            reverse.direction == .responderToInitiator
        else {
            throw BoundSessionRunEvidenceV2Error.invalidDirection("slot order")
        }
        guard forward.initiatorIdentityFingerprint == reverse.initiatorIdentityFingerprint,
            forward.responderIdentityFingerprint == reverse.responderIdentityFingerprint,
            forward.initiatorIdentityFingerprint != forward.responderIdentityFingerprint
        else {
            throw BoundSessionRunEvidenceV2Error.invalidDirection("identity pair disagreement or alias")
        }
        guard
            signerIdentityFingerprint == forward.initiatorIdentityFingerprint
                || signerIdentityFingerprint == forward.responderIdentityFingerprint
        else {
            throw BoundSessionRunEvidenceV2Error.signerIdentityMismatch
        }
        for (name, first, second) in [
            ("peer session ID", forward.peerSessionID, reverse.peerSessionID),
            ("transfer ID", forward.transferID, reverse.transferID),
            ("authority operation ID", forward.authorityOperationID, reverse.authorityOperationID),
            ("file-content hash", forward.fileContentSHA256, reverse.fileContentSHA256),
        ] where first == second {
            throw BoundSessionRunEvidenceV2Error.duplicateDirectionEvidence(name)
        }
    }

    private static func directionFields(_ direction: BoundSessionDirectionEvidenceV2) -> [(String, Data)] {
        [
            ("peer session ID", direction.peerSessionID),
            ("context digest", direction.contextDigest),
            ("transcript digest", direction.transcriptDigest),
            ("shared grant ID", direction.sharedGrantID),
            ("bilateral Ready digest", direction.bilateralReadyDigest),
            ("policy SHA3-256 digest", direction.policySHA3Digest),
            ("policy-root key fingerprint", direction.policyRootKeyFingerprint),
            ("wire-decision digest", direction.wireDecisionDigest),
            ("recipient KEM public-key digest", direction.recipientKEMPublicKeyDigest),
            ("initiator identity fingerprint", direction.initiatorIdentityFingerprint),
            ("responder identity fingerprint", direction.responderIdentityFingerprint),
            ("Message A wire SHA-256", direction.messageAWireSHA256),
            ("Message B wire SHA-256", direction.messageBWireSHA256),
            ("transfer ID", direction.transferID),
            ("file-content SHA-256", direction.fileContentSHA256),
            ("authority operation ID", direction.authorityOperationID),
            ("durable-file effect digest", direction.durableFileEffectDigest),
            ("EffectReceipt wire SHA-256", direction.effectReceiptWireSHA256),
        ]
    }

    private static func requireNonzeroHash(_ value: Data, name: String) throws {
        guard value.count == 32 else {
            throw BoundSessionRunEvidenceV2Error.invalidFieldLength(name: name, actual: value.count)
        }
        guard value.contains(where: { $0 != 0 }) else {
            throw BoundSessionRunEvidenceV2Error.zeroField(name)
        }
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func appendBigEndian<Integer: FixedWidthInteger>(
        _ value: Integer,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isEndpointIdentifierByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x5F
            || byte == 0x2D
    }
}
