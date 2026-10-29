// Shared loopback substitution for native USB byte-owner interoperability checks.
// No physical USB acquisition, MAIN authentication, account grant or audio hardware.
import Darwin
import Foundation
import os
@testable import SkyBridgeAppleTransport

enum USBLoopbackSocketError: Error { case timedOut, ended }
private struct SocketFailure: Error { let call: String; let code: Int32 }
private struct PeerCleanupFailure: Error { let original: any Error; let cleanup: any Error }
private func checkSocket(_ result: Int32, _ call: String) throws {
    guard result >= 0 else { throw SocketFailure(call: call, code: errno) }
}
private func waitFor(_ fd: Int32, event: Int16, until end: ContinuousClock.Instant) throws {
    while true {
        let left = ContinuousClock.now.duration(to: end)
        guard left > .zero else { throw USBLoopbackSocketError.timedOut }
        let parts = left.components
        let millis = max(1, parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
        var item = pollfd(fd: fd, events: event, revents: 0)
        let result = Darwin.poll(&item, 1, Int32(min(millis, 60_000)))
        if result == 0 { throw USBLoopbackSocketError.timedOut }
        if result < 0 { if errno == EINTR { continue }; throw SocketFailure(call: "poll", code: errno) }
        if item.revents & Int16(POLLNVAL) != 0 { throw SocketFailure(call: "poll descriptor", code: EBADF) }
        // Let recv/send distinguish EOF or an error after HUP/ERR. Readiness is not a receipt.
        if item.revents & (event | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
    }
}

final class USBLoopbackSocketDriver: USBHostDriver {
    private struct State: Sendable { var fd: Int32?; var retired = false }
    private let state: OSAllocatedUnfairLock<State>
    init(fd: Int32) throws {
        let result: Result<Void, any Error> = Result {
            let flags = fcntl(fd, F_GETFL); try checkSocket(flags, "fcntl get")
            try checkSocket(fcntl(fd, F_SETFL, flags | O_NONBLOCK), "fcntl nonblocking")
            var enabled: Int32 = 1
            try checkSocket(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)), "SO_NOSIGPIPE")
        }
        do { try result.get() }
        catch {
            if Darwin.close(fd) != 0 { throw PeerCleanupFailure(original: error, cleanup: SocketFailure(call: "failed socket setup close", code: errno)) }
            throw error
        }
        state = OSAllocatedUnfairLock(initialState: State(fd: fd))
    }
    private func descriptor(admit: Bool = true) throws -> Int32 {
        try state.withLock { value in
            guard let fd = value.fd, !admit || !value.retired else { throw USBLoopbackSocketError.ended }; return fd
        }
    }
    func open(registryID: UInt64) throws -> USBHostDevice {
        _ = try descriptor()
        return USBHostDevice(deviceRegistryID: registryID, interfaceRegistryID: registryID + 1,
                             inputPacketSize: 512, outputPacketSize: 512, inputEndpoint: 0x81, outputEndpoint: 2)
    }
    func read(timeoutMilliseconds: UInt32) throws -> Data {
        let fd = try descriptor(), end = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        var bytes = [UInt8](repeating: 0, count: USBHostByteTransport.transferBytes)
        while true {
            try waitFor(fd, event: Int16(POLLIN), until: end)
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 { throw USBLoopbackSocketError.ended }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw SocketFailure(call: "recv", code: errno)
            }
            return Data(bytes.prefix(count))
        }
    }
    func write(_ bytes: Data, timeoutMilliseconds: UInt32) throws {
        let fd = try descriptor(), end = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        var offset = 0
        while offset < bytes.count {
            _ = try descriptor(); try waitFor(fd, event: Int16(POLLOUT), until: end)
            let count = bytes.withUnsafeBytes { buffer in Darwin.send(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, 0) }
            if count <= 0 {
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                throw SocketFailure(call: "send", code: count == 0 ? EIO : errno)
            }
            offset += count
        }
    }
    func retire() { state.withLock { $0.retired = true } }
    func interrupt() -> (any Error)? {
        do {
            let result = Darwin.shutdown(try descriptor(admit: false), SHUT_RDWR)
            if result == 0 || errno == ENOTCONN { return nil }
            return SocketFailure(call: "shutdown", code: errno)
        } catch { return error }
    }
    func closeAndRelease() -> USBHostCleanup {
        state.withLock { value in
            guard let fd = value.fd else { return USBHostCleanup(referencesReleased: true, failure: USBLoopbackSocketError.ended) }
            if Darwin.close(fd) != 0 {
                return USBHostCleanup(referencesReleased: false, failure: SocketFailure(call: "close", code: errno))
            }
            value.fd = nil; return USBHostCleanup(referencesReleased: true, failure: nil)
        }
    }
}

enum USBLoopbackSocketFixture {
    static func accept(onListening: (UInt16) throws -> Void) throws -> Int32 {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try checkSocket(listener, "socket")
        var accepted: Int32?
        let result: Result<Int32, any Error> = Result {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try checkSocket(bound, "bind loopback"); try checkSocket(Darwin.listen(listener, 1), "listen")
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &size) }
            }
            try checkSocket(named, "getsockname")
            try onListening(UInt16(bigEndian: address.sin_port))
            try waitFor(listener, event: Int16(POLLIN), until: .now.advanced(by: .seconds(10)))
            let fd = Darwin.accept(listener, nil, nil); try checkSocket(fd, "accept"); accepted = fd
            return fd
        }
        if Darwin.close(listener) != 0 {
            let failure = SocketFailure(call: "listener close", code: errno)
            if let accepted, Darwin.close(accepted) != 0 { throw PeerCleanupFailure(original: failure, cleanup: SocketFailure(call: "accepted close", code: errno)) }
            throw failure
        }
        return try result.get()
    }
}
