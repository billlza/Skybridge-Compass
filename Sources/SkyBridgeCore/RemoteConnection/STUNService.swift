import Foundation
import Network
import OSLog
import SkyBridgeProtocolCore

public enum STUNServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidTimeout
    case connectionFailed
    case timeout
    case incompleteResponse
    case invalidResponse(STUNMessageCodecError)
    case allServersFailed

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "STUN timeout must be positive."
        case .connectionFailed:
            return "STUN connection failed."
        case .timeout:
            return "STUN query timed out."
        case .incompleteResponse:
            return "STUN server returned an incomplete datagram."
        case .invalidResponse(let error):
            return "STUN server returned an invalid response: \(error.localizedDescription)"
        case .allServersFailed:
            return "Every configured STUN server failed."
        }
    }
}

private struct STUNProbeEndpoint: Sendable, Equatable {
    let host: String
    let port: UInt16
}

protocol STUNDatagramConnection: AnyObject, Sendable {
    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    )
    func clearStateUpdateHandler()
    func start()
    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    )
    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    )
    func cancel()
}

private final class NWSTUNDatagramConnection: STUNDatagramConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "com.skybridge.signal.stun-query",
        qos: .userInitiated
    )

    init(endpoint: STUNProbeEndpoint) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(integerLiteral: endpoint.port)
        )
        connection = NWConnection(to: endpoint, using: .udp)
    }

    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    ) {
        connection.stateUpdateHandler = handler
    }

    func clearStateUpdateHandler() {
        connection.stateUpdateHandler = nil
    }

    func start() {
        connection.start(queue: queue)
    }

    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    ) {
        connection.receiveMessage { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class STUNQueryCompletion: @unchecked Sendable {
    typealias PublicAddress = (address: String, port: UInt16)

    private enum Stage {
        case waitingForReady
        case sending
        case receiving
        case completed
    }

    private struct State {
        var stage = Stage.waitingForReady
        var timeoutTask: Task<Void, Never>?
        var connection: (any STUNDatagramConnection)?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: CheckedContinuation<PublicAddress, Error>

    init(
        continuation: CheckedContinuation<PublicAddress, Error>,
        connection: any STUNDatagramConnection
    ) {
        self.continuation = continuation
        state = OSAllocatedUnfairLock(
            initialState: State(connection: connection)
        )
    }

    func beginSending() -> Bool {
        state.withLock { state in
            guard state.stage == .waitingForReady else { return false }
            state.stage = .sending
            return true
        }
    }

    func beginReceiving() -> Bool {
        state.withLock { state in
            guard state.stage == .sending else { return false }
            state.stage = .receiving
            return true
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state -> Bool in
            guard state.stage != .completed else { return true }
            state.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func complete(_ result: Result<PublicAddress, Error>) {
        let completion = state.withLock { state -> (
            shouldResume: Bool,
            timeoutTask: Task<Void, Never>?,
            connection: (any STUNDatagramConnection)?
        ) in
            guard state.stage != .completed else { return (false, nil, nil) }
            state.stage = .completed
            defer {
                state.timeoutTask = nil
                state.connection = nil
            }
            return (true, state.timeoutTask, state.connection)
        }
        guard completion.shouldResume else { return }

        // Cleanup stays outside the state lock because cancel() can synchronously
        // deliver a terminal state on test and adapter implementations.
        completion.timeoutTask?.cancel()
        completion.connection?.clearStateUpdateHandler()
        completion.connection?.cancel()
        continuation.resume(with: result)
    }
}

private final class WeakSTUNDatagramConnection: @unchecked Sendable {
    weak var value: (any STUNDatagramConnection)?

    init(_ value: any STUNDatagramConnection) {
        self.value = value
    }
}

private final class STUNQueryCancellationRelay: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var completion: STUNQueryCompletion?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ completion: STUNQueryCompletion) -> Bool {
        state.withLock { state in
            guard !state.isCancelled else { return false }
            state.completion = completion
            return true
        }
    }

    func cancel() {
        let completion = state.withLock { state -> STUNQueryCompletion? in
            state.isCancelled = true
            return state.completion
        }
        completion?.complete(.failure(CancellationError()))
    }
}

/// Shared STUN helper for current cross-network connectivity flows.
public actor STUNService {
    public typealias PublicAddress = (address: String, port: UInt16)
    typealias ServerQuery = @Sendable (_ host: String, _ port: UInt16) async throws -> PublicAddress

    public static let shared = STUNService()

    private struct LookupState {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<PublicAddress, Error>]
        var task: Task<Void, Never>?
    }

    private let logger = Logger(subsystem: "com.skybridge.signal", category: "STUN")
    private let stunServers: [STUNProbeEndpoint]
    private let cacheValidDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let queryServer: ServerQuery
    private var cachedAddress: PublicAddress?
    private var cacheTime: Date?
    private var activeLookup: LookupState?

    private init() {
        stunServers = [
            STUNProbeEndpoint(host: "54.92.79.99", port: 3478),
            STUNProbeEndpoint(host: "stun.l.google.com", port: 19302),
            STUNProbeEndpoint(host: "stun1.l.google.com", port: 19302),
            STUNProbeEndpoint(host: "stun.cloudflare.com", port: 3478)
        ]
        cacheValidDuration = 60
        now = { Date() }
        queryServer = { host, port in
            let connection = NWSTUNDatagramConnection(
                endpoint: STUNProbeEndpoint(host: host, port: port)
            )
            return try await STUNService.querySTUNServer(connection: connection)
        }
    }

    init(
        servers: [(host: String, port: UInt16)],
        cacheValidDuration: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        queryServer: @escaping ServerQuery
    ) {
        precondition(!servers.isEmpty, "STUN service requires at least one server")
        precondition(
            cacheValidDuration.isFinite && cacheValidDuration > 0,
            "STUN cache duration must be positive and finite"
        )
        stunServers = servers.map {
            STUNProbeEndpoint(host: $0.host, port: $0.port)
        }
        self.cacheValidDuration = cacheValidDuration
        self.now = now
        self.queryServer = queryServer
    }

    public func getPublicAddress() async throws -> PublicAddress {
        try Task.checkCancellation()
        let currentTime = now()
        if let cachedAddress, let cacheTime {
            let age = currentTime.timeIntervalSince(cacheTime)
            if age >= 0, age < cacheValidDuration {
                return cachedAddress
            }
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueueLookupWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelLookupWaiter(id: waiterID) }
        }
    }

    private func enqueueLookupWaiter(
        id waiterID: UUID,
        continuation: CheckedContinuation<PublicAddress, Error>
    ) {
        if var lookup = activeLookup {
            lookup.waiters[waiterID] = continuation
            activeLookup = lookup
            return
        }

        let lookupID = UUID()
        activeLookup = LookupState(
            id: lookupID,
            waiters: [waiterID: continuation],
            task: nil
        )
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<PublicAddress, Error>
            do {
                result = .success(try await self.performLookup())
            } catch {
                result = .failure(error)
            }
            await self.finishLookup(id: lookupID, result: result)
        }
        activeLookup?.task = task
    }

    private func performLookup() async throws -> PublicAddress {
        for server in stunServers {
            try Task.checkCancellation()
            do {
                let result = try await queryServer(server.host, server.port)
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as STUNServiceError {
                logger.warning(
                    "STUN server \(server.host, privacy: .public):\(server.port, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            } catch {
                throw error
            }
        }
        throw STUNServiceError.allServersFailed
    }

    private func finishLookup(
        id: UUID,
        result: Result<PublicAddress, Error>
    ) {
        guard let lookup = activeLookup, lookup.id == id else { return }
        activeLookup = nil

        switch result {
        case .success(let address):
            cachedAddress = address
            cacheTime = now()
            logger.info(
                "✅ STUN 查询成功: \(address.address, privacy: .private):\(address.port, privacy: .private)"
            )
        case .failure(let error):
            if !(error is CancellationError) {
                logger.warning("⚠️ STUN 查询失败: \(error.localizedDescription, privacy: .public)")
            }
        }

        for continuation in lookup.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelLookupWaiter(id waiterID: UUID) {
        guard var lookup = activeLookup,
              let continuation = lookup.waiters.removeValue(forKey: waiterID) else {
            return
        }

        continuation.resume(throwing: CancellationError())
        if lookup.waiters.isEmpty {
            activeLookup = nil
            lookup.task?.cancel()
        } else {
            activeLookup = lookup
        }
    }

    static func querySTUNServer(
        connection: any STUNDatagramConnection,
        timeout: Duration = .seconds(3)
    ) async throws -> PublicAddress {
        guard timeout > .zero else { throw STUNServiceError.invalidTimeout }
        let cancellationRelay = STUNQueryCancellationRelay()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = STUNQueryCompletion(
                    continuation: continuation,
                    connection: connection
                )
                let weakConnection = WeakSTUNDatagramConnection(connection)
                let request = STUNMessageCodec.makeBindingRequest()

                connection.setStateUpdateHandler { state in
                    switch state {
                    case .ready:
                        guard completion.beginSending() else { return }
                        guard let activeConnection = weakConnection.value else {
                            completion.complete(.failure(STUNServiceError.connectionFailed))
                            return
                        }
                        activeConnection.send(request.payload) { error in
                            guard error == nil else {
                                completion.complete(.failure(STUNServiceError.connectionFailed))
                                return
                            }
                            guard completion.beginReceiving() else { return }
                            guard let activeConnection = weakConnection.value else {
                                completion.complete(.failure(STUNServiceError.connectionFailed))
                                return
                            }
                            activeConnection.receiveMessage { data, isComplete, receiveError in
                                guard receiveError == nil else {
                                    completion.complete(.failure(STUNServiceError.connectionFailed))
                                    return
                                }
                                guard isComplete, let data else {
                                    completion.complete(.failure(STUNServiceError.incompleteResponse))
                                    return
                                }
                                do throws(STUNMessageCodecError) {
                                    let result = try STUNMessageCodec.parseBindingResponse(
                                        data,
                                        expectedTransactionID: request.transactionID
                                    )
                                    completion.complete(.success((result.address, result.port)))
                                } catch {
                                    completion.complete(
                                        .failure(STUNServiceError.invalidResponse(error))
                                    )
                                }
                            }
                        }
                    case .failed, .cancelled:
                        completion.complete(.failure(STUNServiceError.connectionFailed))
                    default:
                        break
                    }
                }

                guard cancellationRelay.register(completion) else {
                    completion.complete(.failure(CancellationError()))
                    return
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        completion.complete(.failure(STUNServiceError.connectionFailed))
                        return
                    }
                    completion.complete(.failure(STUNServiceError.timeout))
                }
                completion.installTimeoutTask(timeoutTask)

                guard !Task.isCancelled else {
                    cancellationRelay.cancel()
                    return
                }

                connection.start()
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }
}
