#if os(macOS)
import XCTest
import Foundation
import Darwin
@testable import SkyBridgeCore

@MainActor
final class SSDPDiscoveryTimeoutTests: XCTestCase {
    func testDefaultFractionalDeadlineReturnsAndClosesSocketWithoutResponse() async throws {
        let peer = try SSDPLoopbackPeer()
        let discovery = SSDPDiscovery(host: "127.0.0.1", port: peer.port)
        let start = DispatchTime.now().uptimeNanoseconds
        let task = Task { try await discovery.searchOnce() }
        let request = try await Task.detached { try peer.receiveRequest() }.value
        let result = try await task.value
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThanOrEqual(elapsed, 0.7)
        XCTAssertLessThan(elapsed, 1.8)
        try SSDPLoopbackPeer.assertReleased(request.sender)
    }

    func testResponseReturnsBeforeDeadlineAndClosesSocket() async throws {
        let peer = try SSDPLoopbackPeer()
        let discovery = SSDPDiscovery(host: "127.0.0.1", port: peer.port)
        let task = Task { try await discovery.searchOnce() }
        let request = try await Task.detached { try peer.receiveRequest() }.value
        XCTAssertTrue(request.payload.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        try peer.reply(to: request.sender)
        let result = try await task.value
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.usn, "uuid:isolated-peer")
        XCTAssertEqual(result.first?.location, "http://127.0.0.1/device.xml")
        try SSDPLoopbackPeer.assertReleased(request.sender)
    }

    func testCancellationClosesOnlyItsSocketAndNextRequestCanFinish() async throws {
        let peer = try SSDPLoopbackPeer()
        let discovery = SSDPDiscovery(host: "127.0.0.1", port: peer.port)
        let cancelled = Task { try await discovery.searchOnce(timeout: 3) }
        let first = try await Task.detached { try peer.receiveRequest() }.value
        let start = DispatchTime.now().uptimeNanoseconds
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled operation returned discovery success")
        } catch is CancellationError {
            XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.5)
        }
        try SSDPLoopbackPeer.assertReleased(first.sender)

        let replacement = Task { try await discovery.searchOnce() }
        let second = try await Task.detached { try peer.receiveRequest() }.value
        cancelled.cancel()
        try peer.reply(to: second.sender)
        let result = try await replacement.value
        XCTAssertEqual(result.first?.usn, "uuid:isolated-peer")
        try SSDPLoopbackPeer.assertReleased(second.sender)
    }

    func testQueueingConsumesTheSameDeadlineWithoutSendingLateProbe() async throws {
        let peer = try SSDPLoopbackPeer()
        let queue = DispatchQueue(label: "isolated.ssdp.held")
        queue.suspend()
        let discovery = SSDPDiscovery(host: "127.0.0.1", port: peer.port, queue: queue)
        let task = Task { try await discovery.searchOnce(timeout: 0.05) }
        try await Task.sleep(for: .milliseconds(150))
        queue.resume()
        let result = try await task.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(try peer.hasRequest(timeoutMilliseconds: 100))
    }

    func testInvalidTimeoutsFailExplicitly() async throws {
        let discovery = SSDPDiscovery(host: "127.0.0.1", port: 1)
        for timeout in [0.0, -0.1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            do {
                _ = try await discovery.searchOnce(timeout: timeout)
                XCTFail("invalid timeout returned success")
            } catch let failure as SSDPDiscovery.Failure {
                XCTAssertEqual(failure, .invalidTimeout)
            }
        }
    }

    func testInvalidDestinationIsAnErrorRatherThanAnEmptyDiscovery() async throws {
        do {
            _ = try await SSDPDiscovery(host: "invalid numeric address", port: 1900).searchOnce()
            XCTFail("invalid destination returned success")
        } catch let failure as SSDPDiscovery.Failure {
            XCTAssertEqual(failure, .invalidDestination)
        }
    }
}

private final class SSDPLoopbackPeer: Sendable {
    struct Request: Sendable {
        let sender: sockaddr_in
        let payload: String
    }
    private let socketFD: Int32
    let port: UInt16
    enum Failure: Error { case posix(Int32), requestMissing }

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.posix(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let code = errno; close(fd); throw Failure.posix(code) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { let code = errno; close(fd); throw Failure.posix(code) }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socketFD) }

    func hasRequest(timeoutMilliseconds: Int32) throws -> Bool {
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMilliseconds)
        guard ready >= 0 else { throw Failure.posix(errno) }
        return ready > 0
    }

    func receiveRequest() throws -> Request {
        guard try hasRequest(timeoutMilliseconds: 1_000) else { throw Failure.requestMissing }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let size = bytes.withUnsafeMutableBytes { buffer in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, buffer.baseAddress, buffer.count, 0, $0, &length)
                }
            }
        }
        guard size >= 0 else { throw Failure.posix(errno) }
        return Request(sender: address, payload: String(decoding: bytes.prefix(size), as: UTF8.self))
    }

    func reply(to destination: sockaddr_in) throws {
        var address = destination
        let reply = Data("HTTP/1.1 200 OK\r\nUSN: uuid:isolated-peer\r\nLOCATION: http://127.0.0.1/device.xml\r\n\r\n".utf8)
        let sent = reply.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == reply.count else { throw Failure.posix(errno) }
    }

    static func assertReleased(_ clientAddress: sockaddr_in) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.posix(errno) }
        defer { close(fd) }
        var address = clientAddress
        let rebound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rebound, 0, "completed SSDP operation retained its UDP port; errno=\(errno)")
    }
}
#endif
