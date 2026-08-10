import CryptoKit
import Darwin
import Foundation
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class AppleCompatibilityVectorCaptureTests: XCTestCase {
    private static let inputRelativePath =
        "Tests/SkyBridgeCoreTests/Fixtures/AppleCompatibilityVectors/inputs.json"
    private static let toolRelativePath =
        "Tests/SkyBridgeCoreTests/AppleCompatibilityVectorCaptureTests.swift"
    private static let expectedInputSHA256 =
        "d69eebb27da06153b7d5a43a1ec3a5dce9d77a4148cc1a295b49fa7e15a473ca"

    func testProductionCodecsBuildDeterministicBoundedCaptureSet() throws {
        let repositoryRoot = Self.repositoryRoot
        let inputData = try Data(contentsOf: repositoryRoot.appendingPathComponent(Self.inputRelativePath))
        guard Self.sha256Hex(inputData) == Self.expectedInputSHA256 else {
            throw CaptureError.semanticInputHashMismatch
        }

        let inputs = try JSONDecoder().decode(SemanticInputs.self, from: inputData)
        try inputs.validate()
        let first = try Self.buildVectors(from: inputs)
        let second = try Self.buildVectors(from: inputs)
        let captureSet = try Self.validateCaptureSet(first: first, repeated: second)

        try Self.assertProductionRoundTrips(inputs: inputs, vectors: captureSet.vectors)
        try Self.assertCaptureUsesShippingCodecs(repositoryRoot: repositoryRoot, inputs: inputs)
        try Self.validateProductionSourceHashes(repositoryRoot: repositoryRoot)
        try Self.exportIfExplicitlyRequested(
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: repositoryRoot,
            inputData: inputData,
            firstVectors: first,
            repeatedVectors: second
        )
    }

    func testInvalidCaptureSetsFailBeforeExporterWritesAnything() throws {
        let repositoryRoot = Self.repositoryRoot
        let inputData = try Data(contentsOf: repositoryRoot.appendingPathComponent(Self.inputRelativePath))
        let inputs = try JSONDecoder().decode(SemanticInputs.self, from: inputData)
        try inputs.validate()
        let valid = try Self.buildVectors(from: inputs)
        let firstVector = try XCTUnwrap(valid.first)

        let cases: [(String, [Vector], [Vector], CaptureError)] = [
            (
                "nondeterministic",
                valid,
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, rawBytes: Data([0x01]))),
                .nondeterministicCaptureSet([firstVector.relativePath])
            ),
            (
                "count",
                Array(valid.dropLast()),
                Array(valid.dropLast()),
                .invalidCaptureVectorCount(22)
            ),
            (
                "surface-count",
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, surface: .p2pHandshake)),
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, surface: .p2pHandshake)),
                .invalidCaptureSurfaceCount("F1", 7)
            ),
            (
                "duplicate-path",
                Self.replacing(valid, at: 1, with: firstVector),
                Self.replacing(valid, at: 1, with: firstVector),
                .duplicateCapturePath(firstVector.relativePath)
            ),
            (
                "empty-raw",
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, rawBytes: Data())),
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, rawBytes: Data())),
                .emptyCaptureRawBytes(firstVector.relativePath)
            ),
            (
                "empty-expected",
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, expectedFields: [:])),
                Self.replacing(valid, at: 0, with: Self.copy(firstVector, expectedFields: [:])),
                .emptyCaptureExpectedFields(firstVector.relativePath)
            ),
            (
                "oversized",
                Self.replacing(
                    valid,
                    at: 0,
                    with: Self.copy(
                        firstVector,
                        rawBytes: Data(count: firstVector.surface.maximumEncodedBytes + 1)
                    )
                ),
                Self.replacing(
                    valid,
                    at: 0,
                    with: Self.copy(
                        firstVector,
                        rawBytes: Data(count: firstVector.surface.maximumEncodedBytes + 1)
                    )
                ),
                .captureExceedsMaximum(firstVector.relativePath)
            )
        ]

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-invalid-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }

        for (name, first, repeated, expectedError) in cases {
            let outputRoot = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let environment = [
                Self.captureRootEnvironmentKey: outputRoot.path,
                Self.collectedAtEnvironmentKey: "2026-08-11T12:34:56.789Z",
                Self.scratchRootEnvironmentKey: parent.path
            ]
            XCTAssertThrowsError(try Self.exportIfExplicitlyRequested(
                environment: environment,
                repositoryRoot: repositoryRoot,
                inputData: inputData,
                firstVectors: first,
                repeatedVectors: repeated
            )) { error in
                XCTAssertEqual(error as? CaptureError, expectedError, name)
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: outputRoot.path),
                [],
                name
            )
        }
    }

    func testCaptureProvenanceRejectsDirtyWrongRepositoryAndUntrackedInputs() throws {
        let required = Set([Self.toolRelativePath, Self.inputRelativePath])
        XCTAssertNoThrow(try Self.validateRepositoryEvidence(
            statusOutput: "",
            sourceCommit: String(repeating: "a", count: 40),
            remoteURL: Self.expectedRemoteURL,
            trackedPaths: required,
            requiredPaths: required
        ))

        XCTAssertThrowsError(try Self.validateRepositoryEvidence(
            statusOutput: " M Package.swift\n",
            sourceCommit: String(repeating: "a", count: 40),
            remoteURL: Self.expectedRemoteURL,
            trackedPaths: required,
            requiredPaths: required
        )) { error in
            XCTAssertEqual(error as? CaptureError, .dirtyRepository)
        }
        XCTAssertThrowsError(try Self.validateRepositoryEvidence(
            statusOutput: "",
            sourceCommit: "abc123",
            remoteURL: Self.expectedRemoteURL,
            trackedPaths: required,
            requiredPaths: required
        )) { error in
            XCTAssertEqual(error as? CaptureError, .invalidSourceCommit)
        }
        XCTAssertThrowsError(try Self.validateRepositoryEvidence(
            statusOutput: "",
            sourceCommit: String(repeating: "a", count: 40),
            remoteURL: "https://example.invalid/not-skybridge",
            trackedPaths: required,
            requiredPaths: required
        )) { error in
            XCTAssertEqual(error as? CaptureError, .unexpectedRepository)
        }
        XCTAssertThrowsError(try Self.validateRepositoryEvidence(
            statusOutput: "",
            sourceCommit: String(repeating: "a", count: 40),
            remoteURL: Self.expectedRemoteURL,
            trackedPaths: [Self.toolRelativePath],
            requiredPaths: required
        )) { error in
            XCTAssertEqual(error as? CaptureError, .untrackedRequiredPath(Self.inputRelativePath))
        }

        for invalidPath in ["", "/absolute", "../escape", "a/../escape", "a//b", "a\\b"] {
            XCTAssertThrowsError(try Self.validateRelativeRepositoryPath(invalidPath))
        }
        XCTAssertNoThrow(try Self.validateRelativeRepositoryPath(Self.inputRelativePath))
        XCTAssertNoThrow(try Self.validateCollectedAtUTC("2026-08-11T12:34:56.789Z"))
        XCTAssertThrowsError(try Self.validateCollectedAtUTC("2026-08-11T12:34:56+08:00"))
    }

    func testCaptureWriterIsIdempotentForIdenticalBytesAndRejectsOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skybridge-apple-vector-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }

        let output = directory.appendingPathComponent("vector.json")
        let validatedDirectory = try Self.validatePrivateDirectory(
            directory,
            isOutside: Self.repositoryRoot
        )
        let original = Data("original\n".utf8)
        try Self.writeOnceOrConfirmIdentical(
            original,
            relativePath: "vector.json",
            under: validatedDirectory
        )
        try Self.writeOnceOrConfirmIdentical(
            original,
            relativePath: "vector.json",
            under: validatedDirectory
        )
        XCTAssertEqual(try Data(contentsOf: output), original)

        XCTAssertThrowsError(try Self.writeOnceOrConfirmIdentical(
            Data("different\n".utf8),
            relativePath: "vector.json",
            under: validatedDirectory
        )) { error in
            XCTAssertEqual(error as? CaptureError, .outputConflict(output.path))
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testCaptureOutputRejectsSymlinkAliasBelowScratchRoot() throws {
        let scratchRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skybridge-capture-alias-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = scratchRoot.appendingPathComponent("real", isDirectory: true)
        let outputDirectory = realDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: scratchRoot.appendingPathComponent("alias"),
            withDestinationURL: realDirectory
        )
        addTeardownBlock { try FileManager.default.removeItem(at: scratchRoot) }

        let validatedScratch = try Self.validatePrivateDirectory(
            scratchRoot,
            isOutside: Self.repositoryRoot
        )
        let aliasedOutput = scratchRoot
            .appendingPathComponent("alias", isDirectory: true)
            .appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try Self.validatePrivateDirectory(
            aliasedOutput,
            isOutside: Self.repositoryRoot,
            containedIn: validatedScratch
        )) { error in
            XCTAssertEqual(error as? CaptureError, .unsafeFileSystemEntry(aliasedOutput.path))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path),
            []
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
private extension AppleCompatibilityVectorCaptureTests {
    enum Surface: String, Codable, CaseIterable {
        case fileTransfer = "F1"
        case p2pHandshake = "F2"
        case hpkeSealedBox = "F3"
        case bonjourTXT = "F4"

