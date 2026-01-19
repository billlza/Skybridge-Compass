import XCTest
import Foundation
import Network
import Security
import NoiseKit
import Atomics

final class BaselineLoopbackBenchTests: XCTestCase {
    private struct BenchConfig {
        let iterations: Int
        let warmup: Int
        let timeoutSeconds: Double
        let kickoffBytes: Int
        let tlsVersion: tls_protocol_version_t
        let quicAlpn: String
    }

    private var shouldRunBenchmarks: Bool {
        ProcessInfo.processInfo.environment["BASELINE_RUN_BENCH"] == "1"
    }

    func testLoopbackBaselines() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set BASELINE_RUN_BENCH=1 to run loopback baselines")

        let config = BenchConfig(
            iterations: 50,
            warmup: 5,
            timeoutSeconds: 5.0,
            kickoffBytes: 1,
            tlsVersion: .TLSv13,
            quicAlpn: "sbq"
        )

        let identity = try loadIdentity(
            path: "Tests/Fixtures/loopback_identity.p12",
            password: "skybridge"
        )

        let tls = try await runTLSBench(config: config, identity: identity)
        let quic = try await runQUICBench(config: config, identity: identity)
        let dtls = try await runDTLSBench(config: config, identity: identity)
        let noise = try await runNoiseBench(config: config)

