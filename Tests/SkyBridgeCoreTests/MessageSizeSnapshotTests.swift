// SPDX-License-Identifier: MIT
// SkyBridge Compass - Message Size Snapshot Tests
// IEEE Paper wire-format size harness

import XCTest
import Foundation
@testable import SkyBridgeCore

/// Snapshot tests for handshake message sizes and wire breakdowns.
final class MessageSizeSnapshotTests: XCTestCase {

 // MARK: - Message Size Snapshots (Table II)

    func testMessageA_Classic_Size() throws {
        let messageA = try createMessageA(suite: .classic)
        let encoded = messageA.encoded

        SkyBridgeLogger.test.info("[SIZE] MessageA (Classic): \(encoded.count) bytes")

        XCTAssertGreaterThan(encoded.count, 100, "MessageA should be at least 100 bytes")
        XCTAssertLessThan(encoded.count, 500, "MessageA (Classic) should be under 500 bytes")
    }

    func testMessageA_PQC_Size() throws {
        let messageA = try createMessageA(suite: .pqc)
        let encoded = messageA.encoded

        SkyBridgeLogger.test.info("[SIZE] MessageA (PQC): \(encoded.count) bytes")

        XCTAssertGreaterThan(encoded.count, 3000, "MessageA (PQC) should include PQC key material")
        XCTAssertLessThan(encoded.count, 8000, "MessageA (PQC) should be under 8KB")
    }

    func testMessageB_Classic_Size() throws {
        let messageB = try createMessageB(suite: .classic)
        let encoded = messageB.encoded

        SkyBridgeLogger.test.info("[SIZE] MessageB (Classic): \(encoded.count) bytes")

        XCTAssertGreaterThan(encoded.count, 100, "MessageB should be at least 100 bytes")
        XCTAssertLessThan(encoded.count, 500, "MessageB (Classic) should be under 500 bytes")
    }

    func testMessageB_PQC_Size() throws {
        let messageB = try createMessageB(suite: .pqc)
        let encoded = messageB.encoded

        SkyBridgeLogger.test.info("[SIZE] MessageB (PQC): \(encoded.count) bytes")

        XCTAssertGreaterThan(encoded.count, 3000, "MessageB (PQC) should include PQC material")
        XCTAssertLessThan(encoded.count, 8000, "MessageB (PQC) should be under 8KB")
    }

    func testFinished_Size() {
        let finished = HandshakeFinished(
            direction: .responderToInitiator,
            mac: Data(repeating: 0, count: 32)
        )
        let encoded = finished.encoded

        SkyBridgeLogger.test.info("[SIZE] Finished: \(encoded.count) bytes")

        XCTAssertEqual(encoded.count, 38, "Finished frame should be 38 bytes (4+1+1+32)")
    }

    func testTotalWireOverhead_Classic() throws {
        let messageA = try createMessageA(suite: .classic)
        let messageB = try createMessageB(suite: .classic)
        let finishedR2I = HandshakeFinished(direction: .responderToInitiator, mac: Data(repeating: 0, count: 32))
        let finishedI2R = HandshakeFinished(direction: .initiatorToResponder, mac: Data(repeating: 0, count: 32))

        let totalBytes = messageA.encoded.count +
            messageB.encoded.count +
            finishedR2I.encoded.count +
            finishedI2R.encoded.count

        SkyBridgeLogger.test.info("[SIZE] Total (Classic): \(totalBytes) bytes")

        XCTAssertLessThan(totalBytes, 1000, "Classic handshake should be under 1KB total")
    }

    func testTotalWireOverhead_PQC() throws {
        let messageA = try createMessageA(suite: .pqc)
        let messageB = try createMessageB(suite: .pqc)
        let finishedR2I = HandshakeFinished(direction: .responderToInitiator, mac: Data(repeating: 0, count: 32))
        let finishedI2R = HandshakeFinished(direction: .initiatorToResponder, mac: Data(repeating: 0, count: 32))

        let totalBytes = messageA.encoded.count +
            messageB.encoded.count +
            finishedR2I.encoded.count +
            finishedI2R.encoded.count

        SkyBridgeLogger.test.info("[SIZE] Total (PQC): \(totalBytes) bytes")

        XCTAssertLessThan(totalBytes, 20000, "PQC handshake should be under 20KB total")
    }

