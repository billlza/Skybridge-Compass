#!/usr/bin/env swift
import CryptoKit
import Foundation

struct Signature: Encodable {
    let algorithm: String
    let keyId: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case algorithm
        case keyId = "key_id"
        case value
    }
}

struct ApplePQCSDKBuildAttestation: Encodable {
    let compiledWithHASApplePQCSDK: Bool
    let compileMarker: String
    let probeMode: String
    let sdkName: String
    let sdkVersion: String
    let swiftTarget: String
    let secureEnclaveSymbolsIncluded: Bool
    let symbolSet: String
    let signature: Signature?

    enum CodingKeys: String, CodingKey {
        case compiledWithHASApplePQCSDK = "compiled_with_has_apple_pqc_sdk"
        case compileMarker = "compile_marker"
        case probeMode = "probe_mode"
        case sdkName = "sdk_name"
        case sdkVersion = "sdk_version"
        case swiftTarget = "swift_target"
        case secureEnclaveSymbolsIncluded = "secure_enclave_symbols_included"
        case symbolSet = "symbol_set"
        case signature
    }
}

struct Manifest: Encodable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let platform: String
    let channel: String
    let version: String
    let build: String
    let sequence: Int64
    let publishedAt: String
    let expiresAt: String
    let minimumSystemVersion: String
    let releaseNotesURL: String?
    let downloadURL: String
    let sha256: String
    let packageFormat: String
    let distribution: String
    let notarized: Bool
    let sizeBytes: Int64
    let applePQCSDKBuild: ApplePQCSDKBuildAttestation
    let signature: Signature?

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
        case applePQCSDKBuild = "apple_pqc_sdk_build"
        case signature
    }
}

struct Options {
    var appPath: String?
    var packagePath: String?
    var outputPath: String?
    var downloadURL: String?
    var releaseNotesURL: String?
    var keyId: String?
    var privateKeyFile: String?
    var sequence: Int64?
    var publishedAt: String?
    var expiresAt: String?
    var channel = "stable"
    var minimumSystemVersion: String?
    var notarized = false
}

enum ManifestToolError: Error, CustomStringConvertible {
    case usage(String)
    case invalidURL(String)
    case invalidTimestamp(String)
    case invalidSequence(String)
    case missingPlistKey(String)
    case invalidPrivateKey
    case invalidPackage(String)
    case invalidApplePQCSDKBuildProvenance(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .invalidURL(let value):
            return "expected an HTTPS URL, got: \(value)"
        case .invalidTimestamp(let value):
            return "expected an ISO-8601 UTC timestamp, got: \(value)"
        case .invalidSequence(let value):
            return "sequence must be a positive Int64, got: \(value)"
        case .missingPlistKey(let key):
            return "app Info.plist is missing required key: \(key)"
        case .invalidPrivateKey:
            return "manifest private key must be a base64-encoded 32-byte Ed25519 seed"
        case .invalidPackage(let message):
            return message
        case .invalidApplePQCSDKBuildProvenance(let message):
            return "invalid Apple PQC SDK build provenance: \(message)"
        }
    }
}

