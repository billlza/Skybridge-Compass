import Foundation
import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class PairingKEMProductionPathContractTests: XCTestCase {
    func testEveryProductionPairingHandlerUsesSharedAtomicCommitCoordinator() throws {
        let paths = [
            PairingHandlerPath(
                name: "P2PDiscoveryService inbound control",
                relativePath: "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
                startMarker: "case .pairingIdentityExchange(let payload):",
                endMarker: "case .ping(let payload):"
            ),
            PairingHandlerPath(
                name: "DeviceDiscoveryManager inbound control",
                relativePath: "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
                startMarker: "case .pairingIdentityExchange(let payload):",
                endMarker: "case .ping(let payload):"
            ),
            PairingHandlerPath(
                name: "DeviceDiscoveryManagerOptimized inbound control",
                relativePath: "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift",
                startMarker: "case .pairingIdentityExchange(let payload):",
                endMarker: "case .ping(let payload):"
            ),
            PairingHandlerPath(
                name: "P2PConnection post-auth exchange",
                relativePath: "Sources/SkyBridgeCore/P2P/P2PModels.swift",
                startMarker: "private func handlePairingIdentityExchange(",
                endMarker: "internal static func isBootstrapControlMessage("
            ),
            PairingHandlerPath(
                name: "CrossNetwork authenticated exchange",
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
                startMarker: "case .pairingIdentityExchange(let rawPayload):",
                endMarker: "case .heartbeat(let payload):"
            )
        ]

        for path in paths {
            let source = try repositorySource(path.relativePath)
            let handler = try sourceSlice(
                from: path.startMarker,
                to: path.endMarker,
                in: source,
                pathName: path.name
            )
            let compact = handler.filter { !$0.isWhitespace }

            XCTAssertTrue(
                compact.contains("PairingIdentityExchangeCommitCoordinator.reserve("),
                "\(path.name) must reserve admission through the shared coordinator"
            )
            XCTAssertTrue(
                compact.contains(".commitAuthorityAndKEM("),
                "\(path.name) must commit authority and KEM through one ordered path"
            )
            XCTAssertTrue(
                compact.contains("PairingIdentityExchangeCommitCoordinator.isCurrent("),
                "\(path.name) must revalidate the exact commit before post-commit side effects"
            )
            XCTAssertTrue(
                compact.contains("rollbackPairingCommit("),
                "\(path.name) must roll back its exact pre-commit reservation on failure"
            )
            XCTAssertFalse(
                compact.contains("rollbackPairingCommit(commitReceipt"),
                "\(path.name) must preserve an authority/KEM pair after the final authority commit point"
            )
            XCTAssertFalse(
                compact.contains("PeerKEMBootstrapStore.shared.clear("),
                "\(path.name) must not clear replacement or signed-refresh KEM entries"
            )
            XCTAssertFalse(
                compact.contains("clearPairingIdentityExchangeEntries("),
                "\(path.name) must not clear another pairing generation"
            )
            XCTAssertFalse(
                compact.contains("PeerKEMBootstrapStore.shared.upsert("),
                "\(path.name) must not bypass the shared durable commit coordinator"
            )
            XCTAssertFalse(
                compact.contains("TrustSyncService.shared.recordAuthenticatedRemoteAuthorityForPairing("),
                "\(path.name) must not split authority persistence from KEM persistence"
            )
        }
    }

    func testSharedCoordinatorOwnsGenerationBoundAuthorityAndKEMTransaction() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/PairingIdentityExchangeCommitCoordinator.swift"
        )
        let compact = source.filter { !$0.isWhitespace }

        XCTAssertTrue(compact.contains("reservePairingWriteGeneration(deviceIds:"))
        XCTAssertTrue(compact.contains("recordAuthenticatedRemoteAuthorityForPairing("))
        XCTAssertTrue(compact.contains("pairingWriteGeneration:reservation.generation"))
        XCTAssertTrue(compact.contains("rollbackPairingIdentityExchangeEntries("))
        XCTAssertTrue(compact.contains("matchingWriteGeneration:reservation.generation"))
        XCTAssertTrue(compact.contains("isCurrentPairingWriteReservation("))
        XCTAssertTrue(compact.contains("isCurrentPairingWriteCommit("))
        XCTAssertTrue(compact.contains("matchingProtocolFingerprint:"))
        let stagedKEMCommit = try XCTUnwrap(
            compact.range(of: "letstaged=tryawaitPeerKEMBootstrapStore.shared.upsert(")
        )
        let authorityCommit = try XCTUnwrap(
            compact.range(of: "recordAuthenticatedRemoteAuthorityForPairing(")
        )
        XCTAssertLessThan(
            stagedKEMCommit.lowerBound,
            authorityCommit.lowerBound,
            "The non-authoritative generation-bound KEM must be staged before TrustSync authority becomes durable."
        )
        let authorityCommitTail = String(compact[authorityCommit.lowerBound...])
        let finalCommitStart = try XCTUnwrap(authorityCommitTail.range(of: "guardpersistedelse"))
        let finalCommitTail = String(authorityCommitTail[finalCommitStart.lowerBound...])
        XCTAssertTrue(finalCommitTail.contains("return.committed(CommitReceipt("))
        XCTAssertFalse(finalCommitTail.contains("Task.checkCancellation()"))
        XCTAssertFalse(finalCommitTail.contains("PeerProtocolIdentityBootstrapStore.shared.upsert("))
        XCTAssertFalse(finalCommitTail.contains("isCurrent(receipt"))
        XCTAssertFalse(compact.contains("staticfuncrollback(_receipt:CommitReceipt"))
        XCTAssertFalse(compact.contains("staticfuncrollbackResult(_receipt:CommitReceipt"))
        XCTAssertFalse(compact.contains("PeerKEMBootstrapStore.shared.clear("))
    }

    func testFinalAuthorityCommitHasDeterministicSupersessionRaceCoverage() throws {
        let source = try repositorySource(
            "Tests/SkyBridgeCoreTests/TrustSyncConcurrencyHardeningTests.swift"
        )
        let test = try sourceSlice(
            from: "func testPairingAuthoritySupersededAfterSigningNeverReachesDurableState()",
            to: "private func makeRecord(",
            in: source,
            pathName: "pairing authority post-sign supersession race"
        )

        XCTAssertTrue(test.contains("pairingAuthorityPostSignBarrierForTesting"))
        XCTAssertTrue(test.contains("await blocker.waitUntilEntered()"))
        XCTAssertTrue(test.contains("isCurrent = false"))
        XCTAssertTrue(test.contains("await blocker.release()"))
        XCTAssertTrue(test.contains("case .pairingAuthorityCommitSuperseded"))
        XCTAssertTrue(test.contains("let persistedRecord = await service.rawTrustRecordForTesting"))
        XCTAssertTrue(test.contains("XCTAssertNil(persistedRecord)"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String,
        pathName: String
    ) throws -> String {
        guard let start = source.range(of: startMarker) else {
            XCTFail("Missing pairing handler start marker for \(pathName)")
            throw PairingHandlerContractError.missingMarker
        }
        guard let end = source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex
        ) else {
            XCTFail("Missing pairing handler end marker for \(pathName)")
            throw PairingHandlerContractError.missingMarker
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

}

private struct PairingHandlerPath {
    let name: String
    let relativePath: String
    let startMarker: String
    let endMarker: String
}

private enum PairingHandlerContractError: Error {
    case missingMarker
}