        var directoryName: String {
            switch self {
            case .fileTransfer: "f1-file-transfer"
            case .p2pHandshake: "f2-p2p-handshake"
            case .hpkeSealedBox: "f3-hpke-sealed-box"
            case .bonjourTXT: "f4-bonjour-txt"
            }
        }

        var maximumEncodedBytes: Int {
            switch self {
            case .fileTransfer: 1 * 1_024 * 1_024
            case .p2pHandshake: 65_535
            case .hpkeSealedBox: 128 * 1_024
            case .bonjourTXT: 1_300
            }
        }
    }

    struct Vector: Equatable {
        let surface: Surface
        let messageType: String
        let rawBytes: Data
        let expectedFields: [String: String]
        let sourcePath: String
        let note: String

        var relativePath: String {
            "\(surface.directoryName)/\(messageType)-1.json"
        }
    }

    struct ValidatedCaptureSet {
        let vectors: [Vector]
    }

    static func validateCaptureSet(
        first: [Vector],
        repeated: [Vector]
    ) throws -> ValidatedCaptureSet {
        let changedPaths: [String]
        if first.count == repeated.count {
            changedPaths = zip(first, repeated).compactMap { left, right in
                left == right ? nil : left.relativePath
            }
        } else {
            changedPaths = ["<count>\(first.count)->\(repeated.count)"]
        }
        guard changedPaths.isEmpty else {
            throw CaptureError.nondeterministicCaptureSet(changedPaths)
        }
        guard first.count == 23 else {
            throw CaptureError.invalidCaptureVectorCount(first.count)
        }

        let expectedCounts: [(Surface, Int)] = [
            (.fileTransfer, 8),
            (.p2pHandshake, 5),
            (.hpkeSealedBox, 5),
            (.bonjourTXT, 5)
        ]
        let actualCounts = Dictionary(grouping: first, by: \.surface).mapValues(\.count)
        for (surface, expected) in expectedCounts {
            let actual = actualCounts[surface, default: 0]
            guard actual == expected else {
                throw CaptureError.invalidCaptureSurfaceCount(surface.rawValue, actual)
            }
        }

        var paths: Set<String> = []
        for vector in first {
            guard paths.insert(vector.relativePath).inserted else {
                throw CaptureError.duplicateCapturePath(vector.relativePath)
            }
            guard !vector.rawBytes.isEmpty else {
                throw CaptureError.emptyCaptureRawBytes(vector.relativePath)
            }
            guard !vector.expectedFields.isEmpty else {
                throw CaptureError.emptyCaptureExpectedFields(vector.relativePath)
            }
            guard vector.rawBytes.count <= vector.surface.maximumEncodedBytes else {
                throw CaptureError.captureExceedsMaximum(vector.relativePath)
            }
        }
        return ValidatedCaptureSet(vectors: first)
    }

    static func replacing(_ vectors: [Vector], at index: Int, with vector: Vector) -> [Vector] {
        var result = vectors
        result[index] = vector
        return result
    }

    static func copy(
        _ vector: Vector,
        surface: Surface? = nil,
        rawBytes: Data? = nil,
        expectedFields: [String: String]? = nil
    ) -> Vector {
        Vector(
            surface: surface ?? vector.surface,
            messageType: vector.messageType,
            rawBytes: rawBytes ?? vector.rawBytes,
            expectedFields: expectedFields ?? vector.expectedFields,
            sourcePath: vector.sourcePath,
            note: vector.note
        )
    }

    struct SemanticInputs: Decodable {
        let schemaVersion: Int
        let fixtureSetId: String
        let fileTransfer: [FileTransferInput]
        let cryptoCapabilities: CryptoCapabilitiesInput
        let handshakePolicy: HandshakePolicyInput
        let messageA: MessageAInput
        let messageB: MessageBInput
        let finished: FinishedInput
        let hpke: [HPKEInput]
        let bonjour: [BonjourInput]

        func validate() throws {
            guard schemaVersion == 1, fixtureSetId == "apple-production-codec-v1" else {
                throw CaptureError.invalidSemanticInput("unsupported schema or fixture set")
            }
            guard fileTransfer.count == 8,
                  Set(fileTransfer.map(\.messageType)) == [
                    "metadata", "metadataAck", "chunk", "chunkAck",
                    "complete", "completeAck", "cancel", "error"
                  ],
                  Set(fileTransfer.map(\.transferId)).count == fileTransfer.count else {
                throw CaptureError.invalidSemanticInput("F1 must contain eight unique declared message types")
            }
            for input in fileTransfer {
                guard input.messageType == input.op, !input.transferId.isEmpty else {
                    throw CaptureError.invalidSemanticInput("F1 messageType/op/transferId mismatch")
                }
                try Self.validateHexFields(input.allHexFields)
            }

            guard messageA.supportedSuiteWireIds == [0x1001],
                  messageA.keyShares.map(\.suiteWireId) == messageA.supportedSuiteWireIds,
                  messageB.selectedSuiteWireId == 0x1001,
                  messageB.encryptedPayload.suiteWireId == messageB.selectedSuiteWireId else {
                throw CaptureError.invalidSemanticInput("F2 suite IDs or raw order changed")
            }
            try Self.requireByteCount(messageA.clientNonceHex, 32, "MessageA client nonce")
            try Self.requireByteCount(messageA.identityPublicKeyHex, 32, "MessageA identity key")
            try Self.requireByteCount(messageA.signatureHex, 64, "MessageA signature")
            try Self.requireByteCount(messageA.keyShares[0].shareHex, 32, "MessageA X25519 share")
            try Self.requireByteCount(messageB.responderShareHex, 32, "MessageB responder share")
            try Self.requireByteCount(messageB.serverNonceHex, 32, "MessageB server nonce")
            try Self.requireByteCount(messageB.identityPublicKeyHex, 32, "MessageB identity key")
            try Self.requireByteCount(messageB.signatureHex, 64, "MessageB signature")
            try Self.requireByteCount(finished.macHex, 32, "Finished MAC")
            try Self.validateEncryptedPayload(messageB.encryptedPayload)

            guard hpke.count == 5,
                  Set(hpke.map(\.messageType)) == [
                    "application-v1", "application-v2", "handshake-v1",
                    "handshake-v2", "v2-empty-nonce-tag"
                  ] else {
                throw CaptureError.invalidSemanticInput("F3 must contain five declared message types")
            }
            for input in hpke {
                try Self.validateEncryptedPayload(input.payload)
                let isV1 = input.nonceHex.utf8.count == 24 && input.tagHex.utf8.count == 32
                guard input.messageType.hasSuffix(isV1 ? "v1" : "v2")
                        || input.messageType == "v2-empty-nonce-tag" else {
                    throw CaptureError.invalidSemanticInput("F3 message type/version mismatch")
                }
            }

            guard bonjour.count == 5,
                  Set(bonjour.map(\.messageType)) == [
                    "capabilities-record", "identity-keys-record", "main-service-record",
                    "remote-service-record", "transfer-service-record"
                  ] else {
                throw CaptureError.invalidSemanticInput("F4 must contain five declared message types")
            }
        }

        private static func validateHexFields(_ values: [String]) throws {
            for value in values {
                _ = try decodeHex(value)
            }
        }

        private static func requireByteCount(_ value: String, _ count: Int, _ field: String) throws {
            guard try decodeHex(value).count == count else {
                throw CaptureError.invalidSemanticInput("\(field) must be \(count) bytes")
            }
        }

        private static func validateEncryptedPayload(_ input: EncryptedPayloadInput) throws {
            guard input.suiteWireId == 0x1001 else {
                throw CaptureError.invalidSemanticInput("capture fixtures use the declared X25519 suite")
            }
            let nonce = try decodeHex(input.nonceHex)
            let tag = try decodeHex(input.tagHex)
            guard (nonce.count == 12 && tag.count == 16) || (nonce.isEmpty && tag.isEmpty) else {
                throw CaptureError.invalidSemanticInput("HPKE nonce/tag must select production v1 or v2")
            }
            guard !(try decodeHex(input.encapsulatedKeyHex)).isEmpty else {
                throw CaptureError.invalidSemanticInput("HPKE encapsulated key must not be empty")
            }
            _ = try decodeHex(input.ciphertextHex)
        }
    }

    struct FileTransferInput: Decodable {
        let messageType: String
        let op: String
        let transferId: String
        let senderDeviceId: String?
        let senderDeviceName: String?
        let fileName: String?
        let fileSize: Int64?
        let chunkSize: Int?
        let totalChunks: Int?
        let mimeType: String?
        let chunkIndex: Int?
        let chunkDataHex: String?
        let chunkSha256Hex: String?
        let rawSize: Int?
        let receivedBytes: Int64?
        let fileSha256Hex: String?
        let merkleRootHex: String?
        let merkleRootSignatureHex: String?
        let merkleRootSignatureAlg: String?
        let missingChunks: [Int]?
        let batchId: String?
        let batchIndex: Int?
        let batchTotal: Int?
        let relativePath: String?
        let message: String?

