import Darwin
import Foundation
@preconcurrency import Network
import XCTest
@testable import SkyBridgeCameraKit

final class LoopbackIntegrationTests: XCTestCase {
    func testPublicClientCompletesRTSPInterleavedLifecycleAgainstLocalServer() async throws {
        let host = try Self.privateIPv4Address()
        let server = try LoopbackRTSPServer(host: host)
        let port = try await server.start()
        defer { server.stop() }

        let endpoint = try RTSPEndpoint("rtsp://\(host):\(port)/live/")
        let configuration = try RTSPClientConfiguration(
            endpoint: endpoint,
            connectTimeout: .seconds(3),
            requestTimeout: .seconds(3),
            firstFrameTimeout: .seconds(3),
            streamInactivityTimeout: .seconds(3),
            teardownTimeout: .seconds(2),
            frameBufferCapacity: 1,
            userAgent: "SkyBridgeCameraKitTests/1"
        )
        let client = RTSPInterleavedClient(configuration: configuration)
        let frames = await client.frames()
        var iterator = frames.makeAsyncIterator()

        try await client.connectAndPlay()
        let nextFrame = try await iterator.next()
        let frame = try XCTUnwrap(nextFrame)

        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertTrue(frame.containsVideoCodingLayer)
        XCTAssertEqual(frame.rtpTimestamp, 90_000)
        XCTAssertEqual(frame.firstSequenceNumber, 1)
        XCTAssertEqual(frame.lastSequenceNumber, 1)
        XCTAssertEqual(frame.frameSequenceNumber, 0)
        XCTAssertEqual(
            frame.data,
            Data([
                0, 0, 0, 1, 0x67, 0x42,
                0, 0, 0, 1, 0x68, 0xCE,
                0, 0, 0, 1, 0x65, 0x88,
            ])
        )

        // Session timeout=1 makes the public client issue its normal OPTIONS
        // keepalive after 500 ms. Waiting on the server observation also
        // exercises the timed logical receive -> still-single underlying
        // Network.framework receive handoff before the response arrives.
        try await server.waitUntilObserved(method: "OPTIONS", timeout: .seconds(2))
        try await client.stop()
        try await server.waitUntilObserved(method: "TEARDOWN", timeout: .seconds(2))
        try server.assertHealthy()

        XCTAssertEqual(
            server.observedMethods,
            ["DESCRIBE", "SETUP", "PLAY", "OPTIONS", "TEARDOWN"]
        )
    }