        reportStats(label: "TLS13", samples: tls)
        reportStats(label: "QUIC", samples: quic)
        reportStats(label: "WebRTC-DTLS", samples: dtls)
        reportStats(label: "Noise-XX", samples: noise)
    }

    private func reportStats(label: String, samples: [Double]) {
        XCTAssertFalse(samples.isEmpty, "\(label) produced no samples")
        let p50 = percentile(samples, p: 0.50)
        let p95 = percentile(samples, p: 0.95)
        print("[BASELINE] \(label) p50=\(String(format: "%.2f", p50)) ms p95=\(String(format: "%.2f", p95)) ms")
    }

    private func runTLSBench(config: BenchConfig, identity: SecIdentity) async throws -> [Double] {
        let tlsOptions = makeTLSOptions(identity: identity, isServer: true, version: config.tlsVersion)
        let serverParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: config.tlsVersion)
        let clientParams = NWParameters(tls: clientTlsOptions, tcp: NWProtocolTCP.Options())
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "TLS13",
            serverParameters: serverParams,
            clientParameters: clientParams,
            config: config
        )
    }

    private func runQUICBench(config: BenchConfig, identity: SecIdentity) async throws -> [Double] {
        let serverQuicOptions = NWProtocolQUIC.Options(alpn: [config.quicAlpn])
        serverQuicOptions.direction = .bidirectional
        serverQuicOptions.initialMaxStreamsBidirectional = 1
        if #available(macOS 13.0, *) {
            serverQuicOptions.isDatagram = true
            serverQuicOptions.maxDatagramFrameSize = 1200
        }
        configureTLSOptions(
            serverQuicOptions.securityProtocolOptions,
            identity: identity,
            isServer: true,
            version: .TLSv13,
            alpn: nil,
            serverName: nil,
            peerAuthenticationRequired: false,
            useVerifyBlock: false
        )
        let serverParams = NWParameters(quic: serverQuicOptions)
        serverParams.allowLocalEndpointReuse = true

        let clientQuicOptions = NWProtocolQUIC.Options(alpn: [config.quicAlpn])
        clientQuicOptions.direction = .bidirectional
        clientQuicOptions.initialMaxStreamsBidirectional = 1
        if #available(macOS 13.0, *) {
            clientQuicOptions.isDatagram = true
            clientQuicOptions.maxDatagramFrameSize = 1200
        }
        configureTLSOptions(
            clientQuicOptions.securityProtocolOptions,
            identity: identity,
            isServer: false,
            version: .TLSv13,
            alpn: nil,
            serverName: "localhost",
            peerAuthenticationRequired: false,
            useVerifyBlock: true
        )
        let clientParams = NWParameters(quic: clientQuicOptions)
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "QUIC",
            serverParameters: serverParams,
            clientParameters: clientParams,
            config: config
        )
    }

    private func runDTLSBench(config: BenchConfig, identity: SecIdentity) async throws -> [Double] {
        let serverTlsOptions = makeTLSOptions(identity: identity, isServer: true, version: .DTLSv12, alpn: "webrtc")
        let serverParams = NWParameters(dtls: serverTlsOptions, udp: NWProtocolUDP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: .DTLSv12, alpn: "webrtc")
        let clientParams = NWParameters(dtls: clientTlsOptions, udp: NWProtocolUDP.Options())
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "WebRTC-DTLS",
            serverParameters: serverParams,
            clientParameters: clientParams,
            config: config
        )
    }

    private func runNoiseBench(config: BenchConfig) async throws -> [Double] {
        let queue = DispatchQueue(label: "baseline.noise.tests")
        let listener = try NWListener(using: .udp)
        listener.start(queue: queue)
        try await Self.waitForListenerReady(listener: listener, queue: queue, timeoutSeconds: config.timeoutSeconds)
        guard let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "BaselineBenchTests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Listener port unavailable"
            ])
        }

        let clientConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: .udp
        )
        clientConnection.start(queue: queue)

        let clientChannel = UDPChannel(connection: clientConnection)

        let serverConnectionStream = AsyncThrowingStream<NWConnection, Error> { continuation in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + config.timeoutSeconds)
            timer.setEventHandler {
                listener.cancel()
                continuation.finish(throwing: NSError(domain: "BaselineBenchTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(config.timeoutSeconds)s"
                ]))
            }
            timer.activate()

            listener.newConnectionHandler = { connection in
                timer.cancel()
                listener.newConnectionHandler = nil
                connection.start(queue: queue)
                continuation.yield(connection)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                timer.cancel()
                listener.newConnectionHandler = nil
            }
        }

        var serverConnectionIterator = serverConnectionStream.makeAsyncIterator()
        try await clientChannel.send(Data([0x00]))
        guard let serverConnection = try await serverConnectionIterator.next() else {
            listener.cancel()
            throw NSError(domain: "BaselineBenchTests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Listener did not accept a connection"
            ])
        }
        let serverChannel = UDPChannel(connection: serverConnection)
        _ = try await serverChannel.receive()

        let initiatorStatic = NoiseXX.makeStaticKeyPair()
        let responderStatic = NoiseXX.makeStaticKeyPair()

        var samples: [Double] = []
        for iteration in 0..<(config.warmup + config.iterations) {
            let start = Date().timeIntervalSince1970
            async let responderTask: Void = try NoiseXX.runResponder(
                staticKey: responderStatic,
                send: serverChannel.send,
                receive: serverChannel.receive
            )
            try await NoiseXX.runInitiator(
                staticKey: initiatorStatic,
                send: clientChannel.send,
                receive: clientChannel.receive
            )
            try await responderTask
            let end = Date().timeIntervalSince1970
            if iteration >= config.warmup {
                samples.append((end - start) * 1000.0)
            }
        }

        clientConnection.cancel()
        serverConnection.cancel()
        listener.cancel()
        return samples
    }

    private func runNWHandshakeBench(
        protocolName: String,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        config: BenchConfig
    ) async throws -> [Double] {
        let queue = DispatchQueue(label: "baseline.\(protocolName.lowercased()).tests")
        let listener = try NWListener(using: serverParameters)
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        try await Self.waitForListenerReady(listener: listener, queue: queue, timeoutSeconds: config.timeoutSeconds)
        guard let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "BaselineBenchTests", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Listener port unavailable"
            ])
        }
        try await Task.sleep(for: .milliseconds(10))

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        var samples: [Double] = []
        for iteration in 0..<(config.warmup + config.iterations) {
            let connection = NWConnection(to: endpoint, using: clientParameters)
            let start = Date().timeIntervalSince1970
            try await Self.waitForReady(
                connection: connection,
                queue: queue,
                timeoutSeconds: config.timeoutSeconds,
                kickoffBytes: config.kickoffBytes
            )
            let end = Date().timeIntervalSince1970
            connection.cancel()
            if iteration >= config.warmup {
                samples.append((end - start) * 1000.0)
            }
        }

        listener.cancel()
        return samples
    }

    private func loadIdentity(path: String, password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        var status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        if status != errSecSuccess {
            if let keychain = try? makeTemporaryKeychain(password: password) {
                options[kSecImportExportKeychain as String] = keychain
                status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            }
        }
        if status == errSecSuccess,
           let array = items as? [[String: Any]],
           let first = array.first,
           let anyIdentity = first[kSecImportItemIdentity as String],
           CFGetTypeID(anyIdentity as CFTypeRef) == SecIdentityGetTypeID() {
            return unsafeDowncast(anyIdentity as AnyObject, to: SecIdentity.self)
        }

        if let pemIdentity = try? loadIdentityFromPEM(p12Path: path) {
            return pemIdentity
        }

        throw NSError(domain: "BaselineBenchTests", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "PKCS#12 import failed (\(status))"
        ])
    }

    private func makeTemporaryKeychain(password: String) throws -> SecKeychain {
        let path = "/tmp/skybridge_baseline_tests_\(UUID().uuidString).keychain-db"
        let passwordBytes = Array(password.utf8)
        var keychain: SecKeychain?
        let status = passwordBytes.withUnsafeBufferPointer { buffer -> OSStatus in
            let base = buffer.baseAddress?.withMemoryRebound(to: Int8.self, capacity: buffer.count) { $0 }
            return SecKeychainCreate(path, UInt32(passwordBytes.count), base, false, nil, &keychain)
        }
        guard status == errSecSuccess, let created = keychain else {
            throw NSError(domain: "BaselineBenchTests", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Temporary keychain creation failed (\(status))"
            ])
        }
        return created
    }

    private func loadIdentityFromPEM(p12Path: String) throws -> SecIdentity {
        let p12URL = URL(fileURLWithPath: p12Path)
        let baseDir = p12URL.deletingLastPathComponent()
        let certURL = baseDir.appendingPathComponent("loopback_cert.pem")
        let keyURL = baseDir.appendingPathComponent("loopback_key.pem")

        let certPEM = try Data(contentsOf: certURL)
        let keyPEM = try Data(contentsOf: keyURL)
        let certDER = try decodePEM(certPEM, header: "CERTIFICATE")
        let keyDER = try ((try? decodePEM(keyPEM, header: "PRIVATE KEY")) ?? decodePEM(keyPEM, header: "EC PRIVATE KEY"))

        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw NSError(domain: "BaselineBenchTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create certificate from PEM"
            ])
        }

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyDER as CFData, keyAttributes as CFDictionary, &keyError) else {
            let message = keyError?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw NSError(domain: "BaselineBenchTests", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create private key: \(message)"
            ])
        }

        let keychain = try makeTemporaryKeychain(password: UUID().uuidString)
        let label = "BaselineBenchTests.\(UUID().uuidString)"
        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label,
            kSecValueRef as String: key,
            kSecUseKeychain as String: keychain,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(addKeyQuery as CFDictionary)
        let keyStatus = SecItemAdd(addKeyQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            throw NSError(domain: "BaselineBenchTests", code: Int(keyStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to add key to keychain (\(keyStatus))"
            ])
        }

        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: cert,
            kSecUseKeychain as String: keychain,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(addCertQuery as CFDictionary)
        let certStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            throw NSError(domain: "BaselineBenchTests", code: Int(certStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to add certificate to keychain (\(certStatus))"
            ])
        }

        var identity: SecIdentity?
        let idStatus = SecIdentityCreateWithCertificate(keychain, cert, &identity)
        guard idStatus == errSecSuccess, let created = identity else {
            throw NSError(domain: "BaselineBenchTests", code: Int(idStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to create identity from PEM (\(idStatus))"
            ])
        }
        return created
    }

    private func decodePEM(_ data: Data, header: String) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "BaselineBenchTests", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "PEM is not valid UTF-8"
            ])
        }
        let begin = "-----BEGIN \(header)-----"
        let end = "-----END \(header)-----"
        guard let rangeStart = text.range(of: begin),
              let rangeEnd = text.range(of: end) else {
            throw NSError(domain: "BaselineBenchTests", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "PEM block \(header) not found"
            ])
        }
        let body = text[rangeStart.upperBound..<rangeEnd.lowerBound]
        let base64 = body
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let decoded = Data(base64Encoded: base64) else {
            throw NSError(domain: "BaselineBenchTests", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode PEM base64"
            ])
        }
        return decoded
    }

    private func makeTLSOptions(
        identity: SecIdentity,
        isServer: Bool,
        version: tls_protocol_version_t,
        alpn: String? = nil
    ) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        configureTLSOptions(
            tlsOptions.securityProtocolOptions,
            identity: identity,
            isServer: isServer,
            version: version,
            alpn: alpn,
            serverName: "localhost",
            peerAuthenticationRequired: false,
            useVerifyBlock: true
        )
        return tlsOptions
    }

    private func configureTLSOptions(
        _ secOptions: sec_protocol_options_t,
        identity: SecIdentity,
        isServer: Bool,
        version: tls_protocol_version_t,
        alpn: String?,
        serverName: String?,
        peerAuthenticationRequired: Bool,
        useVerifyBlock: Bool
    ) {
        sec_protocol_options_set_min_tls_protocol_version(secOptions, version)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, version)

        if let alpn {
            alpn.utf8CString.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                sec_protocol_options_add_tls_application_protocol(secOptions, base)
            }
        }

        if isServer {
            if let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(secOptions, secIdentity)
            }
        } else {
            if let serverName {
                serverName.utf8CString.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    sec_protocol_options_set_tls_server_name(secOptions, base)
                }
            }
            sec_protocol_options_set_peer_authentication_required(secOptions, peerAuthenticationRequired)
            if useVerifyBlock {
                sec_protocol_options_set_verify_block(secOptions, { _, _, complete in
                    complete(true)
                }, .global())
            }
        }
    }

    private static func waitForReady(
        connection: NWConnection,
        queue: DispatchQueue,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let didResume = ManagedAtomic(false)
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                guard didResume.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
                timer.cancel()
                connection.stateUpdateHandler = nil
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                connection.cancel()
                resumeOnce(.failure(NSError(domain: "BaselineBenchTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(NSError(domain: "BaselineBenchTests", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Connection cancelled"
                    ])))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            if kickoffBytes > 0 {
                let payload = Data(repeating: 0x00, count: kickoffBytes)
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    private static func waitForListenerReady(
        listener: NWListener,
        queue: DispatchQueue,
        timeoutSeconds: Double
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let didResume = ManagedAtomic(false)
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                guard didResume.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
                timer.cancel()
                listener.stateUpdateHandler = nil
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                listener.cancel()
                resumeOnce(.failure(NSError(domain: "BaselineBenchTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Listener timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(NSError(domain: "BaselineBenchTests", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Listener cancelled"
                    ])))
                default:
                    break
                }
            }
        }
    }

    private static func waitForNewConnection(
        listener: NWListener,
        queue: DispatchQueue,
        timeoutSeconds: Double
    ) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let didResume = ManagedAtomic(false)
            let resumeOnce: @Sendable (Result<NWConnection, Error>) -> Void = { result in
                guard didResume.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
                timer.cancel()
                listener.newConnectionHandler = nil
                switch result {
                case .success(let connection):
                    continuation.resume(returning: connection)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                listener.cancel()
                resumeOnce(.failure(NSError(domain: "BaselineBenchTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                resumeOnce(.success(connection))
            }
        }
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let idx = Int(Double(sorted.count - 1) * p)
        return sorted[idx]
    }
}

private actor UDPChannel {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "BaselineBenchTests", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "No datagram received"
                    ]))
                }
            }
        }
    }
}
