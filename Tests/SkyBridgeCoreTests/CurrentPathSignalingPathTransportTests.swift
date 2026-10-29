import CryptoKit
import Foundation
import Network
import XCTest
import SkyBridgeProtocolCore

@MainActor
final class CurrentPathSignalingPathTransportTests: XCTestCase {
    private let path = "/signal/%41/%20/%7e/%25/%E4%B8%AD"

    func testNetworkWebSocketPreservesRawRequestTarget() async throws {
        let server = try RawWebSocketRequestCapture()
        await fulfillment(of: [server.ready], timeout: 5)
        var client: NWConnection?
        let witness = NativeConnectionWitness()
        var failure: (any Error)?
        do {
            let request = try request(port: XCTUnwrap(server.listener.port))
            let parameters = NWParameters(tls: nil)
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            parameters.preferNoProxies = true
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = 64 * 1024
            options.setAdditionalHeaders((request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
                .map { (name: $0.key, value: $0.value) })
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let connection = NWConnection(to: .url(try XCTUnwrap(request.url)), using: parameters)
            client = connection
            connection.stateUpdateHandler = { state in
                Task { @MainActor in witness.record(state) }
            }
            connection.start(queue: .main)
            await fulfillment(of: [server.captured, witness.ready], timeout: 5)
            if let error = witness.failure { throw error }
            let target = try XCTUnwrap(server.result).get()
            XCTAssertEqual(target, expectedTarget)
            print("native-network request-target=\(target)")
        } catch {
            failure = error
        }
        client?.cancel()
        var stopped = server.stop()
        if client != nil { stopped.append(witness.stopped) }
        await fulfillment(of: stopped, timeout: 5)
        if let failure { throw failure }
    }

    func testURLSessionWebSocketPreservesRawRequestTarget() async throws {
        let server = try RawWebSocketRequestCapture()
        await fulfillment(of: [server.ready], timeout: 5)
        let witness = URLSessionConnectionWitness()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        let session = URLSession(configuration: configuration, delegate: witness, delegateQueue: nil)
        var task: URLSessionWebSocketTask?
        var failure: (any Error)?
        do {
            let taskRequest = try request(port: XCTUnwrap(server.listener.port))
            let socketTask = session.webSocketTask(with: taskRequest)
            task = socketTask
            socketTask.resume()
            await fulfillment(of: [server.captured, witness.opened], timeout: 5)
            let target = try XCTUnwrap(server.result).get()
            XCTAssertEqual(target, expectedTarget)
            print("url-session request-target=\(target)")
        } catch {
            failure = error
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        await fulfillment(of: server.stop() + [witness.invalidated], timeout: 5)
        if let failure { throw failure }
    }

    private var expectedTarget: String {
        path + "?shard=SESSION-MIXED&cv=1.2.3&pv=2"
    }

    private func request(port: NWEndpoint.Port) throws -> URLRequest {
        let url = try XCTUnwrap(CurrentPathSignalingWebSocketPolicy.webSocketURL(
            signalingServerOrigin: "http://127.0.0.1:\(port.rawValue)", wsPath: path,
            sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2"
        ))
        let headers = try XCTUnwrap(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2"
        ))
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

@MainActor
private final class NativeConnectionWitness {
    let ready = XCTestExpectation(description: "Native WebSocket upgrade completed")
    let stopped = XCTestExpectation(description: "Native WebSocket connection cancelled")
    var failure: NWError?
    private var started = false

    func record(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if !started { started = true; ready.fulfill() }
        case .failed(let error):
            failure = error
            if !started { started = true; ready.fulfill() }
        case .cancelled:
            stopped.fulfill()
        default:
            break
        }
    }
}

private final class URLSessionConnectionWitness: NSObject, URLSessionWebSocketDelegate {
    let opened = XCTestExpectation(description: "URLSession WebSocket upgrade completed")
    let invalidated = XCTestExpectation(description: "URLSession invalidation completed")

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened.fulfill()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        XCTAssertNil(error)
        invalidated.fulfill()
    }
}

// Uses the existing tests' MainActor NWListener pattern; all fixture state stays on that actor.
@MainActor
private final class RawWebSocketRequestCapture {
    enum Failure: Error { case tooManyConnections, incompleteRequest, oversizedHeaders, malformedRequest }
    let listener: NWListener
    let ready = XCTestExpectation(description: "Loopback TCP listener ready")
    let captured = XCTestExpectation(description: "Raw WebSocket request captured")
    private let listenerStopped = XCTestExpectation(description: "Loopback listener cancelled")
    private let connectionStopped = XCTestExpectation(description: "Accepted connection cancelled")
    private var connection: NWConnection?
    private var bytes = Data()
    private var readySignalled = false
    private(set) var result: Result<String, any Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    if !readySignalled { readySignalled = true; ready.fulfill() }
                case .failed(let error):
                    finish(.failure(error))
                    if !readySignalled { readySignalled = true; ready.fulfill() }
                case .cancelled:
                    listenerStopped.fulfill()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() -> [XCTestExpectation] {
        listener.cancel()
        connection?.cancel()
        return connection == nil ? [listenerStopped] : [listenerStopped, connectionStopped]
    }

    private func accept(_ accepted: NWConnection) {
        guard connection == nil else {
            finish(.failure(Failure.tooManyConnections))
            accepted.cancel()
            return
        }
        connection = accepted
        accepted.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .cancelled = state { connectionStopped.fulfill() }
            }
        }
        accepted.start(queue: .main)
        receive(accepted)
    }

    private func receive(_ accepted: NWConnection) {
        accepted.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, result == nil else { return }
                if let error { finish(.failure(error)); return }
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384 else { finish(.failure(Failure.oversizedHeaders)); return }
                guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { finish(.failure(Failure.incompleteRequest)) }
                    else { receive(accepted) }
                    return
                }
                let lines = text.components(separatedBy: "\r\n")
                let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
                let key = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                    .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1", let key, !key.isEmpty else {
                    finish(.failure(Failure.malformedRequest)); return
                }
                let target = String(request[1])
                // RFC 6455's required upgrade response; no product security mechanism is added.
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                let response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
                accepted.send(content: response, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error { finish(.failure(error)) }
                        else { finish(.success(target)) }
                    }
                })
            }
        }
    }

    private func finish(_ outcome: Result<String, any Error>) {
        guard result == nil else { return }
        result = outcome
        captured.fulfill()
    }
}
