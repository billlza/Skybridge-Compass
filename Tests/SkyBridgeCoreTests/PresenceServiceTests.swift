import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PresenceServiceTests: XCTestCase {
    func testRefreshIsSingleFlightWhileRegistrationIsSuspended() async {
        let registrationGate = PresenceSuspensionGate()
        let queryState = PresenceQueryCounter()
        let service = makeService(
            registerPresence: {
                await registrationGate.enter()
            },
            queryPresence: { _ in
                queryState.count += 1
                return ["peer"]
            }
        )

        service.start()
        await registrationGate.waitForEntryCount(1)
        for _ in 0..<20 {
            service.triggerRefresh()
        }

        let entryCount = await registrationGate.entryCount
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(queryState.count, 0)

        await registrationGate.releaseAll()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(queryState.count, 1)
        service.stop()
    }

    func testStoppedGenerationCannotOverwriteRestartedGeneration() async {
        let queryProbe = SequencedPresenceQuery()
        let service = makeService(
            queryPresence: { _ in
                await queryProbe.execute()
            },
            trustedDeviceIDs: { ["stale-peer", "current-peer"] }
        )

        service.start()
        await queryProbe.waitForCallCount(1)
        service.stop()

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["current-peer"])

        await queryProbe.releaseFirstCall()
        await queryProbe.waitForFirstCallReturn()
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(service.onlinePeerDeviceIds, ["current-peer"])
        service.stop()
    }

    func testQueryFailureExpiresOnlineStateAtTTLAndFiltersUntrustedIDs() async {
        let queryState = PresenceTimedQueryState()
        let service = makeService(
            onlineStateTTL: 90,
            now: { queryState.currentTime },
            queryPresence: { _ in
                if queryState.shouldFail {
                    throw PresenceTestError.queryFailed
                }
                return ["trusted-peer", "server-injected-untrusted-peer"]
            },
            trustedDeviceIDs: { ["trusted-peer"] }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["trusted-peer"])

        queryState.shouldFail = true
        queryState.currentTime = queryState.currentTime.addingTimeInterval(89)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["trusted-peer"])

        queryState.currentTime = queryState.currentTime.addingTimeInterval(1)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertTrue(service.onlinePeerDeviceIds.isEmpty)
        service.stop()
    }

    func testClockRollbackFailsClosedInsteadOfExtendingStalePresence() async {
        let queryState = PresenceTimedQueryState()
        let service = makeService(
            now: { queryState.currentTime },
            queryPresence: { _ in
                if queryState.shouldFail {
                    throw PresenceTestError.queryFailed
                }
                return ["peer"]
            }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["peer"])

        queryState.shouldFail = true
        queryState.currentTime = queryState.currentTime.addingTimeInterval(-1)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()

        XCTAssertTrue(service.onlinePeerDeviceIds.isEmpty)
        service.stop()
    }

    func testMoreThanTwoHundredTrustedDevicesAreQueriedInStableBoundedBatches() async {
        let trustedIDs = Set((0..<451).map { String(format: "peer-%03d", $0) })
        let batchRecorder = PresenceBatchRecorder()
        let service = makeService(
            queryPresence: { batch in
                batchRecorder.batches.append(batch)
                return batch
            },
            trustedDeviceIDs: { trustedIDs }
        )

        service.start()
        await service.waitForCurrentRefresh()

        XCTAssertEqual(batchRecorder.batches.map(\.count), [200, 200, 51])
        XCTAssertEqual(batchRecorder.batches.flatMap { $0 }, trustedIDs.sorted())
        XCTAssertEqual(service.onlinePeerDeviceIds, trustedIDs)
        service.stop()
    }

    func testBatchFailureDoesNotPublishPartialPresenceResult() async {
        let batchState = PresenceAtomicBatchState()
        let service = makeService(
            queryPresence: { batch in
                batchState.currentRefreshBatchCount += 1
                if batchState.shouldFailSecondBatch,
                   batchState.currentRefreshBatchCount == 2 {
                    throw PresenceTestError.queryFailed
                }
                return batch
            },
            trustedDeviceIDs: { batchState.trustedIDs }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["existing-peer"])

        batchState.trustedIDs = Set((0..<401).map { String(format: "new-peer-%03d", $0) })
        batchState.trustedIDs.insert("existing-peer")
        batchState.shouldFailSecondBatch = true
        batchState.currentRefreshBatchCount = 0
        service.triggerRefresh()
        await service.waitForCurrentRefresh()

        XCTAssertEqual(batchState.currentRefreshBatchCount, 2)
        XCTAssertEqual(service.onlinePeerDeviceIds, ["existing-peer"])
        service.stop()
    }

    func testPresenceLifecycleAndTTLSourceContract() throws {
        let source = try presenceServiceSource()

        XCTAssertTrue(source.contains("private var refreshTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("guard isCurrentGeneration(generation), refreshTask == nil"))
        XCTAssertTrue(source.contains("private var lifecycleGeneration: UInt64"))
        XCTAssertTrue(source.contains("refreshToken == token"))
        XCTAssertTrue(source.contains("private static let maximumQueryBatchSize = 200"))
        XCTAssertTrue(source.contains("queriedOnlineIds.formUnion(onlineBatch)"))
        XCTAssertTrue(source.contains(".intersection(currentTrustedIds)"))
        XCTAssertTrue(source.contains("guard age >= 0, age < onlineStateTTL"))
        XCTAssertTrue(source.contains("onlinePeerDeviceIds = []"))
        XCTAssertFalse(source.contains("try? await Task.sleep"))
    }

    private func makeService(
        onlineStateTTL: TimeInterval = 90,
        now: @escaping PresenceService.NowProvider = { Date(timeIntervalSince1970: 0) },
        registerPresence: @escaping PresenceService.RegistrationOperation = {},
        queryPresence: @escaping PresenceService.QueryOperation = { _ in ["peer"] },
        trustedDeviceIDs: @escaping PresenceService.TrustedDeviceIDsProvider = { ["peer"] }
    ) -> PresenceService {
        PresenceService(
            refreshInterval: .seconds(3_600),
            onlineStateTTL: onlineStateTTL,
            now: now,
            registerPresence: registerPresence,
            queryPresence: queryPresence,
            trustedDeviceIDs: trustedDeviceIDs
        )
    }

    private func presenceServiceSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/PresenceService.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private enum PresenceTestError: Error {
    case queryFailed
}

@MainActor
private final class PresenceQueryCounter {
    var count = 0
}

@MainActor
private final class PresenceTimedQueryState {
    var currentTime = Date(timeIntervalSince1970: 1_000)
    var shouldFail = false
}

@MainActor
private final class PresenceBatchRecorder {
    var batches: [[String]] = []
}

@MainActor
private final class PresenceAtomicBatchState {
    var trustedIDs: Set<String> = ["existing-peer"]
    var shouldFailSecondBatch = false
    var currentRefreshBatchCount = 0
}

private actor PresenceSuspensionGate {
    private var entries = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var entryCount: Int { entries }

    func enter() async {
        entries += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForEntryCount(_ expectedCount: Int) async {
        while entries < expectedCount {
            await Task.yield()
        }
    }

    func releaseAll() {
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

private actor SequencedPresenceQuery {
    private var calls = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var firstCallReturned = false

    func execute() async -> [String] {
        calls += 1
        guard calls == 1 else { return ["current-peer"] }
        await withCheckedContinuation { continuation in
            firstCallContinuation = continuation
        }
        firstCallReturned = true
        return ["stale-peer"]
    }

    func waitForCallCount(_ expectedCount: Int) async {
        while calls < expectedCount {
            await Task.yield()
        }
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func waitForFirstCallReturn() async {
        while !firstCallReturned {
            await Task.yield()
        }
    }
}
