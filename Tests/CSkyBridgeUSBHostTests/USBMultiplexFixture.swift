import Foundation
import SkyBridgeProtocolCore
import os
@testable import SkyBridgeAppleTransport

enum MultiplexFixtureError: Error, Equatable { case check(String), disconnected, nativeTimeout, revoked, closeFailed }
func usbCheck(_ value: Bool, _ message: String) throws {
    if !value { throw MultiplexFixtureError.check(message) }
}
func usbEventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        try usbCheck(ContinuousClock.now < end, "Fixture condition timed out")
        try await Task.sleep(for: .milliseconds(1))
    }
}
func usbExpect(_ expected: any Error, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch {
        if let a = error as? USBHostMultiplexError, let b = expected as? USBHostMultiplexError { try usbCheck(a == b, "Wrong multiplex error: \(a), expected \(b)"); return }
        if let a = error as? USBLogicalStreamError, let b = expected as? USBLogicalStreamError { try usbCheck(a == b, "Wrong protocol error: \(a), expected \(b)"); return }
        if let a = error as? MultiplexFixtureError, let b = expected as? MultiplexFixtureError { try usbCheck(a == b, "Wrong fixture error: \(a), expected \(b)"); return }
        if error is CancellationError && expected is CancellationError { return }
        throw MultiplexFixtureError.check("Wrong failure: \(error), expected \(expected)")
    }
    throw MultiplexFixtureError.check("Unexpected success; expected \(expected)")
}
func usbPattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 17 + $0 / 7) }) }

final class USBFixtureGate: Sendable {
    let entered = OSAllocatedUnfairLock(initialState: false)
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() throws {
        entered.withLock { $0 = true }
        try usbCheck(semaphore.wait(timeout: .now() + .seconds(4)) == .success, "Fixture gate not released")
    }
    func release() { semaphore.signal() }
}

/// Bounded synthetic physical byte pipe, not a USB device. Only acquisition/native I/O is
/// replaced; the real USBHostByteTransport workers and multiplex connection run unchanged.
private final class USBFixturePipe: Sendable {
    private struct State: Sendable { var chunks: [Data] = []; var offset = 0, count = 0; var closed = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readable = DispatchSemaphore(value: 0), writable = DispatchSemaphore(value: 0)
    func receive(limit: Int, timeoutMilliseconds: UInt32) throws -> Data {
        let end = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds))
        while true {
            let bytes = try state.withLock { value -> Data? in
                if value.closed { throw MultiplexFixtureError.disconnected }
                guard let first = value.chunks.first else { return nil }
                let count = min(limit, first.count - value.offset)
                let data = first.subdata(in: value.offset..<(value.offset + count))
                value.offset += count; value.count -= count
                if value.offset == first.count { value.chunks.removeFirst(); value.offset = 0 }
                return data
            }
            if let bytes { writable.signal(); return bytes }
            guard readable.wait(timeout: end) == .success else { throw MultiplexFixtureError.nativeTimeout }
        }
    }
    func send(_ bytes: Data, timeoutMilliseconds: UInt32) throws {
        try usbCheck((1...16_384).contains(bytes.count), "Native transfer escaped 16 KiB bound")
        let end = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds))
        while true {
            let stored = try state.withLock { value in
                if value.closed { throw MultiplexFixtureError.disconnected }
                guard value.count + bytes.count <= 524_288 else { return false }
                value.chunks.append(Data(bytes)); value.count += bytes.count; return true
            }
            if stored { readable.signal(); return }
            guard writable.wait(timeout: end) == .success else { throw MultiplexFixtureError.nativeTimeout }
        }
    }
    func close() { state.withLock { $0.closed = true }; readable.signal(); writable.signal() }
}

