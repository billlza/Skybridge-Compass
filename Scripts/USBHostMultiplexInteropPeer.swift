// Local fixture for Kotlin interoperability with the actual byte owner and multiplex pumps.
// Only native acquisition/I/O is substituted with a bounded loopback socket. No USB/auth/audio claim.
import CryptoKit
import Darwin
import Foundation
import SkyBridgeProtocolCore
import os
@testable import SkyBridgeAppleTransport

private enum NativePeerError: Error { case arguments, timedOut, ended, invalidData, unexpectedFIN, cleanupUnconfirmed }
private struct SocketFailure: Error { let call: String; let code: Int32 }
private struct PeerCleanupFailure: Error { let original: any Error; let cleanup: any Error }
private func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}
private func checkSocket(_ result: Int32, _ call: String) throws {
    guard result >= 0 else { throw SocketFailure(call: call, code: errno) }
}
private func waitFor(_ fd: Int32, event: Int16, until end: ContinuousClock.Instant) throws {
    while true {
        let left = ContinuousClock.now.duration(to: end)
        guard left > .zero else { throw NativePeerError.timedOut }
        let parts = left.components
        let millis = max(1, parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
        var item = pollfd(fd: fd, events: event, revents: 0)
        let result = Darwin.poll(&item, 1, Int32(min(millis, 60_000)))
        if result == 0 { throw NativePeerError.timedOut }
        if result < 0 { if errno == EINTR { continue }; throw SocketFailure(call: "poll", code: errno) }
        if item.revents & Int16(POLLNVAL) != 0 { throw SocketFailure(call: "poll descriptor", code: EBADF) }
        // Let recv/send distinguish EOF or an error after HUP/ERR. Readiness is not a receipt.
        if item.revents & (event | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
    }
}

private final class SocketDriver: USBHostDriver {
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
            guard let fd = value.fd, !admit || !value.retired else { throw NativePeerError.ended }; return fd
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
            if count == 0 { throw NativePeerError.ended }
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
            guard let fd = value.fd else { return USBHostCleanup(referencesReleased: true, failure: NativePeerError.ended) }
            if Darwin.close(fd) != 0 {
                return USBHostCleanup(referencesReleased: false, failure: SocketFailure(call: "close", code: errno))
            }
            value.fd = nil; return USBHostCleanup(referencesReleased: true, failure: nil)
        }
    }
}

