import Foundation
import Network

public struct RTSPClientConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let endpoint: RTSPEndpoint
    let credentials: RTSPCredentials?
    let connectTimeout: Duration
    let requestTimeout: Duration
    let firstFrameTimeout: Duration
    let streamInactivityTimeout: Duration
    let teardownTimeout: Duration
    let frameBufferCapacity: Int
    let userAgent: String

    public var description: String { "RTSPClientConfiguration(<redacted>)" }
    public var debugDescription: String { description }

    public init(
        endpoint: RTSPEndpoint,
        credentials: RTSPCredentials? = nil,
        connectTimeout: Duration = .seconds(10),
        requestTimeout: Duration = .seconds(10),
        firstFrameTimeout: Duration = .seconds(15),
        streamInactivityTimeout: Duration = .seconds(30),
        teardownTimeout: Duration = .seconds(1),
        frameBufferCapacity: Int = 3,
        userAgent: String = "SkyBridgeCameraKit/1"
    ) throws {
        guard connectTimeout > .zero,
              requestTimeout > .zero,
              firstFrameTimeout > .zero,
              streamInactivityTimeout > .zero,
              teardownTimeout > .zero
        else {
            throw SkyBridgeCameraError.invalidState("network timeouts must be positive")
        }
        guard (1...4).contains(frameBufferCapacity) else {
            throw SkyBridgeCameraError.invalidState(
                "frame buffer capacity must be between 1 and 4"
            )
        }
        guard !userAgent.isEmpty, userAgent.utf8.count <= 128,
              userAgent.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 })
        else {
            throw SkyBridgeCameraError.invalidState("the RTSP user agent is invalid")
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.firstFrameTimeout = firstFrameTimeout
        self.streamInactivityTimeout = streamInactivityTimeout
        self.teardownTimeout = teardownTimeout
        self.frameBufferCapacity = frameBufferCapacity
        self.userAgent = userAgent
    }
}

struct RTSPKeepaliveDeadlinePolicy: Sendable {
    enum LimitingTimeout: Sendable, Equatable {
        case response
        case firstAccessUnit
        case subsequentAccessUnit

        var stage: String {
            switch self {
            case .response:
                "completing the session keepalive request"
            case .firstAccessUnit:
                "waiting for the first H.264 access unit"
            case .subsequentAccessUnit:
                "waiting for a subsequent H.264 access unit"
            }
        }
    }

    struct Wait: Sendable, Equatable {
        let deadline: ContinuousClock.Instant
        let limitingTimeout: LimitingTimeout
    }

    let responseDeadline: ContinuousClock.Instant

    func nextWait(
        now: ContinuousClock.Instant,
        mediaDeadline: ContinuousClock.Instant,
        hasReceivedAccessUnit: Bool
    ) throws -> Wait {
        let wait: Wait
        if responseDeadline <= mediaDeadline {
            wait = Wait(deadline: responseDeadline, limitingTimeout: .response)
        } else {
            wait = Wait(
                deadline: mediaDeadline,
                limitingTimeout: hasReceivedAccessUnit
                    ? .subsequentAccessUnit
                    : .firstAccessUnit
            )
        }
        guard now < wait.deadline else {
            throw SkyBridgeCameraError.timedOut(wait.limitingTimeout.stage)
        }
        return wait
    }
}

struct RTSPAuthenticationRetryState: Sendable {
    private(set) var hasRetried = false

    mutating func prepareRetry(
        for response: RTSPResponse,
        credentials: RTSPCredentials?,
        secureTransport: Bool,
        authenticationContext: inout RTSPAuthenticationContext?
    ) throws {
        guard response.statusCode == 401 else {
            throw SkyBridgeCameraError.invalidState(
                "an authentication retry requires a 401 response"
            )
        }
        guard !hasRetried else {
            throw SkyBridgeCameraError.authenticationRejected
        }

        if var currentContext = authenticationContext {
            guard try currentContext.refreshIfStale(
                from: response.headerValues(named: "www-authenticate")
            ) else {
                throw SkyBridgeCameraError.authenticationRejected
            }
            authenticationContext = currentContext
        } else {
            guard let credentials else {
                throw SkyBridgeCameraError.credentialsMissing
            }
            let selection = try RTSPAuthentication.selectChallenge(
                from: response.headerValues(named: "www-authenticate"),
                isSecureTransport: secureTransport
            )
            authenticationContext = try RTSPAuthenticationContext(
                selection: selection,
                credentials: credentials,
                secureTransport: secureTransport
            )
        }
        hasRetried = true
    }
}

struct RTSPReceiveChunk: Sendable, Equatable {
    let data: Data?
    let isComplete: Bool
}

struct RTSPReceiveContext: Sendable, Equatable {
    let connectionGeneration: UInt64
    let connectionIdentifier: ObjectIdentifier
}

struct RTSPReceiveTimeoutHandle: Sendable {
    let cancel: @Sendable () -> Void
}

struct RTSPReceiveTimeoutScheduler: Sendable {
    let schedule: @Sendable (
        Duration,
        @escaping @Sendable (
            Result<Void, SkyBridgeCameraError>
        ) async -> Void
    ) -> RTSPReceiveTimeoutHandle

    static let continuous = RTSPReceiveTimeoutScheduler { duration, action in
        let task = Task.detached {
            do {
                try await Task.sleep(for: duration)
                await action(.success(()))
            } catch is CancellationError {
                return
            } catch {
                await action(.failure(.transportFailed(
                    "the RTSP receive timeout scheduler failed unexpectedly"
                )))
            }
        }
        return RTSPReceiveTimeoutHandle(cancel: { task.cancel() })
    }
}

