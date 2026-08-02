import Foundation
import Network
import enum SkyBridgeProtocolCore.STUNMessageCodec
import struct SkyBridgeProtocolCore.STUNMappedAddress
import XCTest

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class STUNClientSecurityTests: XCTestCase {
    func testQueryPipelineBindsTransactionAcceptsOffsetSliceAndCleansUpOnce() async throws {
        let connection = ControllableSTUNConnection()
        let task = Task {
            try await IOSSTUNQueryPipeline.query(
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

        let response = makeXORMappedResponse(
            request: request,
            address: [203, 0, 113, 9],
            port: 51_234,
            asOffsetSlice: true
        )
        XCTAssertNotEqual(response.startIndex, 0)
        connection.completeReceive(data: response, isComplete: true, error: nil)

        let result = try await task.value
        XCTAssertEqual(result, STUNMappedAddress(address: "203.0.113.9", port: 51_234))
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)

        // Late state callbacks must have no observer and cannot resume again.
        connection.emitState(.failed(NWError.posix(.ECONNRESET)))
        connection.emitState(.cancelled)
        XCTAssertEqual(connection.cancelCount, 1)
    }

    func testQueryPipelineRejectsWrongTransactionID() async throws {
        let connection = ControllableSTUNConnection()
        let task = Task {
            try await IOSSTUNQueryPipeline.query(
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

        var wrongTransactionID = Data(request[8..<20])
        wrongTransactionID[0] ^= 0xFF
        connection.completeReceive(
            data: makeXORMappedResponse(
                request: request,
                transactionID: wrongTransactionID,
                address: [198, 51, 100, 7],
                port: 44_444
            ),
            isComplete: true,
            error: nil
        )

        do {
            _ = try await task.value
            XCTFail("Expected transaction mismatch to fail")
        } catch let error as STUNError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
    }

    func testCompletedQueryReleasesConnectionEvenWhenFakeRetainsCallbacks() async throws {
        var connection: ControllableSTUNConnection? = ControllableSTUNConnection()
        weak let weakConnection = connection

        do {
            let activeConnection = try XCTUnwrap(connection)
            let task = Task {
                try await IOSSTUNQueryPipeline.query(
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
                    request: request,
                    address: [192, 0, 2, 77],
                    port: 55_555
                ),
                isComplete: true,
                error: nil
            )
            _ = try await task.value
        }

        connection = nil
        for _ in 0..<100 where weakConnection != nil {
            await Task.yield()
        }
        XCTAssertNil(weakConnection)
    }

    func testTimeoutBeforeReadyCompletesAndCleansUp() async {
        let connection = ControllableSTUNConnection()

        do {
            _ = try await IOSSTUNQueryPipeline.query(
                connection: connection,
                timeout: .milliseconds(20)
            )
            XCTFail("Expected timeout")
        } catch let error as STUNError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(connection.startCount, 1)
        XCTAssertEqual(connection.sendCount, 0)
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)
    }

    func testLateSendCompletionAfterTimeoutCannotStartReceive() async {
        let connection = ControllableSTUNConnection()
        let task = Task {
            try await IOSSTUNQueryPipeline.query(
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
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as STUNError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        connection.completeSend(error: nil)
        await Task.yield()
        XCTAssertEqual(connection.receiveCount, 0)
        XCTAssertEqual(connection.cancelCount, 1)
    }

    func testCallerCancellationBeforeReadyCompletesAndCleansUp() async throws {
        let connection = ControllableSTUNConnection()
        let task = Task {
            try await IOSSTUNQueryPipeline.query(
                connection: connection,
                timeout: .seconds(30)
            )
        }

        let didStart = await waitUntil { connection.startCount == 1 }
        XCTAssertTrue(didStart)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(connection.clearHandlerCount, 1)
        XCTAssertFalse(connection.hasStateHandler)
    }

    func testIncompleteDatagramIsRejected() async throws {
        let connection = ControllableSTUNConnection()
        let task = Task {
            try await IOSSTUNQueryPipeline.query(
                connection: connection,
                timeout: .seconds(1)
            )
        }

        let didStart = await waitUntil { connection.startCount == 1 }
        XCTAssertTrue(didStart)
        connection.emitState(.ready)
        let didSend = await waitUntil { connection.sendCount == 1 }
        XCTAssertTrue(didSend)
        connection.completeSend(error: nil)
        let didReceive = await waitUntil { connection.receiveCount == 1 }
        XCTAssertTrue(didReceive)
        connection.completeReceive(data: Data(repeating: 0, count: 20), isComplete: false, error: nil)

        do {
            _ = try await task.value
            XCTFail("Expected incomplete datagram to fail")
        } catch let error as STUNError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testNATClassificationDoesNotMisreportEqualMappingsAsFullCone() async throws {
        let servers = [
            STUNServer(host: "stun-a.test"),
            STUNServer(host: "stun-b.test")
        ]
        let client = STUNClient(servers: servers, timeout: 1) { _, _ in
            STUNMappedAddress(address: "198.51.100.8", port: 40_000)
        }

        let natType = try await client.detectNATType()
        XCTAssertEqual(natType, .unknown)
    }

    func testNATClassificationReportsOnlyEndpointDependentMappingEvidence() async throws {
        let servers = [
            STUNServer(host: "stun-a.test"),
            STUNServer(host: "stun-b.test")
        ]
        let client = STUNClient(servers: servers, timeout: 1) { server, _ in
            if server.host == "stun-a.test" {
                return STUNMappedAddress(address: "198.51.100.8", port: 40_000)
            }
            return STUNMappedAddress(address: "198.51.100.8", port: 40_001)
        }

        let natType = try await client.detectNATType()
        XCTAssertEqual(natType, .symmetric)
    }

    func testDiscoveryCancellationDoesNotFailOverToAnotherServer() async throws {
        let probe = CancellingServerQueryProbe()
        let client = STUNClient(
            servers: [STUNServer(host: "one.test"), STUNServer(host: "two.test")],
            timeout: 1
        ) { server, _ in
            try await probe.query(server)
        }

        do {
            _ = try await client.discoverPublicAddress()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let queriedHosts = await probe.hosts
        XCTAssertEqual(queriedHosts, ["one.test"])
    }

    func testInvalidTimeoutFailsExplicitlyWithoutStartingQuery() async throws {
        let probe = CancellingServerQueryProbe()
        let client = STUNClient(
            servers: [STUNServer(host: "one.test")],
            timeout: 0
        ) { server, _ in
            try await probe.query(server)
        }

        do {
            _ = try await client.discoverPublicAddress()
            XCTFail("Expected invalid configuration")
        } catch let error as STUNError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        let queriedHosts = await probe.hosts
        XCTAssertEqual(queriedHosts, [])
    }

    func testNATDetectionDoesNotDisguiseInvalidConfigurationAsUnknown() async throws {
        let probe = CancellingServerQueryProbe()
        let client = STUNClient(
            servers: [STUNServer(host: "one.test"), STUNServer(host: "two.test")],
            timeout: .nan
        ) { server, _ in
            try await probe.query(server)
        }

        do {
            _ = try await client.detectNATType()
            XCTFail("Expected invalid configuration")
        } catch let error as STUNError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        let queriedHosts = await probe.hosts
        XCTAssertEqual(queriedHosts, [])
    }

    func testNATDetectionPropagatesProbeFailure() async throws {
        let client = STUNClient(
            servers: [STUNServer(host: "one.test"), STUNServer(host: "two.test")],
            timeout: 1
        ) { _, _ in
            throw STUNError.connectionFailed
        }

        do {
            _ = try await client.detectNATType()
            XCTFail("Expected STUN probe failure")
        } catch let error as STUNError {
            XCTAssertEqual(error, .connectionFailed)
        }
    }

    func testNATTraversalCompatibilityPropagatesConfigurationFailure() async throws {
        let client = STUNClient(
            servers: [STUNServer(host: "one.test"), STUNServer(host: "two.test")],
            timeout: 0
        ) { _, _ in
            XCTFail("Invalid configuration must fail before network I/O")
            return STUNMappedAddress(address: "192.0.2.1", port: 9)
        }
        let helper = NATTraversalHelper(stunClient: client)

        do {
            _ = try await helper.canEstablishDirectConnection(with: .fullCone)
            XCTFail("Expected invalid configuration")
        } catch let error as STUNError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
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

    private func makeXORMappedResponse(
        request: Data,
        transactionID: Data? = nil,
        address: [UInt8],
        port: UInt16,
        asOffsetSlice: Bool = false
    ) -> Data {
        precondition(request.count == 20)
        precondition(address.count == 4)
        let responseTransactionID = transactionID ?? Data(request[8..<20])
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
        response.append(responseTransactionID)
        response.append(body)
        guard asOffsetSlice else { return response }

        var storage = Data(repeating: 0xEE, count: 17)
        storage.append(response)
        return storage.dropFirst(17)
    }
}

@available(iOS 17.0, *)
private final class ControllableSTUNConnection: IOSSTUNDatagramConnection, @unchecked Sendable {
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

@available(iOS 17.0, *)
private actor CancellingServerQueryProbe {
    private(set) var hosts: [String] = []

    func query(_ server: STUNServer) throws -> STUNMappedAddress {
        hosts.append(server.host)
        throw CancellationError()
    }
}
