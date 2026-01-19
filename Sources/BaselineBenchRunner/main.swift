import Foundation
import Atomics
import Network
import Security
import SkyBridgeCore
import NoiseKit

@main
struct BaselineBenchRunner {
    struct BenchConfig {
        let iterations: Int
        let warmup: Int
        let timeoutSeconds: Double
        let outputPath: String
        let tlsPort: UInt16
        let quicPort: UInt16
        let dtlsPort: UInt16
        let noisePort: UInt16
        let skybridgePort: UInt16
        let p12Path: String
        let p12Password: String
        let protocolFilter: Set<String>?
        let kickoffBytes: Int
        let tlsVersion: tls_protocol_version_t
        let quicAlpn: String
    }

    struct TimingSample {
        let protocolName: String
        let iteration: Int
        let startEpoch: TimeInterval
        let endEpoch: TimeInterval
        let durationMs: Double
        let ports: String
    }

    static func main() async {
        do {
            let config = makeConfig()
            let skipIdentity = boolEnv(ProcessInfo.processInfo.environment, "BASELINE_SKIP_IDENTITY", defaultValue: false)
            if debugEnabled() {
                let env = ProcessInfo.processInfo.environment
                print("[BASELINE] ENV BASELINE_PROTOCOLS=\(env["BASELINE_PROTOCOLS"] ?? "<nil>") BASELINE_SKIP_IDENTITY=\(env["BASELINE_SKIP_IDENTITY"] ?? "<nil>")")
            }
            let needsIdentity = shouldRun("TLS13", filter: config.protocolFilter)
                || shouldRun("QUIC", filter: config.protocolFilter)
                || shouldRun("WebRTC-DTLS", filter: config.protocolFilter)
            var identity: SecIdentity?
            if needsIdentity && !skipIdentity {
                do {
                    identity = try loadIdentity(path: config.p12Path, password: config.p12Password)
                } catch {
                    print("[BASELINE] Skipping TLS/QUIC/DTLS: \(error)")
                }
            } else if needsIdentity && skipIdentity {
                print("[BASELINE] Skipping TLS/QUIC/DTLS: BASELINE_SKIP_IDENTITY=1")
            }

            var samples: [TimingSample] = []

            samples += try await runTCPBench(config: config)
            if let identity {
                samples += try await runTLSBench(config: config, identity: identity)
                samples += try await runQUICBench(config: config, identity: identity)
                samples += try await runDTLSBench(config: config, identity: identity)
            }
            samples += try await runNoiseBench(config: config)
            if #available(macOS 14.0, *) {
                samples += try await runSkyBridgeBench(config: config, filter: config.protocolFilter)
            }

            try writeTimings(samples, to: config.outputPath)
            print("[BASELINE] Wrote timings to \(config.outputPath)")
        } catch {
            fputs("[BASELINE] Failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func makeConfig() -> BenchConfig {
        let env = ProcessInfo.processInfo.environment
        let iterations = intEnv(env, "BASELINE_ITERATIONS", defaultValue: 200)
        let warmup = intEnv(env, "BASELINE_WARMUP", defaultValue: 10)
        let timeoutSeconds = doubleEnv(env, "BASELINE_TIMEOUT_SECONDS", defaultValue: 5.0)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let outputPath = env["BASELINE_OUTPUT"] ?? "Artifacts/baseline_timings_\(dateString).csv"

        let tlsPort = UInt16(intEnv(env, "BASELINE_TLS_PORT", defaultValue: 9443))
        let quicPort = UInt16(intEnv(env, "BASELINE_QUIC_PORT", defaultValue: 9444))
        let dtlsPort = UInt16(intEnv(env, "BASELINE_DTLS_PORT", defaultValue: 9445))
        let noisePort = UInt16(intEnv(env, "BASELINE_NOISE_PORT", defaultValue: 9446))
        let skybridgePort = UInt16(intEnv(env, "BASELINE_SKYBRIDGE_PORT", defaultValue: 9447))

        let p12Path = env["BASELINE_P12_PATH"] ?? "Tests/Fixtures/loopback_identity.p12"
        let p12Password = env["BASELINE_P12_PASSWORD"] ?? "skybridge"
        let protocolFilter = parseProtocolFilter(env["BASELINE_PROTOCOLS"])
        let kickoffBytes = intEnv(env, "BASELINE_KICKOFF_BYTES", defaultValue: 0)
        let tlsVersion = parseTLSVersion(env["BASELINE_TLS_VERSION"]) ?? .TLSv13
        let quicAlpn = env["BASELINE_QUIC_ALPN"] ?? "sbq"

        return BenchConfig(
            iterations: iterations,
            warmup: warmup,
            timeoutSeconds: timeoutSeconds,
            outputPath: outputPath,
            tlsPort: tlsPort,
            quicPort: quicPort,
            dtlsPort: dtlsPort,
            noisePort: noisePort,
            skybridgePort: skybridgePort,
            p12Path: p12Path,
            p12Password: p12Password,
            protocolFilter: protocolFilter,
            kickoffBytes: kickoffBytes,
            tlsVersion: tlsVersion,
            quicAlpn: quicAlpn
        )
    }

    private static func intEnv(_ env: [String: String], _ key: String, defaultValue: Int) -> Int {
        if let raw = env[key], let value = Int(raw) {
            return value
        }
        return defaultValue
    }

    private static func doubleEnv(_ env: [String: String], _ key: String, defaultValue: Double) -> Double {
        if let raw = env[key], let value = Double(raw) {
            return value
        }
        return defaultValue
    }

    private static func boolEnv(_ env: [String: String], _ key: String, defaultValue: Bool) -> Bool {
        guard let raw = env[key]?.lowercased() else { return defaultValue }
        if ["1", "true", "yes", "y"].contains(raw) { return true }
        if ["0", "false", "no", "n"].contains(raw) { return false }
        return defaultValue
    }

    private static func parseProtocolFilter(_ value: String?) -> Set<String>? {
        guard let value, !value.isEmpty else { return nil }
        let items = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : Set(items)
    }

    private static func shouldRun(_ label: String, filter: Set<String>?) -> Bool {
        guard let filter else { return true }
        let normalized = label.lowercased()
        if filter.contains(normalized) { return true }
        return filter.contains { normalized.contains($0) }
    }

    private static func debugEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["BASELINE_DEBUG"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    private static func parseTLSVersion(_ value: String?) -> tls_protocol_version_t? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "1.2", "tls1.2", "tls12":
            return .TLSv12
        case "1.3", "tls1.3", "tls13":
            return .TLSv13
        default:
            return nil
        }
    }

