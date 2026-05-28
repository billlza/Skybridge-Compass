import CryptoKit
import Foundation

public enum SkyBridgeAppUpdateValidationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case platformMismatch(String)
    case channelMismatch(expected: String, actual: String)
    case invalidVersion(String)
    case invalidMinimumSystemVersion(String)
    case invalidDownloadURL
    case invalidReleaseNotesURL
    case invalidSHA256
    case unsupportedPackageFormat(String)
    case unsupportedDistribution(String)
    case packageNotNotarized
    case missingManifestSignature
    case unsupportedManifestSignatureAlgorithm(String)
    case missingTrustedManifestSigningKeys
    case manifestSignatureKeyNotTrusted(String)
    case invalidTrustedManifestSigningKey(String)
    case invalidManifestSignatureEncoding
    case manifestSignatureVerificationFailed
    case invalidManifestSequence(Int64)
    case manifestSequenceRollback(minimum: Int64, actual: Int64)
    case invalidPublishedAt(String)
    case invalidExpiresAt(String)
    case manifestPublishedInFuture(String)
    case manifestExpired(String)
    case manifestExpirationBeforePublication

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            return "Unsupported update manifest schema_version=\(schema)"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "Update manifest bundle_id mismatch: expected \(expected), got \(actual)"
        case .platformMismatch(let platform):
            return "Update manifest platform must be macos, got \(platform)"
        case .channelMismatch(let expected, let actual):
            return "Update manifest channel mismatch: expected \(expected), got \(actual)"
        case .invalidVersion(let version):
            return "Invalid update version: \(version)"
        case .invalidMinimumSystemVersion(let version):
            return "Invalid minimum macOS version: \(version)"
        case .invalidDownloadURL:
            return "Update download URL must use HTTPS"
        case .invalidReleaseNotesURL:
            return "Update release notes URL must use HTTPS"
        case .invalidSHA256:
            return "Update package sha256 must be 64 lowercase or uppercase hex characters"
        case .unsupportedPackageFormat(let format):
            return "Update package format must be dmg, got \(format)"
        case .unsupportedDistribution(let distribution):
            return "Update distribution must be developer-id, got \(distribution)"
        case .packageNotNotarized:
            return "Update manifest must only advertise notarized packages"
        case .missingManifestSignature:
            return "Update manifest must include an Ed25519 signature"
        case .unsupportedManifestSignatureAlgorithm(let algorithm):
            return "Update manifest signature algorithm must be ed25519, got \(algorithm)"
        case .missingTrustedManifestSigningKeys:
            return "No trusted update manifest signing keys are configured"
        case .manifestSignatureKeyNotTrusted(let keyId):
            return "Update manifest signature key is not trusted: \(keyId)"
        case .invalidTrustedManifestSigningKey(let keyId):
            return "Trusted update manifest signing key is invalid: \(keyId)"
        case .invalidManifestSignatureEncoding:
            return "Update manifest signature must be base64 or base64url encoded"
        case .manifestSignatureVerificationFailed:
            return "Update manifest signature verification failed"
        case .invalidManifestSequence(let sequence):
            return "Update manifest sequence must be positive, got \(sequence)"
        case .manifestSequenceRollback(let minimum, let actual):
            return "Update manifest sequence rollback detected: minimum \(minimum), got \(actual)"
        case .invalidPublishedAt(let value):
            return "Invalid update manifest published_at timestamp: \(value)"
        case .invalidExpiresAt(let value):
            return "Invalid update manifest expires_at timestamp: \(value)"
        case .manifestPublishedInFuture(let value):
            return "Update manifest published_at is in the future: \(value)"
        case .manifestExpired(let value):
            return "Update manifest expired at \(value)"
        case .manifestExpirationBeforePublication:
            return "Update manifest expires_at must be later than published_at"
        }
    }
}