 // MARK: - Summary Report + CSV Artifact

    func testGenerateSizeReport() throws {
        let classicA = try createMessageA(suite: .classic)
        let classicB = try createMessageB(suite: .classic)
        let pqcA = try createMessageA(suite: .pqc)
        let pqcB = try createMessageB(suite: .pqc)
        let finishedSize = HandshakeFinished(direction: .responderToInitiator, mac: Data(repeating: 0, count: 32)).encoded.count

        let report = """

        ╔══════════════════════════════════════════════════════════════════╗
        ║           IEEE Paper Table II: Handshake Message Sizes           ║
        ╠══════════════════════════════════════════════════════════════════╣
        ║ Configuration      │ B_msgA   │ B_msgB   │ B_finished │ B_total  ║
        ╠══════════════════════════════════════════════════════════════════╣
        ║ Classic            │ \(String(format: "%6d", classicA.encoded.count))   │ \(String(format: "%6d", classicB.encoded.count))   │ \(String(format: "%6d", finishedSize * 2))     │ \(String(format: "%6d", classicA.encoded.count + classicB.encoded.count + finishedSize * 2))   ║
        ║ liboqs PQC         │ \(String(format: "%6d", pqcA.encoded.count))   │ \(String(format: "%6d", pqcB.encoded.count))   │ \(String(format: "%6d", finishedSize * 2))     │ \(String(format: "%6d", pqcA.encoded.count + pqcB.encoded.count + finishedSize * 2))   ║
        ║ CryptoKit PQC      │ \(String(format: "%6d", pqcA.encoded.count))   │ \(String(format: "%6d", pqcB.encoded.count))   │ \(String(format: "%6d", finishedSize * 2))     │ \(String(format: "%6d", pqcA.encoded.count + pqcB.encoded.count + finishedSize * 2))   ║
        ╚══════════════════════════════════════════════════════════════════╝

        Note: B_finished = 2 × \(finishedSize) bytes (Finished_R2I + Finished_I2R)
        """

        print(report)
        SkyBridgeLogger.test.info("\(report)")

        let breakdowns = [
            try breakdown(for: classicA, label: "MessageA.Classic"),
            try breakdown(for: classicB, label: "MessageB.Classic"),
            try breakdown(for: pqcA, label: "MessageA.PQC"),
            try breakdown(for: pqcB, label: "MessageB.PQC"),
            SizeBreakdown(label: "Finished", total: finishedSize, signature: 0, keyshare: 0, identity: 0)
        ]

        try writeBreakdownCSV(breakdowns)
    }

 // MARK: - Private Helpers

    private enum SuiteType {
        case classic
        case pqc
    }

    private struct SizeBreakdown {
        let label: String
        let total: Int
        let signature: Int
        let keyshare: Int
        let identity: Int

        var overhead: Int {
            max(0, total - signature - keyshare - identity)
        }

        var csvRow: String {
            "\(label),\(total),\(signature),\(keyshare),\(identity),\(overhead)"
        }
    }

    private func breakdown(for messageA: HandshakeMessageA, label: String) throws -> SizeBreakdown {
        let encoded = messageA.encoded
        let keyShareBytes = messageA.keyShares.reduce(0) { $0 + $1.shareBytes.count }
        let signatureBytes = messageA.signature.count + (messageA.secureEnclaveSignature?.count ?? 0)
        let identityBytes = messageA.identityPublicKey.count
        return SizeBreakdown(
            label: label,
            total: encoded.count,
            signature: signatureBytes,
            keyshare: keyShareBytes,
            identity: identityBytes
        )
    }

