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
            ),
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
                "\(path.name) must reserve through the shared transaction boundary"
            )
            XCTAssertTrue(
                compact.contains(".commitAuthorityAndKEM("),
                "\(path.name) must commit authority and KEM through one ordered path"
            )
            XCTAssertTrue(
                compact.contains("PairingIdentityExchangeCommitCoordinator.isCurrent("),
                "\(path.name) must revalidate the exact committed generation before later side effects"
            )
            XCTAssertTrue(
                compact.contains(".withCommittedReceipt(")
                    || compact.contains(".withMainActorCommittedReceipt("),
                "\(path.name) must retire its committed reservation after every side-effect exit"
            )
            XCTAssertTrue(
                compact.contains(".rollback(") || compact.contains("rollbackPairingCommit("),
                "\(path.name) must retire its exact pre-commit reservation"
            )
            XCTAssertFalse(
                compact.contains("PeerKEMBootstrapStore.shared.clear("),
                "\(path.name) must not clear a replacement or signed-refresh KEM"
            )
            XCTAssertFalse(compact.contains("clearPairingIdentityExchangeEntries("))
            XCTAssertFalse(
                compact.contains("PeerKEMBootstrapStore.shared.upsert("),
                "\(path.name) must not bypass the shared commit coordinator"
            )
            XCTAssertFalse(
                compact.contains("TrustSyncService.shared.recordAuthenticatedRemoteAuthorityForPairing("),
                "\(path.name) must not split authority persistence from KEM persistence"
            )
        }
    }

    func testSharedCoordinatorOwnsExactReservationKEMAndFinalAuthorityCommit() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/PairingIdentityExchangeCommitCoordinator.swift"
        )
        let compact = source.filter { !$0.isWhitespace }

        XCTAssertTrue(compact.contains("privatestaticletregistry=ReservationRegistry()"))
        XCTAssertTrue(compact.contains("currentEpochByDeviceId"))
        XCTAssertTrue(compact.contains("upsertAuthorityBoundPairingKEM("))
        XCTAssertTrue(compact.contains("rollbackAuthorityBoundPairingKEMMutation(kemReceipt)"))
        XCTAssertTrue(compact.contains("recordAuthenticatedRemoteAuthorityForPairing("))
        XCTAssertTrue(compact.contains("isCurrent:reservationIsCurrent"))
        XCTAssertTrue(compact.contains("isCurrentAuthorityBoundPairingKEMMutation("))
        XCTAssertTrue(compact.contains("AuthenticatedProtocolIdentityBinding.matchingPublicKey("))

        let stagedKEM = try XCTUnwrap(
            compact.range(of: "upsertAuthorityBoundPairingKEM(")
        )
        let authorityCommit = try XCTUnwrap(
            compact.range(of: "recordAuthenticatedRemoteAuthorityForPairing(")
        )
        XCTAssertLessThan(stagedKEM.lowerBound, authorityCommit.lowerBound)

        let durableCommitGuard = try XCTUnwrap(
            compact.range(of: "guardpersistedelse")
        )
        let committedReturn = try XCTUnwrap(
            compact.range(
                of: "return.committed(CommitReceipt(",
                range: durableCommitGuard.upperBound..<compact.endIndex
            )
        )
        let afterDurableCommit = compact[
            durableCommitGuard.upperBound..<committedReturn.lowerBound
        ]
        XCTAssertFalse(afterDurableCommit.contains("Task.checkCancellation()"))
        XCTAssertFalse(afterDurableCommit.contains("reservationIsCurrent()"))
        XCTAssertFalse(afterDurableCommit.contains("rollbackAuthorityBoundPairingKEMMutation"))
    }

    func testCoordinatorHasDeterministicConcurrencyCancellationAndABACoverage() throws {
        let source = try repositorySource(
            "Tests/SkyBridgeCoreTests/PairingIdentityExchangeCommitCoordinatorTests.swift"
        )
        for testName in [
            "testNewReservationSupersedesSuspendedCommitWithoutOldRollbackDeletingSuccessor",
            "testCancellationAfterKEMStagingRollsBackBeforeAuthorityCommit",
            "testFailedSuccessorReservationDoesNotReviveOldCommittedGeneration",
            "testPartiallyOverlappingSuccessorPreservesReplacementAndReleasesOldDisjointAlias",
            "testCommittedScopeAlwaysFinishesWithoutRollingBackDurableAuthorityOrKEM",
            "testReservationLimitsAreAtomicAndOverlappingSuccessorDoesNotConsumeCapacity",
            "testAlreadyCancelledCommittedScopeSkipsEffectsAndFinishesLease",
        ] {
            XCTAssertTrue(source.contains("func \(testName)"))
        }
        XCTAssertTrue(source.contains("mutationPostSignBarrierForTesting"))
        XCTAssertTrue(source.contains("await blocker.waitUntilEntered()"))
        XCTAssertTrue(source.contains("task.cancel()"))
        XCTAssertTrue(source.contains("XCTAssertTrue(storedKEM.isEmpty)"))
        XCTAssertTrue(source.contains("oldIsCurrentAfterSuccessorRollback"))
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