func usage() -> String {
    """
    Generate a signed SkyBridge macOS update manifest.

    Usage:
      swift Scripts/generate_macos_update_manifest.swift \\
        --app-path <SkyBridge Compass Pro.app> \\
        --package-path <SkyBridgeCompassPro.dmg> \\
        --download-url <https://github.com/owner/repo/releases/download/stable/SkyBridgeCompassPro.dmg> \\
        --key-id <public-key-id> \\
        --private-key-file <base64-raw-ed25519-seed-file> \\
        --sequence <monotonic-int64> \\
        --published-at <iso8601> \\
        --expires-at <iso8601> \\
        --output <macos-stable.json> \\
        --notarized

    The private key may also be supplied through
    SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64. Do not pass private
    key material on the command line.
    """
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() throws -> String {
            guard index + 1 < arguments.count else {
                throw ManifestToolError.usage("missing value for \(argument)")
            }
            index += 1
            return arguments[index]
        }

        switch argument {
        case "--app-path":
            options.appPath = try value()
        case "--package-path":
            options.packagePath = try value()
        case "--output":
            options.outputPath = try value()
        case "--download-url":
            options.downloadURL = try value()
        case "--release-notes-url":
            options.releaseNotesURL = try value()
        case "--key-id":
            options.keyId = try value()
        case "--private-key-file":
            options.privateKeyFile = try value()
        case "--sequence":
            let raw = try value()
            guard let sequence = Int64(raw), sequence > 0 else {
                throw ManifestToolError.invalidSequence(raw)
            }
            options.sequence = sequence
        case "--published-at":
            options.publishedAt = try value()
        case "--expires-at":
            options.expiresAt = try value()
        case "--channel":
            options.channel = try value()
        case "--minimum-system-version":
            options.minimumSystemVersion = try value()
        case "--notarized":
            options.notarized = true
        case "-h", "--help":
            print(usage())
            exit(0)
        default:
            throw ManifestToolError.usage("unknown option: \(argument)\n\(usage())")
        }
        index += 1
    }
    return options
}

func required(_ value: String?, _ name: String) throws -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        throw ManifestToolError.usage("missing required option: \(name)\n\(usage())")
    }
    return value
}

func requiredSequence(_ value: Int64?) throws -> Int64 {
    guard let value, value > 0 else {
        throw ManifestToolError.usage("missing required option: --sequence\n\(usage())")
    }
    return value
}

func validateHTTPSURL(_ raw: String) throws {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.host?.isEmpty == false else {
        throw ManifestToolError.invalidURL(raw)
    }
}

func parseTimestamp(_ raw: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: raw) {
        return date
    }
    throw ManifestToolError.invalidTimestamp(raw)
}

func readInfoPlist(appPath: String) throws -> [String: Any] {
    let infoURL = URL(fileURLWithPath: appPath)
        .appendingPathComponent("Contents")
        .appendingPathComponent("Info.plist")
    let data = try Data(contentsOf: infoURL)
    guard let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any] else {
        throw ManifestToolError.invalidPackage("unable to read app Info.plist: \(infoURL.path)")
    }
    return plist
}

func plistString(_ plist: [String: Any], _ key: String) throws -> String {
    guard let raw = plist[key] as? String,
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ManifestToolError.missingPlistKey(key)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

func plistBool(_ plist: [String: Any], _ key: String) throws -> Bool {
    guard let raw = plist[key] as? Bool else {
        throw ManifestToolError.missingPlistKey(key)
    }
    return raw
}

let applePQCCompileMarker = "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk"
let applePQCMissingCompileMarker = "skybridge.apple-pqc-sdk.compile-fact.v1.missing-has-apple-pqc-sdk"
let applePQCProbeMode = "symbol_probe"
let applePQCSDKName = "macosx"
let applePQCSDKVersion = "26.5"
let applePQCSwiftTarget = "arm64-apple-macosx26.0"
let applePQCSymbolSet = "cryptokit-pqc-v1"

func fileContainsString(_ url: URL, _ needle: Data) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var overlap = Data()
    while true {
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
            return false
        }
        var buffer = overlap
        buffer.append(chunk)
        if buffer.range(of: needle) != nil {
            return true
        }
        let overlapCount = max(needle.count - 1, 0)
        overlap = overlapCount == 0 ? Data() : Data(buffer.suffix(overlapCount))
    }
}

func executableCandidateURLs(appPath: String) throws -> [URL] {
    let appURL = URL(fileURLWithPath: appPath)
    let macOSURL = appURL.appendingPathComponent("Contents").appendingPathComponent("MacOS")
    let frameworksURL = appURL.appendingPathComponent("Contents").appendingPathComponent("Frameworks")
    var candidates: [URL] = []
    let fileManager = FileManager.default

    func appendExecutableFiles(under root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if fileManager.isExecutableFile(atPath: url.path)
                || url.pathExtension == "dylib"
                || url.pathExtension == "so" {
                candidates.append(url)
            }
        }
    }

    try appendExecutableFiles(under: macOSURL)
    if fileManager.fileExists(atPath: frameworksURL.path) {
        try appendExecutableFiles(under: frameworksURL)
    }
    return candidates
}