@main private enum USBNativeInteropMain {
    static let implementation = "skybridge-swift-usb-owner"
    static let command = Data("skybridge-usb-control-1".utf8)
    static func payload(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 + 17) }) }
    static func acceptLoopback() throws -> Int32 {
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
            try emit(["event": "listening", "port": UInt16(bigEndian: address.sin_port), "implementation": implementation])
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
    static func read(_ stream: USBHostMultiplexConnection.Stream, expected: Data) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5)); var offset = 0
        while offset < expected.count {
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero else { throw NativePeerError.timedOut }
            switch try await stream.readBytes(maximumBytes: min(8191, expected.count - offset), timeout: remaining) {
            case .end: throw NativePeerError.unexpectedFIN
            case .bytes(let bytes):
                guard bytes.count <= expected.count - offset,
                      bytes == expected.subdata(in: offset..<(offset + bytes.count)) else { throw NativePeerError.invalidData }
                offset += bytes.count
            }
        }
    }
    static func fin(_ stream: USBHostMultiplexConnection.Stream) async throws {
        switch try await stream.readBytes(maximumBytes: 1, timeout: .seconds(5)) {
        case .end: return
        case .bytes: throw NativePeerError.invalidData
        }
    }
    static func send(_ stream: USBHostMultiplexConnection.Stream, _ bytes: Data) async throws {
        try await stream.writeBytes(bytes, timeout: .seconds(5), requireEffectAuthorization: {})
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2, ["flow", "reverse", "reset"].contains(CommandLine.arguments[1]) else { throw NativePeerError.arguments }
        let mode = CommandLine.arguments[1]
        let driver = try SocketDriver(fd: acceptLoopback())
        let carrier = USBHostByteTransport(deviceRegistryID: 1, driver: driver, requireAttachmentCurrent: {})
        let owner = try USBHostMultiplexConnection(carrier: carrier, role: mode == "flow" ? .server : .client)
        do {
            try await owner.start()
            let bytes: Data
            var resetStage: String?
            if mode == "flow" {
                let file = try await owner.acceptStream(priority: .bulk), control = try await owner.acceptStream()
                defer { withExtendedLifetime((file, control)) {} }
                try await read(control, expected: command); try await send(control, command)
                try await control.finishSending(); try await fin(control); try await control.closeAndAwait()
                bytes = payload(262_145)
                try await read(file, expected: bytes); try await send(file, bytes)
                try await file.finishSending(); try await fin(file); try await file.closeAndAwait()
            } else if mode == "reverse" {
                let file = try await owner.openStream(priority: .bulk), control = try await owner.openStream()
                defer { withExtendedLifetime((file, control)) {} }
                bytes = payload(65_579)
                try await send(file, bytes); try await send(control, command)
                try await control.finishSending(); try await read(control, expected: command); try await fin(control)
                try await control.closeAndAwait()
                try await file.finishSending(); try await read(file, expected: bytes); try await fin(file)
                try await file.closeAndAwait()
            } else {
                var ending: USBHostMultiplexConnection.Stream?
                var waitingAt = "open"
                do {
                    let stream = try await owner.openStream(); ending = stream
                    waitingAt = "read"
                    _ = try await stream.readBytes(maximumBytes: 1, timeout: .seconds(5))
                    throw NativePeerError.invalidData
                } catch USBLogicalStreamError.resetByPeer {
                    // A peer may refuse with RST before ACK. Unlike the state-only fixture,
                    // the real owner's open waits for ACK and must report that refusal here.
                    resetStage = waitingAt
                    if let ending { try await ending.closeAndAwait() }
                }
                guard resetStage != nil, owner.protocolSnapshot.owners == 0 else { throw NativePeerError.cleanupUnconfirmed }
                let control = try await owner.openStream()
                defer { withExtendedLifetime((ending, control)) {} }
                try await send(control, command); try await control.finishSending()
                try await read(control, expected: command); try await fin(control); try await control.closeAndAwait()
                bytes = command
            }
            guard owner.protocolSnapshot.owners == 0 else { throw NativePeerError.cleanupUnconfirmed }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var receipt: [String: Any] = ["event": "verified", "implementation": implementation, "case": mode,
                      "bytes": bytes.count, "sha256": hash, "resetObserved": resetStage != nil]
            if let resetStage { receipt["resetStage"] = resetStage }
            try emit(receipt)
            // Data/FIN receipts were verified first. Physical EOF is only the parent's shutdown.
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while owner.terminalFailure == nil {
                guard ContinuousClock.now < end else { throw NativePeerError.timedOut }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let failure = owner.terminalFailure else { throw NativePeerError.invalidData }
            guard case NativePeerError.ended = failure else { throw failure }
            try await owner.closeAndAwait()
            let state = owner.shutdownState
            guard state.nativeWorkersExited && state.referencesReleased && state.pumpsJoined && state.logicalOwnersReleased else { throw NativePeerError.cleanupUnconfirmed }
            try emit(["event": "closed", "readerExited": true, "nativeWorkersExited": state.nativeWorkersExited,
                      "referencesReleased": state.referencesReleased, "pumpsJoined": state.pumpsJoined,
                      "logicalOwnersReleased": state.logicalOwnersReleased, "owners": owner.protocolSnapshot.owners])
        } catch {
            do { try await owner.closeAndAwait() }
            catch let cleanup { throw PeerCleanupFailure(original: error, cleanup: cleanup) }
            throw error
        }
    }
    static func main() async {
        do { try await run() }
        catch {
            do { try FileHandle.standardError.write(contentsOf: Data("USB owner peer failed: \(error)\n".utf8)) }
            catch { exit(74) }
            exit(1)
        }
    }
}