public struct SkyBridgeVersion: Comparable, Equatable, Sendable {
    public let rawValue: String
    private let components: [Int]

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let parsed = components.compactMap { Int(String($0)) }
        guard !trimmed.isEmpty,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parsed.count == components.count else {
            throw SkyBridgeAppUpdateValidationError.invalidVersion(rawValue)
        }
        self.rawValue = trimmed
        self.components = parsed
    }

    public static func < (lhs: SkyBridgeVersion, rhs: SkyBridgeVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

public struct SkyBridgeBuildNumber: Comparable, Equatable, Sendable {
    public let rawValue: String
    private let numericComponents: [Int]?

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "0" : trimmed
        let components = self.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        if !components.isEmpty,
           components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            self.numericComponents = components.compactMap { Int(String($0)) }
        } else {
            self.numericComponents = nil
        }
    }

    public static func < (lhs: SkyBridgeBuildNumber, rhs: SkyBridgeBuildNumber) -> Bool {
        if let leftComponents = lhs.numericComponents,
           let rightComponents = rhs.numericComponents {
            let count = max(leftComponents.count, rightComponents.count)
            for index in 0..<count {
                let left = index < leftComponents.count ? leftComponents[index] : 0
                let right = index < rightComponents.count ? rightComponents[index] : 0
                if left != right {
                    return left < right
                }
            }
            return false
        }
        return lhs.rawValue.compare(rhs.rawValue, options: [.numeric]) == .orderedAscending
    }
}

public struct SkyBridgeAppUpdateManifest: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let bundleIdentifier: String
    public let platform: String
    public let channel: String
    public let version: String
    public let build: String
    public let sequence: Int64
    public let publishedAt: String
    public let expiresAt: String
    public let minimumSystemVersion: String
    public let releaseNotesURL: URL?
    public let downloadURL: URL
    public let sha256: String
    public let packageFormat: String
    public let distribution: String
    public let notarized: Bool
    public let sizeBytes: Int64?
    public let signature: SkyBridgeAppUpdateManifestSignature?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleIdentifier = "bundle_id"
        case platform
        case channel
        case version
        case build
        case sequence
        case publishedAt = "published_at"
        case expiresAt = "expires_at"
        case minimumSystemVersion = "minimum_system_version"
        case releaseNotesURL = "release_notes_url"
        case downloadURL = "download_url"
        case sha256
        case packageFormat = "package_format"
        case distribution
        case notarized
        case sizeBytes = "size_bytes"
        case signature
    }
}

public struct SkyBridgeAppUpdateManifestSignature: Decodable, Equatable, Sendable {
    public let algorithm: String
    public let keyId: String
    public let value: String

    enum CodingKeys: String, CodingKey {
        case algorithm
        case keyId = "key_id"
        case value
    }
}

public struct SkyBridgeAppUpdateTrustedSigningKey: Equatable, Sendable {
    public let keyId: String
    public let publicKeyBase64: String

