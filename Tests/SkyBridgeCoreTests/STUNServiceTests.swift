import Foundation
import Network
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

final class STUNServiceTests: XCTestCase {
    func testBindingResponseRequiresMatchingTransactionCookieAndLength() throws {
        let transactionID = Data(0..<12)
        let valid = makeXORMappedResponse(
            transactionID: transactionID,
            address: [203, 0, 113, 7],
            port: 54_321
        )

        let parsed = try STUNMessageCodec.parseBindingResponse(
            valid,
            expectedTransactionID: transactionID
        )
        XCTAssertEqual(parsed.address, "203.0.113.7")
        XCTAssertEqual(parsed.port, 54_321)

        var wrongTransactionID = transactionID
        wrongTransactionID[0] ^= 0xFF
        XCTAssertThrowsError(
            try STUNMessageCodec.parseBindingResponse(
                valid,
                expectedTransactionID: wrongTransactionID
            )
        ) { XCTAssertEqual($0 as? STUNMessageCodecError, .transactionIDMismatch) }

        var wrongCookie = valid
        wrongCookie[4] ^= 0x01
        XCTAssertThrowsError(
            try STUNMessageCodec.parseBindingResponse(
                wrongCookie,
                expectedTransactionID: transactionID
            )
        ) { XCTAssertEqual($0 as? STUNMessageCodecError, .invalidMagicCookie) }

        var wrongDeclaredLength = valid
        wrongDeclaredLength[3] = 0x04
        XCTAssertThrowsError(
            try STUNMessageCodec.parseBindingResponse(
                wrongDeclaredLength,
                expectedTransactionID: transactionID
            )
        ) { error in
            guard case STUNMessageCodecError.invalidDeclaredLength = error else {
                XCTFail("Expected invalidDeclaredLength, got \(error)")
                return
            }
        }
    }

    func testBindingResponseRejectsAttributeThatCrossesDeclaredBoundary() {
        let transactionID = Data(repeating: 0xA5, count: 12)
        var response = Data([0x01, 0x01, 0x00, 0x08])
        response.append(STUNMessageCodec.magicCookie)
        response.append(transactionID)
        response.append(contentsOf: [
            0x00, 0x20, 0x00, 0x0C,
            0x00, 0x01, 0x00, 0x00
        ])

        XCTAssertThrowsError(
            try STUNMessageCodec.parseBindingResponse(
                response,
                expectedTransactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(
                error as? STUNMessageCodecError,
                .truncatedAttributeValue(type: 0x0020)
            )
        }
    }

    func testBindingResponseAcceptsNonZeroStartIndexSlice() throws {
        let transactionID = Data(repeating: 0x5A, count: 12)
        let response = makeXORMappedResponse(
            transactionID: transactionID,
            address: [198, 51, 100, 42],
            port: 49_152
        )
        var storage = Data(repeating: 0xEE, count: 17)
        storage.append(response)
        let slice = storage.dropFirst(17)
        XCTAssertNotEqual(slice.startIndex, 0)

        let parsed = try STUNMessageCodec.parseBindingResponse(
            slice,
            expectedTransactionID: transactionID
        )
        XCTAssertEqual(parsed.address, "198.51.100.42")
        XCTAssertEqual(parsed.port, 49_152)
    }

    func testBindingRequestRejectsInvalidTransactionIDLengthWithoutTrap() {
        XCTAssertThrowsError(
            try STUNMessageCodec.makeBindingRequest(transactionID: Data(repeating: 0, count: 11))
        ) { error in
            XCTAssertEqual(
                error as? STUNMessageCodecError,
                .invalidTransactionIDLength(actual: 11)
            )
        }
    }

    func testBindingResponseWithoutMappedAddressFailsExplicitly() {
        let transactionID = Data(repeating: 0xA7, count: 12)
        var response = Data([0x01, 0x01, 0x00, 0x00])
        response.append(STUNMessageCodec.magicCookie)
        response.append(transactionID)

        XCTAssertThrowsError(
            try STUNMessageCodec.parseBindingResponse(
                response,
                expectedTransactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? STUNMessageCodecError, .missingMappedAddress)
        }
    }

    func testSendFailureCompletesWithoutWaitingForTimeoutOrReceiving() async {
        let connection = FailingSendSTUNConnection()
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await STUNService.querySTUNServer(
                connection: connection,
                timeout: .seconds(5)
            )
            XCTFail("Expected send failure")
        } catch let error as STUNServiceError {
            XCTAssertEqual(error, .connectionFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(connection.receiveCount, 0)
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)
    }

    func testTimeoutWhileSendIsPendingPreventsLateReceiveAndCleansUp() async {
        let connection = ControllableMacSTUNConnection()
        let query = Task {
            try await STUNService.querySTUNServer(
                connection: connection,
                timeout: .milliseconds(20)
            )
        }

        let didStart = await waitUntil { connection.startCount == 1 }
        XCTAssertTrue(didStart)
        connection.emitState(.ready)
        let didSend = await waitUntil { connection.sendCount == 1 }
        XCTAssertTrue(didSend)

        do {
            _ = try await query.value
            XCTFail("Expected timeout")
        } catch let error as STUNServiceError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)

        connection.completeSend(error: nil)
        await Task.yield()
        XCTAssertEqual(connection.receiveCount, 0)
        connection.emitState(.failed(NWError.posix(.ECONNRESET)))
        connection.emitState(.cancelled)
        XCTAssertEqual(connection.cancelCount, 1)
    }