    private static func privateIPv4Address() throws -> String {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else {
            throw LoopbackRTSPServerError.privateAddressUnavailable
        }
        defer { freeifaddrs(firstInterface) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = buffer.withUnsafeMutableBufferPointer { hostBuffer in
                getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    hostBuffer.baseAddress,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard status == 0 else { continue }
            let candidate = String(
                decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if RTSPEndpoint.isAllowedLocalHost(candidate) {
                return candidate
            }
        }
        throw LoopbackRTSPServerError.privateAddressUnavailable
    }
}

private enum LoopbackRTSPServerError: Error, Equatable, LocalizedError, Sendable {
    case privateAddressUnavailable
    case listenerFailed(String)
    case missingListenerPort
    case multipleConnections
    case connectionClosedBeforeTeardown
    case requestHeaderTooLarge
    case malformedRequest(String)
    case unexpectedMethod(expected: String, actual: String)
    case invalidRequestTarget(method: String)
    case invalidHeader(method: String, name: String)
    case sendFailed(String)
    case timedOutWaitingForMethod(String)

    var errorDescription: String? {
        switch self {
        case .privateAddressUnavailable:
            "No active RFC1918 IPv4 address is available for the self-hosted RTSP integration test."
        case let .listenerFailed(reason):
            "The local RTSP listener failed: \(reason)"
        case .missingListenerPort:
            "The local RTSP listener became ready without a bound port."
        case .multipleConnections:
            "The local RTSP fixture received more than one client connection."
        case .connectionClosedBeforeTeardown:
            "The RTSP client closed the local connection before sending TEARDOWN."
        case .requestHeaderTooLarge:
            "The RTSP client request exceeded the fixture's 64 KiB header limit."
        case let .malformedRequest(reason):
            "The RTSP client sent a malformed request: \(reason)"
        case let .unexpectedMethod(expected, actual):
            "The RTSP client sent \(actual) while the fixture expected \(expected)."
        case let .invalidRequestTarget(method):
            "The RTSP \(method) request did not use the negotiated aggregate or media control URI."
        case let .invalidHeader(method, name):
            "The RTSP \(method) request did not contain the required \(name) header."
        case let .sendFailed(reason):
            "The local RTSP fixture could not send its response: \(reason)"
        case let .timedOutWaitingForMethod(method):
            "Timed out waiting for the RTSP client to send \(method)."
        }
    }
}

private struct LoopbackRTSPRequest: Sendable {
    let method: String
    let target: String
    let cSeq: Int
    let headers: [String: String]
}

private final class LoopbackRTSPServer: @unchecked Sendable {
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ body: () -> Void) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            body()
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumRequestHeaderBytes = 64 * 1_024
    private static let sessionIdentifier = "skybridge-loopback-session"

    private let host: String
    private let queue = DispatchQueue(label: "com.skybridge.camera.tests.rtsp-loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var requestBuffer = Data()
    private var methods: [String] = []
    private var firstFailure: LoopbackRTSPServerError?
    private var boundPort: UInt16 = 0

    init(host: String) throws {
        guard RTSPEndpoint.isAllowedLocalHost(host) else {
            throw LoopbackRTSPServerError.privateAddressUnavailable
        }
        self.host = host
    }

    var observedMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        lock.withLock {
            self.listener = listener
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = StartGate()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    gate.resumeOnce {
                        guard let port = listener?.port?.rawValue else {
                            continuation.resume(
                                throwing: LoopbackRTSPServerError.missingListenerPort
                            )
                            return
                        }
                        if let self {
                            self.lock.lock()
                            self.boundPort = port
                            self.lock.unlock()
                        }
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    gate.resumeOnce {
                        let fixtureError = LoopbackRTSPServerError.listenerFailed(
                            String(describing: error)
                        )
                        self?.recordFailure(fixtureError)
                        continuation.resume(throwing: fixtureError)
                    }
                case .cancelled:
                    break
                case .setup, .waiting:
                    break
                @unknown default:
                    gate.resumeOnce {
                        let fixtureError = LoopbackRTSPServerError.listenerFailed(
                            "Network.framework entered an unknown listener state"
                        )
                        self?.recordFailure(fixtureError)
                        continuation.resume(throwing: fixtureError)
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let connection = self.connection
        self.listener = nil
        self.connection = nil
        lock.unlock()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    func waitUntilObserved(method: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try assertHealthy()
            if observedMethods.contains(method) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try assertHealthy()
        throw LoopbackRTSPServerError.timedOutWaitingForMethod(method)
    }

    func assertHealthy() throws {
        lock.lock()
        let failure = firstFailure
        lock.unlock()
        if let failure { throw failure }
    }

    private func accept(_ newConnection: NWConnection) {
        lock.lock()
        guard connection == nil else {
            lock.unlock()
            newConnection.cancel()
            recordFailure(.multipleConnections)
            return
        }
        connection = newConnection
        lock.unlock()

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                self?.recordFailure(.listenerFailed(String(describing: error)))
            case .ready, .setup, .preparing, .waiting, .cancelled:
                break
            @unknown default:
                self?.recordFailure(.listenerFailed(
                    "Network.framework entered an unknown connection state"
                ))
            }
        }
        newConnection.start(queue: queue)
        receiveNext(on: newConnection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                self.recordFailure(.listenerFailed(String(describing: error)))
                return
            }
            if let data, !data.isEmpty {
                self.requestBuffer.append(data)
            }
            if self.requestBuffer.count > Self.maximumRequestHeaderBytes {
                self.recordFailure(.requestHeaderTooLarge)
                connection.cancel()
                return
            }
            guard let requestData = self.popRequestHeader() else {
                if isComplete {
                    self.recordFailure(.connectionClosedBeforeTeardown)
                } else {
                    self.receiveNext(on: connection)
                }
                return
            }

            do {
                let request = try self.parseRequest(requestData)
                try self.validateAndRecord(request)
                if request.method == "TEARDOWN" {
                    connection.cancel()
                    return
                }
                let response = try self.response(for: request)
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.recordFailure(.sendFailed(String(describing: error)))
                    } else {
                        self.receiveNext(on: connection)
                    }
                })
            } catch let error as LoopbackRTSPServerError {
                self.recordFailure(error)
                connection.cancel()
            } catch {
                self.recordFailure(.malformedRequest(String(describing: error)))
                connection.cancel()
            }
        }
    }

    private func popRequestHeader() -> Data? {
        guard let terminatorRange = requestBuffer.range(of: Self.headerTerminator) else {
            return nil
        }
        let request = Data(requestBuffer[..<terminatorRange.upperBound])
        requestBuffer.removeSubrange(..<terminatorRange.upperBound)
        return request
    }

    private func parseRequest(_ data: Data) throws -> LoopbackRTSPRequest {
        guard let text = String(data: data, encoding: .ascii) else {
            throw LoopbackRTSPServerError.malformedRequest("header is not ASCII")
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2] == "RTSP/1.0",
              !requestLine[0].isEmpty,
              !requestLine[1].isEmpty else {
            throw LoopbackRTSPServerError.malformedRequest("invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw LoopbackRTSPServerError.malformedRequest("invalid header line")
            }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty, headers[name] == nil else {
                throw LoopbackRTSPServerError.malformedRequest(
                    "empty or duplicate header"
                )
            }
            headers[name] = value
        }
        guard let cSeqText = headers["cseq"],
              cSeqText.allSatisfy(\.isNumber),
              let cSeq = Int(cSeqText), cSeq > 0 else {
            throw LoopbackRTSPServerError.malformedRequest("missing or invalid CSeq")
        }
        return LoopbackRTSPRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            cSeq: cSeq,
            headers: headers
        )
    }

    private func validateAndRecord(_ request: LoopbackRTSPRequest) throws {
        let expectedMethods = ["DESCRIBE", "SETUP", "PLAY", "OPTIONS", "TEARDOWN"]
        lock.lock()
        let methodIndex = methods.count
        lock.unlock()
        guard methodIndex < expectedMethods.count else {
            throw LoopbackRTSPServerError.unexpectedMethod(
                expected: "no further request",
                actual: request.method
            )
        }
        let expectedMethod = expectedMethods[methodIndex]
        guard request.method == expectedMethod else {
            throw LoopbackRTSPServerError.unexpectedMethod(
                expected: expectedMethod,
                actual: request.method
            )
        }
        guard request.cSeq == methodIndex + 1 else {
            throw LoopbackRTSPServerError.malformedRequest(
                "non-monotonic CSeq \(request.cSeq)"
            )
        }

        let baseTarget = "rtsp://\(host):\(try currentPort())/live/"
        let expectedTarget = request.method == "SETUP"
            ? baseTarget + "trackID=1"
            : baseTarget
        guard request.target == expectedTarget else {
            throw LoopbackRTSPServerError.invalidRequestTarget(method: request.method)
        }

        switch request.method {
        case "DESCRIBE":
            guard request.headers["accept"]?.caseInsensitiveCompare("application/sdp")
                    == .orderedSame else {
                throw LoopbackRTSPServerError.invalidHeader(
                    method: request.method,
                    name: "Accept: application/sdp"
                )
            }
        case "SETUP":
            guard request.headers["transport"]?.caseInsensitiveCompare(
                "RTP/AVP/TCP;unicast;interleaved=0-1"
            ) == .orderedSame else {
                throw LoopbackRTSPServerError.invalidHeader(
                    method: request.method,
                    name: "Transport: RTP/AVP/TCP;unicast;interleaved=0-1"
                )
            }
        case "PLAY", "OPTIONS", "TEARDOWN":
            guard request.headers["session"] == Self.sessionIdentifier else {
                throw LoopbackRTSPServerError.invalidHeader(
                    method: request.method,
                    name: "Session"
                )
            }
        default:
            throw LoopbackRTSPServerError.unexpectedMethod(
                expected: expectedMethod,
                actual: request.method
            )
        }

        lock.lock()
        methods.append(request.method)
        lock.unlock()
    }

    private func response(for request: LoopbackRTSPRequest) throws -> Data {
        switch request.method {
        case "DESCRIBE":
            let port = try currentPort()
            let sdp = """
            v=0
            o=- 0 0 IN IP4 \(host)
            s=SkyBridge Loopback Camera
            t=0 0
            a=control:*
            m=video 5004 RTP/AVP/TCP 96
            a=sendonly
            a=rtpmap:96 H264/90000
            a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0I=,aM4=
            a=control:trackID=1
            """
            let body = Data(sdp.utf8)
            return makeResponse(
                cSeq: request.cSeq,
                headers: [
                    ("Content-Type", "application/sdp"),
                    ("Content-Base", "rtsp://\(host):\(port)/live/"),
                    ("Content-Length", String(body.count)),
                ],
                body: body
            )
        case "SETUP":
            return makeResponse(
                cSeq: request.cSeq,
                headers: [
                    ("Session", "\(Self.sessionIdentifier);timeout=1"),
                    ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"),
                ]
            )
        case "PLAY":
            var response = makeResponse(
                cSeq: request.cSeq,
                headers: [("Session", Self.sessionIdentifier)]
            )
            response.append(Self.interleavedIDRFrame())
            return response
        case "OPTIONS":
            return makeResponse(
                cSeq: request.cSeq,
                headers: [
                    ("Session", Self.sessionIdentifier),
                    ("Public", "OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN"),
                ]
            )
        default:
            throw LoopbackRTSPServerError.unexpectedMethod(
                expected: "DESCRIBE, SETUP, PLAY, or OPTIONS",
                actual: request.method
            )
        }
    }

    private func makeResponse(
        cSeq: Int,
        headers: [(String, String)],
        body: Data = Data()
    ) -> Data {
        var text = "RTSP/1.0 200 OK\r\nCSeq: \(cSeq)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var response = Data(text.utf8)
        response.append(body)
        return response
    }

    private static func interleavedIDRFrame() -> Data {
        let rtp = Data([
            0x80, 0xE0, // RTP v2, marker set, payload type 96
            0x00, 0x01, // sequence number 1
            0x00, 0x01, 0x5F, 0x90, // timestamp 90000
            0x01, 0x02, 0x03, 0x04, // SSRC
            0x65, 0x88, // single H.264 IDR NAL
        ])
        precondition(rtp.count <= Int(UInt16.max))
        var length = UInt16(rtp.count).bigEndian
        var frame = Data([0x24, 0x00])
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(rtp)
        return frame
    }

    private func currentPort() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        guard boundPort != 0 else {
            throw LoopbackRTSPServerError.missingListenerPort
        }
        return boundPort
    }

    private func recordFailure(_ error: LoopbackRTSPServerError) {
        lock.lock()
        if firstFailure == nil {
            firstFailure = error
        }
        lock.unlock()
    }
}
