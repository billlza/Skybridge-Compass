import Foundation
import XCTest
@testable import SkyBridgeCore

final class LegacyFileTransferWireContractTests: XCTestCase {
    func testValidEncryptedMetadataAtLegacyLimitIsAccepted() throws {
        let metadata = makeMetadata(
            fileSize: LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes,
            encryptionEnabled: true
        )

        XCTAssertEqual(try LegacyFileTransferWireContract.validate(metadata), 512)
    }

    func testEncryptedMetadataAboveLegacyLimitFailsClosed() {
        let metadata = makeMetadata(
            fileSize: LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes + 1,
            encryptionEnabled: true
        )

        XCTAssertThrowsError(try LegacyFileTransferWireContract.validate(metadata)) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                .unsupportedEncryptedFileSize
            )
        }
    }

    func testUnencryptedFileRetainsBoundedTwoGiBCompatibility() throws {
        let metadata = makeMetadata(
            fileSize: LegacyFileTransferWirePolicy.maximumFileSizeBytes,
            chunkSize: LegacyFileTransferWirePolicy.maximumChunkSizeBytes,
            encryptionEnabled: false
        )

        XCTAssertEqual(try LegacyFileTransferWireContract.validate(metadata), 128)
    }

    func testMetadataRejectsInvalidChunkSizeHashAndSignature() {
        assertMetadataError(
            makeMetadata(chunkSize: 0),
            equals: .invalidChunkSize
        )
        assertMetadataError(
            makeMetadata(checksum: String(repeating: "A", count: 64)),
            equals: .invalidFileHash
        )
        assertMetadataError(
            makeMetadata(signature: Data()),
            equals: .invalidSignature
        )
    }

    func testMetadataRejectsMissingSignatureIdentityFields() {
        assertMetadataError(
            makeMetadata(signature: nil),
            equals: .missingSignature
        )
        assertMetadataError(
            makeMetadata(signatureAlgorithm: nil),
            equals: .invalidSignatureAlgorithm
        )
        assertMetadataError(
            makeMetadata(signerPeerId: nil),
            equals: .invalidSignerIdentifier
        )
    }

    func testPacketHeaderRejectsUnboundedLengthBeforeIntegerConversion() {
        let metadata = makeMetadata(fileSize: 65_536, encryptionEnabled: false)

        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validatePacketHeader(
                transferID: metadata.transferId,
                chunkIndex: 0,
                totalChunks: 1,
                dataLength: UInt64.max,
                checksum: metadata.checksum,
                flags: 0,
                metadata: metadata,
                expectedChunkIndex: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                .invalidPacketLength
            )
        }
    }

    func testPacketHeaderEnforcesSequenceFlagsAndEncodingContract() throws {
        let metadata = makeMetadata(fileSize: 65_536, encryptionEnabled: true)
        let encodedLength = UInt64(((65_536 + 2) / 3) * 4)

        XCTAssertEqual(
            try LegacyFileTransferWireContract.validatePacketHeader(
                transferID: metadata.transferId,
                chunkIndex: 0,
                totalChunks: 1,
                dataLength: encodedLength,
                checksum: metadata.checksum,
                flags: 0x02,
                metadata: metadata,
                expectedChunkIndex: 0
            ),
            Int(encodedLength)
        )

        assertPacketHeaderError(metadata: metadata, flags: 0x82, equals: .invalidPacketFlags)
        assertPacketHeaderError(metadata: metadata, flags: 0x00, equals: .invalidPacketEncryption)

        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validatePacketHeader(
                transferID: metadata.transferId,
                chunkIndex: 0,
                totalChunks: 1,
                dataLength: encodedLength,
                checksum: metadata.checksum,
                flags: 0x02,
                metadata: metadata,
                expectedChunkIndex: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                .invalidChunkSequence
            )
        }
    }

    func testDecodedChunkLengthAndCompletionAreExact() throws {
        let metadata = makeMetadata(fileSize: 65_537, encryptionEnabled: false)

        XCTAssertNoThrow(
            try LegacyFileTransferWireContract.validateDecodedChunkLength(
                65_536,
                metadata: metadata,
                receivedBytes: 0
            )
        )
        XCTAssertNoThrow(
            try LegacyFileTransferWireContract.validateDecodedChunkLength(
                1,
                metadata: metadata,
                receivedBytes: 65_536
            )
        )
        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validateDecodedChunkLength(
                0,
                metadata: metadata,
                receivedBytes: 65_536
            )
        )
        XCTAssertNoThrow(
            try LegacyFileTransferWireContract.validateCompletion(
                receivedBytes: 65_537,
                metadata: metadata
            )
        )
        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validateCompletion(
                receivedBytes: 65_536,
                metadata: metadata
            )
        )
    }

    func testLegacyEncryptionPlaintextRoundTripsBinaryAndRejectsMalformedBase64() throws {
        let payload = Data((0..<257).map { UInt8($0 % 251) })
        let encoded = LegacyFileTransferWireContract.encryptionPlaintext(for: payload)

        XCTAssertEqual(try LegacyFileTransferWireContract.decodeEncryptionPlaintext(encoded), payload)
        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.decodeEncryptionPlaintext(Data("%%%".utf8))
        ) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                .invalidEncryptedPayloadEncoding
            )
        }
    }

    private func makeMetadata(
        fileSize: Int64 = 65_536,
        chunkSize: Int = 65_536,
        encryptionEnabled: Bool = true,
        checksum: String = String(repeating: "a", count: 64),
        signature: Data? = Data([0x01]),
        signatureAlgorithm: String? = "ML-DSA-65",
        signerPeerId: String? = "peer-1"
    ) -> FileTransferMetadata {
        FileTransferMetadata(
            transferId: UUID().uuidString,
            fileName: "report.bin",
            fileSize: fileSize,
            checksum: checksum,
            merkleRoot: String(repeating: "b", count: 64),
            hashAlgorithm: "SHA256",
            compressionEnabled: true,
            encryptionEnabled: encryptionEnabled,
            chunkSize: chunkSize,
            fileSignature: signature,
            signatureAlgorithm: signatureAlgorithm,
            signerPeerId: signerPeerId
        )
    }

    private func assertMetadataError(
        _ metadata: FileTransferMetadata,
        equals expectedError: LegacyFileTransferWireContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validate(metadata),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                expectedError,
                file: file,
                line: line
            )
        }
    }

    private func assertPacketHeaderError(
        metadata: FileTransferMetadata,
        flags: UInt8,
        equals expectedError: LegacyFileTransferWireContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LegacyFileTransferWireContract.validatePacketHeader(
                transferID: metadata.transferId,
                chunkIndex: 0,
                totalChunks: 1,
                dataLength: 65_536,
                checksum: metadata.checksum,
                flags: flags,
                metadata: metadata,
                expectedChunkIndex: 0
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LegacyFileTransferWireContractError,
                expectedError,
                file: file,
                line: line
            )
        }
    }
}