        var allHexFields: [String] {
            [chunkDataHex, chunkSha256Hex, fileSha256Hex, merkleRootHex, merkleRootSignatureHex]
                .compactMap { $0 }
        }
    }

    struct CryptoCapabilitiesInput: Decodable {
        let supportedKEM: [String]
        let supportedSignature: [String]
        let supportedAuthProfiles: [String]
        let supportedAEAD: [String]
        let pqcAvailable: Bool
        let platformVersion: String
        let providerType: String
    }

    struct HandshakePolicyInput: Decodable {
        let requirePQC: Bool
        let allowClassicFallback: Bool
        let minimumTier: String
        let requireSecureEnclavePoP: Bool
    }

    struct KeyShareInput: Decodable {
        let suiteWireId: Int
        let shareHex: String
    }

    struct MessageAInput: Decodable {
        let supportedSuiteWireIds: [Int]
        let keyShares: [KeyShareInput]
        let clientNonceHex: String
        let identityPublicKeyHex: String
        let signatureHex: String
        let extensionsRawHex: String
        let secureEnclaveSignatureHex: String?
        let initiatorContributionHex: String?
    }

    struct EncryptedPayloadInput: Decodable {
        let suiteWireId: Int
        let encapsulatedKeyHex: String
        let nonceHex: String
        let ciphertextHex: String
        let tagHex: String
    }

    struct MessageBInput: Decodable {
        let selectedSuiteWireId: Int
        let responderShareHex: String
        let serverNonceHex: String
        let identityPublicKeyHex: String
        let signatureHex: String
        let secureEnclaveSignatureHex: String?
        let encryptedPayload: EncryptedPayloadInput
    }

    struct FinishedInput: Decodable {
        let direction: String
        let macHex: String
    }

    struct HPKEInput: Decodable {
        let messageType: String
        let suiteWireId: Int
        let encapsulatedKeyHex: String
        let nonceHex: String
        let ciphertextHex: String
        let tagHex: String

        var payload: EncryptedPayloadInput {
            EncryptedPayloadInput(
                suiteWireId: suiteWireId,
                encapsulatedKeyHex: encapsulatedKeyHex,
                nonceHex: nonceHex,
                ciphertextHex: ciphertextHex,
                tagHex: tagHex
            )
        }
    }

    struct BonjourInput: Decodable {
        let messageType: String
        let deviceId: String
        let pubKeyFingerprint: String
        let platform: String
        let role: String
        let serviceType: String
    }
}

@available(macOS 14.0, iOS 17.0, *)
private extension AppleCompatibilityVectorCaptureTests {
    static let fileTransferDefinitionPath =
        "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferWire.swift"
    static let fileTransferWireEncoderPath =
        "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferWireEncoder.swift"
    static let fileTransferWireDecoderPath =
        "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferWireDecoder.swift"
    static let fileTransferAdmissionPolicyPath =
        "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferInboundAdmissionPolicy.swift"
    static let fileTransferShippingCallerPath =
        "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
    static let fileTransferMacResponseCallerPath =
        "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
    static let fileTransferIOSCallerPath =
        "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager+FileTransfer.swift"
    static let cryptoCapabilitiesPath =
        "Sources/SkyBridgeProtocolCore/P2P/CryptoCapabilities.swift"
    static let handshakePolicyPath =
        "Sources/SkyBridgeProtocolCore/P2P/TranscriptBuilder.swift"
    static let handshakeMessagesPath =
        "Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift"
    static let hpkeSealedBoxPath =
        "Sources/SkyBridgeProtocolCore/P2P/HPKESealedBox.swift"
    static let bonjourAdapterPath =
        "Sources/SkyBridgeCore/Discovery/BonjourInteropContract.swift"
    static let bonjourContractPath =
        "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift"
    static let iosBonjourDiscoveryCallerPath =
        "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    static let iosBonjourFileTransferCallerPath =
        "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"

    static let expectedProductionSourceSHA256: [String: String] = [
        fileTransferDefinitionPath:
            "c5e08a59ea3b77fa909e1e0e9e982c78c0dad700b24fb3c6117d7bce89d5882d",
        fileTransferWireEncoderPath:
            "450f04f7ffdb9ed35371affcc9b8797e9bfa62653ec8d6fd37d3970cec8fb7da",
        fileTransferWireDecoderPath:
            "0ae3c4007a6ec4443bac4cba5d865f3971ce955dd84c461cf8b77ddf9575f86c",
        fileTransferAdmissionPolicyPath:
            "6b5387f6074bbcdae8305c656ab27aeaf2259d86f5e8dc70a602a98a89ab598b",
        fileTransferShippingCallerPath:
            "9e8a2dbfc0e22eced3b6cd0ddd2e135104318643e3d9dca2d4dc25df87d21c5f",
        fileTransferMacResponseCallerPath:
            "bf2167d395e353913037475a2a6dc5182ab4e2b0732ecc4f11f81a9cdd17aecb",
        fileTransferIOSCallerPath:
            "0e8abdbce52fda3c6904c8eedc7d0ae1fbbf00a0aa0e35757e941439384232f7",
        cryptoCapabilitiesPath:
            "9e5a861f06b061f6991bd1168ebe3b0ff4156be1ab75489551754a942066ca46",
        handshakePolicyPath:
            "99dd756f728ff590cb9f58be63d89943f8eb7896a7405e4199e4385e44cd672e",
        handshakeMessagesPath:
            "c09023ae9d0fbb4d13d914014112e752aa1ebe566c55a247d20a55b524aedb37",
        hpkeSealedBoxPath:
            "e2943f721252d7751fded95ab3e47b0ecfb6d250aaf325c278244fdcc7fb094b",
        bonjourAdapterPath:
            "a12564720db40d83561357c1d6608db471495e6772a04edc4f37f7006175da98",
        bonjourContractPath:
            "4d8bbf100a52d92e14a2b38cd2c1738aac4a6970212330b93f15118b36d9cc87",
        iosBonjourDiscoveryCallerPath:
            "f3a5a358fe2b927dd4efdcfcbc8bba6864121fbc151a4f68fa675430694dbdea",
        iosBonjourFileTransferCallerPath:
            "74b00f720fb6bb1699b1286973aa214d2fbde068e43974883ee10f3d1401bf89"
    ]

    static func buildVectors(from inputs: SemanticInputs) throws -> [Vector] {
        var vectors = try inputs.fileTransfer.map(makeFileTransferVector)
        vectors.append(contentsOf: try makeHandshakeVectors(inputs))
        vectors.append(contentsOf: try inputs.hpke.map(makeHPKEVector))
        vectors.append(contentsOf: try inputs.bonjour.map(makeBonjourVector))
        return vectors
    }

    static func makeFileTransferVector(_ input: FileTransferInput) throws -> Vector {
        guard let operation = CrossNetworkFileTransferOp(rawValue: input.op) else {
            throw CaptureError.invalidSemanticInput("unknown F1 operation \(input.op)")
        }
        let message = CrossNetworkFileTransferMessage(
            op: operation,
            transferId: input.transferId,
            senderDeviceId: input.senderDeviceId,
            senderDeviceName: input.senderDeviceName,
            fileName: input.fileName,
            fileSize: input.fileSize,
            chunkSize: input.chunkSize,
            totalChunks: input.totalChunks,
            mimeType: input.mimeType,
            chunkIndex: input.chunkIndex,
            chunkData: try decodeOptionalHex(input.chunkDataHex),
            chunkSha256: try decodeOptionalHex(input.chunkSha256Hex),
            rawSize: input.rawSize,
            receivedBytes: input.receivedBytes,
            fileSha256: try decodeOptionalHex(input.fileSha256Hex),
            merkleRoot: try decodeOptionalHex(input.merkleRootHex),
            merkleRootSignature: try decodeOptionalHex(input.merkleRootSignatureHex),
            merkleRootSignatureAlg: input.merkleRootSignatureAlg,
            missingChunks: input.missingChunks,
            batchId: input.batchId,
            batchIndex: input.batchIndex,
            batchTotal: input.batchTotal,
            relativePath: input.relativePath,
            message: input.message
        )

        var fields = [
            "version": "1",
            "op": input.op,
            "transferId": input.transferId
        ]
        add(input.senderDeviceId, as: "senderDeviceId", to: &fields)
        add(input.senderDeviceName, as: "senderDeviceName", to: &fields)
        add(input.fileName, as: "fileName", to: &fields)
        add(input.fileSize, as: "fileSize", to: &fields)
        add(input.chunkSize, as: "chunkSize", to: &fields)
        add(input.totalChunks, as: "totalChunks", to: &fields)
        add(input.mimeType, as: "mimeType", to: &fields)
        add(input.chunkIndex, as: "chunkIndex", to: &fields)
        add(input.chunkDataHex, as: "chunkData", to: &fields)
        add(input.chunkSha256Hex, as: "chunkSha256", to: &fields)
        add(input.rawSize, as: "rawSize", to: &fields)
        add(input.receivedBytes, as: "receivedBytes", to: &fields)
        add(input.fileSha256Hex, as: "fileSha256", to: &fields)
        add(input.merkleRootHex, as: "merkleRoot", to: &fields)
        add(input.merkleRootSignatureHex, as: "merkleRootSignature", to: &fields)
        add(input.merkleRootSignatureAlg, as: "merkleRootSignatureAlg", to: &fields)
        if let missingChunks = input.missingChunks {
            fields["missingChunks"] = missingChunks.description
        }
        add(input.batchId, as: "batchId", to: &fields)
        add(input.batchIndex, as: "batchIndex", to: &fields)
        add(input.batchTotal, as: "batchTotal", to: &fields)
        add(input.relativePath, as: "relativePath", to: &fields)
        add(input.message, as: "message", to: &fields)

        return Vector(
            surface: .fileTransfer,
            messageType: input.messageType,
            rawBytes: try CrossNetworkFileTransferWireEncoder.encode(message),
            expectedFields: fields,
            sourcePath: fileTransferWireEncoderPath,
            note: "CrossNetworkFileTransferMessage encoded by the shipping canonical production codec"
        )
    }