    func testCallerCancellationBeforeReadyCleansUpExactlyOnce() async {
        let connection = ControllableMacSTUNConnection()
        let query = Task {
            try await STUNService.querySTUNServer(
                connection: connection,
                timeout: .seconds(30)
            )
        }

        let didStart = await waitUntil { connection.startCount == 1 }
        XCTAssertTrue(didStart)
        query.cancel()

        do {
            _ = try await query.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)
    }

    func testSuccessfulQueryBindsTransactionAndReleasesCallbacks() async throws {
        let connection = ControllableMacSTUNConnection()
        let query = Task {
            try await STUNService.querySTUNServer(
                connection: connection,
                timeout: .seconds(1)
            )
        }

        let didStart = await waitUntil { connection.startCount == 1 }
        XCTAssertTrue(didStart)
        connection.emitState(.ready)
        let didSend = await waitUntil { connection.sendCount == 1 }
        XCTAssertTrue(didSend)
        let request = try XCTUnwrap(connection.lastSentPayload)
        connection.completeSend(error: nil)
        let didReceive = await waitUntil { connection.receiveCount == 1 }
        XCTAssertTrue(didReceive)

        connection.completeReceive(
            data: makeXORMappedResponse(
                transactionID: Data(request[8..<20]),
                address: [203, 0, 113, 11],
                port: 50_001
            ),
            isComplete: true,
            error: nil
        )

        let result = try await query.value
        XCTAssertEqual(result.address, "203.0.113.11")
        XCTAssertEqual(result.port, 50_001)
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)
    }

    func testNonPositiveTimeoutFailsWithoutStartingConnection() async {
        let connection = ControllableMacSTUNConnection()
        do {
            _ = try await STUNService.querySTUNServer(
                connection: connection,
                timeout: .zero
            )
            XCTFail("Expected invalid timeout")
        } catch let error as STUNServiceError {
            XCTAssertEqual(error, .invalidTimeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(connection.startCount, 0)
        XCTAssertEqual(connection.cancelCount, 0)
        XCTAssertEqual(connection.clearHandlerCount, 0)
    }

    func testConcurrentCacheMissesShareOneLookupAndReuseCache() async throws {
        let probe = DelayedSTUNQueryProbe(
            delay: .milliseconds(120),
            result: (address: "198.51.100.9", port: 44_444)
        )
        let service = STUNService(
            servers: [(host: "stun.test", port: 3478)],
            queryServer: { _, _ in try await probe.query() }
        )

        async let first = service.getPublicAddress()
        async let second = service.getPublicAddress()
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult.address, "198.51.100.9")
        XCTAssertEqual(secondResult.port, 44_444)
        let callsAfterConcurrentLookup = await probe.callCount
        XCTAssertEqual(callsAfterConcurrentLookup, 1)

        let cached = try await service.getPublicAddress()
        XCTAssertEqual(cached.address, "198.51.100.9")
        let callsAfterCacheHit = await probe.callCount
        XCTAssertEqual(callsAfterCacheHit, 1)
    }

    func testCancellingOnlyWaiterCancelsUnderlyingLookupAndPropagatesCancellation() async throws {
        let probe = DelayedSTUNQueryProbe(
            delay: .seconds(30),
            result: (address: "198.51.100.10", port: 34_789)
        )
        let service = STUNService(
            servers: [(host: "stun.test", port: 3478)],
            queryServer: { _, _ in try await probe.query() }
        )
        let lookup = Task { try await service.getPublicAddress() }

        for _ in 0..<100 {
            if await probe.callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let callsBeforeCancellation = await probe.callCount
        XCTAssertEqual(callsBeforeCancellation, 1)

        lookup.cancel()
        do {
            _ = try await lookup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        for _ in 0..<100 {
            if await probe.cancellationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancellations = await probe.cancellationCount
        XCTAssertEqual(cancellations, 1)
    }

    func testCompletedQueryReleasesConnectionEvenWhenFakeRetainsCallbacks() async throws {
        var connection: ControllableMacSTUNConnection? = ControllableMacSTUNConnection()
        weak let weakConnection = connection

        do {
            let activeConnection = try XCTUnwrap(connection)
            let query = Task {
                try await STUNService.querySTUNServer(
                    connection: activeConnection,
                    timeout: .seconds(1)
                )
            }
            let didStart = await waitUntil { activeConnection.startCount == 1 }
            XCTAssertTrue(didStart)
            activeConnection.emitState(.ready)
            let didSend = await waitUntil { activeConnection.sendCount == 1 }
            XCTAssertTrue(didSend)
            let request = try XCTUnwrap(activeConnection.lastSentPayload)
            activeConnection.completeSend(error: nil)
            let didReceive = await waitUntil { activeConnection.receiveCount == 1 }
            XCTAssertTrue(didReceive)
            activeConnection.completeReceive(
                data: makeXORMappedResponse(
                    transactionID: Data(request[8..<20]),
                    address: [192, 0, 2, 88],
                    port: 55_556
                ),
                isComplete: true,
                error: nil
            )
            _ = try await query.value
        }

        connection = nil
        for _ in 0..<100 where weakConnection != nil {
            await Task.yield()
        }
        XCTAssertNil(weakConnection)
    }

    func testExpectedServerFailuresFailOverThenThrowTypedAggregate() async {
        let probe = FailingSTUNQueryProbe()
        let service = STUNService(
            servers: [
                (host: "one.test", port: 3478),
                (host: "two.test", port: 3478)
            ],
            queryServer: { host, _ in try await probe.query(host: host) }
        )

        do {
            _ = try await service.getPublicAddress()
            XCTFail("Expected all STUN servers to fail")
        } catch let error as STUNServiceError {
            XCTAssertEqual(error, .allServersFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let queriedHosts = await probe.hosts
        XCTAssertEqual(queriedHosts, ["one.test", "two.test"])
    }

    private func makeXORMappedResponse(
        transactionID: Data,
        address: [UInt8],
        port: UInt16
    ) -> Data {
        precondition(transactionID.count == 12)
        precondition(address.count == 4)
        let xorPort = port ^ 0x2112
        let cookie = Array(STUNMessageCodec.magicCookie)
        let xorAddress = zip(address, cookie).map { $0 ^ $1 }
        var body = Data([
            0x00, 0x20, 0x00, 0x08,
            0x00, 0x01,
            UInt8(xorPort >> 8), UInt8(xorPort & 0xFF)
        ])
        body.append(contentsOf: xorAddress)

        var response = Data([
            0x01, 0x01,
            UInt8(body.count >> 8), UInt8(body.count & 0xFF)
        ])
        response.append(STUNMessageCodec.magicCookie)
        response.append(transactionID)
        response.append(body)
        return response
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if predicate() { return true }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch is CancellationError {
                return false
            } catch {
                XCTFail("Unexpected wait failure: \(error)")
                return false
            }
        }
        return predicate()
    }
}

private final class FailingSendSTUNConnection: STUNDatagramConnection, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (NWConnection.State) -> Void)?
        var receiveCount = 0
        var cancelCount = 0
        var clearHandlerCount = 0
    }

    private struct SendFailure: Error {}
    private let state = NSLock()
    private var storedState = State()

    var receiveCount: Int {
        state.withLock { storedState.receiveCount }
    }

    var cancelCount: Int {
        state.withLock { storedState.cancelCount }
    }

    var clearHandlerCount: Int {
        state.withLock { storedState.clearHandlerCount }
    }

    var hasStateHandler: Bool {
        state.withLock { storedState.handler != nil }
    }

    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    ) {
        state.withLock { storedState.handler = handler }
    }

    func clearStateUpdateHandler() {
        state.withLock {
            storedState.handler = nil
            storedState.clearHandlerCount += 1
        }
    }

    func start() {
        let handler = state.withLock { storedState.handler }
        handler?(.ready)
    }

    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        completion(SendFailure())
    }

    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    ) {
        state.withLock { storedState.receiveCount += 1 }
    }

    func cancel() {
        let handler: (@Sendable (NWConnection.State) -> Void)? = state.withLock {
            storedState.cancelCount += 1
            return storedState.handler
        }
        handler?(NWConnection.State.cancelled)
    }
}