/// Owns exactly one underlying receive operation for a connection generation.
/// Logical waiters may time out or be cancelled without invalidating that
/// Network.framework callback; a later waiter either attaches to it or consumes
/// its single bounded result.
actor RTSPPendingReceiveBroker {
    static let maximumBufferedBytes = 64 * 1_024

    private struct Operation: Sendable, Equatable {
        let context: RTSPReceiveContext
        let identifier: UInt64
    }

    private struct Waiter {
        let token: UInt64
        let operation: Operation
        let continuation: CheckedContinuation<RTSPReceiveChunk, any Error>
        let timeoutHandle: RTSPReceiveTimeoutHandle
    }

    private let timeoutScheduler: RTSPReceiveTimeoutScheduler
    private var currentContext: RTSPReceiveContext?
    private var inFlightOperation: Operation?
    private var bufferedResult: Result<RTSPReceiveChunk, SkyBridgeCameraError>?
    private var waiter: Waiter?
    private var nextOperationIdentifier: UInt64 = 0
    private var nextWaiterToken: UInt64 = 0

    init(timeoutScheduler: RTSPReceiveTimeoutScheduler = .continuous) {
        self.timeoutScheduler = timeoutScheduler
    }

    func receive(
        context: RTSPReceiveContext,
        timeout: Duration,
        stage: String,
        start: @Sendable (
            @escaping @Sendable (
                Result<RTSPReceiveChunk, SkyBridgeCameraError>
            ) async -> Void
        ) -> Void
    ) async throws -> RTSPReceiveChunk {
        guard timeout > .zero else { throw SkyBridgeCameraError.timedOut(stage) }
        guard !Task.isCancelled else { throw SkyBridgeCameraError.cancelled }

        if let currentContext {
            guard currentContext == context else {
                throw SkyBridgeCameraError.invalidState(
                    "the receive connection changed without resetting its broker"
                )
            }
        } else {
            currentContext = context
        }
        guard waiter == nil else {
            throw SkyBridgeCameraError.invalidState(
                "concurrent RTSP receive waiters are not supported"
            )
        }
        if let bufferedResult {
            self.bufferedResult = nil
            return try bufferedResult.get()
        }

        guard nextWaiterToken < UInt64.max else {
            throw SkyBridgeCameraError.invalidState(
                "the RTSP receive waiter token is exhausted"
            )
        }
        nextWaiterToken += 1
        let waiterToken = nextWaiterToken

        let operation: Operation
        let shouldStartReceive: Bool
        if let inFlightOperation {
            operation = inFlightOperation
            shouldStartReceive = false
        } else {
            guard nextOperationIdentifier < UInt64.max else {
                throw SkyBridgeCameraError.invalidState(
                    "the RTSP receive operation identifier is exhausted"
                )
            }
            nextOperationIdentifier += 1
            operation = Operation(
                context: context,
                identifier: nextOperationIdentifier
            )
            inFlightOperation = operation
            shouldStartReceive = true
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(isolation: self) { continuation in
                let timeoutHandle = timeoutScheduler.schedule(timeout) { [weak self] result in
                    switch result {
                    case .success:
                        await self?.expireWaiter(
                            token: waiterToken,
                            operation: operation,
                            stage: stage
                        )
                    case let .failure(error):
                        await self?.failWaiter(
                            token: waiterToken,
                            operation: operation,
                            error: error
                        )
                    }
                }
                waiter = Waiter(
                    token: waiterToken,
                    operation: operation,
                    continuation: continuation,
                    timeoutHandle: timeoutHandle
                )

                if shouldStartReceive {
                    start { [weak self] result in
                        await self?.complete(operation: operation, with: result)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelWaiter(
                    token: waiterToken,
                    operation: operation
                )
            }
        }
    }

    func reset() {
        currentContext = nil
        inFlightOperation = nil
        bufferedResult = nil
        guard let waiter else { return }
        self.waiter = nil
        resume(waiter, with: .failure(.cancelled))
    }

    private func expireWaiter(
        token: UInt64,
        operation: Operation,
        stage: String
    ) {
        guard let waiter,
              waiter.token == token,
              waiter.operation == operation
        else { return }
        self.waiter = nil
        resume(waiter, with: .failure(.timedOut(stage)))
    }

    private func cancelWaiter(token: UInt64, operation: Operation) {
        failWaiter(token: token, operation: operation, error: .cancelled)
    }

    private func failWaiter(
        token: UInt64,
        operation: Operation,
        error: SkyBridgeCameraError
    ) {
        guard let waiter,
              waiter.token == token,
              waiter.operation == operation
        else { return }
        self.waiter = nil
        resume(waiter, with: .failure(error))
    }

    private func complete(
        operation: Operation,
        with result: Result<RTSPReceiveChunk, SkyBridgeCameraError>
    ) {
        guard currentContext == operation.context,
              inFlightOperation == operation
        else {
            // reset() invalidated this exact callback. It must not cross into a
            // later connection generation, even if an object address is reused.
            return
        }
        inFlightOperation = nil
        let boundedResult = bounded(result)
        if let waiter, waiter.operation == operation {
            self.waiter = nil
            resume(waiter, with: boundedResult)
        } else {
            guard bufferedResult == nil else {
                bufferedResult = .failure(.invalidState(
                    "the receive broker produced more than one pending result"
                ))
                return
            }
            bufferedResult = boundedResult
        }
    }

    private func bounded(
        _ result: Result<RTSPReceiveChunk, SkyBridgeCameraError>
    ) -> Result<RTSPReceiveChunk, SkyBridgeCameraError> {
        guard case let .success(chunk) = result,
              let data = chunk.data,
              data.count > Self.maximumBufferedBytes
        else { return result }
        return .failure(.transportFailed(
            "Network.framework returned more than 65536 bytes from one receive"
        ))
    }

    private func resume(
        _ waiter: Waiter,
        with result: Result<RTSPReceiveChunk, SkyBridgeCameraError>
    ) {
        waiter.timeoutHandle.cancel()
        switch result {
        case let .success(chunk):
            waiter.continuation.resume(returning: chunk)
        case let .failure(error):
            waiter.continuation.resume(throwing: error)
        }
    }
}

public actor RTSPInterleavedClient {
    private enum State: Sendable {
        case idle
        case connecting
        case playing
        case stopping
        case closed
    }

    private let configuration: RTSPClientConfiguration
    private let stopBarrier: @Sendable () async -> Void
    private let networkQueue = DispatchQueue(
        label: "com.skybridge.camera.rtsp.network",
        qos: .userInitiated
    )
    private let receiveBroker = RTSPPendingReceiveBroker()
    private var state: State = .idle
    private var generation: UInt64 = 0
    private var connection: NWConnection?
    private var parser = RTSPMessageParser()
    private var pendingEvents: [RTSPWireEvent] = []
    private var pendingEventOffset = 0
    private var authenticationContext: RTSPAuthenticationContext?
    private var sessionIdentifier: String?
    private var aggregateControlURL: URL?
    private var keepaliveInterval: Duration?
    private var depacketizer: H264RTPDepacketizer?
    private var nextCSeq = 1
    private var readerTask: Task<Void, Never>?
    private var stopCompletion: Task<Result<Void, SkyBridgeCameraError>, Never>?
    private var streamSubscriptionGeneration: UInt64 = 0
    private var frameStreamActive = false
    private var frameStreamFinished = false
    private var frameStreamError: SkyBridgeCameraError?
    private var frameQueue: [H264AccessUnit] = []
    private var frameWaiter: CheckedContinuation<H264AccessUnit?, any Error>?
    private var waitingForKeyFrame = true
    private var playbackStartedAt: ContinuousClock.Instant?
    private(set) var lastAccessUnitAt: ContinuousClock.Instant?
    private var networkOperationToken: UInt64 = 0
    private var activeNetworkCancellation: (token: UInt64, action: @Sendable () -> Void)?

    public init(configuration: RTSPClientConfiguration) {
        self.configuration = configuration
        self.stopBarrier = {}
    }

    init(
        configuration: RTSPClientConfiguration,
        stopBarrier: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.stopBarrier = stopBarrier
    }

    deinit {
        readerTask?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    public func frames() -> AsyncThrowingStream<H264AccessUnit, any Error> {
        guard !frameStreamActive else {
            return AsyncThrowingStream(unfolding: {
                throw SkyBridgeCameraError.invalidState("only one frame consumer is supported")
            })
        }
        streamSubscriptionGeneration &+= 1
        let subscription = streamSubscriptionGeneration
        frameStreamActive = true
        frameStreamFinished = false
        frameStreamError = nil
        frameQueue.removeAll(keepingCapacity: true)
        waitingForKeyFrame = true
        let lifetime = FrameStreamLifetime { [weak self] in
            Task { await self?.frameConsumerTerminated(subscription: subscription) }
        }
        return AsyncThrowingStream(
            unfolding: { [weak self, lifetime] in
                _ = lifetime
                guard let self else { return nil }
                return try await self.nextFrame(subscription: subscription)
            }
        )
    }

    public func connectAndPlay() async throws {
        guard state == .idle || state == .closed else {
            throw SkyBridgeCameraError.invalidState("connect requires an idle client")
        }

        generation &+= 1
        let operationGeneration = generation
        stopCompletion = nil
        state = .connecting
        await resetProtocolState()

        do {
            try requireCurrent(operationGeneration, expectedState: .connecting)
            let newConnection = try makeConnection()
            connection = newConnection
            try await waitUntilReady(
                newConnection,
                timeout: configuration.connectTimeout,
                stage: "connecting"
            )
            try requireCurrent(operationGeneration, expectedState: .connecting)
            newConnection.stateUpdateHandler = nil

            let describeResponse = try await authenticatedDescribe(
                generation: operationGeneration
            )
            let baseURL = try descriptionBaseURL(from: describeResponse)
            let media = try SDPParser().parseH264Media(
                describeResponse.body,
                baseURL: baseURL,
                endpoint: configuration.endpoint
            )
            aggregateControlURL = media.playURL
            depacketizer = H264RTPDepacketizer(
                payloadType: media.payloadType,
                packetizationMode: media.packetizationMode,
                sequenceParameterSets: media.sequenceParameterSets,
                pictureParameterSets: media.pictureParameterSets
            )

            let setupResponse = try await performRequest(
                method: "SETUP",
                url: media.controlURL,
                headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")],
                timeout: configuration.requestTimeout,
                generation: operationGeneration
            )
            try requireSuccess(setupResponse, authenticated: authenticationContext != nil)
            let parsedSession = try parseSessionIdentifier(setupResponse)
            sessionIdentifier = parsedSession.identifier
            keepaliveInterval = parsedSession.keepaliveInterval
            try validateInterleavedTransport(setupResponse)

            guard let sessionIdentifier else {
                throw SkyBridgeCameraError.missingSession
            }
            let playResponse = try await performRequest(
                method: "PLAY",
                url: media.playURL,
                headers: [("Session", sessionIdentifier)],
                timeout: configuration.requestTimeout,
                generation: operationGeneration
            )
            try requireSuccess(playResponse, authenticated: authenticationContext != nil)
            try requireCurrent(operationGeneration, expectedState: .connecting)

            playbackStartedAt = ContinuousClock().now
            lastAccessUnitAt = nil
            state = .playing
            startReader(generation: operationGeneration)
        } catch {
            let cameraError = normalized(error)
            await failConnection(cameraError, generation: operationGeneration)
            throw cameraError
        }
    }

    public func stop() async throws {
        try await stopResult().get()
    }

    private func stopResult() async -> Result<Void, SkyBridgeCameraError> {
        if let stopCompletion {
            return await stopCompletion.value
        }

        switch state {
        case .closed:
            finishFrameStream(throwing: nil)
            return .success(())

        case .stopping:
            return .failure(.invalidState(
                "the client entered stopping without a shared completion"
            ))

        case .idle, .connecting, .playing:
            generation &+= 1
            state = .stopping
            cancelActiveNetworkOperation()
            readerTask?.cancel()
            readerTask = nil

            let completion = Task { [self] in
                await executeStop()
            }
            stopCompletion = completion
            return await completion.value
        }
    }

    private func executeStop() async -> Result<Void, SkyBridgeCameraError> {
        await stopBarrier()

        var teardownError: SkyBridgeCameraError?
        if let connection, let sessionIdentifier {
            do {
                let request = try buildRequest(
                    method: "TEARDOWN",
                    url: aggregateControlURL ?? configuration.endpoint.url,
                    headers: [("Session", sessionIdentifier)],
                    includeAuthentication: true
                )
                try await send(
                    request,
                    over: connection,
                    timeout: configuration.teardownTimeout,
                    stage: "sending TEARDOWN"
                )
            } catch {
                teardownError = normalized(error)
            }
        }

        await closeTransport()
        state = .closed
        if let teardownError {
            finishFrameStream(throwing: teardownError)
            return .failure(teardownError)
        }
        finishFrameStream(throwing: nil)
        return .success(())
    }

    private func authenticatedDescribe(generation: UInt64) async throws -> RTSPResponse {
        let response = try await performRequest(
            method: "DESCRIBE",
            url: configuration.endpoint.url,
            headers: [("Accept", "application/sdp")],
            timeout: configuration.requestTimeout,
            generation: generation
        )
        try requireSuccess(response, authenticated: authenticationContext != nil)
        guard !response.body.isEmpty else {
            throw SkyBridgeCameraError.malformedSDP("DESCRIBE returned an empty body")
        }
        if let contentType = response.firstHeaderValue(named: "content-type") {
            let mediaType = contentType.split(separator: ";", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard mediaType.caseInsensitiveCompare("application/sdp") == .orderedSame else {
                throw SkyBridgeCameraError.unsupportedMedia(
                    "DESCRIBE did not return application/sdp"
                )
            }
        }
        return response
    }

    private func performRequest(
        method: String,
        url: URL,
        headers: [(String, String)],
        timeout: Duration,
        generation: UInt64
    ) async throws -> RTSPResponse {
        try requireCurrent(generation, expectedState: .connecting)
        guard let connection else {
            throw SkyBridgeCameraError.invalidState("the RTSP transport is unavailable")
        }
        let deadline = ContinuousClock().now.advanced(by: timeout)
        var authenticationRetry = RTSPAuthenticationRetryState()

        requestAttempts: while true {
            let expectedCSeq = nextCSeq
            let request = try buildRequest(
                method: method,
                url: url,
                headers: headers,
                includeAuthentication: true
            )
            try await send(
                request,
                over: connection,
                timeout: try remainingDuration(until: deadline, stage: "sending \(method)"),
                stage: "sending \(method)"
            )
            try requireCurrent(generation, expectedState: .connecting)

            while true {
                let event = try await nextWireEvent(
                    over: connection,
                    generation: generation,
                    deadline: deadline,
                    stage: "waiting for \(method) response"
                )
                try requireCurrent(generation, expectedState: .connecting)
                switch event {
                case let .response(response):
                    guard response.cSeq == expectedCSeq else {
                        throw SkyBridgeCameraError.malformedResponse(
                            "the response CSeq does not match the request"
                        )
                    }
                    if response.statusCode == 401 {
                        try authenticationRetry.prepareRetry(
                            for: response,
                            credentials: configuration.credentials,
                            secureTransport: configuration.endpoint.isSecure,
                            authenticationContext: &authenticationContext
                        )
                        continue requestAttempts
                    }
                    return response
                case .interleaved:
                    throw SkyBridgeCameraError.malformedResponse(
                        "media data arrived before RTSP PLAY completed"
                    )
                }
            }
        }
    }

    func buildRequest(
        method: String,
        url: URL,
        headers: [(String, String)],
        includeAuthentication: Bool
    ) throws -> Data {
        guard method.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }), !method.isEmpty else {
            throw SkyBridgeCameraError.invalidState("the RTSP method is invalid")
        }
        _ = try configuration.endpoint.validateSameOrigin(url)
        let uri = url.absoluteString
        guard !uri.isEmpty, uri.utf8.allSatisfy({ $0 != 13 && $0 != 10 }) else {
            throw SkyBridgeCameraError.invalidEndpoint("the request URI is invalid")
        }
        guard nextCSeq < Int.max else {
            throw SkyBridgeCameraError.invalidState("the RTSP CSeq is exhausted")
        }
        let cSeq = nextCSeq
        nextCSeq += 1

        var requestHeaders = [
            ("CSeq", String(cSeq)),
            ("User-Agent", configuration.userAgent),
        ]
        requestHeaders.append(contentsOf: headers)
        if includeAuthentication, var context = authenticationContext {
            let authorization = try context.authorizationHeader(method: method, uri: uri)
            authenticationContext = context
            requestHeaders.append(("Authorization", authorization))
        }
        for (name, value) in requestHeaders {
            guard validHeaderName(name), validHeaderValue(value) else {
                throw SkyBridgeCameraError.invalidState("an RTSP request header is invalid")
            }
        }

        var request = "\(method) \(uri) RTSP/1.0\r\n"
        for (name, value) in requestHeaders {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        guard let data = request.data(using: .ascii) else {
            throw SkyBridgeCameraError.invalidState("the RTSP request is not ASCII")
        }
        return data
    }

    private func descriptionBaseURL(from response: RTSPResponse) throws -> URL {
        let values = response.headerValues(named: "content-base")
        guard values.count <= 1 else {
            throw SkyBridgeCameraError.malformedResponse(
                "DESCRIBE returned multiple Content-Base headers"
            )
        }
        guard let value = values.first else { return configuration.endpoint.url }
        guard let url = URL(string: value) else {
            throw SkyBridgeCameraError.malformedResponse("Content-Base is not a valid URL")
        }
        return try configuration.endpoint.validateSameOrigin(url)
    }

    struct ParsedSession: Sendable, Equatable {
        let identifier: String
        let keepaliveInterval: Duration
    }

    func parseSessionIdentifier(_ response: RTSPResponse) throws -> ParsedSession {
        let values = response.headerValues(named: "session")
        guard values.count == 1 else { throw SkyBridgeCameraError.missingSession }
        let fields = values[0].split(separator: ";", omittingEmptySubsequences: false)
        let identifier = fields[0]
            .trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 59 })
        else {
            throw SkyBridgeCameraError.missingSession
        }
        var timeoutSeconds = 60
        var foundTimeout = false
        for field in fields.dropFirst() {
            let parameter = field.trimmingCharacters(in: .whitespaces)
            if parameter.lowercased().hasPrefix("timeout=") {
                guard !foundTimeout else {
                    throw SkyBridgeCameraError.malformedResponse(
                        "Session contains duplicate timeout parameters"
                    )
                }
                let value = parameter.dropFirst("timeout=".count)
                guard value.allSatisfy(\.isNumber),
                      let parsed = Int(value), (1...86_400).contains(parsed)
                else {
                    throw SkyBridgeCameraError.malformedResponse(
                        "Session timeout is invalid"
                    )
                }
                timeoutSeconds = parsed
                foundTimeout = true
            } else if parameter.isEmpty {
                throw SkyBridgeCameraError.malformedResponse(
                    "Session contains an empty parameter"
                )
            }
        }
        let keepaliveMilliseconds = max(500, min(30_000, timeoutSeconds * 500))
        return ParsedSession(
            identifier: identifier,
            keepaliveInterval: .milliseconds(keepaliveMilliseconds)
        )
    }

    private func validateInterleavedTransport(_ response: RTSPResponse) throws {
        let values = response.headerValues(named: "transport")
        guard values.count == 1, !values[0].contains(",") else {
            throw SkyBridgeCameraError.malformedResponse(
                "SETUP did not select exactly one transport"
            )
        }
        let parameters = values[0].split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let protocolName = parameters.first,
              protocolName.caseInsensitiveCompare("RTP/AVP/TCP") == .orderedSame,
              parameters.dropFirst().contains(where: {
                  $0.caseInsensitiveCompare("unicast") == .orderedSame
              }),
              !parameters.dropFirst().contains(where: {
                  $0.caseInsensitiveCompare("multicast") == .orderedSame
              })
        else {
            throw SkyBridgeCameraError.unsupportedMedia(
                "SETUP did not select unicast RTP/AVP/TCP"
            )
        }
        let interleaved = parameters.dropFirst().filter {
            $0.lowercased().hasPrefix("interleaved=")
        }
        guard interleaved.count == 1,
              interleaved[0].dropFirst("interleaved=".count) == "0-1"
        else {
            throw SkyBridgeCameraError.unsupportedMedia(
                "SETUP did not accept interleaved channels 0-1"
            )
        }
    }

    private func requireSuccess(_ response: RTSPResponse, authenticated: Bool) throws {
        if response.statusCode == 401, authenticated {
            throw SkyBridgeCameraError.authenticationRejected
        }
        guard response.statusCode == 200 else {
            throw SkyBridgeCameraError.unexpectedStatus(
                code: response.statusCode,
                reason: "camera server response"
            )
        }
    }

    private func startReader(generation: UInt64) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            await self?.readMediaLoop(generation: generation)
        }
    }

    private func readMediaLoop(generation: UInt64) async {
        do {
            guard let connection else {
                throw SkyBridgeCameraError.invalidState("the RTSP transport is unavailable")
            }
            guard let playbackStartedAt else {
                throw SkyBridgeCameraError.invalidState("the playback clock was not initialized")
            }
            var nextKeepaliveAt = playbackStartedAt.advanced(
                by: keepaliveInterval ?? .seconds(30)
            )
            while state == .playing, self.generation == generation {
                let now = ContinuousClock().now
                let frameDeadline = currentFrameDeadline(playbackStartedAt: playbackStartedAt)
                guard now < frameDeadline else {
                    let stage = lastAccessUnitAt == nil
                        ? "waiting for the first H.264 access unit"
                        : "waiting for a subsequent H.264 access unit"
                    throw SkyBridgeCameraError.timedOut(stage)
                }
                if now >= nextKeepaliveAt {
                    try await performKeepalive(
                        over: connection,
                        generation: generation,
                        playbackStartedAt: playbackStartedAt
                    )
                    nextKeepaliveAt = ContinuousClock().now.advanced(
                        by: keepaliveInterval ?? .seconds(30)
                    )
                    continue
                }

                let eventDeadline = min(frameDeadline, nextKeepaliveAt)
                let event: RTSPWireEvent
                do {
                    event = try await nextWireEvent(
                        over: connection,
                        generation: generation,
                        deadline: eventDeadline,
                        stage: "waiting for camera media"
                    )
                } catch let error as SkyBridgeCameraError {
                    if case .timedOut = error { continue }
                    throw error
                }
                try requireCurrent(generation, expectedState: .playing)
                switch event {
                case let .interleaved(frame):
                    try handleInterleavedFrame(frame)
                case .response:
                    throw SkyBridgeCameraError.malformedResponse(
                        "an unsolicited RTSP response arrived during playback"
                    )
                }
            }
        } catch {
            guard state == .playing, self.generation == generation else { return }
            await failConnection(normalized(error), generation: generation)
        }
    }

    private func currentFrameDeadline(
        playbackStartedAt: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        if let lastAccessUnitAt {
            return lastAccessUnitAt.advanced(by: configuration.streamInactivityTimeout)
        }
        return playbackStartedAt.advanced(by: configuration.firstFrameTimeout)
    }

    private func performKeepalive(
        over connection: NWConnection,
        generation: UInt64,
        playbackStartedAt: ContinuousClock.Instant
    ) async throws {
        guard let sessionIdentifier else {
            throw SkyBridgeCameraError.missingSession
        }
        let clock = ContinuousClock()
        let deadlinePolicy = RTSPKeepaliveDeadlinePolicy(
            responseDeadline: clock.now.advanced(by: configuration.requestTimeout)
        )
        var authenticationRetry = RTSPAuthenticationRetryState()

        requestAttempts: while true {
            let sendWait = try deadlinePolicy.nextWait(
                now: clock.now,
                mediaDeadline: currentFrameDeadline(playbackStartedAt: playbackStartedAt),
                hasReceivedAccessUnit: lastAccessUnitAt != nil
            )
            let expectedCSeq = nextCSeq
            let request = try buildRequest(
                method: "OPTIONS",
                url: aggregateControlURL ?? configuration.endpoint.url,
                headers: [("Session", sessionIdentifier)],
                includeAuthentication: true
            )
            try await send(
                request,
                over: connection,
                timeout: try remainingDuration(
                    until: sendWait.deadline,
                    stage: sendWait.limitingTimeout.stage
                ),
                stage: sendWait.limitingTimeout.stage
            )
            try requireCurrent(generation, expectedState: .playing)

            while true {
                let wait = try deadlinePolicy.nextWait(
                    now: clock.now,
                    mediaDeadline: currentFrameDeadline(playbackStartedAt: playbackStartedAt),
                    hasReceivedAccessUnit: lastAccessUnitAt != nil
                )
                let event = try await nextWireEvent(
                    over: connection,
                    generation: generation,
                    deadline: wait.deadline,
                    stage: wait.limitingTimeout.stage
                )
                try requireCurrent(generation, expectedState: .playing)
                switch event {
                case let .interleaved(frame):
                    try handleInterleavedFrame(frame)
                case let .response(response):
                    guard response.cSeq == expectedCSeq else {
                        throw SkyBridgeCameraError.malformedResponse(
                            "the keepalive response CSeq does not match the request"
                        )
                    }
                    if response.statusCode == 401 {
                        try authenticationRetry.prepareRetry(
                            for: response,
                            credentials: configuration.credentials,
                            secureTransport: configuration.endpoint.isSecure,
                            authenticationContext: &authenticationContext
                        )
                        continue requestAttempts
                    }
                    try requireSuccess(
                        response,
                        authenticated: authenticationContext != nil
                    )
                    return
                }
            }
        }
    }

    @discardableResult
    private func handleInterleavedFrame(_ frame: RTSPInterleavedFrame) throws -> Bool {
        switch frame.channel {
        case 0:
            guard var depacketizer else {
                throw SkyBridgeCameraError.invalidState("the H.264 depacketizer is unavailable")
            }
            let accessUnit = try depacketizer.consume(frame.payload)
            self.depacketizer = depacketizer
            if let accessUnit {
                return processDepacketizedAccessUnit(
                    accessUnit,
                    receivedAt: ContinuousClock().now
                )
            }
            return false
        case 1:
            return false
        default:
            throw SkyBridgeCameraError.malformedResponse(
                "media arrived on an unnegotiated interleaved channel"
            )
        }
    }

    @discardableResult
    func processDepacketizedAccessUnit(
        _ accessUnit: H264AccessUnit,
        receivedAt: ContinuousClock.Instant
    ) -> Bool {
        // Parameter-set-only access units advance depacketizer state but are
        // not display frames. Publishing them could satisfy a waiter or evict
        // a valid GOP from the bounded frame queue.
        guard accessUnit.containsVideoCodingLayer else { return false }
        lastAccessUnitAt = receivedAt
        return publish(accessUnit)
    }

    @discardableResult
    func publish(_ accessUnit: H264AccessUnit) -> Bool {
        // Keep the queue boundary correct even if an internal caller bypasses
        // processDepacketizedAccessUnit. Parameter-set-only access units are
        // decoder metadata, not frames, and must never satisfy a frame waiter
        // or consume bounded GOP capacity.
        guard accessUnit.containsVideoCodingLayer else { return false }
        guard frameStreamActive, !frameStreamFinished else {
            waitingForKeyFrame = true
            return false
        }
        if waitingForKeyFrame, !accessUnit.isKeyFrame { return false }
        if accessUnit.isKeyFrame { waitingForKeyFrame = false }

        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(returning: accessUnit)
            return true
        }
        if frameQueue.count < configuration.frameBufferCapacity {
            frameQueue.append(accessUnit)
            return true
        }

        frameQueue.removeAll(keepingCapacity: true)
        waitingForKeyFrame = true
        if accessUnit.isKeyFrame {
            frameQueue.append(accessUnit)
            waitingForKeyFrame = false
            return true
        }
        return false
    }

    private func nextFrame(subscription: UInt64) async throws -> H264AccessUnit? {
        guard subscription == streamSubscriptionGeneration else {
            throw SkyBridgeCameraError.cancelled
        }
        if !frameQueue.isEmpty {
            return frameQueue.removeFirst()
        }
        if frameStreamFinished {
            if let frameStreamError { throw frameStreamError }
            return nil
        }
        guard frameWaiter == nil else {
            throw SkyBridgeCameraError.invalidState(
                "concurrent iteration of the frame stream is not supported"
            )
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                frameWaiter = continuation
            }
        } onCancel: { [weak self] in
            Task { await self?.frameConsumerTerminated(subscription: subscription) }
        }
    }

    private func finishFrameStream(throwing error: SkyBridgeCameraError?) {
        frameStreamFinished = true
        frameStreamError = error
        frameStreamActive = false
        frameQueue.removeAll(keepingCapacity: true)
        waitingForKeyFrame = true
        if let waiter = frameWaiter {
            frameWaiter = nil
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    private func cancelFrameWaiter() {
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(throwing: SkyBridgeCameraError.cancelled)
        }
        frameQueue.removeAll(keepingCapacity: true)
        frameStreamActive = false
        frameStreamFinished = true
        frameStreamError = .cancelled
        waitingForKeyFrame = true
    }

    private func nextWireEvent(
        over connection: NWConnection,
        generation: UInt64,
        deadline: ContinuousClock.Instant,
        stage: String
    ) async throws -> RTSPWireEvent {
        while true {
            if pendingEventOffset < pendingEvents.count {
                let event = pendingEvents[pendingEventOffset]
                pendingEventOffset += 1
                if pendingEventOffset == pendingEvents.count {
                    pendingEvents.removeAll(keepingCapacity: true)
                    pendingEventOffset = 0
                }
                return event
            }

            let chunk = try await receive(
                over: connection,
                generation: generation,
                timeout: try remainingDuration(until: deadline, stage: stage),
                stage: stage
            )
            if let data = chunk.data, !data.isEmpty {
                pendingEvents = try parser.append(data)
                pendingEventOffset = 0
            } else if !chunk.isComplete {
                throw SkyBridgeCameraError.transportFailed(
                    "Network.framework returned a receive without progress"
                )
            }
            if chunk.isComplete, pendingEvents.isEmpty {
                throw SkyBridgeCameraError.streamEnded
            }
        }
    }

    private func remainingDuration(
        until deadline: ContinuousClock.Instant,
        stage: String
    ) throws -> Duration {
        let now = ContinuousClock().now
        guard now < deadline else { throw SkyBridgeCameraError.timedOut(stage) }
        return now.duration(to: deadline)
    }

    private func makeConnection() throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.endpoint.port)) else {
            throw SkyBridgeCameraError.invalidEndpoint("the endpoint port is invalid")
        }
        let parameters: NWParameters
        if configuration.endpoint.isSecure {
            parameters = NWParameters(
                tls: NWProtocolTLS.Options(),
                tcp: NWProtocolTCP.Options()
            )
        } else {
            parameters = .tcp
        }
        return NWConnection(
            host: NWEndpoint.Host(configuration.endpoint.host),
            port: port,
            using: parameters
        )
    }

    private func waitUntilReady(
        _ connection: NWConnection,
        timeout: Duration,
        stage: String
    ) async throws {
        let gate = OneShot<Void>()
        let operationToken = registerNetworkCancellation {
            gate.resolve(.failure(.cancelled))
        }
        defer { clearNetworkCancellation(token: operationToken) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resolve(.success(()))
                    case let .failed(error):
                        gate.resolve(.failure(.transportFailed(Self.networkError(error))))
                    case .cancelled:
                        gate.resolve(.failure(.cancelled))
                    case .setup, .preparing, .waiting:
                        break
                    @unknown default:
                        gate.resolve(.failure(.transportFailed(
                            "Network.framework entered an unknown connection state"
                        )))
                    }
                }
                gate.attachTimeout(Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resolve(.failure(.timedOut(stage)))
                    } catch is CancellationError {
                        return
                    } catch {
                        gate.resolve(.failure(.transportFailed(
                            "the RTSP connection timeout scheduler failed unexpectedly"
                        )))
                    }
                })
                connection.start(queue: networkQueue)
            }
        } onCancel: {
            gate.resolve(.failure(.cancelled))
        }
    }

    private func send(
        _ data: Data,
        over connection: NWConnection,
        timeout: Duration,
        stage: String
    ) async throws {
        let gate = OneShot<Void>()
        let operationToken = registerNetworkCancellation {
            gate.resolve(.failure(.cancelled))
        }
        defer { clearNetworkCancellation(token: operationToken) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.attachTimeout(Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resolve(.failure(.timedOut(stage)))
                    } catch is CancellationError {
                        return
                    } catch {
                        gate.resolve(.failure(.transportFailed(
                            "the RTSP send timeout scheduler failed unexpectedly"
                        )))
                    }
                })
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        gate.resolve(.failure(.transportFailed(Self.networkError(error))))
                    } else {
                        gate.resolve(.success(()))
                    }
                })
            }
        } onCancel: {
            gate.resolve(.failure(.cancelled))
        }
    }

    private func receive(
        over connection: NWConnection,
        generation: UInt64,
        timeout: Duration,
        stage: String
    ) async throws -> RTSPReceiveChunk {
        let context = RTSPReceiveContext(
            connectionGeneration: generation,
            connectionIdentifier: ObjectIdentifier(connection)
        )
        let receiveTask = Task { [receiveBroker] in
            try await receiveBroker.receive(
                context: context,
                timeout: timeout,
                stage: stage
            ) { completion in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: RTSPPendingReceiveBroker.maximumBufferedBytes
                ) { data, _, isComplete, error in
                    Task {
                        if let error {
                            await completion(.failure(.transportFailed(
                                Self.networkError(error)
                            )))
                        } else {
                            await completion(.success(RTSPReceiveChunk(
                                data: data,
                                isComplete: isComplete
                            )))
                        }
                    }
                }
            }
        }
        let operationToken = registerNetworkCancellation {
            receiveTask.cancel()
        }
        defer { clearNetworkCancellation(token: operationToken) }
        return try await withTaskCancellationHandler {
            try await receiveTask.value
        } onCancel: {
            receiveTask.cancel()
        }
    }

    private func requireCurrent(_ generation: UInt64, expectedState: State) throws {
        guard !Task.isCancelled,
              self.generation == generation,
              state == expectedState
        else {
            throw SkyBridgeCameraError.cancelled
        }
    }

    private func registerNetworkCancellation(
        _ action: @escaping @Sendable () -> Void
    ) -> UInt64 {
        networkOperationToken &+= 1
        activeNetworkCancellation = (networkOperationToken, action)
        return networkOperationToken
    }

    private func clearNetworkCancellation(token: UInt64) {
        if activeNetworkCancellation?.token == token {
            activeNetworkCancellation = nil
        }
    }

    private func cancelActiveNetworkOperation() {
        let action = activeNetworkCancellation?.action
        activeNetworkCancellation = nil
        action?()
    }

    private func frameConsumerTerminated(subscription: UInt64) async {
        guard subscription == streamSubscriptionGeneration else { return }
        guard frameStreamActive || state == .connecting ||
                state == .playing || state == .stopping
        else { return }
        cancelFrameWaiter()
        let result = await stopResult()
        if case let .failure(error) = result {
            frameStreamError = error
        }
    }

    private func failConnection(
        _ error: SkyBridgeCameraError,
        generation: UInt64
    ) async {
        guard self.generation == generation else { return }
        self.generation &+= 1
        readerTask?.cancel()
        readerTask = nil
        await closeTransport()
        state = .closed
        finishFrameStream(throwing: error)
    }

    private func closeTransport() async {
        let closingConnection = connection
        closingConnection?.stateUpdateHandler = nil
        connection = nil
        sessionIdentifier = nil
        aggregateControlURL = nil
        keepaliveInterval = nil
        authenticationContext = nil
        depacketizer = nil
        parser.reset()
        pendingEvents.removeAll(keepingCapacity: true)
        pendingEventOffset = 0
        playbackStartedAt = nil
        lastAccessUnitAt = nil
        await receiveBroker.reset()
        closingConnection?.cancel()
    }

    private func resetProtocolState() async {
        let priorConnection = connection
        priorConnection?.stateUpdateHandler = nil
        connection = nil
        parser.reset()
        pendingEvents.removeAll(keepingCapacity: true)
        pendingEventOffset = 0
        authenticationContext = nil
        sessionIdentifier = nil
        aggregateControlURL = nil
        keepaliveInterval = nil
        depacketizer = nil
        nextCSeq = 1
        readerTask?.cancel()
        readerTask = nil
        waitingForKeyFrame = true
        playbackStartedAt = nil
        lastAccessUnitAt = nil
        await receiveBroker.reset()
        priorConnection?.cancel()
    }

    private func normalized(_ error: any Error) -> SkyBridgeCameraError {
        if let cameraError = error as? SkyBridgeCameraError { return cameraError }
        if error is CancellationError { return .cancelled }
        return .transportFailed("an unexpected transport boundary error occurred")
    }

    private func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 45
        }
    }

    private func validHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 <= 126) }
    }

    nonisolated private static func networkError(_ error: NWError) -> String {
        switch error {
        case let .posix(code):
            "POSIX category \(code.rawValue)"
        case let .dns(code):
            "DNS category \(code)"
        case let .tls(code):
            "TLS category \(code)"
        case .wifiAware:
            "Wi-Fi Aware category"
        @unknown default:
            "unknown Network.framework category"
        }
    }
}

private final class FrameStreamLifetime: @unchecked Sendable {
    private let termination: @Sendable () -> Void

    init(termination: @escaping @Sendable () -> Void) {
        self.termination = termination
    }

    deinit {
        termination()
    }
}

private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var completedResult: Result<Value, SkyBridgeCameraError>?
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result = completedResult {
            lock.unlock()
            resume(continuation, with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func attachTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if completed || continuation == nil && timeoutTask != nil {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, SkyBridgeCameraError>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        guard let continuation else {
            completedResult = result
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            lock.unlock()
            timeoutTask?.cancel()
            return
        }
        self.continuation = nil
        completedResult = result
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<Value, any Error>,
        with result: Result<Value, SkyBridgeCameraError>
    ) {
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}