    static func makeHandshakeVectors(_ inputs: SemanticInputs) throws -> [Vector] {
        guard let provider = CryptoProviderType(rawValue: inputs.cryptoCapabilities.providerType),
              let minimumTier = CryptoTier(rawValue: inputs.handshakePolicy.minimumTier) else {
            throw CaptureError.invalidSemanticInput("unknown F2 provider or minimum tier")
        }
        let capabilities = CryptoCapabilities(
            supportedKEM: inputs.cryptoCapabilities.supportedKEM,
            supportedSignature: inputs.cryptoCapabilities.supportedSignature,
            supportedAuthProfiles: inputs.cryptoCapabilities.supportedAuthProfiles,
            supportedAEAD: inputs.cryptoCapabilities.supportedAEAD,
            pqcAvailable: inputs.cryptoCapabilities.pqcAvailable,
            platformVersion: inputs.cryptoCapabilities.platformVersion,
            providerType: provider
        )
        let policy = HandshakePolicy(
            requirePQC: inputs.handshakePolicy.requirePQC,
            allowClassicFallback: inputs.handshakePolicy.allowClassicFallback,
            minimumTier: minimumTier,
            requireSecureEnclavePoP: inputs.handshakePolicy.requireSecureEnclavePoP
        )

        let messageASuites = try inputs.messageA.supportedSuiteWireIds.map(cryptoSuite)
        let messageA = HandshakeMessageA(
            supportedSuites: messageASuites,
            keyShares: try inputs.messageA.keyShares.map {
                HandshakeKeyShare(
                    suite: try cryptoSuite($0.suiteWireId),
                    shareBytes: try decodeHex($0.shareHex)
                )
            },
            clientNonce: try decodeHex(inputs.messageA.clientNonceHex),
            policy: policy,
            capabilities: capabilities,
            signature: try decodeHex(inputs.messageA.signatureHex),
            identityPublicKey: try decodeHex(inputs.messageA.identityPublicKeyHex),
            extensionsRaw: try decodeHex(inputs.messageA.extensionsRawHex),
            secureEnclaveSignature: try decodeOptionalHex(inputs.messageA.secureEnclaveSignatureHex),
            initiatorContribution: try decodeOptionalHex(inputs.messageA.initiatorContributionHex)
        )

        let messageBSuite = try cryptoSuite(inputs.messageB.selectedSuiteWireId)
        let messageBPayload = try sealedBox(inputs.messageB.encryptedPayload)
        let messageB = HandshakeMessageB(
            selectedSuite: messageBSuite,
            responderShare: try decodeHex(inputs.messageB.responderShareHex),
            serverNonce: try decodeHex(inputs.messageB.serverNonceHex),
            encryptedPayload: messageBPayload,
            signature: try decodeHex(inputs.messageB.signatureHex),
            identityPublicKey: try decodeHex(inputs.messageB.identityPublicKeyHex),
            secureEnclaveSignature: try decodeOptionalHex(inputs.messageB.secureEnclaveSignatureHex)
        )
        guard inputs.finished.direction == "responderToInitiator" else {
            throw CaptureError.invalidSemanticInput("unknown Finished direction")
        }
        let finished = HandshakeFinished(
            direction: .responderToInitiator,
            mac: try decodeHex(inputs.finished.macHex)
        )

        return [
            Vector(
                surface: .p2pHandshake,
                messageType: "cryptoCapabilities",
                rawBytes: try capabilities.deterministicEncode(),
                expectedFields: [
                    "supportedKEM": listDescription(inputs.cryptoCapabilities.supportedKEM),
                    "supportedSignature": listDescription(inputs.cryptoCapabilities.supportedSignature),
                    "supportedAuthProfiles": listDescription(inputs.cryptoCapabilities.supportedAuthProfiles),
                    "supportedAEAD": listDescription(inputs.cryptoCapabilities.supportedAEAD),
                    "pqcAvailable": String(inputs.cryptoCapabilities.pqcAvailable),
                    "platformVersion": inputs.cryptoCapabilities.platformVersion,
                    "providerTypeRaw": inputs.cryptoCapabilities.providerType
                ],
                sourcePath: cryptoCapabilitiesPath,
                note: "CryptoCapabilities.deterministicEncode production output"
            ),
            Vector(
                surface: .p2pHandshake,
                messageType: "finished",
                rawBytes: finished.encoded,
                expectedFields: [
                    "version": String(HandshakeConstants.protocolVersion),
                    "direction": "RESPONDER_TO_INITIATOR",
                    "mac": inputs.finished.macHex
                ],
                sourcePath: handshakeMessagesPath,
                note: "HandshakeFinished.encoded production output"
            ),
            Vector(
                surface: .p2pHandshake,
                messageType: "handshakePolicy",
                rawBytes: policy.deterministicEncode(),
                expectedFields: [
                    "requirePqc": String(inputs.handshakePolicy.requirePQC),
                    "allowClassicFallback": String(inputs.handshakePolicy.allowClassicFallback),
                    "minimumTierRaw": inputs.handshakePolicy.minimumTier,
                    "requireSecureEnclavePoP": String(inputs.handshakePolicy.requireSecureEnclavePoP)
                ],
                sourcePath: handshakePolicyPath,
                note: "HandshakePolicy.deterministicEncode production output"
            ),
            Vector(
                surface: .p2pHandshake,
                messageType: "messageA",
                rawBytes: messageA.encoded,
                expectedFields: [
                    "clientNonce": inputs.messageA.clientNonceHex,
                    "signature": inputs.messageA.signatureHex
                ],
                sourcePath: handshakeMessagesPath,
                note: "HandshakeMessageA.encoded production output; suite order is the semantic input order"
            ),
            Vector(
                surface: .p2pHandshake,
                messageType: "messageB",
                rawBytes: messageB.encoded,
                expectedFields: [
                    "responderShare": inputs.messageB.responderShareHex,
                    "serverNonce": inputs.messageB.serverNonceHex,
                    "signature": inputs.messageB.signatureHex
                ],
                sourcePath: handshakeMessagesPath,
                note: "HandshakeMessageB.encoded production output"
            )
        ]
    }

    static func makeHPKEVector(_ input: HPKEInput) throws -> Vector {
        let suite = try cryptoSuite(input.suiteWireId)
        let box = try sealedBox(input.payload)
        let version = box.nonce.count == 12 && box.tag.count == 16 ? 1 : 2
        return Vector(
            surface: .hpkeSealedBox,
            messageType: input.messageType,
            rawBytes: box.combinedWithHeader(suite: suite),
            expectedFields: [
                "version": String(version),
                "suiteWireId": String(input.suiteWireId),
                "encapsulatedKey": input.encapsulatedKeyHex,
                "nonce": input.nonceHex,
                "ciphertext": input.ciphertextHex,
                "tag": input.tagHex
            ],
            sourcePath: hpkeSealedBoxPath,
            note: "HPKESealedBox.combinedWithHeader(suite:) production output"
        )
    }

    static func makeBonjourVector(_ input: BonjourInput) throws -> Vector {
        guard let platform = BonjourInteropContract.AdvertisementPlatform(rawValue: input.platform),
              let role = BonjourInteropContract.AdvertisementRole(rawValue: input.role),
              BonjourInteropContract.advertisementRole(for: input.serviceType) == role else {
            throw CaptureError.invalidSemanticInput("F4 platform/role/serviceType mismatch")
        }
        let rawWireData = try BonjourInteropProtocolContract.canonicalAdvertisementWireData(
            deviceId: input.deviceId,
            pubKeyFingerprint: input.pubKeyFingerprint,
            platform: platform,
            role: role
        )
        var semanticFields = [
            "version": "2",
            "deviceId": input.deviceId,
            "pubKeyFP": input.pubKeyFingerprint,
            "platform": input.platform
        ]
        if role == .control {
            semanticFields["hs_soa"] = "1"
        }
        return Vector(
            surface: .bonjourTXT,
            messageType: input.messageType,
            rawBytes: rawWireData,
            expectedFields: semanticFields.mapValues { Data($0.utf8).hexLowercased },
            sourcePath: bonjourContractPath,
            note: "canonical production raw TXT; serviceType=\(input.serviceType); role=\(input.role); SRV owns the port"
        )
    }