func appBundleContainsApplePQCCompileMarker(appPath: String) throws -> Bool {
    let hasMarkerData = Data(applePQCCompileMarker.utf8)
    let missingMarkerData = Data(applePQCMissingCompileMarker.utf8)
    var foundHasMarker = false

    for url in try executableCandidateURLs(appPath: appPath) {
        if try fileContainsString(url, missingMarkerData) {
            throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
                "packaged binary contains the missing HAS_APPLE_PQC_SDK marker: \(url.path)"
            )
        }
        if try fileContainsString(url, hasMarkerData) {
            foundHasMarker = true
        }
    }

    return foundHasMarker
}

func readApplePQCSDKBuildAttestation(
    plist: [String: Any],
    appPath: String,
    signature: Signature?
) throws -> ApplePQCSDKBuildAttestation {
    let compiled = try plistBool(plist, "SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK")
    let compileMarker = try plistString(plist, "SkyBridgePackagingApplePQCSDKCompileMarker")
    let probeMode = try plistString(plist, "SkyBridgePackagingApplePQCSDKProbeMode")
    let sdkName = try plistString(plist, "SkyBridgePackagingApplePQCSDKName")
    let sdkVersion = try plistString(plist, "SkyBridgePackagingApplePQCSDKVersion")
    let swiftTarget = try plistString(plist, "SkyBridgePackagingApplePQCSDKSwiftTarget")
    let secureEnclave = try plistBool(plist, "SkyBridgePackagingApplePQCSDKSecureEnclaveSymbolsIncluded")
    let symbolSet = try plistString(plist, "SkyBridgePackagingApplePQCSDKSymbolSet")

    guard compiled else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK must be true for release manifests"
        )
    }
    guard compileMarker == applePQCCompileMarker else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance("unexpected compile marker: \(compileMarker)")
    }
    guard probeMode == applePQCProbeMode else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "probe_mode must be \(applePQCProbeMode), got \(probeMode)"
        )
    }
    guard sdkName == applePQCSDKName else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "sdk_name must be \(applePQCSDKName), got \(sdkName)"
        )
    }
    guard sdkVersion == applePQCSDKVersion else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "sdk_version must be \(applePQCSDKVersion), got \(sdkVersion)"
        )
    }
    guard swiftTarget == applePQCSwiftTarget else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "swift_target must be \(applePQCSwiftTarget), got \(swiftTarget)"
        )
    }
    guard secureEnclave else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "secure_enclave_symbols_included must be true"
        )
    }
    guard symbolSet == applePQCSymbolSet else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance("symbol_set must be \(applePQCSymbolSet), got \(symbolSet)")
    }
    guard try appBundleContainsApplePQCCompileMarker(appPath: appPath) else {
        throw ManifestToolError.invalidApplePQCSDKBuildProvenance(
            "packaged app binaries do not contain \(applePQCCompileMarker)"
        )
    }

    return ApplePQCSDKBuildAttestation(
        compiledWithHASApplePQCSDK: compiled,
        compileMarker: compileMarker,
        probeMode: probeMode,
        sdkName: sdkName,
        sdkVersion: sdkVersion,
        swiftTarget: swiftTarget,
        secureEnclaveSymbolsIncluded: secureEnclave,
        symbolSet: symbolSet,
        signature: signature
    )
}

func readPrivateKeyData(file: String?) throws -> Data {
    let raw: String
    if let file {
        raw = try String(contentsOfFile: file, encoding: .utf8)
    } else if let environment = ProcessInfo.processInfo.environment[
        "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"
    ] {
        raw = environment
    } else {
        throw ManifestToolError.usage(
            "missing --private-key-file or SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"
        )
    }
    guard let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          data.count == 32 else {
        throw ManifestToolError.invalidPrivateKey
    }
    return data
}

