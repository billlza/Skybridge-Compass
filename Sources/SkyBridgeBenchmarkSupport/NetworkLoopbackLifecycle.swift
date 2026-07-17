import Dispatch
import Foundation
import Network

public enum NetworkLoopbackLifecycleError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case listener(protocolName: String, stage: String, detail: String)
    case accept(protocolName: String, iteration: Int?, detail: String)
    case connection(protocolName: String, iteration: Int, role: String, stage: String, detail: String)
    case invariantViolation(String)
    case operationAndCleanup(operation: String, cleanup: String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            return "invalid loopback configuration: \(detail)"
        case .listener(let protocolName, let stage, let detail):
            return "\(protocolName) listener \(stage): \(detail)"
        case .accept(let protocolName, let iteration, let detail):
            if let iteration {
                return "\(protocolName) accept failed on iteration \(iteration): \(detail)"
            }
            return "\(protocolName) accept failed outside an active iteration: \(detail)"
        case .connection(let protocolName, let iteration, let role, let stage, let detail):
            return "\(protocolName) \(role) \(stage) failed on iteration \(iteration): \(detail)"
        case .invariantViolation(let detail):
            return "loopback lifecycle invariant violated: \(detail)"
        case .operationAndCleanup(let operation, let cleanup):
            return "loopback operation failed (\(operation)); cleanup also failed (\(cleanup))"
        }
    }
}

public struct NetworkLoopbackHandshakeSample: Sendable {
    public let iteration: Int
    public let startEpoch: TimeInterval
    public let endEpoch: TimeInterval
    public let readyDuration: Duration

    public init(
        iteration: Int,
        startEpoch: TimeInterval,
        endEpoch: TimeInterval,
        readyDuration: Duration
    ) {
        self.iteration = iteration
        self.startEpoch = startEpoch
        self.endEpoch = endEpoch
        self.readyDuration = readyDuration
    }
}

public enum NetworkLoopbackListenerIsolation: Sendable {
    /// Reuses one listener when the transport gives each accepted connection an
    /// unambiguous lifetime across sequential handshakes.
    case sharedAcrossHandshakes

    /// Rebuilds the listener outside the timed interval for datagram-backed
    /// transports whose late packets could otherwise cross iteration boundaries.
    case perHandshake
}

/// Owns a complete Network.framework loopback lifecycle for benchmark-only transports.
///
/// Each iteration admits exactly one accepted server connection, waits for both peers to
/// become ready, records the client-ready timestamp, and only then performs bounded teardown.
/// The next iteration cannot start until both connections have reached a terminal state.
public enum NetworkLoopbackLifecycle {
    private static let maximumHandshakeCount = 100_000
    private static let maximumKickoffBytes = 1_048_576
    private static let maximumTimeoutSeconds: Double = 300