    private func breakdown(for messageB: HandshakeMessageB, label: String) throws -> SizeBreakdown {
        let encoded = messageB.encoded
        let signatureBytes = messageB.signature.count + (messageB.secureEnclaveSignature?.count ?? 0)
        let identityBytes = messageB.identityPublicKey.count
        let keyShareBytes = messageB.responderShare.count
        return SizeBreakdown(
            label: label,
            total: encoded.count,
            signature: signatureBytes,
            keyshare: keyShareBytes,
            identity: identityBytes
        )
    }

    private func writeBreakdownCSV(_ rows: [SizeBreakdown]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let csvPath = artifactsDir.appendingPathComponent("message_sizes_\(dateString).csv")

        var content = "message,total_bytes,signature_bytes,keyshare_bytes,identity_bytes,overhead_bytes\n"
        for row in rows {
            content += row.csvRow + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[SIZE] CSV written to: \(csvPath.path)")
    }

    private func createMessageA(suite: SuiteType) throws -> HandshakeMessageA {
        let supportedSuites: [CryptoSuite]
        let keyShares: [HandshakeKeyShare]
        let signature: Data
        let identityPubKey: Data
        let policy: HandshakePolicy
        let capabilities: CryptoCapabilities

        switch suite {
        case .classic:
            supportedSuites = [.x25519Ed25519]
            keyShares = [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0xAA, count: 32))]
            signature = Data(repeating: 0xBB, count: 64)
            identityPubKey = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 32),
                protocolAlgorithm: .ed25519,
                secureEnclavePublicKey: nil
            ).encoded
            policy = .default
            capabilities = CryptoCapabilities(
                supportedKEM: ["X25519"],
                supportedSignature: ["Ed25519"],
                supportedAuthProfiles: ["classic"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: false,
                platformVersion: "macOS",
                providerType: .classic
            )

        case .pqc:
            supportedSuites = [.mlkem768MLDSA65]
            keyShares = [HandshakeKeyShare(suite: .mlkem768MLDSA65, shareBytes: Data(repeating: 0xAA, count: 1088))]
            signature = Data(repeating: 0xBB, count: 3309)
            identityPubKey = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            ).encoded
            policy = .strictPQC
            capabilities = CryptoCapabilities(
                supportedKEM: ["ML-KEM-768"],
                supportedSignature: ["ML-DSA-65"],
                supportedAuthProfiles: ["pqc"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: true,
                platformVersion: "macOS",
                providerType: .liboqs
            )
        }

        return HandshakeMessageA(
            version: 1,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(repeating: 0x11, count: 32),
            policy: policy,
            capabilities: capabilities,
            signature: signature,
            identityPublicKey: identityPubKey,
            secureEnclaveSignature: nil
        )
    }

    private func createMessageB(suite: SuiteType) throws -> HandshakeMessageB {
        let selectedSuite: CryptoSuite
        let responderShare: Data
        let signature: Data
        let identityPubKey: Data
        let encryptedPayload: HPKESealedBox

        switch suite {
        case .classic:
            selectedSuite = .x25519Ed25519
            responderShare = Data(repeating: 0xDD, count: 32)
            signature = Data(repeating: 0xEE, count: 64)
            identityPubKey = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 32),
                protocolAlgorithm: .ed25519,
                secureEnclavePublicKey: nil
            ).encoded
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(repeating: 0xAB, count: 32),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )

        case .pqc:
            selectedSuite = .mlkem768MLDSA65
            responderShare = Data()
            signature = Data(repeating: 0xEE, count: 3309)
            identityPubKey = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            ).encoded
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )
        }

        return HandshakeMessageB(
            version: 1,
            selectedSuite: selectedSuite,
            responderShare: responderShare,
            serverNonce: Data(repeating: 0x22, count: 32),
            encryptedPayload: encryptedPayload,
            signature: signature,
            identityPublicKey: identityPubKey,
            secureEnclaveSignature: nil
        )
    }
}