final class USBMultiplexNativeFixture: USBHostDriver {
    struct State: Sendable {
        var beforeWrite: (@Sendable (Data) throws -> Void)?
        var afterWrite: (@Sendable (Data) throws -> Void)?
        var openGate: USBFixtureGate?, closeGate: USBFixtureGate?
        var closeFailure = false
        var retired = false, closes = 0
        var headers: [USBLogicalStreamWire.Header] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    private let input: USBFixturePipe, output: USBFixturePipe
    private let readLimit: Int
    private init(input: USBFixturePipe, output: USBFixturePipe, readLimit: Int) {
        self.input = input; self.output = output; self.readLimit = readLimit
    }
    static func pair(readLimit: Int = 4093) -> (USBMultiplexNativeFixture, USBMultiplexNativeFixture) {
        let a = USBFixturePipe(), b = USBFixturePipe()
        return (.init(input: a, output: b, readLimit: readLimit), .init(input: b, output: a, readLimit: readLimit))
    }
    func open(registryID: UInt64) throws -> USBHostDevice {
        let gate = state.withLock { $0.openGate }; try gate?.wait()
        return USBHostDevice(deviceRegistryID: registryID, interfaceRegistryID: registryID + 1,
                             inputPacketSize: 512, outputPacketSize: 512, inputEndpoint: 0x81, outputEndpoint: 2)
    }
    func read(timeoutMilliseconds: UInt32) throws -> Data { try input.receive(limit: readLimit, timeoutMilliseconds: timeoutMilliseconds) }
    func write(_ bytes: Data, timeoutMilliseconds: UInt32) throws {
        try state.withLock { if $0.retired { throw MultiplexFixtureError.disconnected } }
        let callbacks = state.withLock { ($0.beforeWrite, $0.afterWrite) }
        try callbacks.0?(bytes)
        try output.send(bytes, timeoutMilliseconds: timeoutMilliseconds)
        if bytes.count >= 12 {
            let header = try USBLogicalStreamWire.decodeHeader(Data(bytes.prefix(12)))
            state.withLock { $0.headers.append(header) }
        }
        try callbacks.1?(bytes)
    }
    func retire() { state.withLock { $0.retired = true } }
    func interrupt() -> (any Error)? { input.close(); output.close(); return nil }
    func closeAndRelease() -> USBHostCleanup {
        let settings = state.withLock { value in value.closes += 1; return (value.closeGate, value.closeFailure) }
        do { try settings.0?.wait() }
        catch { return USBHostCleanup(referencesReleased: false, failure: error) }
        input.close(); output.close()
        return USBHostCleanup(referencesReleased: true, failure: settings.1 ? MultiplexFixtureError.closeFailed : nil)
    }
    func inject(_ bytes: Data) throws { try output.send(bytes, timeoutMilliseconds: 1000) }
}

final class USBMultiplexFixture: Sendable {
    let a: USBHostMultiplexConnection, b: USBHostMultiplexConnection
    let nativeA: USBMultiplexNativeFixture, nativeB: USBMultiplexNativeFixture
    init(configuration: USBHostMultiplexConnection.Configuration = .init(), readLimit: Int = 4093) throws {
        (nativeA, nativeB) = USBMultiplexNativeFixture.pair(readLimit: readLimit)
        let carrierA = USBHostByteTransport(deviceRegistryID: 11, driver: nativeA, requireAttachmentCurrent: {})
        let carrierB = USBHostByteTransport(deviceRegistryID: 22, driver: nativeB, requireAttachmentCurrent: {})
        a = try USBHostMultiplexConnection(carrier: carrierA, role: .client, configuration: configuration)
        b = try USBHostMultiplexConnection(carrier: carrierB, role: .server, configuration: configuration)
    }
    func start() async throws { try await a.start(); try await b.start() }
    func open(priority: USBLogicalStreamProtocol.Priority = .control) async throws -> (USBHostMultiplexConnection.Stream, USBHostMultiplexConnection.Stream) {
        let opening = Task { try await a.openStream(priority: priority) }
        let peer = try await b.acceptStream(priority: priority)
        return (try await opening.value, peer)
    }
    func sibling() async throws {
        let (left, right) = try await open()
        let writing = Task { try await left.writeFrame(Data([2, 4, 6, 8]), timeout: .seconds(1), requireEffectAuthorization: {}) }
        let data = try await right.readFrame(timeout: .seconds(1))
        try await writing.value; try usbCheck(data == Data([2, 4, 6, 8]), "Sibling stream changed bytes")
        try await left.closeAndAwait(); try await right.closeAndAwait()
    }
    func close() async throws {
        a.close(); b.close()
        try await a.closeAndAwait(); try await b.closeAndAwait()
        for owner in [a, b] {
            let status = owner.shutdownState
            try usbCheck(status.retired && status.nativeWorkersExited && status.referencesReleased &&
                         status.pumpsJoined && status.logicalOwnersReleased, "Physical or logical cleanup unconfirmed")
        }
    }
}