    public init(keyId: String, publicKeyBase64: String) {
        self.keyId = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKeyBase64 = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SkyBridgeAppUpdateContext: Equatable, Sendable {
    public let bundleIdentifier: String
    public let currentVersion: String
    public let currentBuild: String
    public let channel: String
    public let currentSystemVersion: String
    public let now: Date
    public let minimumAcceptedManifestSequence: Int64

    public init(
        bundleIdentifier: String,
        currentVersion: String,
        currentBuild: String,
        channel: String = "stable",
        currentSystemVersion: String,
        now: Date = Date(),
        minimumAcceptedManifestSequence: Int64 = 0
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.channel = channel
        self.currentSystemVersion = currentSystemVersion
        self.now = now
        self.minimumAcceptedManifestSequence = minimumAcceptedManifestSequence
    }
}

public enum SkyBridgeAppUpdateState: String, Equatable, Sendable {
    case upToDate
    case updateAvailable
    case unsupportedSystemVersion
}

public struct SkyBridgeAppUpdateDecision: Equatable, Sendable {
    public let state: SkyBridgeAppUpdateState
    public let manifest: SkyBridgeAppUpdateManifest

    public init(state: SkyBridgeAppUpdateState, manifest: SkyBridgeAppUpdateManifest) {
        self.state = state
        self.manifest = manifest
    }
}

public enum SkyBridgeAppUpdateEvaluator {
    public static func decodeManifest(from data: Data) throws -> SkyBridgeAppUpdateManifest {
        let decoder = JSONDecoder()
        return try decoder.decode(SkyBridgeAppUpdateManifest.self, from: data)
    }

    public static func evaluate(
        manifest: SkyBridgeAppUpdateManifest,
        context: SkyBridgeAppUpdateContext,
        trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey] = []
    ) throws -> SkyBridgeAppUpdateDecision {
        guard manifest.schemaVersion == 1 else {
            throw SkyBridgeAppUpdateValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.bundleIdentifier == context.bundleIdentifier else {
            throw SkyBridgeAppUpdateValidationError.bundleIdentifierMismatch(
                expected: context.bundleIdentifier,
                actual: manifest.bundleIdentifier
            )
        }
        guard manifest.platform.lowercased() == "macos" else {
            throw SkyBridgeAppUpdateValidationError.platformMismatch(manifest.platform)
        }
        guard manifest.channel.lowercased() == context.channel.lowercased() else {
            throw SkyBridgeAppUpdateValidationError.channelMismatch(
                expected: context.channel,
                actual: manifest.channel
            )
        }
        guard manifest.downloadURL.scheme?.lowercased() == "https" else {
            throw SkyBridgeAppUpdateValidationError.invalidDownloadURL
        }
        if let releaseNotesURL = manifest.releaseNotesURL,
           releaseNotesURL.scheme?.lowercased() != "https" {
            throw SkyBridgeAppUpdateValidationError.invalidReleaseNotesURL
        }
        guard isValidSHA256(manifest.sha256) else {
            throw SkyBridgeAppUpdateValidationError.invalidSHA256
        }
        guard manifest.packageFormat.lowercased() == "dmg" else {
            throw SkyBridgeAppUpdateValidationError.unsupportedPackageFormat(manifest.packageFormat)
        }
        guard manifest.distribution.lowercased() == "developer-id" else {
            throw SkyBridgeAppUpdateValidationError.unsupportedDistribution(manifest.distribution)
        }
        guard manifest.notarized else {
            throw SkyBridgeAppUpdateValidationError.packageNotNotarized
        }
        try validateManifestFreshness(manifest: manifest, context: context)
        try verifySignature(
            manifest: manifest,
            trustedSigningKeys: trustedSigningKeys
        )

        let latestVersion = try SkyBridgeVersion(manifest.version)
        let currentVersion = try SkyBridgeVersion(context.currentVersion)
        let minimumSystemVersion: SkyBridgeVersion
        do {
            minimumSystemVersion = try SkyBridgeVersion(manifest.minimumSystemVersion)
        } catch {
            throw SkyBridgeAppUpdateValidationError.invalidMinimumSystemVersion(manifest.minimumSystemVersion)
        }
        let currentSystemVersion: SkyBridgeVersion
        do {
            currentSystemVersion = try SkyBridgeVersion(context.currentSystemVersion)
        } catch {
            throw SkyBridgeAppUpdateValidationError.invalidMinimumSystemVersion(context.currentSystemVersion)
        }

        if currentSystemVersion < minimumSystemVersion {
            return SkyBridgeAppUpdateDecision(state: .unsupportedSystemVersion, manifest: manifest)
        }

        let latestBuild = SkyBridgeBuildNumber(manifest.build)
        let currentBuild = SkyBridgeBuildNumber(context.currentBuild)
        if latestVersion > currentVersion || (latestVersion == currentVersion && latestBuild > currentBuild) {
            return SkyBridgeAppUpdateDecision(state: .updateAvailable, manifest: manifest)
        }
        return SkyBridgeAppUpdateDecision(state: .upToDate, manifest: manifest)
    }

    public static func signingPayload(for manifest: SkyBridgeAppUpdateManifest) -> Data {
        var payload = Data()
        appendSignedField("schema_version", String(manifest.schemaVersion), to: &payload)
        appendSignedField("bundle_id", manifest.bundleIdentifier, to: &payload)
        appendSignedField("platform", manifest.platform, to: &payload)
        appendSignedField("channel", manifest.channel, to: &payload)
        appendSignedField("version", manifest.version, to: &payload)
        appendSignedField("build", manifest.build, to: &payload)
        appendSignedField("sequence", String(manifest.sequence), to: &payload)
        appendSignedField("published_at", manifest.publishedAt, to: &payload)
        appendSignedField("expires_at", manifest.expiresAt, to: &payload)
        appendSignedField("minimum_system_version", manifest.minimumSystemVersion, to: &payload)
        appendSignedField("release_notes_url", manifest.releaseNotesURL?.absoluteString ?? "", to: &payload)
        appendSignedField("download_url", manifest.downloadURL.absoluteString, to: &payload)
        appendSignedField("sha256", manifest.sha256, to: &payload)
        appendSignedField("package_format", manifest.packageFormat, to: &payload)
        appendSignedField("distribution", manifest.distribution, to: &payload)
        appendSignedField("notarized", manifest.notarized ? "true" : "false", to: &payload)
        appendSignedField("size_bytes", manifest.sizeBytes.map(String.init) ?? "", to: &payload)
        return payload
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else { return false }
        return trimmed.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func validateManifestFreshness(
        manifest: SkyBridgeAppUpdateManifest,
        context: SkyBridgeAppUpdateContext
    ) throws {
        guard manifest.sequence > 0 else {
            throw SkyBridgeAppUpdateValidationError.invalidManifestSequence(manifest.sequence)
        }
        guard manifest.sequence >= context.minimumAcceptedManifestSequence else {
            throw SkyBridgeAppUpdateValidationError.manifestSequenceRollback(
                minimum: context.minimumAcceptedManifestSequence,
                actual: manifest.sequence
            )
        }

        let publishedAt = try parseISO8601Date(
            manifest.publishedAt,
            invalidError: .invalidPublishedAt(manifest.publishedAt)
        )
        let expiresAt = try parseISO8601Date(
            manifest.expiresAt,
            invalidError: .invalidExpiresAt(manifest.expiresAt)
        )
        guard expiresAt > publishedAt else {
            throw SkyBridgeAppUpdateValidationError.manifestExpirationBeforePublication
        }

        let clockSkewAllowance: TimeInterval = 300
        guard publishedAt.timeIntervalSince(context.now) <= clockSkewAllowance else {
            throw SkyBridgeAppUpdateValidationError.manifestPublishedInFuture(manifest.publishedAt)
        }
        guard expiresAt > context.now else {
            throw SkyBridgeAppUpdateValidationError.manifestExpired(manifest.expiresAt)
        }
    }

    private static func parseISO8601Date(
        _ raw: String,
        invalidError: SkyBridgeAppUpdateValidationError
    ) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        throw invalidError
    }

    private static func verifySignature(
        manifest: SkyBridgeAppUpdateManifest,
        trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey]
    ) throws {
        guard let signature = manifest.signature else {
            throw SkyBridgeAppUpdateValidationError.missingManifestSignature
        }
        guard signature.algorithm.lowercased() == "ed25519" else {
            throw SkyBridgeAppUpdateValidationError.unsupportedManifestSignatureAlgorithm(signature.algorithm)
        }
        guard !trustedSigningKeys.isEmpty else {
            throw SkyBridgeAppUpdateValidationError.missingTrustedManifestSigningKeys
        }
        guard let trustedKey = trustedSigningKeys.first(where: { $0.keyId == signature.keyId }) else {
            throw SkyBridgeAppUpdateValidationError.manifestSignatureKeyNotTrusted(signature.keyId)
        }
        guard let publicKeyData = decodeBase64OrBase64URL(trustedKey.publicKeyBase64),
              publicKeyData.count == 32 else {
            throw SkyBridgeAppUpdateValidationError.invalidTrustedManifestSigningKey(trustedKey.keyId)
        }
        guard let signatureData = decodeBase64OrBase64URL(signature.value),
              signatureData.count == 64 else {
            throw SkyBridgeAppUpdateValidationError.invalidManifestSignatureEncoding
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw SkyBridgeAppUpdateValidationError.invalidTrustedManifestSigningKey(trustedKey.keyId)
        }
        guard publicKey.isValidSignature(signatureData, for: signingPayload(for: manifest)) else {
            throw SkyBridgeAppUpdateValidationError.manifestSignatureVerificationFailed
        }
    }

    private static func appendSignedField(_ key: String, _ value: String, to payload: inout Data) {
        let keyData = Data(key.utf8)
        let valueData = Data(value.utf8)
        payload.append(Data(String(keyData.count).utf8))
        payload.append(0x3A)
        payload.append(keyData)
        payload.append(0x3D)
        payload.append(Data(String(valueData.count).utf8))
        payload.append(0x3A)
        payload.append(valueData)
        payload.append(0x0A)
    }

    private static func decodeBase64OrBase64URL(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed) {
            return data
        }
        var normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}