    static func assertProductionRoundTrips(inputs: SemanticInputs, vectors: [Vector]) throws {
        for vector in vectors where vector.surface == .fileTransfer {
            let decoded = try CrossNetworkFileTransferWireDecoder.decode(vector.rawBytes)
            guard try CrossNetworkFileTransferWireEncoder.encode(decoded) == vector.rawBytes else {
                throw CaptureError.roundTripMismatch(vector.relativePath)
            }
            switch decoded.op {
            case .metadata, .chunk, .complete, .cancel:
                guard try CrossNetworkFileTransferInboundAdmissionPolicy.retainedByteCharge(
                    for: decoded,
                    encodedPayloadByteCount: vector.rawBytes.count
                ) == vector.rawBytes.count else {
                    throw CaptureError.productionAdmissionMismatch(vector.relativePath)
                }
            case .metadataAck, .chunkAck, .completeAck, .error:
                try CrossNetworkFileTransferInboundAdmissionPolicy.validateInboundResponse(decoded)
            }
        }

        let byType = Dictionary(uniqueKeysWithValues: vectors.map { ($0.messageType, $0) })
        guard let messageA = byType["messageA"],
              let messageB = byType["messageB"],
              let finished = byType["finished"] else {
            throw CaptureError.invalidSemanticInput("missing F2 vectors")
        }
        guard try HandshakeMessageA.decode(from: messageA.rawBytes).encoded == messageA.rawBytes,
              try HandshakeMessageB.decode(from: messageB.rawBytes).encoded == messageB.rawBytes,
              try HandshakeFinished.decode(from: finished.rawBytes).encoded == finished.rawBytes else {
            throw CaptureError.roundTripMismatch("F2")
        }

        for input in inputs.hpke {
            guard let vector = vectors.first(where: {
                $0.surface == .hpkeSealedBox && $0.messageType == input.messageType
            }) else {
                throw CaptureError.invalidSemanticInput("missing F3 vector \(input.messageType)")
            }
            let parsed = try HPKESealedBox(
                combined: vector.rawBytes,
                isHandshake: input.messageType.hasPrefix("handshake-")
            )
            guard parsed.combinedWithHeader(suite: try cryptoSuite(input.suiteWireId)) == vector.rawBytes else {
                throw CaptureError.roundTripMismatch(vector.relativePath)
            }
        }

        for input in inputs.bonjour {
            guard let vector = vectors.first(where: {
                $0.surface == .bonjourTXT && $0.messageType == input.messageType
            }),
            let role = BonjourInteropContract.AdvertisementRole(rawValue: input.role),
            let platform = BonjourInteropContract.AdvertisementPlatform(rawValue: input.platform) else {
                throw CaptureError.invalidSemanticInput("missing F4 vector \(input.messageType)")
            }
            let decoded = try BonjourInteropProtocolContract.decodeAdvertisement(vector.rawBytes, role: role)
            let appleAdapterData = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
                deviceId: input.deviceId,
                pubKeyFingerprint: input.pubKeyFingerprint,
                platform: platform,
                role: role
            ).data
            guard case .version2(let advertisement) = decoded,
                  advertisement.deviceId == input.deviceId,
                  advertisement.protocolPublicKeyFingerprint == input.pubKeyFingerprint,
                  advertisement.platform.rawValue == input.platform,
                  advertisement.role == role,
                  appleAdapterData == vector.rawBytes else {
                throw CaptureError.roundTripMismatch(vector.relativePath)
            }
        }
    }

    static func assertCaptureUsesShippingCodecs(
        repositoryRoot: URL,
        inputs: SemanticInputs
    ) throws {
        let fileTransferSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(fileTransferShippingCallerPath),
            encoding: .utf8
        )
        guard fileTransferSource.contains(
            "let plain = try CrossNetworkFileTransferWireEncoder.encode(message)"
        ) else {
            throw CaptureError.shippingEncoderDrift
        }
        let macResponseSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(fileTransferMacResponseCallerPath),
            encoding: .utf8
        )
        let iosFileTransferWireSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(fileTransferIOSCallerPath),
            encoding: .utf8
        )
        guard occurrences(
            of: "CrossNetworkFileTransferWireEncoder.encode(response)",
            in: macResponseSource
        ) == 2,
        occurrences(of: "JSONEncoder().encode(response)", in: macResponseSource) == 0,
        iosFileTransferWireSource.contains(
            "CrossNetworkFileTransferWireEncoder.encode(message)"
        ) else {
            throw CaptureError.shippingEncoderDrift
        }

        let macBonjourSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(bonjourAdapterPath),
            encoding: .utf8
        )
        let iosDiscoverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(iosBonjourDiscoveryCallerPath),
            encoding: .utf8
        )
        let iosFileTransferSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(iosBonjourFileTransferCallerPath),
            encoding: .utf8
        )
        guard macBonjourSource.contains("try Core.canonicalAdvertisementWireData("),
              iosDiscoverySource.contains(
                "try BonjourInteropProtocolContract.canonicalAdvertisementWireData("
              ),
              iosDiscoverySource.contains("return NWTXTRecord(wireData)"),
              iosFileTransferSource.contains(
                "try BonjourInteropProtocolContract.canonicalAdvertisementWireData("
              ),
              iosFileTransferSource.contains("txtRecord: txtRecord"),
              !iosFileTransferSource.contains("NetService.data(fromTXTRecord:"),
              !iosFileTransferSource.contains("fields.mapValues") else {
            throw CaptureError.shippingEncoderDrift
        }

        for input in inputs.bonjour {
            guard let platform = BonjourInteropContract.AdvertisementPlatform(rawValue: input.platform),
                  let role = BonjourInteropContract.AdvertisementRole(rawValue: input.role) else {
                throw CaptureError.invalidSemanticInput("invalid F4 shipping parity input")
            }
            let coreData = try BonjourInteropProtocolContract.canonicalAdvertisementWireData(
                deviceId: input.deviceId,
                pubKeyFingerprint: input.pubKeyFingerprint,
                platform: platform,
                role: role
            )
            let adapterData = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
                deviceId: input.deviceId,
                pubKeyFingerprint: input.pubKeyFingerprint,
                platform: platform,
                role: role
            ).data
            guard adapterData == coreData else {
                throw CaptureError.shippingEncoderDrift
            }
        }
    }

    static func cryptoSuite(_ rawValue: Int) throws -> CryptoSuite {
        guard let wireID = UInt16(exactly: rawValue) else {
            throw CaptureError.invalidSemanticInput("suite wire ID outside UInt16")
        }
        let suite = CryptoSuite(wireId: wireID)
        guard suite.isKnown else {
            throw CaptureError.invalidSemanticInput("unknown suite wire ID \(rawValue)")
        }
        return suite
    }

    static func sealedBox(_ input: EncryptedPayloadInput) throws -> HPKESealedBox {
        HPKESealedBox(
            encapsulatedKey: try decodeHex(input.encapsulatedKeyHex),
            nonce: try decodeHex(input.nonceHex),
            ciphertext: try decodeHex(input.ciphertextHex),
            tag: try decodeHex(input.tagHex)
        )
    }

    static func listDescription(_ values: [String]) -> String {
        "[\(values.joined(separator: ", "))]"
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    static func add<T>(_ value: T?, as key: String, to fields: inout [String: String]) {
        if let value {
            fields[key] = String(describing: value)
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private extension AppleCompatibilityVectorCaptureTests {
    static let expectedRemoteURL = "https://github.com/billlza/Skybridge-Compass"
    static let repositoryIdentity = "github.com/billlza/Skybridge-Compass"
    static let captureRootEnvironmentKey = "SKYBRIDGE_APPLE_VECTOR_CAPTURE_ROOT"
    static let collectedAtEnvironmentKey = "SKYBRIDGE_APPLE_VECTOR_COLLECTED_AT_UTC"
    static let scratchRootEnvironmentKey = "SKYBRIDGE_APPLE_VECTOR_SCRATCH_ROOT"
    static let maximumRequiredSourceByteCount = 4 * 1_024 * 1_024
    static let maximumSourceSetByteCount = 16 * 1_024 * 1_024

    struct CaptureProvenance: Encodable {
        let origin: String
        let source: String
        let collectedAtUtc: String
        let repoIdentity: String
        let repositoryRemoteURL: String
        let sourceCommit: String
        let sourcePath: String
        let captureToolPath: String
        let semanticInputPath: String
        let semanticInputSha256: String
        let sourceSetSha256: String
        let note: String
    }

    struct CaptureDocument: Encodable {
        let schemaVersion: Int
        let surface: String
        let messageType: String
        let rawBytesHex: String
        let expectedFields: [String: String]
        let provenance: CaptureProvenance
    }

    struct ManifestCapture: Encodable {
        let relativePath: String
        let surface: String
        let messageType: String
        let documentSha256: String
        let rawByteCount: Int
        let sourcePath: String
    }

    struct CaptureManifest: Encodable {
        let schemaVersion: Int
        let fixtureSetId: String
        let integrityPurpose: String
        let repoIdentity: String
        let repositoryRemoteURL: String
        let sourceCommit: String
        let captureToolPath: String
        let semanticInputPath: String
        let semanticInputSha256: String
        let sourceSetSha256: String
        let collectedAtUtc: String
        let toolchain: ToolchainEvidence
        let captures: [ManifestCapture]
    }

    struct ToolchainEvidence: Encodable, Equatable {
        let swiftVersion: String
        let xcodeVersion: String
        let testExecutableSha256: String
    }

    struct RequiredFileEvidence: Equatable {
        let relativePath: String
        let gitMode: String
        let objectID: String
        let contentSha256: String
        let byteCount: Int
    }

    struct RepositorySnapshot: Equatable {
        let resolvedRootPath: String
        let sourceCommit: String
        let remoteURL: String
        let sourceSetSha256: String
        let requiredFiles: [RequiredFileEvidence]
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct ValidatedPrivateDirectory {
        let url: URL
        let identity: FileIdentity
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func exportIfExplicitlyRequested(
        environment: [String: String],
        repositoryRoot: URL,
        inputData: Data,
        firstVectors: [Vector],
        repeatedVectors: [Vector]
    ) throws {
        // The exporter accepts only a typed capture set produced by the same
        // fail-fast gate as the normal test. No environment or filesystem work
        // occurs before this succeeds.
        let captureSet = try validateCaptureSet(first: firstVectors, repeated: repeatedVectors)
        let outputPath = environment[captureRootEnvironmentKey]
        let collectedAt = environment[collectedAtEnvironmentKey]
        let scratchPath = environment[scratchRootEnvironmentKey]
        if outputPath == nil, collectedAt == nil, scratchPath == nil {
            return
        }
        guard let outputPath, !outputPath.isEmpty,
              let collectedAt, !collectedAt.isEmpty,
              let scratchPath, !scratchPath.isEmpty else {
            throw CaptureError.incompleteExportEnvironment
        }
        guard NSString(string: outputPath).isAbsolutePath,
              NSString(string: scratchPath).isAbsolutePath else {
            throw CaptureError.outputMustBeAbsolute
        }
        let inputHash = sha256Hex(inputData)
        guard inputHash == expectedInputSHA256 else {
            throw CaptureError.semanticInputHashMismatch
        }
        try validateCollectedAtUTC(collectedAt)

        let scratchRoot = try validatePrivateDirectory(
            URL(fileURLWithPath: scratchPath, isDirectory: true),
            isOutside: repositoryRoot
        )
        let testExecutable = try validateCurrentTestExecutable(inside: scratchRoot)
        let outputRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
        let validatedOutputRoot = try validatePrivateDirectory(
            outputRoot,
            isOutside: repositoryRoot,
            containedIn: scratchRoot
        )

        let requiredPaths = requiredTrackedPaths(for: captureSet.vectors)
        let initialSnapshot = try captureRepositorySnapshot(
            repositoryRoot: repositoryRoot,
            requiredPaths: requiredPaths
        )
        try validateProductionSourceHashes(repositoryRoot: repositoryRoot)
        let toolchain = try captureToolchainEvidence(
            repositoryRoot: repositoryRoot,
            testExecutable: testExecutable
        )

        let encoder = captureJSONEncoder()
        var encodedDocuments: [(vector: Vector, data: Data)] = []
        for vector in captureSet.vectors.sorted(by: { $0.relativePath < $1.relativePath }) {
            let document = CaptureDocument(
                schemaVersion: 1,
                surface: vector.surface.rawValue,
                messageType: vector.messageType,
                rawBytesHex: vector.rawBytes.hexLowercased,
                expectedFields: vector.expectedFields,
                provenance: CaptureProvenance(
                    origin: "APPLE_REFERENCE_CAPTURE",
                    source: "SkyBridge Apple production codec XCTest capture",
                    collectedAtUtc: collectedAt,
                    repoIdentity: repositoryIdentity,
                    repositoryRemoteURL: initialSnapshot.remoteURL,
                    sourceCommit: initialSnapshot.sourceCommit,
                    sourcePath: vector.sourcePath,
                    captureToolPath: toolRelativePath,
                    semanticInputPath: inputRelativePath,
                    semanticInputSha256: inputHash,
                    sourceSetSha256: initialSnapshot.sourceSetSha256,
                    note: vector.note
                )
            )
            encodedDocuments.append((vector, try newlineTerminated(encoder.encode(document))))
        }

        let manifestEntries = encodedDocuments.map { item in
            ManifestCapture(
                relativePath: item.vector.relativePath,
                surface: item.vector.surface.rawValue,
                messageType: item.vector.messageType,
                documentSha256: sha256Hex(item.data),
                rawByteCount: item.vector.rawBytes.count,
                sourcePath: item.vector.sourcePath
            )
        }
        let manifest = CaptureManifest(
            schemaVersion: 1,
            fixtureSetId: "apple-production-codec-v1",
            integrityPurpose: "SHA-256 values detect accidental capture corruption; they are not an authenticity claim",
            repoIdentity: repositoryIdentity,
            repositoryRemoteURL: initialSnapshot.remoteURL,
            sourceCommit: initialSnapshot.sourceCommit,
            captureToolPath: toolRelativePath,
            semanticInputPath: inputRelativePath,
            semanticInputSha256: inputHash,
            sourceSetSha256: initialSnapshot.sourceSetSha256,
            collectedAtUtc: collectedAt,
            toolchain: toolchain,
            captures: manifestEntries
        )

        let immediatelyBeforeWrite = try captureRepositorySnapshot(
            repositoryRoot: repositoryRoot,
            requiredPaths: requiredPaths
        )
        guard immediatelyBeforeWrite == initialSnapshot else {
            throw CaptureError.repositoryChangedDuringCapture
        }
        try revalidatePrivateDirectory(validatedOutputRoot)

        // Each document is created atomically and without replacement. The manifest is last,
        // so its presence denotes a complete capture set. Identical reruns are idempotent.
        for item in encodedDocuments {
            try writeOnceOrConfirmIdentical(
                item.data,
                relativePath: item.vector.relativePath,
                under: validatedOutputRoot
            )
        }

        let afterDocuments = try captureRepositorySnapshot(
            repositoryRoot: repositoryRoot,
            requiredPaths: requiredPaths
        )
        guard afterDocuments == initialSnapshot else {
            throw CaptureError.repositoryChangedDuringCapture
        }
        try revalidatePrivateDirectory(validatedOutputRoot)
        try writeOnceOrConfirmIdentical(
            newlineTerminated(try encoder.encode(manifest)),
            relativePath: "manifest.json",
            under: validatedOutputRoot
        )
    }

    static func requiredTrackedPaths(for vectors: [Vector]) -> Set<String> {
        Set([
            "Package.swift",
            toolRelativePath,
            inputRelativePath,
            fileTransferDefinitionPath,
            fileTransferWireEncoderPath,
            fileTransferWireDecoderPath,
            fileTransferAdmissionPolicyPath,
            fileTransferShippingCallerPath,
            fileTransferMacResponseCallerPath,
            fileTransferIOSCallerPath,
            cryptoCapabilitiesPath,
            handshakePolicyPath,
            handshakeMessagesPath,
            hpkeSealedBoxPath,
            bonjourAdapterPath,
            bonjourContractPath,
            iosBonjourDiscoveryCallerPath,
            iosBonjourFileTransferCallerPath
        ] + vectors.map(\.sourcePath))
    }

    static func validateRepositoryEvidence(
        statusOutput: String,
        sourceCommit: String,
        remoteURL: String,
        trackedPaths: Set<String>,
        requiredPaths: Set<String>
    ) throws {
        guard statusOutput.isEmpty else {
            throw CaptureError.dirtyRepository
        }
        guard sourceCommit.utf8.count == 40,
              sourceCommit.utf8.allSatisfy({
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
              }) else {
            throw CaptureError.invalidSourceCommit
        }
        guard remoteURL == expectedRemoteURL else {
            throw CaptureError.unexpectedRepository
        }
        for path in requiredPaths.sorted() {
            try validateRelativeRepositoryPath(path)
            guard trackedPaths.contains(path) else {
                throw CaptureError.untrackedRequiredPath(path)
            }
        }
    }

    static func validateRelativeRepositoryPath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//") else {
            throw CaptureError.invalidRepositoryPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureError.invalidRepositoryPath(path)
        }
    }

    static func validateCollectedAtUTC(_ value: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw CaptureError.invalidCollectedAtUTC
        }
    }

    static func captureRepositorySnapshot(
        repositoryRoot: URL,
        requiredPaths: Set<String>
    ) throws -> RepositorySnapshot {
        let resolvedRoot = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let reportedRoot = try runGit(["rev-parse", "--show-toplevel"], at: resolvedRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: reportedRoot).standardizedFileURL.resolvingSymlinksInPath().path
                == resolvedRoot.path else {
            throw CaptureError.unexpectedRepositoryRoot
        }

        let status = try runGit(
            ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"],
            at: resolvedRoot
        )
        let sourceCommit = try runGit(
            ["rev-parse", "--verify", "HEAD^{commit}"],
            at: resolvedRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = try runGit(["remote", "get-url", "origin"], at: resolvedRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try validateNoHiddenGitIndexFlags(repositoryRoot: resolvedRoot)
        var evidence: [RequiredFileEvidence] = []
        var totalByteCount = 0
        for path in requiredPaths.sorted() {
            let item = try captureRequiredFileEvidence(
                relativePath: path,
                repositoryRoot: resolvedRoot
            )
            totalByteCount += item.byteCount
            guard totalByteCount <= maximumSourceSetByteCount else {
                throw CaptureError.requiredSourceSetTooLarge
            }
            evidence.append(item)
        }
        try validateRepositoryEvidence(
            statusOutput: status,
            sourceCommit: sourceCommit,
            remoteURL: remoteURL,
            trackedPaths: Set(evidence.map(\.relativePath)),
            requiredPaths: requiredPaths
        )

        var digestPreimage = Data()
        for item in evidence {
            digestPreimage.append(Data(item.relativePath.utf8))
            digestPreimage.append(0)
            digestPreimage.append(Data(item.gitMode.utf8))
            digestPreimage.append(0)
            digestPreimage.append(Data(item.objectID.utf8))
            digestPreimage.append(0)
            digestPreimage.append(Data(item.contentSha256.utf8))
            digestPreimage.append(0x0A)
        }
        return RepositorySnapshot(
            resolvedRootPath: resolvedRoot.path,
            sourceCommit: sourceCommit,
            remoteURL: remoteURL,
            sourceSetSha256: sha256Hex(digestPreimage),
            requiredFiles: evidence
        )
    }

    static func captureRequiredFileEvidence(
        relativePath: String,
        repositoryRoot: URL
    ) throws -> RequiredFileEvidence {
        try validateRelativeRepositoryPath(relativePath)
        let treeRecord = try singleNULTerminatedRecord(
            runGitData(["ls-tree", "-z", "HEAD", "--", relativePath], at: repositoryRoot),
            command: "ls-tree"
        )
        guard let treeTab = treeRecord.firstIndex(of: "\t") else {
            throw CaptureError.invalidGitEvidence(relativePath)
        }
        let treeMetadata = treeRecord[..<treeTab].split(separator: " ")
        let treePath = String(treeRecord[treeRecord.index(after: treeTab)...])
        guard treeMetadata.count == 3,
              ["100644", "100755"].contains(String(treeMetadata[0])),
              treeMetadata[1] == "blob",
              treePath == relativePath else {
            throw CaptureError.invalidGitEvidence(relativePath)
        }
        let mode = String(treeMetadata[0])
        let objectID = String(treeMetadata[2])

        let stageRecord = try singleNULTerminatedRecord(
            runGitData(["ls-files", "--stage", "-z", "--", relativePath], at: repositoryRoot),
            command: "ls-files --stage"
        )
        guard let stageTab = stageRecord.firstIndex(of: "\t") else {
            throw CaptureError.invalidGitEvidence(relativePath)
        }
        let stageMetadata = stageRecord[..<stageTab].split(separator: " ")
        let stagePath = String(stageRecord[stageRecord.index(after: stageTab)...])
        guard stageMetadata.count == 3,
              String(stageMetadata[0]) == mode,
              String(stageMetadata[1]) == objectID,
              stageMetadata[2] == "0",
              stagePath == relativePath else {
            throw CaptureError.invalidGitEvidence(relativePath)
        }

        let flagRecord = try singleNULTerminatedRecord(
            runGitData(["ls-files", "-v", "-z", "--", relativePath], at: repositoryRoot),
            command: "ls-files -v"
        )
        guard flagRecord == "H \(relativePath)" else {
            throw CaptureError.hiddenGitIndexState(relativePath)
        }

        let fileURL = repositoryRoot.appendingPathComponent(relativePath)
        guard let info = try lstatInfo(fileURL), isRegular(info), info.st_uid == geteuid() else {
            throw CaptureError.unsafeFileSystemEntry(relativePath)
        }
        let currentMode = (info.st_mode & mode_t(S_IXUSR)) == 0 ? "100644" : "100755"
        guard currentMode == mode,
              info.st_size >= 0,
              info.st_size <= off_t(maximumRequiredSourceByteCount) else {
            throw CaptureError.invalidGitEvidence(relativePath)
        }
        let currentBytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let headBytes = try runGitData(["cat-file", "blob", objectID], at: repositoryRoot)
        guard currentBytes.count == Int(info.st_size),
              currentBytes == headBytes else {
            throw CaptureError.requiredSourceContentMismatch(relativePath)
        }
        return RequiredFileEvidence(
            relativePath: relativePath,
            gitMode: mode,
            objectID: objectID,
            contentSha256: sha256Hex(currentBytes),
            byteCount: currentBytes.count
        )
    }

    static func validateNoHiddenGitIndexFlags(repositoryRoot: URL) throws {
        let output = try runGitData(["ls-files", "-v", "-z"], at: repositoryRoot)
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard let value = String(data: Data(record), encoding: .utf8), value.count >= 2 else {
                throw CaptureError.invalidGitEvidence("<index>")
            }
            if value.hasPrefix("h ") || value.hasPrefix("s ") || value.hasPrefix("S ") {
                throw CaptureError.hiddenGitIndexState(String(value.dropFirst(2)))
            }
        }
    }

    static func validateProductionSourceHashes(repositoryRoot: URL) throws {
        for (path, expectedHash) in expectedProductionSourceSHA256.sorted(by: { $0.key < $1.key }) {
            let data = try Data(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                options: .mappedIfSafe
            )
            guard sha256Hex(data) == expectedHash else {
                throw CaptureError.productionSourceDigestMismatch(path)
            }
        }
    }

    static func singleNULTerminatedRecord(_ data: Data, command: String) throws -> String {
        guard data.last == 0,
              data.dropLast().allSatisfy({ $0 != 0 }),
              let value = String(data: data.dropLast(), encoding: .utf8) else {
            throw CaptureError.gitCommandFailed(command)
        }
        return value
    }

    static func runGit(_ arguments: [String], at repositoryRoot: URL) throws -> String {
        let data = try runGitData(arguments, at: repositoryRoot)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CaptureError.gitCommandFailed(arguments.joined(separator: " "))
        }
        return value
    }

    static func runGitData(_ arguments: [String], at repositoryRoot: URL) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false"
        ] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0"
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw CaptureError.gitCommandFailed(arguments.joined(separator: " "))
        }
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, errorOutput.isEmpty else {
            throw CaptureError.gitCommandFailed(arguments.joined(separator: " "))
        }
        return output
    }

    static func validatePrivateDirectory(
        _ directory: URL,
        isOutside repositoryRoot: URL,
        containedIn parent: ValidatedPrivateDirectory? = nil
    ) throws -> ValidatedPrivateDirectory {
        guard directory.path.hasPrefix("/") else {
            throw CaptureError.outputMustBeAbsolute
        }
        let standardized = directory.standardizedFileURL
        guard let originalInfo = try lstatInfo(standardized),
              !isSymbolicLink(originalInfo),
              isDirectory(originalInfo) else {
            throw CaptureError.unsafePrivateDirectory(standardized.path)
        }
        if let parent {
            try revalidatePrivateDirectory(parent)
            guard standardized.path != parent.url.path,
                  path(standardized.path, isEqualToOrDescendantOf: parent.url.path),
                  try hasNoSymlinkComponents(standardized, beneath: parent) else {
                throw CaptureError.unsafeFileSystemEntry(standardized.path)
            }
        }
        let resolved = standardized.resolvingSymlinksInPath()
        guard let info = try lstatInfo(resolved),
              !isSymbolicLink(info),
              isDirectory(info),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw CaptureError.unsafePrivateDirectory(resolved.path)
        }
        let repositoryPath = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path(resolved.path, isEqualToOrDescendantOf: repositoryPath) else {
            throw CaptureError.outputInsideRepository
        }
        if let parent {
            guard resolved.path != parent.url.path,
                  path(resolved.path, isEqualToOrDescendantOf: parent.url.path) else {
                throw CaptureError.outputOutsideScratchRoot
            }
        }
        return ValidatedPrivateDirectory(
            url: resolved,
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        )
    }

    static func revalidatePrivateDirectory(_ directory: ValidatedPrivateDirectory) throws {
        guard let info = try lstatInfo(directory.url),
              !isSymbolicLink(info),
              isDirectory(info),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o700),
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
                == directory.identity else {
            throw CaptureError.unsafePrivateDirectory(directory.url.path)
        }
    }

    static func validateCurrentTestExecutable(
        inside scratchRoot: ValidatedPrivateDirectory
    ) throws -> URL {
        try revalidatePrivateDirectory(scratchRoot)
        guard let executable = Bundle(for: AppleCompatibilityVectorCaptureTests.self).executableURL else {
            throw CaptureError.testExecutableUnavailable
        }
        let standardized = executable.standardizedFileURL
        guard path(standardized.path, isEqualToOrDescendantOf: scratchRoot.url.path),
              standardized.path != scratchRoot.url.path,
              try hasNoSymlinkComponents(standardized, beneath: scratchRoot),
              let info = try lstatInfo(standardized),
              isRegular(info),
              info.st_uid == geteuid() else {
            throw CaptureError.testExecutableOutsideScratchRoot
        }
        return standardized
    }

    static func captureToolchainEvidence(
        repositoryRoot: URL,
        testExecutable: URL
    ) throws -> ToolchainEvidence {
        let swift = try runEvidenceCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "-print-target-info"],
            at: repositoryRoot
        )
        let xcode = try runEvidenceCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            at: repositoryRoot
        )
        struct SwiftTargetInfo: Decodable {
            let compilerVersion: String
        }
        guard swift.standardError.isEmpty,
              xcode.standardError.isEmpty,
              let swiftData = swift.standardOutput.data(using: .utf8),
              let swiftInfo = try? JSONDecoder().decode(SwiftTargetInfo.self, from: swiftData),
              !swiftInfo.compilerVersion.isEmpty,
              !xcode.standardOutput.isEmpty else {
            throw CaptureError.toolchainEvidenceUnavailable
        }
        return ToolchainEvidence(
            swiftVersion: swiftInfo.compilerVersion,
            xcodeVersion: xcode.standardOutput,
            testExecutableSha256: sha256Hex(
                try Data(contentsOf: testExecutable, options: .mappedIfSafe)
            )
        )
    }

    static func runEvidenceCommand(
        executable: String,
        arguments: [String],
        at repositoryRoot: URL
    ) throws -> (standardOutput: String, standardError: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        var environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "LC_ALL": "C",
            "LANG": "C"
        ]
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developerDirectory
        }
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw CaptureError.toolchainEvidenceUnavailable
        }
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8),
              let error = String(data: errorData, encoding: .utf8) else {
            throw CaptureError.toolchainEvidenceUnavailable
        }
        return (
            output.trimmingCharacters(in: .whitespacesAndNewlines),
            error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func writeOnceOrConfirmIdentical(
        _ data: Data,
        relativePath: String,
        under outputRoot: ValidatedPrivateDirectory
    ) throws {
        try validateRelativeRepositoryPath(relativePath)
        try revalidatePrivateDirectory(outputRoot)
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw CaptureError.invalidRepositoryPath(relativePath)
        }
        var parent = outputRoot.url
        for component in components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            if try lstatInfo(parent) == nil {
                do {
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    throw CaptureError.outputWriteFailed(relativePath)
                }
            }
            guard let info = try lstatInfo(parent),
                  isDirectory(info),
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                throw CaptureError.unsafeFileSystemEntry(parent.path)
            }
            try revalidatePrivateDirectory(outputRoot)
        }

        let output = parent.appendingPathComponent(fileName)
        guard path(output.path, isEqualToOrDescendantOf: outputRoot.url.path) else {
            throw CaptureError.outputOutsideScratchRoot
        }
        if let existing = try lstatInfo(output) {
            try validatePublishedFile(existing, at: output)
            guard try Data(contentsOf: output, options: .mappedIfSafe) == data else {
                throw CaptureError.outputConflict(output.path)
            }
            return
        }

        let temporary = parent.appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try setFilePermissions(0o600, at: temporary)
            guard let temporaryInfo = try lstatInfo(temporary),
                  isRegular(temporaryInfo),
                  temporaryInfo.st_uid == geteuid(),
                  temporaryInfo.st_nlink == 1 else {
                throw CaptureError.unsafeFileSystemEntry(temporary.path)
            }
            try FileManager.default.linkItem(at: temporary, to: output)
            try FileManager.default.removeItem(at: temporary)
        } catch let error as CaptureError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            let existingInfo = try lstatInfo(output)
            if let existingInfo {
                try validatePublishedFile(existingInfo, at: output)
                let existingData = try Data(contentsOf: output, options: .mappedIfSafe)
                try? FileManager.default.removeItem(at: temporary)
                guard existingData == data else {
                    throw CaptureError.outputConflict(output.path)
                }
                return
            }
            try? FileManager.default.removeItem(at: temporary)
            throw CaptureError.outputWriteFailed(output.path)
        }
        guard let published = try lstatInfo(output) else {
            throw CaptureError.outputWriteFailed(output.path)
        }
        try validatePublishedFile(published, at: output)
        guard try Data(contentsOf: output, options: .mappedIfSafe) == data else {
            throw CaptureError.outputWriteFailed(output.path)
        }
        try revalidatePrivateDirectory(outputRoot)
    }

    static func validatePublishedFile(_ info: stat, at url: URL) throws {
        guard isRegular(info),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw CaptureError.unsafeFileSystemEntry(url.path)
        }
    }

    static func setFilePermissions(_ permissions: mode_t, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chmod(path, permissions)
        }
        guard result == 0 else {
            throw CaptureError.outputWriteFailed(url.path)
        }
    }

    static func hasNoSymlinkComponents(
        _ candidate: URL,
        beneath root: ValidatedPrivateDirectory
    ) throws -> Bool {
        try revalidatePrivateDirectory(root)
        let standardized = candidate.standardizedFileURL
        guard standardized.path != root.url.path,
              path(standardized.path, isEqualToOrDescendantOf: root.url.path) else {
            return false
        }
        let relativePath = String(standardized.path.dropFirst(root.url.path.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        var current = root.url
        for (offset, component) in components.enumerated() {
            current.appendPathComponent(component)
            guard let info = try lstatInfo(current), !isSymbolicLink(info) else {
                return false
            }
            if offset < components.count - 1, !isDirectory(info) {
                return false
            }
        }
        return true
    }

    static func lstatInfo(_ url: URL) throws -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &info)
        }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw CaptureError.fileSystemInspectionFailed(url.path)
    }

    static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    static func isSymbolicLink(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    static func path(_ candidate: String, isEqualToOrDescendantOf root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func captureJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func newlineTerminated(_ data: Data) -> Data {
        var result = data
        result.append(0x0A)
        return result
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexLowercased
    }

    static func decodeOptionalHex(_ value: String?) throws -> Data? {
        guard let value else { return nil }
        return try decodeHex(value)
    }

    static func decodeHex(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard value == value.lowercased(), bytes.count.isMultiple(of: 2) else {
            throw CaptureError.invalidSemanticInput("hex must be lowercase and even-length")
        }
        var decoded = Data()
        decoded.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexNibble(bytes[index]), let low = hexNibble(bytes[index + 1]) else {
                throw CaptureError.invalidSemanticInput("hex contains a non-hexadecimal byte")
            }
            decoded.append((high << 4) | low)
            index += 2
        }
        return decoded
    }

    static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        default:
            nil
        }
    }
}

