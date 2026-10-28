import Foundation
import Darwin
import os.lock

/// One bounded SSDP/UPnP M-SEARCH. A response deadline with no packets is a valid empty result.
public final class SSDPDiscovery: Sendable {
    public enum Failure: Error, Equatable {
        case invalidTimeout
        case invalidDestination
        case socket(Int32)
        case configuration(Int32)
        case send(Int32)
        case receive(Int32)
        case wait(Int32)

        var diagnosticCode: String {
            switch self {
            case .invalidTimeout: "invalid_timeout"
            case .invalidDestination: "invalid_destination"
            case .socket(let code): "socket_\(code)"
            case .configuration(let code): "configuration_\(code)"
            case .send(let code): "send_\(code)"
            case .receive(let code): "receive_\(code)"
            case .wait(let code): "wait_\(code)"
            }
        }
    }

    private let queue: DispatchQueue
    private let multicastHost: String
    private let multicastPort: UInt16

    public convenience init() {
        self.init(host: "239.255.255.250", port: 1900)
    }

    internal init(host: String, port: UInt16, queue: DispatchQueue = DispatchQueue(label: "ssdp.discovery", qos: .utility)) {
        self.multicastHost = host
        self.multicastPort = port
        self.queue = queue
    }

    /// The deadline includes queueing, sending, interrupted waits, and receiving. Invalid durations
    /// and I/O failures throw; cancellation never closes a descriptor owned by another operation.
    public func searchOnce(st: String = "ssdp:all", timeout: TimeInterval = 0.8) async throws -> [(usn: String, location: String)] {
        guard timeout.isFinite, timeout > 0, timeout <= Double(Int32.max) / 1_000 else {
            throw Failure.invalidTimeout
        }
        let duration = UInt64(ceil(timeout * 1_000_000_000))
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(duration)
        guard !overflow else { throw Failure.invalidTimeout }
        let cancellation = CancellationFlag()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[(usn: String, location: String)], Error>) in
                queue.async {
                    do {
                        let result = try self.search(st: st, deadline: deadline, cancellation: cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private func search(st: String, deadline: UInt64, cancellation: CancellationFlag) throws -> [(usn: String, location: String)] {
        try cancellation.check()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return [] }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(multicastPort).bigEndian
        guard multicastHost.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw Failure.invalidDestination
        }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw Failure.socket(errno) }
        defer { close(sock) }
        let flags = fcntl(sock, F_GETFL)
        guard flags >= 0, fcntl(sock, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.configuration(errno)
        }
        let payload = Data(("M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(multicastHost):\(multicastPort)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" + "MX: 1\r\n" + "ST: \(st)\r\n\r\n").utf8)
        while true {
            guard try wait(sock, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation) else { return [] }
            let sent = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sock, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == payload.count { break }
            let code = errno
            if sent < 0, code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
            throw Failure.send(sent < 0 ? code : EMSGSIZE)
        }
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while true {
            guard try wait(sock, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation) else { return [] }
            let received = buffer.withUnsafeMutableBytes { recvfrom(sock, $0.baseAddress, $0.count, 0, nil, nil) }
            if received < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                throw Failure.receive(code)
            }
            try cancellation.check()
            guard let text = String(data: Data(buffer.prefix(received)), encoding: .utf8) else { return [] }
            let usn = parseHeader(text, key: "USN")
            let location = parseHeader(text, key: "LOCATION")
            return usn.isEmpty && location.isEmpty ? [] : [(usn, location)]
        }
    }

    private func wait(_ socket: Int32, events: Int16, deadline: UInt64, cancellation: CancellationFlag) throws -> Bool {
        while true {
            try cancellation.check()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            // A short poll slice observes cancellation without a cross-thread close/reused-FD race.
            let milliseconds = Int32(min(50, (deadline - now + 999_999) / 1_000_000))
            var descriptor = pollfd(fd: socket, events: events, revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            try cancellation.check()
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.wait(errno)
            }
            if ready == 0 { continue }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            if descriptor.revents & Int16(POLLNVAL) != 0 { throw Failure.wait(EBADF) }
            // Let send/recv surface the concrete socket error when poll reports POLLERR/HUP.
            if descriptor.revents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0 { return true }
        }
    }

    private final class CancellationFlag: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        func cancel() { cancelled.withLock { $0 = true } }
        func check() throws {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        }
    }

    private func parseHeader(_ text: String, key: String) -> String {
        for line in text.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(key.lowercased()), let range = line.range(of: ":") {
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
