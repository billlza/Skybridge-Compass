import Foundation
import os
import XCTest
@testable import SkyBridgeCore

@MainActor
final class USBMultiplexTransportTests: XCTestCase {
    private let udid = "00008140-000E788401C0801C"

    private func row(id: UInt32, type: String = "USB") -> [String: Any] {
        ["DeviceID": id, "Properties": ["DeviceID": id, "SerialNumber": udid,
            "ConnectionType": type, "ProductID": UInt32(4776)]]
    }

    func testNetworkTwinIsNeverSelectedAsUSB() throws {
        let result = try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10, type: "Network"), row(id: 11)]
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.deviceID, 11)
        XCTAssertEqual(result.first?.udid, udid)
        XCTAssertEqual(result.first?.connectionType, "USB")
        XCTAssertTrue(try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10, type: "Network")]
        ]).isEmpty)
    }

    func testDuplicateOrMisboundDeviceIsRejected() throws {
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10), row(id: 11)]
        ]))
        var mismatched = row(id: 10)
        mismatched["DeviceID"] = UInt32(11)
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [mismatched]]))
        for invalid: Any in [true, -1, 1.5, UInt64(UInt32.max) + 1] {
            let record: [String: Any] = ["DeviceID": invalid, "Properties": [
                "DeviceID": invalid, "SerialNumber": udid, "ConnectionType": "USB", "ProductID": 4776
            ]]
            XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [record]]))
        }
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["Result": 0]))
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [row(id: 10, type: "Other")]]))
    }

    func testFramingEnforcesVersionTypeTransactionAndBounds() throws {
        let packet = try USBMultiplexTransport.packet(Data([1, 2, 3]), tag: 0x01020304)
        XCTAssertEqual(Array(packet.prefix(16)), [19, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 4, 3, 2, 1])
        XCTAssertEqual(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(16)), tag: 0x01020304), 3)
        XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(16)), tag: 5))
        for offset in [0, 4, 8, 12] {
            var bad = Data(packet.prefix(16)); bad[offset] = 0
            XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: bad, tag: 0x01020304))
        }
        XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(15)), tag: 0x01020304))
        XCTAssertThrowsError(try USBMultiplexTransport.packet(Data(), tag: 1))
        XCTAssertThrowsError(try USBMultiplexTransport.packet(Data(count: USBMultiplexTransport.maximumPacketBytes), tag: 1))
    }

    func testOnlyConnectionRefusalCanBecomeListenerReadinessRetry() throws {
        XCTAssertNoThrow(try USBMultiplexTransport.validateConnectResult(["MessageType": "Result", "Number": 0]))
        for (code, expected): (UInt32, USBMultiplexError) in [
            (1, .unavailable), (2, .deviceUnavailable), (3, .portUnavailable),
            (6, .unavailable), (99, .unavailable)
        ] {
            XCTAssertThrowsError(try USBMultiplexTransport.validateConnectResult(["MessageType": "Result", "Number": code])) {
                XCTAssertEqual($0 as? USBMultiplexError, expected)
            }
        }
        for number: Any in [true, -1, 1.5, "3"] {
            XCTAssertThrowsError(try USBMultiplexTransport.validateConnectResult(["MessageType": "Result", "Number": number])) {
                XCTAssertEqual($0 as? USBMultiplexError, .malformedResponse)
            }
        }
        XCTAssertThrowsError(try USBMultiplexTransport.validateConnectResult(["MessageType": "Attached", "Number": 0]))
    }

    func testReadinessWaitReusesOneDeadlineAndReturnsOnlyTheSuccessfulDial() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let result: Int = try await USBMultiplexTransport.awaitControlPort(deadline: deadline, retryDelay: .zero,
            open: { received in
                XCTAssertEqual(received, deadline)
                let attempt = attempts.withLock { $0 += 1; return $0 }
                if attempt < 3 { throw USBMultiplexError.portUnavailable }
                return 42
            }, close: { _ in XCTFail("Successful ownership was discarded") })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }

    func testReadinessWaitHasAnAttemptLimitEvenBeforeDeadline() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        do {
            let _: Int = try await USBMultiplexTransport.awaitControlPort(
                deadline: .now.advanced(by: .seconds(2)), retryDelay: .zero,
                open: { _ in attempts.withLock { $0 += 1 }; throw USBMultiplexError.portUnavailable },
                close: { _ in XCTFail("No connection was opened") })
            XCTFail("Unready listener was accepted")
        } catch { XCTAssertEqual(error as? USBMultiplexError, .portUnavailable) }
        XCTAssertEqual(attempts.withLock { $0 }, 16)
    }

    func testReadinessNeverRetriesDeviceProtocolTransportOrPermissionFailures() async throws {
        let failures: [any Error] = [USBMultiplexError.deviceUnavailable, USBMultiplexError.ambiguousDevice,
            USBMultiplexError.malformedResponse, USBMultiplexError.unavailable, USBMultiplexError.timedOut,
            USBMultiplexError.peerClosed, CocoaError(.fileReadNoPermission)]
        for failure in failures {
            let attempts = OSAllocatedUnfairLock(initialState: 0)
            do {
                let _: Int = try await USBMultiplexTransport.awaitControlPort(
                    deadline: .now.advanced(by: .seconds(2)), retryDelay: .zero,
                    open: { _ in attempts.withLock { $0 += 1 }; throw failure },
                    close: { _ in XCTFail("No connection was opened") })
                XCTFail("Terminal failure was accepted")
            } catch { XCTAssertEqual(String(reflecting: error), String(reflecting: failure)) }
            XCTAssertEqual(attempts.withLock { $0 }, 1)
        }
    }

    func testCancellationDuringBackoffDoesNotDialAgain() async throws {
        let entered = expectation(description: "first refused dial")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try await USBMultiplexTransport.awaitControlPort(
                deadline: .now.advanced(by: .seconds(2)), retryDelay: .seconds(1),
                open: { _ -> Int in
                    attempts.withLock { $0 += 1 }; entered.fulfill()
                    throw USBMultiplexError.portUnavailable
                }, close: { _ in XCTFail("No connection was opened") })
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled wait succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
    }

    func testCancellationAsDialReturnsClosesTheUnpublishedConnection() async throws {
        let closed = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let task = Task {
            try await USBMultiplexTransport.awaitControlPort(deadline: .now.advanced(by: .seconds(2)),
                open: { _ in withUnsafeCurrentTask { $0?.cancel() }; return 73 },
                close: { value in closed.withLock { $0.append(value) } })
        }
        do { _ = try await task.value; XCTFail("Cancelled dial escaped") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(closed.withLock { $0 }, [73])
    }

    func testLateDialCompletionIsClosedAndCannotExtendReadinessDeadline() async throws {
        let closed = OSAllocatedUnfairLock<[Int]>(initialState: [])
        do {
            let _: Int = try await USBMultiplexTransport.awaitControlPort(deadline: .now.advanced(by: .milliseconds(10)),
                open: { _ in try await Task.sleep(for: .milliseconds(25)); return 91 },
                close: { value in closed.withLock { $0.append(value) } })
            XCTFail("Late connection escaped")
        } catch { XCTAssertEqual(error as? USBMultiplexError, .timedOut) }
        XCTAssertEqual(closed.withLock { $0 }, [91])
    }

    func testExpiredReadinessDeadlineDoesNotEnumerateOrDial() async throws {
        do {
            let _: Int = try await USBMultiplexTransport.awaitControlPort(deadline: .now.advanced(by: .seconds(-1)),
                open: { _ in XCTFail("Expired operation dialed"); return 1 }, close: { _ in XCTFail("No dial owned") })
            XCTFail("Expired operation succeeded")
        } catch { XCTAssertEqual(error as? USBMultiplexError, .timedOut) }
    }
}