private enum CaptureError: Error, Equatable {
    case invalidSemanticInput(String)
    case semanticInputHashMismatch
    case shippingEncoderDrift
    case roundTripMismatch(String)
    case productionAdmissionMismatch(String)
    case nondeterministicCaptureSet([String])
    case invalidCaptureVectorCount(Int)
    case invalidCaptureSurfaceCount(String, Int)
    case duplicateCapturePath(String)
    case emptyCaptureRawBytes(String)
    case emptyCaptureExpectedFields(String)
    case captureExceedsMaximum(String)
    case incompleteExportEnvironment
    case outputMustBeAbsolute
    case invalidCollectedAtUTC
    case outputInsideRepository
    case outputOutsideScratchRoot
    case dirtyRepository
    case invalidSourceCommit
    case unexpectedRepository
    case unexpectedRepositoryRoot
    case invalidRepositoryPath(String)
    case untrackedRequiredPath(String)
    case hiddenGitIndexState(String)
    case invalidGitEvidence(String)
    case requiredSourceContentMismatch(String)
    case requiredSourceSetTooLarge
    case productionSourceDigestMismatch(String)
    case repositoryChangedDuringCapture
    case gitCommandFailed(String)
    case unsafePrivateDirectory(String)
    case unsafeFileSystemEntry(String)
    case fileSystemInspectionFailed(String)
    case testExecutableUnavailable
    case testExecutableOutsideScratchRoot
    case toolchainEvidenceUnavailable
    case outputConflict(String)
    case outputWriteFailed(String)
}

private extension Data {
    var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
