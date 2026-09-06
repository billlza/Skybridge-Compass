import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PresenceServiceTests: XCTestCase {
    func testRefreshIsSingleFlightWhileRegistrationIsSuspended() async {
        let registrationGate = PresenceSuspensionGate()
        let listState = PresenceListCounter()
        let service = makeService(
            registerPresence: {
                await registrationGate.enter()
            },
            listAccountDevices: {
                listState.count += 1
                return Self.snapshot(online: ["peer"])
            }
        )

        service.start()
        await registrationGate.waitForEntryCount(1)
        for _ in 0..<20 {
            service.triggerRefresh()
        }

        let entryCount = await registrationGate.entryCount
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(listState.count, 0)

        await registrationGate.releaseAll()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(listState.count, 1)
        XCTAssertEqual(service.onlinePeerDeviceIds, ["peer"])
        service.stop()
    }

    func testStoppedGenerationCannotOverwriteRestartedGeneration() async {
        let listProbe = SequencedPresenceList()
        let service = makeService(
            listAccountDevices: {
                await listProbe.execute()
            },
            trustedDeviceIDs: { ["stale-peer", "current-peer"] }
        )

        service.start()
        await listProbe.waitForCallCount(1)
        service.stop()

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["current-peer"])
        XCTAssertEqual(service.accountDevices?.callerDeviceId, "current")

        await listProbe.releaseFirstCall()
        await listProbe.waitForFirstCallReturn()
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(service.onlinePeerDeviceIds, ["current-peer"])
        XCTAssertEqual(service.accountDevices?.callerDeviceId, "current")
        service.stop()
    }

    func testListFailureExpiresOnlineStateAtTTLAndFiltersUntrustedIDs() async throws {
        let listState = PresenceTimedListState()
        let service = makeService(
            onlineStateTTL: 90,
            now: { listState.currentTime },
            listAccountDevices: {
                if listState.shouldFail {
                    throw PresenceTestError.listFailed
                }
                return Self.snapshot(online: ["trusted-peer", "server-injected-untrusted-peer"])
            },
            trustedDeviceIDs: { ["trusted-peer"] }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["trusted-peer"])
        XCTAssertNil(service.lastListFailure)
        let successfulSnapshot = service.accountDevices
        XCTAssertNotNil(successfulSnapshot)

        listState.shouldFail = true
        listState.currentTime = listState.currentTime.addingTimeInterval(89)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["trusted-peer"])
        XCTAssertEqual(service.lastListFailure, .transport)
        XCTAssertEqual(service.accountDevices, successfulSnapshot, "a failed refresh keeps the last good snapshot")

        listState.currentTime = listState.currentTime.addingTimeInterval(1)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertTrue(service.onlinePeerDeviceIds.isEmpty)
        XCTAssertTrue(service.isAccountDevicesSnapshotStale())
        let expired = try XCTUnwrap(service.accountDevices)
        XCTAssertEqual(
            expired.devices.map(\.deviceId),
            successfulSnapshot?.devices.map(\.deviceId),
            "static device data survives expiry so names/addresses stay visible"
        )
        XCTAssertTrue(expired.onlineDeviceIds.isEmpty, "no device may still read as online after the TTL")
        XCTAssertFalse(expired.hasOnlineDevices)
        XCTAssertEqual(expired.callerDeviceId, successfulSnapshot?.callerDeviceId)
        XCTAssertNotEqual(service.accountDevices, successfulSnapshot, "the published snapshot must change so observers re-render")
        service.stop()
    }

    func testClockRollbackFailsClosedInsteadOfExtendingStalePresence() async {
        let listState = PresenceTimedListState()
        let service = makeService(
            now: { listState.currentTime },
            listAccountDevices: {
                if listState.shouldFail {
                    throw PresenceTestError.listFailed
                }
                return Self.snapshot(online: ["peer"])
            }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["peer"])

        listState.shouldFail = true
        listState.currentTime = listState.currentTime.addingTimeInterval(-1)
        service.triggerRefresh()
        await service.waitForCurrentRefresh()

        XCTAssertTrue(service.onlinePeerDeviceIds.isEmpty)
        XCTAssertEqual(service.accountDevices?.hasOnlineDevices, false, "clock rollback must also clear snapshot online flags")
        service.stop()
    }

    func testHeartbeatFailureIsTypedAndDoesNotBlockTheList() async {
        let heartbeatState = PresenceTimedListState()
        let service = makeService(
            registerPresence: {
                if heartbeatState.shouldFail {
                    throw PresenceTestError.listFailed
                }
            },
            listAccountDevices: { Self.snapshot(online: ["peer"]) },
            classifyFailure: { _ in .deviceNotActive(code: "device_revoked") }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertNil(service.lastHeartbeatFailure)

        heartbeatState.shouldFail = true
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.lastHeartbeatFailure, .deviceNotActive(code: "device_revoked"))
        XCTAssertEqual(service.onlinePeerDeviceIds, ["peer"], "the list still refreshes when the heartbeat fails")
        XCTAssertNil(service.lastListFailure)

        heartbeatState.shouldFail = false
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertNil(service.lastHeartbeatFailure)
        service.stop()
    }

    func testTrustRevokedWhileListingIsHonoredBeforePublishing() async {
        let trust = PresenceMutableTrust(ids: ["peer-a", "peer-b"])
        let service = makeService(
            listAccountDevices: {
                trust.ids = ["peer-a"]
                return Self.snapshot(online: ["peer-a", "peer-b"])
            },
            trustedDeviceIDs: { trust.ids }
        )

        service.start()
        await service.waitForCurrentRefresh()
        XCTAssertEqual(service.onlinePeerDeviceIds, ["peer-a"])
        service.stop()
    }

    func testStopClearsSnapshotOnlineStateAndFailures() async {
        let listState = PresenceTimedListState()
        let service = makeService(
            listAccountDevices: {
                if listState.shouldFail {
                    throw PresenceTestError.listFailed
                }
                return Self.snapshot(online: ["peer"])
            }
        )

        service.start()
        await service.waitForCurrentRefresh()
        listState.shouldFail = true
        service.triggerRefresh()
        await service.waitForCurrentRefresh()
        XCTAssertNotNil(service.accountDevices)
        XCTAssertNotNil(service.lastListFailure)

        service.stop()
        XCTAssertNil(service.accountDevices)
        XCTAssertNil(service.lastListFailure)
        XCTAssertNil(service.lastHeartbeatFailure)
        XCTAssertNil(service.lastSuccessfulListAt)
        XCTAssertTrue(service.onlinePeerDeviceIds.isEmpty)
        XCTAssertTrue(service.isAccountDevicesSnapshotStale())
    }

    func testPresenceLifecycleAndTTLSourceContract() throws {
        let engine = try repositorySource("Sources/SkyBridgeProtocolCore/AccountDevices/AccountPresenceRefreshEngine.swift")
        XCTAssertTrue(engine.contains("private var refreshTask: Task<Void, Never>?"))
        XCTAssertTrue(engine.contains("guard isCurrentGeneration(generation), refreshTask == nil"))
        XCTAssertTrue(engine.contains("private var lifecycleGeneration: UInt64"))
        XCTAssertTrue(engine.contains("refreshToken == token"))
        XCTAssertTrue(engine.contains("snapshot.onlineDeviceIds.intersection(trustedDeviceIDs())"))
        XCTAssertTrue(engine.contains("guard age >= 0, age < onlineStateTTL"))
        XCTAssertTrue(engine.contains("next.onlinePeerDeviceIds = []"))
        XCTAssertTrue(
            engine.contains("next.accountDevices = next.accountDevices?.markingAllOffline()"),
            "expiry must fail closed in the published snapshot, not only in the trusted-online set"
        )
        XCTAssertTrue(
            engine.contains("AccountPresenceRefreshPolicy.loopSleepInterval(") &&
                engine.contains("untilOnlineStateExpires: self.timeUntilOnlineStateExpires(at: current)"),
            "the loop must wake for TTL expiry even while refresh is in a long backoff"
        )
        XCTAssertTrue(engine.contains("AccountPresenceRefreshPolicy.retryDelay("))
        XCTAssertFalse(engine.contains("try? await Task.sleep"))
        XCTAssertFalse(engine.contains("while let self"), "never hold the engine strongly across the sleep")

        let service = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/PresenceService.swift")
        XCTAssertTrue(service.contains("AccountPresenceRefreshEngine("), "macOS must wrap the shared engine, not re-implement the loop")
        XCTAssertFalse(service.contains("Task.sleep"), "no second scheduler on macOS")
        XCTAssertTrue(service.contains("LocalDevicePresenceReportBuilder.currentReport()"))
        XCTAssertTrue(service.contains("CrossNetworkConnectionManager.shared.listAccountDevices()"))
        XCTAssertFalse(service.contains("queryDevicePresence"), "the list endpoint replaces the presence/query poll")
        XCTAssertFalse(service.contains("presence/query"))
    }

    // MARK: - Helpers

    static func snapshot(
        online: [String],
        offline: [String] = [],
        caller: String = "current"
    ) -> AccountDeviceListSnapshot {
        func record(_ id: String, online: Bool) -> AccountDeviceRecord {
            AccountDeviceRecord(
                deviceId: id,
                deviceName: id,
                status: "active",
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                platformRawValue: "macos",
                deviceModel: nil,
                osVersion: nil,
                appVersion: nil,
                lanAddresses: [],
                publicAddress: nil,
                capabilities: [],
                registeredAtEpochMilliseconds: nil,
                lastSeenAtEpochMilliseconds: nil,
                presenceUpdatedAtEpochMilliseconds: nil,
                online: online,
                isCaller: id == caller
            )
        }
        return AccountDeviceListSnapshot(
            generatedAtEpochMilliseconds: 1,
            callerDeviceId: caller,
            truncated: false,
            devices: online.map { record($0, online: true) } + offline.map { record($0, online: false) }
        )
    }

    private func makeService(
        onlineStateTTL: TimeInterval = 90,
        now: @escaping PresenceService.NowProvider = { Date(timeIntervalSince1970: 0) },
        registerPresence: @escaping PresenceService.RegistrationOperation = {},
        listAccountDevices: @escaping PresenceService.AccountDeviceListOperation = { PresenceServiceTests.snapshot(online: ["peer"]) },
        trustedDeviceIDs: @escaping PresenceService.TrustedDeviceIDsProvider = { ["peer"] },
        classifyFailure: @escaping PresenceService.FailureClassifier = { _ in .transport }
    ) -> PresenceService {
        PresenceService(
            refreshInterval: .seconds(3_600),
            onlineStateTTL: onlineStateTTL,
            now: now,
            registerPresence: registerPresence,
            listAccountDevices: listAccountDevices,
            trustedDeviceIDs: trustedDeviceIDs,
            classifyFailure: classifyFailure
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private enum PresenceTestError: Error {
    case listFailed
}

@MainActor
private final class PresenceListCounter {
    var count = 0
}

@MainActor
private final class PresenceTimedListState {
    var currentTime = Date(timeIntervalSince1970: 1_000)
    var shouldFail = false
}

@MainActor
private final class PresenceMutableTrust {
    var ids: Set<String>
    init(ids: Set<String>) { self.ids = ids }
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

private actor SequencedPresenceList {
    private var calls = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var firstCallReturned = false

    func execute() async -> AccountDeviceListSnapshot {
        calls += 1
        guard calls == 1 else {
            return await PresenceServiceTests.snapshot(online: ["current-peer"], caller: "current")
        }
        await withCheckedContinuation { continuation in
            firstCallContinuation = continuation
        }
        firstCallReturned = true
        return await PresenceServiceTests.snapshot(online: ["stale-peer"], caller: "stale")
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
