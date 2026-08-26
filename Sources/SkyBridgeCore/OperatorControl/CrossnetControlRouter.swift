import Foundation

/// Serializes session-plane mutations so a read-back describes the mutation it
/// belongs to.
///
/// ``OperatorControlServer`` handles every accepted client on its own detached
/// task, and `crossnet.host` / `crossnet.connect` / `crossnet.disconnect` all
/// suspend between mutating the runtime and re-reading it. Without this gate two
/// concurrent operator calls interleave and each one's "read-back" can describe
/// the other's effect — the validation would look strict while proving nothing.
///
/// A second concurrent call is refused rather than queued: an operator waiting
/// behind an unbounded queue for a verb that already changed session state is
/// worse than a clear, immediate rejection.
public actor CrossnetControlSessionGate {
    private var inFlight = false

    public init() {}

    func run<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard !inFlight else {
            throw CrossnetControlFailure.sessionMutationRejected("concurrent_session_mutation")
        }
        inFlight = true
        defer { inFlight = false }
        return try await body()
    }
}

public struct CrossnetControlRuntime: Sendable {
    public let hello: @Sendable () async -> CrossnetControlHelloResult
    public let status: @Sendable () async -> CrossnetControlStatusResult
    public let settingsSnapshot: @Sendable () async -> CrossnetControlSettingsSnapshotResult
    /// Applies one allowlisted setting to the live Mac app runtime and reports the
    /// value read back afterwards.
    ///
    /// Defaults to ``unavailableSettingsMutation``, so a runtime that does not
    /// explicitly wire mutation up keeps the previous `method_not_enabled`
    /// behaviour instead of silently gaining write authority.
    public let applySetting: @Sendable (CrossnetControlSettingsMutationRequest) async throws
        -> CrossnetControlSettingsMutationResult
    /// Issues a connection code against the live Mac app runtime.
    ///
    /// Like ``applySetting`` this defaults to a fail-closed handler, so a host
    /// process that does not deliberately grant session authority keeps the
    /// previous `method_not_enabled` behaviour.
    public let hostSession: @Sendable (CrossnetControlHostLeaseMode) async throws
        -> CrossnetControlHostResult
    /// Redeems a connection code against the live Mac app runtime.
    public let connectSession: @Sendable (String) async throws -> CrossnetControlConnectResult
    /// Tears down the live Mac app runtime's cross-network session.
    public let disconnectSession: @Sendable () async throws -> CrossnetControlDisconnectResult
    /// Navigates the Mac app UI to a typed destination and reports the
    /// destination the UI confirmed presenting.
    public let navigate: @Sendable (CrossnetControlNavigationDestination) async throws
        -> CrossnetControlNavigateResult
    /// Lists the app's online account devices, redacted for the operator.
    public let listOnlineDevices: @Sendable () async throws -> CrossnetControlDevicesResult
    /// One-click join of an online account device by redacted reference.
    public let connectOnlineDevice: @Sendable (String) async throws
        -> CrossnetControlConnectDeviceResult
    /// A live source of status snapshots for `crossnet.status --watch`.
    ///
    /// `nil` means this build does not push status: `crossnet.status` with
    /// `watch:true` fails closed with `watch_not_supported`, exactly as before.
    /// When wired, each yielded snapshot is encoded as one `status` event frame
    /// after the initial response. The stream should coalesce to the latest
    /// value and end when its consumer stops (client disconnect).
    public let statusEvents: (@Sendable () -> AsyncStream<CrossnetControlStatusResult>)?

