import XCTest
import Foundation
import Network
import Security
import NoiseKit
import Atomics
import SkyBridgeBenchmarkSupport

final class BaselineLoopbackBenchTests: XCTestCase {
    private struct BenchConfig {
        let iterations: Int
        let warmup: Int
        let timeoutSeconds: Double
        let kickoffBytes: Int
        let tlsVersion: tls_protocol_version_t
        let quicAlpn: String
    }

    private struct LoadedIdentity {
        let secIdentity: SecIdentity
        let certificateDER: Data
    }

    private var shouldRunBenchmarks: Bool {
        ProcessInfo.processInfo.environment["BASELINE_RUN_BENCH"] == "1"
    }

    func testLoopbackLifecycleRejectsUnsafeConfiguration() async throws {
        let invalidConfigurations: [(iterations: Int, warmup: Int, timeoutSeconds: Double, kickoffBytes: Int)] = [
            (0, 0, 5, 0),
            (100_000, 1, 5, 0),
            (1, 0, 300.000_1, 0),
            (1, 0, 5, 1_048_577)
        ]

        for configuration in invalidConfigurations {
            do {
                _ = try await NetworkLoopbackLifecycle.measureHandshakes(
                    protocolName: "configuration-validation",
                    serverParameters: .tcp,
                    clientParameters: .tcp,
                    iterations: configuration.iterations,
                    warmup: configuration.warmup,
                    timeoutSeconds: configuration.timeoutSeconds,
                    kickoffBytes: configuration.kickoffBytes
                )
                XCTFail("Unsafe loopback configuration must fail before allocating a listener")
            } catch let error as NetworkLoopbackLifecycleError {
                if case .invalidConfiguration = error {
                    continue
                }
                XCTFail("Expected invalidConfiguration, received \(error)")
            }
        }
    }

    func testLoopbackLifecycleCancellationFailsAfterCleanup() async throws {
        let operation = Task {
            try await NetworkLoopbackLifecycle.measureHandshakes(
                protocolName: "cancellation",
                serverParameters: .tcp,
                clientParameters: .tcp,
                iterations: 10_000,
                warmup: 0,
                timeoutSeconds: 5,
                kickoffBytes: 1
            )
        }
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("A cancelled benchmark must not return successful samples")
        } catch let error as NetworkLoopbackLifecycleError {
            XCTAssertTrue(error.description.contains("task cancelled"), "Unexpected cancellation error: \(error)")
        }
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
            certificatePath: "Tests/Fixtures/loopback_test_server_certificate.der",
            privateKeyPath: "Tests/Fixtures/loopback_test_server_private_key.x963"
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

    func testLoopbackConnectionTeardownStress() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set BASELINE_RUN_BENCH=1 to run loopback baselines")

        let standardConfig = BenchConfig(
            iterations: 50,
            warmup: 5,
            timeoutSeconds: 5.0,
            kickoffBytes: 1,
            tlsVersion: .TLSv13,
            quicAlpn: "sbq"
        )
        let dtlsStressConfig = BenchConfig(
            iterations: 256,
            warmup: 5,
            timeoutSeconds: 5.0,
            kickoffBytes: 1,
            tlsVersion: .TLSv13,
            quicAlpn: "sbq"
        )
        let identity = try loadIdentity(
            certificatePath: "Tests/Fixtures/loopback_test_server_certificate.der",
            privateKeyPath: "Tests/Fixtures/loopback_test_server_private_key.x963"
        )

        let tls = try await runTLSBench(config: standardConfig, identity: identity)
        let quic = try await runQUICBench(config: standardConfig, identity: identity)
        let dtls = try await runDTLSBench(config: dtlsStressConfig, identity: identity)

