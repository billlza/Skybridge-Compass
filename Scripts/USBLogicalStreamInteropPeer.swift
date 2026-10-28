// Local-only test peer for Android/Swift wire compatibility. Not a USB product entry.
import CryptoKit
import Foundation
import Network
import SkyBridgeProtocolCore
import os

private enum PeerError: Error { case invalidMode, timedOut, ended, invalidData, unexpectedFIN, cleanupUnconfirmed }
private typealias ProtocolState = USBLogicalStreamProtocol
private typealias Wire = USBLogicalStreamWire

private func emit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
}

/// Network.framework is used only as the test's local reliable byte-stream substitute.
private final class Peer: Sendable {
    let protocolState: ProtocolState
    private let connection: NWConnection
    private struct State: Sendable { var closing = false, exited = false; var failure: (any Error)? }
    private let state: OSAllocatedUnfairLock<State>
    private let reader: Task<Void, Never>
    private let began = ContinuousClock.now

    init(_ connection: NWConnection, role: ProtocolState.Role) throws {
        self.connection = connection
        let protocolState = try ProtocolState(role: role)
        self.protocolState = protocolState
        let state = OSAllocatedUnfairLock(initialState: State()); self.state = state
        reader = Task {
            defer { state.withLock { $0.exited = true } }
            do {
                while !state.withLock({ $0.closing }) {
                    let header = try Wire.decodeHeader(await Self.readExactly(connection, count: Wire.headerBytes))
                    let body = try await Self.readExactly(connection, count: header.type == .data ? Int(header.value) : 0)
                    try protocolState.receive(Wire.Frame(header: header, body: body))
                }
            } catch {
                state.withLock { if !$0.closing && $0.failure == nil { $0.failure = error } }
                protocolState.failCarrier(error)
            }
        }
    }

    private static func readExactly(_ connection: NWConnection, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(16_384, remaining)) { bytes, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: complete ? PeerError.ended : PeerError.invalidData) }
                }
            }
            guard next.count <= remaining else { throw PeerError.invalidData }
            result.append(next)
        }
        return result
    }

    private func check() throws {
        try Task.checkCancellation()
        guard began.duration(to: .now) < .seconds(18) else { throw PeerError.timedOut }
        if let error = state.withLock({ $0.failure }) { throw error }
    }

    func step() async throws {
        try check()
        for _ in 0..<64 {
            guard let frame = try protocolState.pollOutbound() else { return }
            let bytes = frame.wireBytes()
            guard bytes.count <= Wire.maximumNativeTransfer else { throw PeerError.invalidData }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            } catch { try protocolState.reportWriteFailure(frame, cause: error); throw error }
            try protocolState.reportWritten(frame)
        }
    }

    func until(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw PeerError.timedOut }
            try await step(); try await Task.sleep(for: .milliseconds(1))
        }
        try check()
    }

    func accept() async throws -> UInt32 {
        try await until { !protocolState.pendingAcceptIDs.isEmpty }
        guard let id = try protocolState.acceptStream() else { throw PeerError.invalidData }
        return id
    }

    func send(_ id: UInt32, _ bytes: Data) async throws {
        for offset in stride(from: 0, to: bytes.count, by: Wire.outboundDataBytes) {
            let end = min(bytes.count, offset + Wire.outboundDataBytes)
            let ticket = try protocolState.queueData(streamID: id, bytes: bytes.subdata(in: offset..<end))
            try await until {
                switch ticket.result {
                case .waiting: false
                case .written: true
                case .failed(let error): throw error
                }
            }
        }
    }

    func read(_ id: UInt32, _ expected: Data) async throws {
        var offset = 0
        try await until {
            switch try protocolState.read(streamID: id, maximum: min(8_191, max(1, expected.count - offset))) {
            case .waiting: return false
            case .remoteFIN: throw PeerError.unexpectedFIN
            case .data(let bytes):
                guard offset + bytes.count <= expected.count,
                      bytes == expected.subdata(in: offset..<(offset + bytes.count)) else { throw PeerError.invalidData }
                offset += bytes.count
                return offset == expected.count
            }
        }
    }

    func fin(_ id: UInt32) async throws {
        try await until {
            switch try protocolState.read(streamID: id, maximum: 1) {
            case .waiting: false
            case .remoteFIN: true
            case .data: throw PeerError.invalidData
            }
        }
    }

    func finish(_ id: UInt32) async throws {
        try protocolState.finishSending(streamID: id)
        try await until { try protocolState.snapshot(streamID: id).localFINSent }
    }

    /// Only after independently verified payload/FIN receipts; carrier EOF never proves data completion.
    func awaitParentClose() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !state.withLock({ $0.exited }) {
            guard ContinuousClock.now < deadline else { throw PeerError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
        await reader.value
        guard let error = state.withLock({ $0.failure }) else { throw PeerError.invalidData }
        guard case PeerError.ended = error else { throw error }
    }

    func close() async throws {
        state.withLock { $0.closing = true }; connection.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !state.withLock({ $0.exited }) {
            guard ContinuousClock.now < deadline else { throw PeerError.cleanupUnconfirmed }
            try await Task.sleep(for: .milliseconds(2))
        }
        await reader.value
    }
}