func packageDigestAndSize(path: String) throws -> (sha256: String, size: Int64) {
    let url = URL(fileURLWithPath: path)
    guard url.pathExtension.lowercased() == "dmg" else {
        throw ManifestToolError.invalidPackage("update package must be a .dmg: \(path)")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let sizeNumber = attributes[.size] as? NSNumber,
          sizeNumber.int64Value > 0 else {
        throw ManifestToolError.invalidPackage("update package is empty or unreadable: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1024 * 1024)
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    let digest = hasher.finalize()
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return (hex, sizeNumber.int64Value)
}

func appendSignedField(_ key: String, _ value: String, to payload: inout Data) {
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

func signingPayload(for manifest: Manifest) -> Data {
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
    appendSignedField("release_notes_url", manifest.releaseNotesURL ?? "", to: &payload)
    appendSignedField("download_url", manifest.downloadURL, to: &payload)
    appendSignedField("sha256", manifest.sha256, to: &payload)
    appendSignedField("package_format", manifest.packageFormat, to: &payload)
    appendSignedField("distribution", manifest.distribution, to: &payload)
    appendSignedField("notarized", manifest.notarized ? "true" : "false", to: &payload)
    appendSignedField("size_bytes", String(manifest.sizeBytes), to: &payload)
    return payload
}

func applePQCSDKBuildSigningPayload(
    for manifest: Manifest,
    attestation: ApplePQCSDKBuildAttestation
) -> Data {
    var payload = Data()
    appendSignedField("bundle_id", manifest.bundleIdentifier, to: &payload)
    appendSignedField("platform", manifest.platform, to: &payload)
    appendSignedField("channel", manifest.channel, to: &payload)
    appendSignedField("version", manifest.version, to: &payload)
    appendSignedField("build", manifest.build, to: &payload)
    appendSignedField("sequence", String(manifest.sequence), to: &payload)
    appendSignedField("download_url", manifest.downloadURL, to: &payload)
    appendSignedField("sha256", manifest.sha256, to: &payload)
    appendSignedField("package_format", manifest.packageFormat, to: &payload)
    appendSignedField("distribution", manifest.distribution, to: &payload)
    appendSignedField("notarized", manifest.notarized ? "true" : "false", to: &payload)
    appendSignedField("size_bytes", String(manifest.sizeBytes), to: &payload)
    appendSignedField(
        "apple_pqc_sdk_build.compiled_with_has_apple_pqc_sdk",
        attestation.compiledWithHASApplePQCSDK ? "true" : "false",
        to: &payload
    )
    appendSignedField("apple_pqc_sdk_build.compile_marker", attestation.compileMarker, to: &payload)
    appendSignedField("apple_pqc_sdk_build.probe_mode", attestation.probeMode, to: &payload)
    appendSignedField("apple_pqc_sdk_build.sdk_name", attestation.sdkName, to: &payload)
    appendSignedField("apple_pqc_sdk_build.sdk_version", attestation.sdkVersion, to: &payload)
    appendSignedField("apple_pqc_sdk_build.swift_target", attestation.swiftTarget, to: &payload)
    appendSignedField(
        "apple_pqc_sdk_build.secure_enclave_symbols_included",
        attestation.secureEnclaveSymbolsIncluded ? "true" : "false",
        to: &payload
    )
    appendSignedField("apple_pqc_sdk_build.symbol_set", attestation.symbolSet, to: &payload)
    return payload
}

func writeManifest(_ manifest: Manifest, to outputPath: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    let outputURL = URL(fileURLWithPath: outputPath)
    let parent = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try data.write(to: outputURL, options: [.atomic])
}

func main() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let appPath = try required(options.appPath, "--app-path")
    let packagePath = try required(options.packagePath, "--package-path")
    let outputPath = try required(options.outputPath, "--output")
    let downloadURL = try required(options.downloadURL, "--download-url")
    let keyId = try required(options.keyId, "--key-id")
    let sequence = try requiredSequence(options.sequence)
    let publishedAt = try required(options.publishedAt, "--published-at")
    let expiresAt = try required(options.expiresAt, "--expires-at")

    guard options.notarized else {
        throw ManifestToolError.usage("manifest generation requires --notarized; do not advertise unnotarized packages")
    }
    try validateHTTPSURL(downloadURL)
    if let releaseNotesURL = options.releaseNotesURL {
        try validateHTTPSURL(releaseNotesURL)
    }
    let publishedDate = try parseTimestamp(publishedAt)
    let expiresDate = try parseTimestamp(expiresAt)
    guard expiresDate > publishedDate else {
        throw ManifestToolError.usage("--expires-at must be later than --published-at")
    }

    let plist = try readInfoPlist(appPath: appPath)
    let bundleId = try plistString(plist, "CFBundleIdentifier")
    let version = try plistString(plist, "CFBundleShortVersionString")
    let build = try plistString(plist, "CFBundleVersion")
    let minimumSystemVersion = options.minimumSystemVersion
        ?? (plist["LSMinimumSystemVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "14.0.0"
    let package = try packageDigestAndSize(path: packagePath)
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: readPrivateKeyData(file: options.privateKeyFile))
    let unsignedApplePQCSDKBuild = try readApplePQCSDKBuildAttestation(
        plist: plist,
        appPath: appPath,
        signature: nil
    )

    let unsignedManifest = Manifest(
        schemaVersion: 1,
        bundleIdentifier: bundleId,
        platform: "macos",
        channel: options.channel,
        version: version,
        build: build,
        sequence: sequence,
        publishedAt: publishedAt,
        expiresAt: expiresAt,
        minimumSystemVersion: minimumSystemVersion,
        releaseNotesURL: options.releaseNotesURL,
        downloadURL: downloadURL,
        sha256: package.sha256,
        packageFormat: "dmg",
        distribution: "developer-id",
        notarized: true,
        sizeBytes: package.size,
        applePQCSDKBuild: unsignedApplePQCSDKBuild,
        signature: nil
    )
    let applePQCSDKBuildSignature = try privateKey
        .signature(for: applePQCSDKBuildSigningPayload(for: unsignedManifest, attestation: unsignedApplePQCSDKBuild))
        .base64EncodedString()
    let signedApplePQCSDKBuild = try readApplePQCSDKBuildAttestation(
        plist: plist,
        appPath: appPath,
        signature: Signature(algorithm: "ed25519", keyId: keyId, value: applePQCSDKBuildSignature)
    )
    let signature = try privateKey.signature(for: signingPayload(for: unsignedManifest)).base64EncodedString()
    let signedManifest = Manifest(
        schemaVersion: unsignedManifest.schemaVersion,
        bundleIdentifier: unsignedManifest.bundleIdentifier,
        platform: unsignedManifest.platform,
        channel: unsignedManifest.channel,
        version: unsignedManifest.version,
        build: unsignedManifest.build,
        sequence: unsignedManifest.sequence,
        publishedAt: unsignedManifest.publishedAt,
        expiresAt: unsignedManifest.expiresAt,
        minimumSystemVersion: unsignedManifest.minimumSystemVersion,
        releaseNotesURL: unsignedManifest.releaseNotesURL,
        downloadURL: unsignedManifest.downloadURL,
        sha256: unsignedManifest.sha256,
        packageFormat: unsignedManifest.packageFormat,
        distribution: unsignedManifest.distribution,
        notarized: unsignedManifest.notarized,
        sizeBytes: unsignedManifest.sizeBytes,
        applePQCSDKBuild: signedApplePQCSDKBuild,
        signature: Signature(algorithm: "ed25519", keyId: keyId, value: signature)
    )
    try writeManifest(signedManifest, to: outputPath)
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    FileHandle.standardError.write(Data("wrote \(outputPath)\ntrusted public key: \(keyId):\(publicKey)\n".utf8))
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("generate_macos_update_manifest: \(error)\n".utf8))
    exit(1)
}