private final class ControllableMacSTUNConnection: STUNDatagramConnection, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (NWConnection.State) -> Void)?
        var sendCompletion: (@Sendable (Error?) -> Void)?
        var receiveCompletion: (@Sendable (Data?, Bool, Error?) -> Void)?
        var startCount = 0
        var sendCount = 0
        var receiveCount = 0
        var cancelCount = 0
        var clearHandlerCount = 0
        var lastSentPayload: Data?
    }

    private let lock = NSLock()
    private var state = State()

    var startCount: Int { withState { $0.startCount } }
    var sendCount: Int { withState { $0.sendCount } }
    var receiveCount: Int { withState { $0.receiveCount } }
    var cancelCount: Int { withState { $0.cancelCount } }
    var clearHandlerCount: Int { withState { $0.clearHandlerCount } }
    var lastSentPayload: Data? { withState { $0.lastSentPayload } }
    var hasStateHandler: Bool { withState { $0.handler != nil } }

    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    ) {
        mutateState { $0.handler = handler }
    }

    func clearStateUpdateHandler() {
        mutateState {
            $0.handler = nil
            $0.clearHandlerCount += 1
        }
    }

    func start() {
        mutateState { $0.startCount += 1 }
    }

    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        mutateState {
            $0.sendCount += 1
            $0.lastSentPayload = Data(data)
            $0.sendCompletion = completion
        }
    }

    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    ) {
        mutateState {
            $0.receiveCount += 1
            $0.receiveCompletion = completion
        }
    }

    func cancel() {
        mutateState { $0.cancelCount += 1 }
    }

    func emitState(_ connectionState: NWConnection.State) {
        withState { $0.handler }?(connectionState)
    }

    func completeSend(error: Error?) {
        withState { $0.sendCompletion }?(error)
    }

    func completeReceive(data: Data?, isComplete: Bool, error: Error?) {
        withState { $0.receiveCompletion }?(data, isComplete, error)
    }

    private func withState<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func mutateState(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }
}

private actor DelayedSTUNQueryProbe {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private let delay: Duration
    private let result: STUNService.PublicAddress

    init(delay: Duration, result: STUNService.PublicAddress) {
        self.delay = delay
        self.result = result
    }

    func query() async throws -> STUNService.PublicAddress {
        callCount += 1
        do {
            try await Task.sleep(for: delay)
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        } catch {
            throw error
        }
        return result
    }
}

private actor FailingSTUNQueryProbe {
    private(set) var hosts: [String] = []

    func query(host: String) throws -> STUNService.PublicAddress {
        hosts.append(host)
        throw STUNServiceError.connectionFailed
    }
}