        XCTAssertEqual(tls.count, standardConfig.iterations)
        XCTAssertEqual(quic.count, standardConfig.iterations)
        XCTAssertEqual(dtls.count, dtlsStressConfig.iterations)
    }

    private func reportStats(label: String, samples: [Double]) {
        XCTAssertFalse(samples.isEmpty, "\(label) produced no samples")
        let p50 = percentile(samples, p: 0.50)
        let p95 = percentile(samples, p: 0.95)
        print("[BASELINE] \(label) p50=\(String(format: "%.2f", p50)) ms p95=\(String(format: "%.2f", p95)) ms")
    }

    private func runTLSBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [Double] {
        let tlsOptions = makeTLSOptions(identity: identity, isServer: true, version: config.tlsVersion)
        let serverParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: config.tlsVersion)
        let clientParams = NWParameters(tls: clientTlsOptions, tcp: NWProtocolTCP.Options())

        return try await runNWHandshakeBench(
            protocolName: "TLS13",
            serverParameters: serverParams,
            clientParameters: clientParams,
            config: config
        )
    }

    private func runQUICBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [Double] {
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
            peerAuthenticationRequired: true,
            useVerifyBlock: true
        )
        let clientParams = NWParameters(quic: clientQuicOptions)

        return try await runNWHandshakeBench(
            protocolName: "QUIC",
            serverParameters: serverParams,
            clientParameters: clientParams,
            config: config
        )
    }

    private func runDTLSBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [Double] {
        let serverTlsOptions = makeTLSOptions(identity: identity, isServer: true, version: .DTLSv12, alpn: "webrtc")
        let serverParams = NWParameters(dtls: serverTlsOptions, udp: NWProtocolUDP.Options())

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: .DTLSv12, alpn: "webrtc")
        let clientParams = NWParameters(dtls: clientTlsOptions, udp: NWProtocolUDP.Options())

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
        defer {
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        let serverConnectionStream = Self.makeSingleConnectionStream(
            listener: listener,
            queue: queue,
            timeoutSeconds: config.timeoutSeconds
        )
        var serverConnectionIterator = serverConnectionStream.makeAsyncIterator()
        try await Self.startListenerAndWaitUntilReady(
            listener: listener,
            queue: queue,
            timeoutSeconds: config.timeoutSeconds
        )
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
        defer { clientConnection.cancel() }
        clientConnection.start(queue: queue)

        let clientChannel = UDPChannel(connection: clientConnection)
        try await clientChannel.send(Data([0x00]))
        guard let serverConnection = try await serverConnectionIterator.next() else {
            throw NSError(domain: "BaselineBenchTests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Listener did not accept a connection"
            ])
        }
        defer { serverConnection.cancel() }
        let serverChannel = UDPChannel(connection: serverConnection)
        _ = try await serverChannel.receive()

        let initiatorStatic = NoiseXX.makeStaticKeyPair()
        let responderStatic = NoiseXX.makeStaticKeyPair()

        var samples: [Double] = []
        for iteration in 0..<(config.warmup + config.iterations) {
            let start = ContinuousClock.now
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
            let elapsed = ContinuousClock.now - start
            if iteration >= config.warmup {
                samples.append(Self.durationToMilliseconds(elapsed))
            }
        }

        return samples
    }

    private func runNWHandshakeBench(
        protocolName: String,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        config: BenchConfig
    ) async throws -> [Double] {
        let lifecycleSamples = try await NetworkLoopbackLifecycle.measureHandshakes(
            protocolName: protocolName,
            serverParameters: serverParameters,
            clientParameters: clientParameters,
            iterations: config.iterations,
            warmup: config.warmup,
            timeoutSeconds: config.timeoutSeconds,
            kickoffBytes: config.kickoffBytes
        )
        return lifecycleSamples.map { Self.durationToMilliseconds($0.readyDuration) }
    }

    private func loadIdentity(
        certificatePath: String,
        privateKeyPath: String
    ) throws -> LoadedIdentity {
        let certificateData = try Data(contentsOf: URL(fileURLWithPath: certificatePath))
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw NSError(domain: "BaselineBenchTests", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Invalid loopback certificate DER: \(certificatePath)"
            ])
        }

        let privateKeyData = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyData as CFData,
            attributes as CFDictionary,
            &keyError
        ) else {
            let underlyingError = keyError?.takeRetainedValue()
            throw NSError(domain: "BaselineBenchTests", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Invalid loopback private-key representation: \(privateKeyPath)",
                NSUnderlyingErrorKey: underlyingError as Any
            ])
        }

        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw NSError(domain: "BaselineBenchTests", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Loopback certificate and private key do not match"
            ])
        }
        return LoadedIdentity(secIdentity: identity, certificateDER: certificateData)
    }

    private func makeTLSOptions(
        identity: LoadedIdentity,
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
            peerAuthenticationRequired: !isServer,
            useVerifyBlock: true
        )
        return tlsOptions
    }

    private func configureTLSOptions(
        _ secOptions: sec_protocol_options_t,
        identity: LoadedIdentity,
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

        sec_protocol_options_set_peer_authentication_required(secOptions, peerAuthenticationRequired)

        if isServer {
            if let secIdentity = sec_identity_create(identity.secIdentity) {
                sec_protocol_options_set_local_identity(secOptions, secIdentity)
            }
        } else {
            if let serverName {
                serverName.utf8CString.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    sec_protocol_options_set_tls_server_name(secOptions, base)
                }
            }
            if useVerifyBlock {
                let expectedCertificateDER = identity.certificateDER
                sec_protocol_options_set_verify_block(secOptions, { _, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                          let leafCertificate = chain.first else {
                        complete(false)
                        return
                    }
                    let actualCertificateDER = SecCertificateCopyData(leafCertificate) as Data
                    complete(actualCertificateDER == expectedCertificateDER)
                }, .global())
            }
        }
    }

    private static func durationToMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
    }

    private static func startListenerAndWaitUntilReady(
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
            listener.start(queue: queue)
        }
    }

    private static func makeSingleConnectionStream(
        listener: NWListener,
        queue: DispatchQueue,
        timeoutSeconds: Double
    ) -> AsyncThrowingStream<NWConnection, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let didFinish = ManagedAtomic(false)
            let finishOnce: @Sendable (Result<NWConnection, Error>) -> Void = { result in
                guard didFinish.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
                timer.cancel()
                listener.newConnectionHandler = nil
                switch result {
                case .success(let connection):
                    connection.start(queue: queue)
                    continuation.yield(connection)
                    continuation.finish()
                case .failure(let error):
                    listener.cancel()
                    continuation.finish(throwing: error)
                }
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                finishOnce(.failure(NSError(domain: "BaselineBenchTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            listener.newConnectionHandler = { connection in
                finishOnce(.success(connection))
            }
            continuation.onTermination = { _ in
                guard didFinish.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
                timer.cancel()
                listener.newConnectionHandler = nil
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
