import Foundation
import Atomics
import Network
import Security
import SkyBridgeCore
import SkyBridgeBenchmarkSupport
import NoiseKit

@main
struct BaselineBenchRunner {
    private enum BenchConfigurationError: Error, CustomStringConvertible {
        case invalidEnvironmentValue(key: String, value: String, expected: String)

        var description: String {
            switch self {
            case .invalidEnvironmentValue(let key, let value, let expected):
                return "invalid \(key)=\(value.debugDescription); expected \(expected)"
            }
        }
    }

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
        let certificatePath: String
        let privateKeyPath: String
        let protocolFilter: Set<String>?
        let kickoffBytes: Int
        let tlsVersion: tls_protocol_version_t
        let quicAlpn: String
    }

    struct LoadedIdentity {
        let secIdentity: SecIdentity
        let certificateDER: Data
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
            let config = try makeConfig()
            if debugEnabled() {
                let env = ProcessInfo.processInfo.environment
                print("[BASELINE] ENV BASELINE_PROTOCOLS=\(env["BASELINE_PROTOCOLS"] ?? "<nil>")")
            }
            let needsIdentity = shouldRun("TLS13", filter: config.protocolFilter)
                || shouldRun("QUIC", filter: config.protocolFilter)
                || shouldRun("WebRTC-DTLS", filter: config.protocolFilter)
            let identity = needsIdentity
                ? try loadIdentity(
                    certificatePath: config.certificatePath,
                    privateKeyPath: config.privateKeyPath
                )
                : nil

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

            try validateTimingSamples(samples, config: config)
            try writeTimings(samples, to: config.outputPath)
            print("[BASELINE] Wrote timings to \(config.outputPath)")
        } catch {
            fputs("[BASELINE] Failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func makeConfig() throws -> BenchConfig {
        let env = ProcessInfo.processInfo.environment
        let iterations = try intEnv(env, "BASELINE_ITERATIONS", defaultValue: 200)
        let warmup = try intEnv(env, "BASELINE_WARMUP", defaultValue: 10)
        let timeoutSeconds = try doubleEnv(env, "BASELINE_TIMEOUT_SECONDS", defaultValue: 5.0)

        guard (1...100_000).contains(iterations) else {
            throw invalidConfiguration(
                key: "BASELINE_ITERATIONS",
                value: String(iterations),
                expected: "an integer between 1 and 100000"
            )
        }
        guard (0...100_000).contains(warmup) else {
            throw invalidConfiguration(
                key: "BASELINE_WARMUP",
                value: String(warmup),
                expected: "an integer between 0 and 100000"
            )
        }
        let (totalIterations, iterationOverflow) = iterations.addingReportingOverflow(warmup)
        guard !iterationOverflow, totalIterations <= 100_000 else {
            throw invalidConfiguration(
                key: "BASELINE_ITERATIONS+BASELINE_WARMUP",
                value: "\(iterations)+\(warmup)",
                expected: "a total no greater than 100000"
            )
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300 else {
            throw invalidConfiguration(
                key: "BASELINE_TIMEOUT_SECONDS",
                value: String(timeoutSeconds),
                expected: "a finite number greater than 0 and no greater than 300"
            )
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let outputPath = env["BASELINE_OUTPUT"] ?? "Artifacts/baseline_timings_\(dateString).csv"

        let tlsPort = try portEnv(env, "BASELINE_TLS_PORT", defaultValue: 9443)
        let quicPort = try portEnv(env, "BASELINE_QUIC_PORT", defaultValue: 9444)
        let dtlsPort = try portEnv(env, "BASELINE_DTLS_PORT", defaultValue: 9445)
        let noisePort = try portEnv(env, "BASELINE_NOISE_PORT", defaultValue: 9446)
        let skybridgePort = try portEnv(env, "BASELINE_SKYBRIDGE_PORT", defaultValue: 9447)

        let certificatePath = env["BASELINE_CERTIFICATE_PATH"]
            ?? "Tests/Fixtures/loopback_test_server_certificate.der"
        let privateKeyPath = env["BASELINE_PRIVATE_KEY_PATH"]
            ?? "Tests/Fixtures/loopback_test_server_private_key.x963"
        let protocolFilter = try parseProtocolFilter(env["BASELINE_PROTOCOLS"])
        let kickoffBytes = try intEnv(env, "BASELINE_KICKOFF_BYTES", defaultValue: 0)
        guard (0...1_048_576).contains(kickoffBytes) else {
            throw invalidConfiguration(
                key: "BASELINE_KICKOFF_BYTES",
                value: String(kickoffBytes),
                expected: "an integer between 0 and 1048576"
            )
        }
        let tlsVersion: tls_protocol_version_t
        if let rawTLSVersion = env["BASELINE_TLS_VERSION"] {
            guard let parsedTLSVersion = parseTLSVersion(rawTLSVersion) else {
                throw invalidConfiguration(
                    key: "BASELINE_TLS_VERSION",
                    value: rawTLSVersion,
                    expected: "TLS 1.2 or TLS 1.3"
                )
            }
            tlsVersion = parsedTLSVersion
        } else {
            tlsVersion = .TLSv13
        }
        let quicAlpn = env["BASELINE_QUIC_ALPN"] ?? "sbq"
        guard (1...255).contains(quicAlpn.utf8.count) else {
            throw invalidConfiguration(
                key: "BASELINE_QUIC_ALPN",
                value: quicAlpn,
                expected: "a non-empty protocol identifier of at most 255 UTF-8 bytes"
            )
        }

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
            certificatePath: certificatePath,
            privateKeyPath: privateKeyPath,
            protocolFilter: protocolFilter,
            kickoffBytes: kickoffBytes,
            tlsVersion: tlsVersion,
            quicAlpn: quicAlpn
        )
    }

    private static func invalidConfiguration(
        key: String,
        value: String,
        expected: String
    ) -> BenchConfigurationError {
        .invalidEnvironmentValue(key: key, value: value, expected: expected)
    }

    private static func intEnv(
        _ env: [String: String],
        _ key: String,
        defaultValue: Int
    ) throws -> Int {
        guard let raw = env[key] else { return defaultValue }
        guard let value = Int(raw) else {
            throw invalidConfiguration(key: key, value: raw, expected: "an integer")
        }
        return value
    }

    private static func doubleEnv(
        _ env: [String: String],
        _ key: String,
        defaultValue: Double
    ) throws -> Double {
        guard let raw = env[key] else { return defaultValue }
        guard let value = Double(raw), value.isFinite else {
            throw invalidConfiguration(key: key, value: raw, expected: "a finite number")
        }
        return value
    }

    private static func portEnv(
        _ env: [String: String],
        _ key: String,
        defaultValue: UInt16
    ) throws -> UInt16 {
        let value = try intEnv(env, key, defaultValue: Int(defaultValue))
        guard let port = UInt16(exactly: value), port != 0 else {
            throw invalidConfiguration(key: key, value: String(value), expected: "an integer from 1 through 65535")
        }
        return port
    }

    private static func boolEnv(
        _ env: [String: String],
        _ key: String,
        defaultValue: Bool
    ) throws -> Bool {
        guard let raw = env[key]?.lowercased() else { return defaultValue }
        if ["1", "true", "yes", "y"].contains(raw) { return true }
        if ["0", "false", "no", "n"].contains(raw) { return false }
        throw invalidConfiguration(key: key, value: raw, expected: "one of 1, true, yes, y, 0, false, no, n")
    }

    private static func parseProtocolFilter(_ value: String?) throws -> Set<String>? {
        guard let value else { return nil }

        let aliases: [String: String] = [
            "tcp": "tcp",
            "tls13": "tls13",
            "tls-13": "tls13",
            "quic": "quic",
            "webrtc-dtls": "webrtc-dtls",
            "dtls": "webrtc-dtls",
            "noise-xx": "noise-xx",
            "noise": "noise-xx",
            "skybridge": "skybridge",
            "skybridge-classic": "skybridge-classic",
            "skybridge-liboqs": "skybridge-liboqs",
            "skybridge-cryptokit": "skybridge-cryptokit"
        ]
        let rawTokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !rawTokens.isEmpty else {
            throw invalidConfiguration(
                key: "BASELINE_PROTOCOLS",
                value: value,
                expected: "a comma-separated list of known protocol names"
            )
        }

        var protocols = Set<String>()
        for rawToken in rawTokens {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty, let canonical = aliases[token] else {
                throw invalidConfiguration(
                    key: "BASELINE_PROTOCOLS",
                    value: value,
                    expected: "TCP, TLS13, QUIC, WebRTC-DTLS, Noise-XX, SkyBridge, SkyBridge-Classic, SkyBridge-liboqs, or SkyBridge-CryptoKit"
                )
            }
            protocols.insert(canonical)
        }
        return protocols
    }

    private static func shouldRun(_ label: String, filter: Set<String>?) -> Bool {
        guard let filter else { return true }
        return filter.contains(label.lowercased())
    }

    private static func validateTimingSamples(
        _ samples: [TimingSample],
        config: BenchConfig
    ) throws {
        var expectedLabels = Set<String>()
        let filter = config.protocolFilter

        if filter == nil || filter?.contains("tls13") == true {
            expectedLabels.insert("TLS13")
        }
        if filter == nil || filter?.contains("quic") == true {
            expectedLabels.insert("QUIC")
        }
        if filter == nil || filter?.contains("webrtc-dtls") == true {
            expectedLabels.insert("WebRTC-DTLS")
        }
        if filter == nil || filter?.contains("noise-xx") == true {
            expectedLabels.insert("Noise-XX")
        }
        if filter?.contains("tcp") == true {
            expectedLabels.insert("TCP")
        }

        let allSkyBridge = filter == nil || filter?.contains("skybridge") == true
        if allSkyBridge || filter?.contains("skybridge-classic") == true {
            expectedLabels.insert("SkyBridge-Classic")
        }
        if allSkyBridge || filter?.contains("skybridge-liboqs") == true {
            expectedLabels.insert("SkyBridge-liboqs")
        }
        if allSkyBridge || filter?.contains("skybridge-cryptokit") == true {
            #if HAS_APPLE_PQC_SDK
            expectedLabels.insert("SkyBridge-CryptoKit")
            #else
            throw NoiseError.handshakeFailed(
                "SkyBridge-CryptoKit evidence was requested but HAS_APPLE_PQC_SDK is not compiled"
            )
            #endif
        }

        guard !expectedLabels.isEmpty else {
            throw invalidConfiguration(
                key: "BASELINE_PROTOCOLS",
                value: config.protocolFilter?.sorted().joined(separator: ",") ?? "<default>",
                expected: "at least one runnable protocol"
            )
        }

        let actualLabels = Set(samples.map(\.protocolName))
        guard actualLabels == expectedLabels else {
            let missing = expectedLabels.subtracting(actualLabels).sorted().joined(separator: ",")
            let unexpected = actualLabels.subtracting(expectedLabels).sorted().joined(separator: ",")
            throw NoiseError.handshakeFailed(
                "baseline evidence label mismatch: missing=[\(missing)] unexpected=[\(unexpected)]"
            )
        }

        for label in expectedLabels {
            let labelSamples = samples.filter { $0.protocolName == label }
            guard labelSamples.count == config.iterations else {
                throw NoiseError.handshakeFailed(
                    "baseline evidence count mismatch for \(label): expected \(config.iterations), got \(labelSamples.count)"
                )
            }
            let actualIterations = Set(labelSamples.map(\.iteration))
            let expectedIterations = Set(0..<config.iterations)
            guard actualIterations == expectedIterations else {
                throw NoiseError.handshakeFailed(
                    "baseline evidence iteration set mismatch for \(label)"
                )
            }
        }
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

    private static func loadIdentity(
        certificatePath: String,
        privateKeyPath: String
    ) throws -> LoadedIdentity {
        let certificateData = try Data(contentsOf: URL(fileURLWithPath: certificatePath))
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw NSError(domain: "BaselineBench", code: 6, userInfo: [
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
            throw NSError(domain: "BaselineBench", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Invalid loopback private-key representation: \(privateKeyPath)",
                NSUnderlyingErrorKey: underlyingError as Any
            ])
        }

        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw NSError(domain: "BaselineBench", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Loopback certificate and private key do not match"
            ])
        }
        return LoadedIdentity(secIdentity: identity, certificateDER: certificateData)
    }

    private static func makeTLSOptions(
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

    private static func configureTLSOptions(
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

        if let alpn = alpn {
            alpn.utf8CString.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                sec_protocol_options_add_tls_application_protocol(secOptions, base)
            }
        }

        sec_protocol_options_set_peer_authentication_required(secOptions, peerAuthenticationRequired)

        if isServer {
            if let secIdentity = sec_identity_create(identity.secIdentity) {
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

    private static func runTLSBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [TimingSample] {
        guard shouldRun("TLS13", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] TLS13 bench start (iterations=\(config.iterations))")
        let tlsOptions = makeTLSOptions(identity: identity, isServer: true, version: config.tlsVersion)
        let serverParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: config.tlsVersion)
        let clientParams = NWParameters(tls: clientTlsOptions, tcp: NWProtocolTCP.Options())

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

    private static func runQUICBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [TimingSample] {
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
            peerAuthenticationRequired: true,
            useVerifyBlock: true
        )
        let clientParams = NWParameters(quic: clientQuicOptions)

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

    private static func runDTLSBench(config: BenchConfig, identity: LoadedIdentity) async throws -> [TimingSample] {
        guard shouldRun("WebRTC-DTLS", filter: config.protocolFilter) else { return [] }
        print("[BASELINE] WebRTC-DTLS bench start (iterations=\(config.iterations))")
        let serverTlsOptions = makeTLSOptions(identity: identity, isServer: true, version: .DTLSv12, alpn: "webrtc")
        let serverParams = NWParameters(dtls: serverTlsOptions, udp: NWProtocolUDP.Options())
        serverParams.allowLocalEndpointReuse = true

        let clientTlsOptions = makeTLSOptions(identity: identity, isServer: false, version: .DTLSv12, alpn: "webrtc")
        let clientParams = NWParameters(dtls: clientTlsOptions, udp: NWProtocolUDP.Options())

        return try await runNWHandshakeBench(
            protocolName: "WebRTC-DTLS",
            port: config.dtlsPort,
            serverParameters: serverParams,
            clientParameters: clientParams,
            listenerIsolation: .perHandshake,
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
        guard let noisePort = NWEndpoint.Port(rawValue: config.noisePort) else {
            throw NSError(domain: "BaselineBenchRunner", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UDP port: \(config.noisePort)"
            ])
        }
        let listener = try NWListener(using: .udp, on: noisePort)
        defer {
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        let serverConnectionStream = makeSingleConnectionStream(
            listener: listener,
            queue: queue,
            timeoutSeconds: config.timeoutSeconds
        )
        var serverConnectionIterator = serverConnectionStream.makeAsyncIterator()
        try await startListenerAndWaitUntilReady(
            listener: listener,
            queue: queue,
            timeoutSeconds: config.timeoutSeconds
        )
        let clientConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: noisePort),
            using: .udp
        )
        defer { clientConnection.cancel() }
        clientConnection.start(queue: queue)

        let clientChannel = UDPChannel(connection: clientConnection)
        try await clientChannel.send(Data([0x00]))
        guard let serverConnection = try await serverConnectionIterator.next() else {
            throw NSError(domain: "BaselineBench", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Noise listener did not accept a connection"
            ])
        }
        defer { serverConnection.cancel() }
        let serverChannel = UDPChannel(connection: serverConnection)
        _ = try await serverChannel.receive()

        let initiatorStatic = NoiseXX.makeStaticKeyPair()
        let responderStatic = NoiseXX.makeStaticKeyPair()

        var samples: [TimingSample] = []
        for iteration in 0..<(config.warmup + config.iterations) {
            let startEpoch = Date().timeIntervalSince1970
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
            let endEpoch = Date().timeIntervalSince1970
            if iteration >= config.warmup {
                samples.append(TimingSample(
                    protocolName: "Noise-XX",
                    iteration: iteration - config.warmup,
                    startEpoch: startEpoch,
                    endEpoch: endEpoch,
                    durationMs: durationToSeconds(elapsed) * 1_000.0,
                    ports: "\(config.noisePort)"
                ))
            }
        }

        print("[BASELINE] Noise-XX bench done")
        return samples
    }

    private static func runNWHandshakeBench(
        protocolName: String,
        port: UInt16,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        listenerIsolation: NetworkLoopbackListenerIsolation = .sharedAcrossHandshakes,
        iterations: Int,
        warmup: Int,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws -> [TimingSample] {
        guard let benchmarkPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "BaselineBenchRunner", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid benchmark port: \(port)"
            ])
        }
        let lifecycleSamples = try await NetworkLoopbackLifecycle.measureHandshakes(
            protocolName: protocolName,
            serverParameters: serverParameters,
            clientParameters: clientParameters,
            listenerPort: benchmarkPort,
            listenerIsolation: listenerIsolation,
            iterations: iterations,
            warmup: warmup,
            timeoutSeconds: timeoutSeconds,
            kickoffBytes: kickoffBytes
        )

        print("[BASELINE] \(protocolName) bench done")
        return lifecycleSamples.map { sample in
            TimingSample(
                protocolName: protocolName,
                iteration: sample.iteration,
                startEpoch: sample.startEpoch,
                endEpoch: sample.endEpoch,
                durationMs: durationToSeconds(sample.readyDuration) * 1_000.0,
                ports: "\(port)"
            )
        }
    }

    private static func runTCPBench(config: BenchConfig) async throws -> [TimingSample] {
        guard let filter = config.protocolFilter, shouldRun("TCP", filter: filter) else { return [] }
        print("[BASELINE] TCP bench start (iterations=\(config.iterations))")
        let serverParams = NWParameters.tcp
        serverParams.allowLocalEndpointReuse = true
        let clientParams = NWParameters.tcp

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

        let contexts = try await makeSkyBridgeContexts(filter: filter)
        var samples: [TimingSample] = []
        let useHandshakeMetrics = try boolEnv(
            ProcessInfo.processInfo.environment,
            "BASELINE_USE_HANDSHAKE_METRICS",
            defaultValue: false
        )
        let reuseSkyBridgeConnections = try boolEnv(
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
                    trustProvider: context.trustProviderInitiator,
                    kemIdentityStore: context.kemIdentityStore
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
                    trustProvider: context.trustProviderResponder,
                    kemIdentityStore: context.kemIdentityStore
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
        let kemIdentityStore: BenchmarkHandshakeKEMIdentityStore
        let handshakePolicy: HandshakePolicy
        let handshakeTimeout: Duration
    }

    @available(macOS 14.0, *)
    private static func makeSkyBridgeContexts(filter: Set<String>?) async throws -> [SkyBridgeContext] {
        var contexts: [SkyBridgeContext] = []
        let runAll = shouldRun("SkyBridge", filter: filter)
        func shouldAttempt(_ label: String) -> Bool {
            runAll || shouldRun(label, filter: filter)
        }

        if shouldAttempt("SkyBridge-Classic") {
            contexts.append(try await prepareSkyBridgeContext(
                label: "SkyBridge-Classic",
                providerType: .classic
            ))
        }

        if shouldAttempt("SkyBridge-liboqs") {
            contexts.append(try await prepareSkyBridgeContext(
                label: "SkyBridge-liboqs",
                providerType: .liboqs
            ))
        }

        if shouldAttempt("SkyBridge-CryptoKit") {
            #if HAS_APPLE_PQC_SDK
            contexts.append(try await prepareSkyBridgeContext(
                label: "SkyBridge-CryptoKit",
                providerType: .applePQC
            ))
            #else
            throw NoiseError.handshakeFailed(
                "SkyBridge-CryptoKit was requested but HAS_APPLE_PQC_SDK is not compiled"
            )
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

        let offeredSuites: [CryptoSuite]
        switch providerType {
        case .classic:
            let result = TwoAttemptHandshakeManager.getSuites(
                for: .classicOnly,
                cryptoProvider: provider
            )
            guard case .suites(let suites) = result else {
                throw NoiseError.handshakeFailed("empty offered suites")
            }
            offeredSuites = suites
        case .liboqs, .applePQC:
            offeredSuites = [.mlkem768MLDSA65]
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
        let kemIdentityStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: offeredSuites,
            provider: provider
        )
        let peerKEMPublicKeys = try kemIdentityStore.trustPublicKeys(for: offeredSuites)
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

        let overrideTimeout = try doubleEnv(
            ProcessInfo.processInfo.environment,
            "BASELINE_SKYBRIDGE_TIMEOUT_SECONDS",
            defaultValue: 0
        )
        guard overrideTimeout >= 0, overrideTimeout <= 300 else {
            throw invalidConfiguration(
                key: "BASELINE_SKYBRIDGE_TIMEOUT_SECONDS",
                value: String(overrideTimeout),
                expected: "a finite number between 0 and 300"
            )
        }
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
            kemIdentityStore: kemIdentityStore,
            handshakePolicy: handshakePolicy,
            handshakeTimeout: handshakeTimeout
        )
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

    private static func startListenerAndWaitUntilReady(
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
            listener.start(queue: queue)
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

    private static func makeSingleConnectionStream(
        listener: NWListener,
        queue: DispatchQueue,
        timeoutSeconds: Double
    ) -> AsyncThrowingStream<NWConnection, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let didFinish = ManagedAtomic(false)
            let finishOnce: @Sendable (Result<NWConnection, Error>) -> Void = { result in
                if didFinish.exchange(true, ordering: .relaxed) { return }
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
                finishOnce(.failure(NSError(domain: "BaselineBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out after \(timeoutSeconds)s"
                ])))
            }
            timer.activate()

            listener.newConnectionHandler = { connection in
                finishOnce(.success(connection))
            }
            continuation.onTermination = { _ in
                if didFinish.exchange(true, ordering: .relaxed) { return }
                timer.cancel()
                listener.newConnectionHandler = nil
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