    public static func measureHandshakes(
        protocolName: String,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        listenerPort: NWEndpoint.Port? = nil,
        listenerIsolation: NetworkLoopbackListenerIsolation = .sharedAcrossHandshakes,
        iterations: Int,
        warmup: Int,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws -> [NetworkLoopbackHandshakeSample] {
        guard !protocolName.isEmpty else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration("protocol name is empty")
        }
        guard iterations > 0 else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration("iterations must be positive")
        }
        guard warmup >= 0 else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration("warmup cannot be negative")
        }
        let (totalHandshakes, countOverflow) = warmup.addingReportingOverflow(iterations)
        guard !countOverflow, totalHandshakes <= maximumHandshakeCount else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration(
                "warmup plus iterations must not exceed \(maximumHandshakeCount)"
            )
        }
        guard timeoutSeconds.isFinite,
              timeoutSeconds > 0,
              timeoutSeconds <= maximumTimeoutSeconds else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration(
                "timeout must be finite, positive, and no greater than \(maximumTimeoutSeconds)s"
            )
        }
        guard (0...maximumKickoffBytes).contains(kickoffBytes) else {
            throw NetworkLoopbackLifecycleError.invalidConfiguration(
                "kickoff byte count must be between 0 and \(maximumKickoffBytes)"
            )
        }

        let queueLabel = protocolName
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let queue = DispatchQueue(
            label: "skybridge.loopback.\(queueLabel)",
            qos: .userInitiated
        )
        let rawSamples: [NetworkLoopbackHandshakeSample]
        switch listenerIsolation {
        case .sharedAcrossHandshakes:
            rawSamples = try await runListenerSession(
                protocolName: protocolName,
                iterations: 0..<totalHandshakes,
                serverParameters: serverParameters,
                clientParameters: clientParameters,
                listenerPort: listenerPort,
                queue: queue,
                timeoutSeconds: timeoutSeconds,
                kickoffBytes: kickoffBytes
            )
        case .perHandshake:
            var isolatedSamples: [NetworkLoopbackHandshakeSample] = []
            isolatedSamples.reserveCapacity(totalHandshakes)
            for rawIteration in 0..<totalHandshakes {
                let sessionSamples = try await runListenerSession(
                    protocolName: protocolName,
                    iterations: rawIteration..<(rawIteration + 1),
                    serverParameters: serverParameters,
                    clientParameters: clientParameters,
                    listenerPort: listenerPort,
                    queue: queue,
                    timeoutSeconds: timeoutSeconds,
                    kickoffBytes: kickoffBytes
                )
                isolatedSamples.append(contentsOf: sessionSamples)
            }
            rawSamples = isolatedSamples
        }

        return rawSamples.compactMap { sample in
            guard sample.iteration >= warmup else { return nil }
            return NetworkLoopbackHandshakeSample(
                iteration: sample.iteration - warmup,
                startEpoch: sample.startEpoch,
                endEpoch: sample.endEpoch,
                readyDuration: sample.readyDuration
            )
        }
    }

    private static func runListenerSession(
        protocolName: String,
        iterations: Range<Int>,
        serverParameters: NWParameters,
        clientParameters: NWParameters,
        listenerPort: NWEndpoint.Port?,
        queue: DispatchQueue,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws -> [NetworkLoopbackHandshakeSample] {
        let listener: NWListener
        if let listenerPort {
            listener = try NWListener(using: serverParameters, on: listenerPort)
        } else {
            listener = try NWListener(using: serverParameters)
        }

        let mailbox = AcceptedConnectionMailbox(protocolName: protocolName)
        let listenerLifecycle = ListenerLifecycle(
            protocolName: protocolName,
            listener: listener,
            mailbox: mailbox,
            queue: queue
        )
        let operationResult: Result<[NetworkLoopbackHandshakeSample], NetworkLoopbackLifecycleError>
        do {
            let port = try await listenerLifecycle.startAndWaitUntilReady(
                timeoutSeconds: timeoutSeconds
            )
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            var samples: [NetworkLoopbackHandshakeSample] = []
            samples.reserveCapacity(iterations.count)
            for iteration in iterations {
                samples.append(try await runIteration(
                    protocolName: protocolName,
                    iteration: iteration,
                    endpoint: endpoint,
                    clientParameters: clientParameters,
                    mailbox: mailbox,
                    queue: queue,
                    timeoutSeconds: timeoutSeconds,
                    kickoffBytes: kickoffBytes
                ))
            }
            operationResult = .success(samples)
        } catch let error as NetworkLoopbackLifecycleError {
            operationResult = .failure(error)
        } catch {
            operationResult = .failure(.listener(
                protocolName: protocolName,
                stage: "operation",
                detail: String(describing: error)
            ))
        }

        let cleanupResult: Result<Void, NetworkLoopbackLifecycleError>
        do {
            try await listenerLifecycle.cancelAndWaitForTerminal(
                timeoutSeconds: timeoutSeconds
            )
            cleanupResult = .success(())
        } catch let error as NetworkLoopbackLifecycleError {
            cleanupResult = .failure(error)
        } catch {
            cleanupResult = .failure(.listener(
                protocolName: protocolName,
                stage: "teardown",
                detail: String(describing: error)
            ))
        }

        return try resolveSessionResults(
            protocolName: protocolName,
            operation: operationResult,
            cleanup: cleanupResult
        )
    }

    private static func resolveSessionResults<Value>(
        protocolName: String,
        operation: Result<Value, NetworkLoopbackLifecycleError>,
        cleanup: Result<Void, NetworkLoopbackLifecycleError>
    ) throws -> Value {
        let finalOperation: Result<Value, NetworkLoopbackLifecycleError>
        if Task.isCancelled, case .success = operation {
            finalOperation = .failure(.listener(
                protocolName: protocolName,
                stage: "operation",
                detail: "task cancelled"
            ))
        } else {
            finalOperation = operation
        }

        switch (finalOperation, cleanup) {
        case (.success(let value), .success):
            return value
        case (.failure(let operationError), .success):
            throw operationError
        case (.success, .failure(let cleanupError)):
            throw cleanupError
        case (.failure(let operationError), .failure(let cleanupError)):
            throw NetworkLoopbackLifecycleError.operationAndCleanup(
                operation: operationError.description,
                cleanup: cleanupError.description
            )
        }
    }

    private static func runIteration(
        protocolName: String,
        iteration: Int,
        endpoint: NWEndpoint,
        clientParameters: NWParameters,
        mailbox: AcceptedConnectionMailbox,
        queue: DispatchQueue,
        timeoutSeconds: Double,
        kickoffBytes: Int
    ) async throws -> NetworkLoopbackHandshakeSample {
        let reservation = try mailbox.reserve(
            iteration: iteration,
            queue: queue,
            timeoutSeconds: timeoutSeconds
        )
        let clientConnection = NWConnection(to: endpoint, using: clientParameters)
        let clientLifecycle = ConnectionLifecycle(
            protocolName: protocolName,
            iteration: iteration,
            role: "client",
            connection: clientConnection,
            queue: queue
        )
        let startEpoch = Date().timeIntervalSince1970
        let startInstant = ContinuousClock.now
        clientLifecycle.start(
            timeoutSeconds: timeoutSeconds,
            kickoffBytes: kickoffBytes
        )

        var serverLifecycle: ConnectionLifecycle?
        var acceptedServerConnection: NWConnection?
        let operationResult: Result<ReadyStamp, NetworkLoopbackLifecycleError>
        do {
            let serverConnection = try await reservation.connection()
            acceptedServerConnection = serverConnection
            let lifecycle = ConnectionLifecycle(
                protocolName: protocolName,
                iteration: iteration,
                role: "server",
                connection: serverConnection,
                queue: queue
            )
            serverLifecycle = lifecycle
            lifecycle.start(timeoutSeconds: timeoutSeconds, kickoffBytes: 0)

            async let clientReady = clientLifecycle.waitUntilReady()
            async let serverReady = lifecycle.waitUntilReady()
            let (clientStamp, _) = try await (clientReady, serverReady)
            operationResult = .success(clientStamp)
        } catch let error as NetworkLoopbackLifecycleError {
            operationResult = .failure(error)
        } catch {
            operationResult = .failure(.connection(
                protocolName: protocolName,
                iteration: iteration,
                role: "pair",
                stage: "ready",
                detail: String(describing: error)
            ))
        }

        clientLifecycle.requestCancel()
        serverLifecycle?.requestCancel()

        let cleanupResult = await cleanupPair(
            protocolName: protocolName,
            iteration: iteration,
            client: clientLifecycle,
            server: serverLifecycle,
            timeoutSeconds: timeoutSeconds
        )

        if case .success = cleanupResult, let acceptedServerConnection {
            do {
                try mailbox.release(acceptedServerConnection, iteration: iteration)
            } catch let error as NetworkLoopbackLifecycleError {
                switch operationResult {
                case .success:
                    throw error
                case .failure(let operationError):
                    throw NetworkLoopbackLifecycleError.operationAndCleanup(
                        operation: operationError.description,
                        cleanup: error.description
                    )
                }
            } catch {
                throw NetworkLoopbackLifecycleError.invariantViolation(String(describing: error))
            }
        }

        switch (operationResult, cleanupResult) {
        case (.success(let clientStamp), .success):
            return NetworkLoopbackHandshakeSample(
                iteration: iteration,
                startEpoch: startEpoch,
                endEpoch: clientStamp.epoch,
                readyDuration: startInstant.duration(to: clientStamp.instant)
            )
        case (.failure(let operationError), .success):
            throw operationError
        case (.success, .failure(let cleanupError)):
            throw cleanupError
        case (.failure(let operationError), .failure(let cleanupError)):
            throw NetworkLoopbackLifecycleError.operationAndCleanup(
                operation: operationError.description,
                cleanup: cleanupError.description
            )
        }
    }

    private static func cleanupPair(
        protocolName: String,
        iteration: Int,
        client: ConnectionLifecycle,
        server: ConnectionLifecycle?,
        timeoutSeconds: Double
    ) async -> Result<Void, NetworkLoopbackLifecycleError> {
        do {
            if let server {
                async let clientTerminal: Void = client.waitForTerminal(timeoutSeconds: timeoutSeconds)
                async let serverTerminal: Void = server.waitForTerminal(timeoutSeconds: timeoutSeconds)
                _ = try await (clientTerminal, serverTerminal)
            } else {
                try await client.waitForTerminal(timeoutSeconds: timeoutSeconds)
            }
            return .success(())
        } catch let error as NetworkLoopbackLifecycleError {
            return .failure(error)
        } catch {
            return .failure(.connection(
                protocolName: protocolName,
                iteration: iteration,
                role: "pair",
                stage: "teardown",
                detail: String(describing: error)
            ))
        }
    }
}