    public init(
        hello: @escaping @Sendable () async -> CrossnetControlHelloResult,
        status: @escaping @Sendable () async -> CrossnetControlStatusResult,
        settingsSnapshot: @escaping @Sendable () async -> CrossnetControlSettingsSnapshotResult,
        applySetting: @escaping @Sendable (CrossnetControlSettingsMutationRequest) async throws
            -> CrossnetControlSettingsMutationResult = CrossnetControlRuntime
            .unavailableSettingsMutation,
        hostSession: @escaping @Sendable (CrossnetControlHostLeaseMode) async throws
            -> CrossnetControlHostResult = CrossnetControlRuntime.unavailableHostSession,
        connectSession: @escaping @Sendable (String) async throws
            -> CrossnetControlConnectResult = CrossnetControlRuntime.unavailableConnectSession,
        disconnectSession: @escaping @Sendable () async throws
            -> CrossnetControlDisconnectResult = CrossnetControlRuntime
            .unavailableDisconnectSession,
        navigate: @escaping @Sendable (CrossnetControlNavigationDestination) async throws
            -> CrossnetControlNavigateResult = CrossnetControlRuntime.unavailableNavigation,
        listOnlineDevices: @escaping @Sendable () async throws
            -> CrossnetControlDevicesResult = CrossnetControlRuntime.unavailableListOnlineDevices,
        connectOnlineDevice: @escaping @Sendable (String) async throws
            -> CrossnetControlConnectDeviceResult = CrossnetControlRuntime
            .unavailableConnectOnlineDevice,
        statusEvents: (@Sendable () -> AsyncStream<CrossnetControlStatusResult>)? = nil
    ) {
        self.hello = hello
        self.status = status
        self.settingsSnapshot = settingsSnapshot
        self.applySetting = applySetting
        self.hostSession = hostSession
        self.connectSession = connectSession
        self.disconnectSession = disconnectSession
        self.navigate = navigate
        self.listOnlineDevices = listOnlineDevices
        self.connectOnlineDevice = connectOnlineDevice
        self.statusEvents = statusEvents
    }

    /// Fail-closed default mutation handler.
    public static let unavailableSettingsMutation:
        @Sendable (CrossnetControlSettingsMutationRequest) async throws
        -> CrossnetControlSettingsMutationResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }

    /// Fail-closed default session handlers.
    public static let unavailableHostSession:
        @Sendable (CrossnetControlHostLeaseMode) async throws
        -> CrossnetControlHostResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }

    public static let unavailableConnectSession:
        @Sendable (String) async throws -> CrossnetControlConnectResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }

    public static let unavailableDisconnectSession:
        @Sendable () async throws -> CrossnetControlDisconnectResult = {
            throw CrossnetControlFailure.methodNotEnabled
        }

    public static let unavailableNavigation:
        @Sendable (CrossnetControlNavigationDestination) async throws
        -> CrossnetControlNavigateResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }

    public static let unavailableListOnlineDevices:
        @Sendable () async throws -> CrossnetControlDevicesResult = {
            throw CrossnetControlFailure.methodNotEnabled
        }

    public static let unavailableConnectOnlineDevice:
        @Sendable (String) async throws -> CrossnetControlConnectDeviceResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }
}

/// The result of routing one input line: a single response, or a live stream
/// (an initial response frame followed by unsolicited event frames).
public enum CrossnetControlLineOutcome: Sendable {
    case response(Data)
    case stream(initial: Data, events: AsyncStream<Data>)
}

public struct CrossnetControlRouter: Sendable {
    private let runtime: CrossnetControlRuntime
    private let sessionGate: CrossnetControlSessionGate

    public init(
        runtime: CrossnetControlRuntime,
        sessionGate: CrossnetControlSessionGate = CrossnetControlSessionGate()
    ) {
        self.runtime = runtime
        self.sessionGate = sessionGate
    }

    /// One line of input, resolved to either a single response or a live stream.
    ///
    /// Only `crossnet.status` with `watch:true` on a build that wired
    /// ``CrossnetControlRuntime/statusEvents`` produces `.stream`; every other
    /// request — including `watch:true` on a build without a push source —
    /// resolves to `.response` via ``handleLine(_:)``, unchanged.
    public func handleLineStreaming(_ line: Data) async -> CrossnetControlLineOutcome {
        guard
            let request = try? CrossnetControlWire.decodeRequest(line: line),
            request.method == "crossnet.status",
            request.params.bool("watch") == true,
            let statusEvents = runtime.statusEvents
        else {
            return .response(await handleLine(line))
        }

        // The first frame is the ordinary response carrying the initial
        // snapshot, correlated by id; the client then reads unsolicited events.
        let initialResult = await runtime.status()
        guard
            let initial = try? CrossnetControlWire.successData(
                id: request.id,
                result: initialResult
            )
        else {
            return .response(
                CrossnetControlWire.failureData(
                    id: request.id,
                    failure: .internalError("failed to encode status")
                )
            )
        }

        let events = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let bridge = Task {
                for await snapshot in statusEvents() {
                    if Task.isCancelled { break }
                    guard
                        let frame = try? CrossnetControlWire.eventData(
                            event: "status",
                            data: snapshot
                        )
                    else { continue }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in bridge.cancel() }
        }
        return .stream(initial: initial, events: events)
    }