@main
private struct USBInteropMain {
    static let command = Data("skybridge-usb-control-1".utf8)
    static func payload(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 + 17) }) }

    static func main() async {
        do { try await run() }
        catch {
            do { try FileHandle.standardError.write(contentsOf: Data("USB Swift peer failed: \(error)\n".utf8)) }
            catch { exit(74) }
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2, ["flow", "reverse", "reset"].contains(CommandLine.arguments[1]) else {
            throw PeerError.invalidMode
        }
        let mode = CommandLine.arguments[1]
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            listener.cancel()
        }
        let connection: NWConnection
        do {
            connection = try await withCheckedThrowingContinuation { continuation in
                let resolved = OSAllocatedUnfairLock(initialState: false)
                let claim: @Sendable () -> Bool = {
                    resolved.withLock { value in if value { return false }; value = true; return true }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        do {
                            guard let port = listener.port else { throw PeerError.invalidData }
                            try emit(["event": "listening", "port": port.rawValue, "implementation": "skybridge-swift-yamux"])
                        } catch { if claim() { continuation.resume(throwing: error) }; listener.cancel() }
                    case .failed(let error): if claim() { continuation.resume(throwing: error) }
                    case .cancelled: if claim() { continuation.resume(throwing: PeerError.timedOut) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in
                    if claim() { continuation.resume(returning: connection) } else { connection.cancel() }
                    listener.cancel()
                }
                listener.start(queue: DispatchQueue(label: "USB Swift reference listener"))
            }
        } catch { watchdog.cancel(); listener.cancel(); throw error }
        watchdog.cancel()
        let connectionDeadline = Task { try await Task.sleep(for: .seconds(20)); connection.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resolved = OSAllocatedUnfairLock(initialState: false)
                connection.stateUpdateHandler = { state in
                    let outcome: Result<Void, Error>
                    switch state {
                    case .ready: outcome = .success(())
                    case .failed(let error): outcome = .failure(error)
                    case .cancelled: outcome = .failure(PeerError.timedOut)
                    default: return
                    }
                    let first = resolved.withLock { value in if value { return false }; value = true; return true }
                    if first { continuation.resume(with: outcome) }
                }
                connection.start(queue: DispatchQueue(label: "USB Swift reference connection"))
            }
            let peer = try Peer(connection, role: mode == "flow" ? .server : .client)
            do {
                let bytes: Data
                if mode == "flow" {
                    let file = try await peer.accept(), control = try await peer.accept()
                    try await peer.read(control, command); try await peer.send(control, command)
                    try await peer.finish(control); try await peer.fin(control); try peer.protocolState.releaseStream(control)
                    bytes = payload(262_145)
                    try await peer.read(file, bytes); try await peer.send(file, bytes)
                    try await peer.finish(file); try await peer.fin(file); try peer.protocolState.releaseStream(file)
                } else if mode == "reverse" {
                    let file = try peer.protocolState.openStream(priority: .bulk), control = try peer.protocolState.openStream()
                    bytes = payload(65_579)
                    try await peer.send(file, bytes); try await peer.send(control, command)
                    try await peer.finish(control); try await peer.read(control, command); try await peer.fin(control)
                    try peer.protocolState.releaseStream(control)
                    try await peer.finish(file); try await peer.read(file, bytes); try await peer.fin(file)
                    try peer.protocolState.releaseStream(file)
                } else {
                    let ending = try peer.protocolState.openStream()
                    do {
                        try await peer.until { _ = try peer.protocolState.read(streamID: ending, maximum: 1); return false }
                        throw PeerError.invalidData
                    } catch USBLogicalStreamError.resetByPeer { try peer.protocolState.releaseStream(ending) }
                    let control = try peer.protocolState.openStream()
                    try await peer.send(control, command); try await peer.finish(control)
                    try await peer.read(control, command); try await peer.fin(control); try peer.protocolState.releaseStream(control)
                    bytes = command
                }
                guard peer.protocolState.snapshot.owners == 0 else { throw PeerError.cleanupUnconfirmed }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                try emit(["event": "verified", "implementation": "skybridge-swift-yamux", "case": mode,
                          "bytes": bytes.count, "sha256": digest, "resetObserved": mode == "reset"])
                try await peer.awaitParentClose(); try await peer.close()
                try emit(["event": "closed", "readerExited": true, "owners": 0])
            } catch {
                do { try await peer.close() }
                catch let cleanup { throw NSError(domain: "USB Swift peer cleanup", code: 1,
                                                  userInfo: [NSUnderlyingErrorKey: error, "cleanup": String(describing: cleanup)]) }
                throw error
            }
        } catch { connectionDeadline.cancel(); connection.cancel(); throw error }
        connectionDeadline.cancel(); connection.cancel()
    }
}