    private static func loadIdentity(path: String, password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        if status == errSecSuccess,
           let array = items as? [[String: Any]],
           let first = array.first,
           let anyIdentity = first[kSecImportItemIdentity as String],
           CFGetTypeID(anyIdentity as CFTypeRef) == SecIdentityGetTypeID() {
            return unsafeDowncast(anyIdentity as AnyObject, to: SecIdentity.self)
        }

        throw NSError(domain: "BaselineBench", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "PKCS#12 import failed (\(status)). Use a legacy PKCS#12 (PBE-SHA1-3DES) via BASELINE_P12_PATH."
        ])
    }

    private static func makeTLSOptions(
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

    private static func configureTLSOptions(
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

        if let alpn = alpn {
            alpn.utf8CString.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                sec_protocol_options_add_tls_application_protocol(secOptions, base)
            }
        }

        if isServer {
            if let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(secOptions, secIdentity)
            } else if debugEnabled() {
                print("[BASELINE] Failed to create sec_identity_t for TLS server")
            }
        } else {
            if let serverName = serverName {
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

    private static func runTLSBench(config: BenchConfig, identity: SecIdentity) async throws -> [TimingSample] {
        guard shouldRun("TLS13", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] TLS13 bench start (iterations=\(config.iterations))")
        let tlsOptions = makeTLSOptions(identity: identity, isServer: true, version: config.tlsVersion)
        let serverParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: config.tlsVersion)
        let clientParams = NWParameters(tls: clientTlsOptions, tcp: NWProtocolTCP.Options())
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "TLS13",
            port: config.tlsPort,
            serverParameters: serverParams,
            clientParameters: clientParams,
            iterations: config.iterations,
            warmup: config.warmup,
            timeoutSeconds: config.timeoutSeconds,
            kickoffBytes: config.kickoffBytes
        )
    }

    private static func runQUICBench(config: BenchConfig, identity: SecIdentity) async throws -> [TimingSample] {
        guard shouldRun("QUIC", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] QUIC bench start (iterations=\(config.iterations))")
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
            port: config.quicPort,
            serverParameters: serverParams,
            clientParameters: clientParams,
            iterations: config.iterations,
            warmup: config.warmup,
            timeoutSeconds: config.timeoutSeconds,
            kickoffBytes: config.kickoffBytes
        )
    }

    private static func runDTLSBench(config: BenchConfig, identity: SecIdentity) async throws -> [TimingSample] {
        guard shouldRun("WebRTC-DTLS", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] WebRTC-DTLS bench start (iterations=\(config.iterations))")
        let serverTlsOptions = makeTLSOptions(identity: identity, isServer: true, version: .DTLSv12, alpn: "webrtc")
        let serverParams = NWParameters(dtls: serverTlsOptions, udp: NWProtocolUDP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: .DTLSv12, alpn: "webrtc")
        let clientParams = NWParameters(dtls: clientTlsOptions, udp: NWProtocolUDP.Options())
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "WebRTC-DTLS",
            port: config.dtlsPort,
            serverParameters: serverParams,
            clientParameters: clientParams,
            iterations: config.iterations,
            warmup: config.warmup,
            timeoutSeconds: config.timeoutSeconds,
            kickoffBytes: config.kickoffBytes
        )
    }

    private static func runNoiseBench(config: BenchConfig) async throws -> [TimingSample] {
        guard shouldRun("Noise-XX", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] Noise-XX bench start (iterations=\(config.iterations))")
        let queue = DispatchQueue(label: "baseline.noise")
        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: config.noisePort)!)
        let clientConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.noisePort)!),
            using: .udp
        )
        listener.start(queue: queue)
        clientConnection.start(queue: queue)

        let clientChannel = UDPChannel(connection: clientConnection)
        let connectionTask = Task {
            try await waitForNewConnection(
                listener: listener,
                queue: queue,
                timeoutSeconds: config.timeoutSeconds
            )
        }
        await Task.yield()
        try await clientChannel.send(Data([0x00]))
        let serverConnection = try await connectionTask.value
        let serverChannel = UDPChannel(connection: serverConnection)
        _ = try await serverChannel.receive()

        let initiatorStatic = NoiseXX.makeStaticKeyPair()
        let responderStatic = NoiseXX.makeStaticKeyPair()

        var samples: [TimingSample] = []
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
                samples.append(TimingSample(
                    protocolName: "Noise-XX",
                    iteration: iteration - config.warmup,
                    startEpoch: start,
                    endEpoch: end,
                    durationMs: (end - start) * 1000.0,
                    ports: "\(config.noisePort)"
                ))
            }
        }

        clientConnection.cancel()
        serverConnection.cancel()
        listener.cancel()
        print("[BASELINE] Noise-XX bench done")
        return samples
    }

    private static func runNWHandshakeBench(
        protocolName: String,
        port: UInt16,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        iterations: Int,
        warmup: Int,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws -> [TimingSample] {
        let queue = DispatchQueue(label: "baseline.\(protocolName.lowercased())")
        let listener = try NWListener(using: serverParameters, on: NWEndpoint.Port(rawValue: port)!)
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
        try await waitForListenerReady(listener: listener, queue: queue, timeoutSeconds: timeoutSeconds)
        try await Task.sleep(for: .milliseconds(10))

        var samples: [TimingSample] = []
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        for iteration in 0..<(warmup + iterations) {
            let connection = NWConnection(to: endpoint, using: clientParameters)
            let start = Date().timeIntervalSince1970
            do {
                try await waitForReady(
                    connection: connection,
                    queue: queue,
                    timeoutSeconds: timeoutSeconds,
                    kickoffBytes: kickoffBytes
                )
            } catch {
                connection.cancel()
                throw NSError(domain: "BaselineBench", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "\(protocolName) ready timeout on iteration \(iteration): \(error)"
                ])
            }
            let end = Date().timeIntervalSince1970
            connection.cancel()
            if iteration >= warmup {
                samples.append(TimingSample(
                    protocolName: protocolName,
                    iteration: iteration - warmup,
                    startEpoch: start,
                    endEpoch: end,
                    durationMs: (end - start) * 1000.0,
                    ports: "\(port)"
                ))
            }
        }

        listener.cancel()
        print("[BASELINE] \(protocolName) bench done")
        return samples
    }

    private static func runTCPBench(config: BenchConfig) async throws -> [TimingSample] {
        guard let filter = config.protocolFilter, shouldRun("TCP", filter: filter) else { return [] }
        print("[BASELINE] TCP bench start (iterations=\(config.iterations))")
        let serverParams = NWParameters.tcp
        serverParams.allowLocalEndpointReuse = true
        let clientParams = NWParameters.tcp
        clientParams.allowLocalEndpointReuse = true

        return try await runNWHandshakeBench(
            protocolName: "TCP",
            port: config.tlsPort,
            serverParameters: serverParams,
            clientParameters: clientParams,
            iterations: config.iterations,
            warmup: config.warmup,
            timeoutSeconds: config.timeoutSeconds,
            kickoffBytes: config.kickoffBytes
        )
    }

    @available(macOS 14.0, *)
    private static func runSkyBridgeBench(
        config: BenchConfig,
        filter: Set<String>?
    ) async throws -> [TimingSample] {
        let shouldRunAny = shouldRun("SkyBridge", filter: filter)
            || shouldRun("SkyBridge-Classic", filter: filter)
            || shouldRun("SkyBridge-liboqs", filter: filter)
            || shouldRun("SkyBridge-CryptoKit", filter: filter)
        guard shouldRunAny else { return [] }

        let contexts = await makeSkyBridgeContexts(filter: filter)
        var samples: [TimingSample] = []
        let useHandshakeMetrics = boolEnv(
            ProcessInfo.processInfo.environment,
            "BASELINE_USE_HANDSHAKE_METRICS",
            defaultValue: false
        )
        let reuseSkyBridgeConnections = boolEnv(
            ProcessInfo.processInfo.environment,
            "BASELINE_REUSE_CONNECTIONS",
            defaultValue: false
        )

        for context in contexts {
            guard shouldRun(context.label, filter: filter) || shouldRun("SkyBridge", filter: filter) else {
                continue
            }
            print("[BASELINE] \(context.label) bench start (iterations=\(config.iterations))")
            let timeoutSeconds = durationToSeconds(context.handshakeTimeout)
            let responderTransport = BonjourDiscoveryTransport()
            _ = try await responderTransport.start(port: config.skybridgePort)
            let initiatorTransport = BonjourDiscoveryTransport()

            for iteration in 0..<(config.warmup + config.iterations) {
                let initiatorDriver = try HandshakeDriver(
                    transport: initiatorTransport,
                    cryptoProvider: context.provider,
                    protocolSignatureProvider: context.protocolSignatureProvider,
                    protocolSigningKeyHandle: context.initiatorKeyHandle,
                    sigAAlgorithm: context.sigAAlgorithm,
                    identityPublicKey: context.initiatorIdentityPublicKey,
                    offeredSuites: context.offeredSuites,
                    policy: context.handshakePolicy,
                    timeout: context.handshakeTimeout,
                    trustProvider: context.trustProviderInitiator
                )

                let responderDriver = try HandshakeDriver(
                    transport: responderTransport,
                    cryptoProvider: context.provider,
                    protocolSignatureProvider: context.protocolSignatureProvider,
                    protocolSigningKeyHandle: context.responderKeyHandle,
                    sigAAlgorithm: context.sigAAlgorithm,
                    identityPublicKey: context.responderIdentityPublicKey,
                    offeredSuites: context.offeredSuites,
                    policy: context.handshakePolicy,
                    timeout: context.handshakeTimeout,
                    trustProvider: context.trustProviderResponder
                )

                let benchPeer = PeerIdentifier(
                    deviceId: "bench-peer",
                    address: "127.0.0.1:\(config.skybridgePort)"
                )

                await initiatorTransport.setMessageHandler { [initiatorDriver] peer, data in
                    let mappedPeer = PeerIdentifier(deviceId: "bench-peer", address: peer.address)
                    await initiatorDriver.handleMessage(data, from: mappedPeer)
                }
                await responderTransport.setMessageHandler { [responderDriver] peer, data in
                    let mappedPeer = PeerIdentifier(deviceId: "bench-peer", address: peer.address)
                    await responderDriver.handleMessage(data, from: mappedPeer)
                }

                let start = Date().timeIntervalSince1970
                do {
                    _ = try await awaitHandshake(
                        driver: initiatorDriver,
                        peer: benchPeer,
                        timeoutSeconds: timeoutSeconds
                    )
                } catch {
                    if debugEnabled() {
                        let state = await initiatorDriver.getCurrentState()
                        let metrics = await initiatorDriver.getLastMetrics()
                        let responderState = await responderDriver.getCurrentState()
                        let responderMetrics = await responderDriver.getLastMetrics()
                        print("[BASELINE] \(context.label) failed at iteration \(iteration): \(error); state=\(state); metrics=\(String(describing: metrics)); responderState=\(responderState); responderMetrics=\(String(describing: responderMetrics))")
                    }
                    throw error
                }
                let end = Date().timeIntervalSince1970

                if !reuseSkyBridgeConnections {
                    await initiatorTransport.closeAllConnections()
                    await responderTransport.closeAllConnections()
                }

                if iteration >= config.warmup {
                    var durationMs = (end - start) * 1000.0
                    if useHandshakeMetrics,
                       let metrics = await initiatorDriver.getLastMetrics(),
                       metrics.handshakeDurationMs >= 0 {
                        durationMs = metrics.handshakeDurationMs
                    }
                    samples.append(TimingSample(
                        protocolName: context.label,
                        iteration: iteration - config.warmup,
                        startEpoch: start,
                        endEpoch: end,
                        durationMs: durationMs,
                        ports: "\(config.skybridgePort)"
                    ))
                }
            }

            await responderTransport.stop()
            await initiatorTransport.stop()
            try await Task.sleep(for: .milliseconds(50))
            print("[BASELINE] \(context.label) bench done")
        }

        return samples
    }

    @available(macOS 14.0, *)
    private struct SkyBridgeContext {
        let label: String
        let provider: any CryptoProvider
        let offeredSuites: [CryptoSuite]
        let protocolSignatureProvider: any ProtocolSignatureProvider
        let sigAAlgorithm: ProtocolSigningAlgorithm
        let initiatorKeyHandle: SigningKeyHandle
        let responderKeyHandle: SigningKeyHandle
        let initiatorIdentityPublicKey: Data
        let responderIdentityPublicKey: Data
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        let handshakePolicy: HandshakePolicy
        let handshakeTimeout: Duration
    }

    @available(macOS 14.0, *)
    private static func makeSkyBridgeContexts(filter: Set<String>?) async -> [SkyBridgeContext] {
        var contexts: [SkyBridgeContext] = []
        let runAll = shouldRun("SkyBridge", filter: filter)
        func shouldAttempt(_ label: String) -> Bool {
            runAll || shouldRun(label, filter: filter)
        }

        if shouldAttempt("SkyBridge-Classic") {
            do {
                contexts.append(try await prepareSkyBridgeContext(label: "SkyBridge-Classic", providerType: .classic))
            } catch {
                print("[BASELINE] Skipping SkyBridge-Classic: \(error)")
            }
        }

        if shouldAttempt("SkyBridge-liboqs") {
            do {
                contexts.append(try await prepareSkyBridgeContext(label: "SkyBridge-liboqs", providerType: .liboqs))
            } catch {
                print("[BASELINE] Skipping SkyBridge-liboqs: \(error)")
            }
        }

        if shouldAttempt("SkyBridge-CryptoKit") {
            #if HAS_APPLE_PQC_SDK
            do {
                contexts.append(try await prepareSkyBridgeContext(label: "SkyBridge-CryptoKit", providerType: .applePQC))
            } catch {
                print("[BASELINE] Skipping SkyBridge-CryptoKit: \(error)")
            }
            #else
            print("[BASELINE] Skipping SkyBridge-CryptoKit: Apple PQC SDK not available")
            #endif
        }
        return contexts
    }

    @available(macOS 14.0, *)
    private enum SkyBridgeProviderType {
        case classic
        case liboqs
        case applePQC
    }

    @available(macOS 14.0, *)
    private static func prepareSkyBridgeContext(
        label: String,
        providerType: SkyBridgeProviderType
    ) async throws -> SkyBridgeContext {
        let provider: any CryptoProvider
        switch providerType {
        case .classic:
            provider = ClassicCryptoProvider()
        case .liboqs:
            #if canImport(OQSRAII)
            provider = OQSPQCCryptoProvider()
            #else
            throw NoiseError.handshakeFailed("liboqs not available")
            #endif
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = ApplePQCCryptoProvider()
            } else {
                throw NoiseError.handshakeFailed("Apple PQC not available")
            }
            #else
            throw NoiseError.handshakeFailed("Apple PQC SDK not available")
            #endif
        }

        let strategy: HandshakeAttemptStrategy = (providerType == .classic) ? .classicOnly : .pqcOnly
        let suitesResult = TwoAttemptHandshakeManager.getSuites(for: strategy, cryptoProvider: provider)
        guard case .suites(let offeredSuites) = suitesResult else {
            throw NoiseError.handshakeFailed("empty offered suites")
        }

        let protocolSignatureProvider = ProtocolSignatureProviderSelector.select(for: provider.tier)
        let sigAAlgorithm = protocolSignatureProvider.signatureAlgorithm

        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderKeyPair = try await provider.generateKeyPair(for: .signing)

        let initiatorKeyHandle = SigningKeyHandle.softwareKey(initiatorKeyPair.privateKey.bytes)
        let responderKeyHandle = SigningKeyHandle.softwareKey(responderKeyPair.privateKey.bytes)

        let initiatorIdentityPublicKey = encodeIdentityPublicKey(
            initiatorKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )
        let responderIdentityPublicKey = encodeIdentityPublicKey(
            responderKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )

        let peer = PeerIdentifier(deviceId: "bench-peer")
        let peerKEMPublicKeys = try await makeKEMPublicKeysForPeer(
            offeredSuites: offeredSuites,
            provider: provider
        )
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        if peerKEMPublicKeys.isEmpty {
            trustProviderInitiator = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
            trustProviderResponder = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
        } else {
            trustProviderInitiator = StaticTrustProviderWithKEM(
                deviceId: peer.deviceId,
                kemPublicKeys: peerKEMPublicKeys
            )
            trustProviderResponder = StaticTrustProviderWithKEM(
                deviceId: peer.deviceId,
                kemPublicKeys: peerKEMPublicKeys
            )
        }

        let overrideTimeout = doubleEnv(
            ProcessInfo.processInfo.environment,
            "BASELINE_SKYBRIDGE_TIMEOUT_SECONDS",
            defaultValue: 0
        )
        let handshakeTimeout: Duration
        if overrideTimeout > 0 {
            handshakeTimeout = .milliseconds(Int(overrideTimeout * 1000))
        } else {
            handshakeTimeout = (providerType == .classic) ? .seconds(15) : .seconds(25)
        }
        let handshakePolicy: HandshakePolicy = (providerType == .classic) ? .default : .strictPQC

        return SkyBridgeContext(
            label: label,
            provider: provider,
            offeredSuites: offeredSuites,
            protocolSignatureProvider: protocolSignatureProvider,
            sigAAlgorithm: sigAAlgorithm,
            initiatorKeyHandle: initiatorKeyHandle,
            responderKeyHandle: responderKeyHandle,
            initiatorIdentityPublicKey: initiatorIdentityPublicKey,
            responderIdentityPublicKey: responderIdentityPublicKey,
            trustProviderInitiator: trustProviderInitiator,
            trustProviderResponder: trustProviderResponder,
            handshakePolicy: handshakePolicy,
            handshakeTimeout: handshakeTimeout
        )
    }

    @available(macOS 14.0, *)
    private static func makeKEMPublicKeysForPeer(
        offeredSuites: [CryptoSuite],
        provider: any CryptoProvider
    ) async throws -> [CryptoSuite: Data] {
        let pqcSuites = offeredSuites.filter { $0.isPQC }
        guard !pqcSuites.isEmpty else {
            return [:]
        }

        var kemPublicKeys: [CryptoSuite: Data] = [:]
        for suite in pqcSuites {
            let publicKey = try await DeviceIdentityKeyManager.shared.getKEMPublicKey(
                for: suite,
                provider: provider
            )
            kemPublicKeys[suite] = publicKey
        }
        return kemPublicKeys
    }

    private static func encodeIdentityPublicKey(
        _ publicKey: Data,
        algorithm: SignatureAlgorithm
    ) -> Data {
        IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: algorithm,
            secureEnclavePublicKey: nil
        ).encoded
    }

    @available(macOS 14.0, *)
    private struct StaticTrustProvider: HandshakeTrustProvider, Sendable {
        let deviceId: String
        let fingerprint: String?

        func trustedFingerprint(for deviceId: String) async -> String? {
            guard deviceId == self.deviceId else { return nil }
            return fingerprint
        }

        func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
            [:]
        }

        func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
            nil
        }
    }

    @available(macOS 14.0, *)
    private struct StaticTrustProviderWithKEM: HandshakeTrustProvider, Sendable {
        let deviceId: String
        let kemPublicKeys: [CryptoSuite: Data]

        func trustedFingerprint(for deviceId: String) async -> String? {
            nil
        }

        func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
            guard deviceId == self.deviceId else { return [:] }
            return kemPublicKeys
        }

        func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
            nil
        }
    }

    private static func writeTimings(_ samples: [TimingSample], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var content = "protocol,iteration,start_epoch,end_epoch,duration_ms,ports\n"
        for sample in samples {
            content += "\(sample.protocolName),\(sample.iteration),\(sample.startEpoch),\(sample.endEpoch),\(sample.durationMs),\(sample.ports)\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func durationToSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000.0)
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
                if didResume.exchange(true, ordering: .relaxed) { return }
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
                resumeOnce(.failure(NSError(domain: "BaselineBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            connection.stateUpdateHandler = { state in
                if debugEnabled() {
                    print("[BASELINE] connection state: \(state)")
                }
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(NSError(domain: "BaselineBench", code: 1, userInfo: [
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
                if didResume.exchange(true, ordering: .relaxed) { return }
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
                resumeOnce(.failure(NSError(domain: "BaselineBench", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Listener timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            listener.stateUpdateHandler = { state in
                if debugEnabled() {
                    print("[BASELINE] listener state: \(state)")
                }
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(NSError(domain: "BaselineBench", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Listener cancelled"
                    ])))
                default:
                    break
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func awaitHandshake(
        driver: HandshakeDriver,
        peer: PeerIdentifier,
        timeoutSeconds: Double
    ) async throws -> SessionKeys {
        try await withThrowingTaskGroup(of: SessionKeys.self) { group in
            group.addTask {
                try await driver.initiateHandshake(with: peer)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(domain: "BaselineBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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
                if didResume.exchange(true, ordering: .relaxed) { return }
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
                resumeOnce(.failure(NSError(domain: "BaselineBench", code: 2, userInfo: [
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
                    continuation.resume(throwing: NSError(domain: "BaselineBench", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Empty UDP message"
                    ]))
                }
            }
        }
    }
}