    public func handleLine(_ line: Data) async -> Data {
        let request: CrossnetControlRequest
        do {
            request = try CrossnetControlWire.decodeRequest(line: line)
        } catch let failure as CrossnetControlFailure {
            return CrossnetControlWire.failureData(id: nil, failure: failure)
        } catch {
            return CrossnetControlWire.failureData(
                id: nil,
                failure: .malformedRequest("invalid JSON request")
            )
        }

        do {
            switch request.method {
            case "crossnet.hello":
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: await runtime.hello()
                )
            case "crossnet.status":
                if request.params.bool("watch") == true {
                    throw CrossnetControlFailure.watchNotSupported
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: await runtime.status()
                )
            case "crossnet.settings.snapshot":
                let snapshot = try CrossnetControlSettingsProjectionPolicy.validate(
                    await runtime.settingsSnapshot()
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: snapshot
                )
            case "crossnet.settings.set":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let mutation = try CrossnetControlSettingsMutationPolicy.parse(
                    params: request.params
                )
                let applied = try CrossnetControlSettingsMutationPolicy.validate(
                    try await runtime.applySetting(mutation),
                    request: mutation
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: applied
                )
            case "crossnet.connect":
                // Code shape is validated before auth so a malformed code is
                // reported as `invalid_code` rather than masked by auth state.
                let code = try CrossnetControlWire.strictConnectionCode(
                    request.params.string("code")
                )
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let connected = try await sessionGate.run { [runtime] in
                    try CrossnetControlSessionMutationPolicy.validate(
                        try await runtime.connectSession(code)
                    )
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: connected
                )
            case "crossnet.host":
                let leaseMode = try CrossnetControlHostLeaseMode.parse(params: request.params)
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let hosted = try await sessionGate.run { [runtime] in
                    try CrossnetControlSessionMutationPolicy.validate(
                        try await runtime.hostSession(leaseMode),
                        request: leaseMode
                    )
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: hosted
                )
            case "crossnet.disconnect":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let torn = try await sessionGate.run { [runtime] in
                    try CrossnetControlSessionMutationPolicy.validate(
                        try await runtime.disconnectSession()
                    )
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: torn
                )
            case "crossnet.devices":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let devices = try CrossnetControlDevicePolicy.validate(
                    try await runtime.listOnlineDevices()
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: devices
                )
            case "crossnet.connect_device":
                let deviceRef = try CrossnetControlDevicePolicy.parseDeviceRef(
                    params: request.params
                )
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let joined = try await sessionGate.run { [runtime] in
                    try CrossnetControlDevicePolicy.validate(
                        try await runtime.connectOnlineDevice(deviceRef),
                        request: deviceRef
                    )
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: joined
                )
            case "crossnet.navigate":
                // Destination shape is validated before auth so an unknown
                // destination is reported as such rather than masked by auth
                // state — mirroring how connect validates the code first.
                let destination = try CrossnetControlNavigationDestination.parse(
                    params: request.params
                )
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let navigated = try CrossnetControlNavigationPolicy.validate(
                    try await runtime.navigate(destination),
                    request: destination
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: navigated
                )
            default:
                throw CrossnetControlFailure.methodNotFound
            }
        } catch let failure as CrossnetControlFailure {
            return CrossnetControlWire.failureData(id: request.id, failure: failure)
        } catch {
            return CrossnetControlWire.failureData(
                id: request.id,
                failure: .internalError("failed to encode response")
            )
        }
    }

    private static func requireAuthenticatedOperatorContext(_ hello: CrossnetControlHelloResult) throws {
        guard hello.authLoaded else {
            throw CrossnetControlFailure.authRequired
        }
        guard hello.tenantBound else {
            throw CrossnetControlFailure.tenantRequired
        }
    }
}
