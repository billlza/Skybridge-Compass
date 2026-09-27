import Foundation
import SkyBridgeProtocolCore

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
    public let nearby: (@Sendable (Int) async throws -> OperatorNearbyResult)?
    public let connectNearby: (@Sendable (String) async throws -> OperatorNearbyConnectResult)?
    public let sendFile: (@Sendable (OperatorFileSendRequest) async throws -> AsyncStream<OperatorFileTransferEvent>)?
    public let usbDevices: (@Sendable () async throws -> OperatorUSBDevicesResult)?
    public let inspectUSB: (@Sendable (String) async throws -> USBPeerInspection)?
    public let localApproval: (@Sendable (OperatorLocalApprovalRequest) async throws -> OperatorLocalApprovalResult)?
    public let usbPeers: (@Sendable () async throws -> OperatorUSBPeersResult)?
    public let connectUSB: (@Sendable (OperatorUSBConnectRequest) async throws -> OperatorNearbyConnectResult)?
    public let connectUSBDevice: (@Sendable (OperatorUSBDeviceConnectRequest) async throws -> OperatorNearbyConnectResult)?
    public let previewTrustRecovery: (@Sendable (String, String, String?) async throws -> TrustRecoveryPreview)?
    public let desktop: (@Sendable (OperatorDesktopRequest) async throws -> OperatorDesktopResult)?
    public let fileApproval: (@Sendable (OperatorFileApprovalRequest) async throws -> OperatorFileApprovalResult)?
    public let handshakeConfiguration: (@Sendable (OperatorHandshakeRequest) async throws -> OperatorHandshakeResult)?
    public let recoverTrust: (@Sendable (OperatorTrustRecoveryRequest) async throws -> TrustMirrorRecoveryResult)?

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
        statusEvents: (@Sendable () -> AsyncStream<CrossnetControlStatusResult>)? = nil,
        nearby: (@Sendable (Int) async throws -> OperatorNearbyResult)? = nil,
        connectNearby: (@Sendable (String) async throws -> OperatorNearbyConnectResult)? = nil,
        sendFile: (@Sendable (OperatorFileSendRequest) async throws -> AsyncStream<OperatorFileTransferEvent>)? = nil,
        usbDevices: (@Sendable () async throws -> OperatorUSBDevicesResult)? = nil,
        inspectUSB: (@Sendable (String) async throws -> USBPeerInspection)? = nil,
        localApproval: (@Sendable (OperatorLocalApprovalRequest) async throws -> OperatorLocalApprovalResult)? = nil,
        usbPeers: (@Sendable () async throws -> OperatorUSBPeersResult)? = nil,
        connectUSB: (@Sendable (OperatorUSBConnectRequest) async throws -> OperatorNearbyConnectResult)? = nil,
        connectUSBDevice: (@Sendable (OperatorUSBDeviceConnectRequest) async throws -> OperatorNearbyConnectResult)? = nil,
        previewTrustRecovery: (@Sendable (String, String, String?) async throws -> TrustRecoveryPreview)? = nil,
        recoverTrust: (@Sendable (OperatorTrustRecoveryRequest) async throws -> TrustMirrorRecoveryResult)? = nil,
        desktop: (@Sendable (OperatorDesktopRequest) async throws -> OperatorDesktopResult)? = nil,
        fileApproval: (@Sendable (OperatorFileApprovalRequest) async throws -> OperatorFileApprovalResult)? = nil,
        handshakeConfiguration: (@Sendable (OperatorHandshakeRequest) async throws -> OperatorHandshakeResult)? = nil
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
        self.nearby = nearby
        self.connectNearby = connectNearby
        self.sendFile = sendFile
        self.usbDevices = usbDevices
        self.usbPeers = usbPeers
        self.inspectUSB = inspectUSB
        self.localApproval = localApproval
        self.connectUSB = connectUSB
        self.connectUSBDevice = connectUSBDevice
        self.previewTrustRecovery = previewTrustRecovery
        self.recoverTrust = recoverTrust
        self.handshakeConfiguration = handshakeConfiguration
        self.fileApproval = fileApproval
        self.desktop = desktop
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
        if let request = try? CrossnetControlWire.decodeRequest(line: line),
           request.method == "crossnet.file.send" {
            return await fileStream(request)
        }
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

    private func fileStream(_ request: CrossnetControlRequest) async -> CrossnetControlLineOutcome {
        do {
            try Self.requireAuthenticatedOperatorContext(await runtime.hello())
            guard let sendFile = runtime.sendFile else { throw CrossnetControlFailure.methodNotEnabled }
            let send = try OperatorFileSendRequest(operationID: request.id, params: request.params)
            let source = try await sendFile(send)
            let initial = try CrossnetControlWire.successData(
                id: request.id,
                result: OperatorFileTransferEvent(request: send, status: .preparing)
            )
            let events = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let bridge = Task {
                    for await event in source {
                        if Task.isCancelled { break }
                        do {
                            guard event.operation_id == send.operationID,
                                  event.device_ref == send.deviceRef else {
                                throw CrossnetControlFailure.internalError("transfer event binding mismatch")
                            }
                            continuation.yield(try CrossnetControlWire.eventData(
                                event: "file_transfer", data: event.validated()
                            ))
                        } catch {
                            continuation.yield(CrossnetControlWire.failureData(
                                id: request.id, failure: .internalError("invalid transfer event")
                            ))
                            break
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in bridge.cancel() }
            }
            return .stream(initial: initial, events: events)
        } catch let failure as CrossnetControlFailure {
            return .response(CrossnetControlWire.failureData(id: request.id, failure: failure))
        } catch {
            return .response(CrossnetControlWire.failureData(
                id: request.id, failure: .internalError("file transfer could not start")
            ))
        }
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
            case "crossnet.desktop.devices", "crossnet.desktop.start", "crossnet.desktop.status", "crossnet.desktop.stop":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let desktop = runtime.desktop,
                      let action = OperatorDesktopRequest.Action(rawValue: String(request.method.split(separator: ".").last ?? "")) else {
                    throw CrossnetControlFailure.methodNotEnabled
                }
                let input = try OperatorDesktopRequest(action: action, params: request.params)
                return try CrossnetControlWire.successData(id: request.id, result: await desktop(input))
            case "crossnet.file.approval.status", "crossnet.file.approval.authorize", "crossnet.file.approval.decide", "crossnet.file.approval.revoke":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let handler = runtime.fileApproval,
                      let action = OperatorFileApprovalRequest.Action(rawValue: String(request.method.split(separator: ".").last ?? "")) else {
                    throw CrossnetControlFailure.methodNotEnabled
                }
                let input = try OperatorFileApprovalRequest(action: action, params: request.params)
                let result = try await handler(input)
                return try CrossnetControlWire.successData(id: request.id, result: result)
            case "crossnet.handshake.list", "crossnet.handshake.status", "crossnet.handshake.set", "crossnet.handshake.revoke":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let handler = runtime.handshakeConfiguration,
                      let action = OperatorHandshakeRequest.Action(rawValue: String(request.method.split(separator: ".").last ?? "")) else {
                    throw CrossnetControlFailure.methodNotEnabled
                }
                let input = try OperatorHandshakeRequest(action: action, params: request.params)
                let result: OperatorHandshakeResult
                do {
                    if action == .set || action == .revoke {
                        result = try await sessionGate.run { try await handler(input) }
                    } else { result = try await handler(input) }
                } catch let failure as CrossnetControlFailure { throw failure }
                catch { throw CrossnetControlFailure.sessionMutationRejected("handshake_configuration_failed") }
                return try CrossnetControlWire.successData(id: request.id, result: result)
            case "crossnet.trust.recover":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let recover = runtime.recoverTrust else { throw CrossnetControlFailure.methodNotEnabled }
                let input = try OperatorTrustRecoveryRequest(params: request.params)
                do {
                    let result = try await sessionGate.run { try await recover(input) }
                    return try CrossnetControlWire.successData(id: request.id, result: result)
                } catch let failure as CrossnetControlFailure { throw failure }
                catch { throw Self.nearbyConnectionFailure(error) }
            case "crossnet.trust.preview":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let preview = runtime.previewTrustRecovery else { throw CrossnetControlFailure.methodNotEnabled }
                let preserved = request.params.string("preserve_shared_peer_id")
                guard !request.params.contains("preserve_shared_peer_id") || preserved.flatMap(UUID.init(uuidString:)) != nil else {
                    throw CrossnetControlFailure.malformedRequest("shared peer preservation requires a stable UUID")
                }
                guard let peer = request.params.string("peer_id"), UUID(uuidString: peer) != nil,
                      let fingerprint = request.params.string("expected_fingerprint"), fingerprint.count == 64,
                      fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw CrossnetControlFailure.malformedRequest("trust preview requires a stable peer UUID and full lowercase protocol fingerprint")
                }
                do {
                    return try CrossnetControlWire.successData(id: request.id, result: await preview(peer, fingerprint, preserved))
                } catch let failure as CrossnetControlFailure { throw failure }
                catch { throw Self.nearbyConnectionFailure(error) }
            case "crossnet.usb.devices":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let devices = runtime.usbDevices else { throw CrossnetControlFailure.methodNotEnabled }
                do {
                    return try CrossnetControlWire.successData(id: request.id, result: await devices())
                } catch let failure as CrossnetControlFailure { throw failure }
                catch { throw Self.nearbyConnectionFailure(error) }
            case "crossnet.approval.pending", "crossnet.approval.decide":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let handler = runtime.localApproval,
                      let action = OperatorLocalApprovalRequest.Action(rawValue: String(request.method.split(separator: ".").last ?? "")) else {
                    throw CrossnetControlFailure.methodNotEnabled
                }
                let input = try OperatorLocalApprovalRequest(action: action, params: request.params)
                return try CrossnetControlWire.successData(id: request.id, result: await handler(input))
            case "crossnet.usb.inspect":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let inspect = runtime.inspectUSB else { throw CrossnetControlFailure.methodNotEnabled }
                guard let udid = request.params.string("udid"), (24...64).contains(udid.utf8.count),
                      udid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }) else {
                    throw CrossnetControlFailure.malformedRequest("USB inspection requires a physical UDID")
                }
                let result: USBPeerInspection
                do { result = try await inspect(udid) }
                catch let failure as CrossnetControlFailure { throw failure }
                catch let failure as USBPeerDiscoveryError {
                    throw CrossnetControlFailure.sessionMutationRejected("usb_inspection_\(failure.rawValue)")
                } catch let failure as HandshakeConfigurationError {
                    throw CrossnetControlFailure.sessionMutationRejected("usb_inspection_\(failure.rawValue)")
                } catch { throw Self.nearbyConnectionFailure(error) }
                return try CrossnetControlWire.successData(id: request.id, result: result)
            case "crossnet.usb.peers":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let peers = runtime.usbPeers else { throw CrossnetControlFailure.methodNotEnabled }
                do {
                    return try CrossnetControlWire.successData(id: request.id, result: await peers())
                } catch let failure as CrossnetControlFailure { throw failure }
                catch { throw CrossnetControlFailure.sessionMutationRejected("usb_pairing_catalog_unavailable") }
            case "crossnet.usb.connect_device":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let connect = runtime.connectUSBDevice else { throw CrossnetControlFailure.methodNotEnabled }
                let input = try OperatorUSBDeviceConnectRequest(params: request.params)
                let result: OperatorNearbyConnectResult
                do { result = try await sessionGate.run { try await connect(input) } }
                catch let failure as CrossnetControlFailure { throw failure }
                catch { throw Self.nearbyConnectionFailure(error) }
                guard result.device_ref == input.deviceRef, result.authenticated,
                      result.transport == "usb", result.pqc == true,
                      let fingerprint = result.peer_fingerprint, fingerprint.count == 64,
                      fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      result.negotiated_suite?.isEmpty == false else {
                    throw CrossnetControlFailure.sessionRuntimeApplyFailed
                }
                return try CrossnetControlWire.successData(id: request.id, result: result)
            case "crossnet.usb.connect":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let connect = runtime.connectUSB else { throw CrossnetControlFailure.methodNotEnabled }
                let input = try OperatorUSBConnectRequest(params: request.params)
                let result: OperatorNearbyConnectResult
                do { result = try await sessionGate.run { try await connect(input) } }
                catch let failure as CrossnetControlFailure { throw failure }
                catch { throw Self.nearbyConnectionFailure(error) }
                guard result.authenticated, result.transport == "usb",
                      result.pqc == true,
                      result.peer_fingerprint == input.expectedFingerprint,
                      result.negotiated_suite?.isEmpty == false else {
                    throw CrossnetControlFailure.sessionRuntimeApplyFailed
                }
                return try CrossnetControlWire.successData(id: request.id, result: result)
            case "crossnet.nearby":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let nearby = runtime.nearby else { throw CrossnetControlFailure.methodNotEnabled }
                guard let seconds = request.params.int("scan_seconds"), (0...10).contains(seconds) else {
                    throw CrossnetControlFailure.malformedRequest("scan_seconds must be 0...10")
                }
                return try CrossnetControlWire.successData(id: request.id, result: await nearby(seconds))
            case "crossnet.connect_nearby":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                guard let connect = runtime.connectNearby else { throw CrossnetControlFailure.methodNotEnabled }
                guard let ref = request.params.string("device_ref"), UUID(uuidString: ref) != nil else {
                    throw CrossnetControlFailure.malformedRequest("device_ref must be a discovery reference")
                }
                let result: OperatorNearbyConnectResult
                do {
                    result = try await sessionGate.run { try await connect(ref) }
                } catch let failure as CrossnetControlFailure {
                    throw failure
                } catch {
                    SkyBridgeLogger.p2p.error(
                        "Operator nearby connection failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                    )
                    throw Self.nearbyConnectionFailure(error)
                }
                guard result.authenticated, result.device_ref == ref else {
                    throw CrossnetControlFailure.sessionRuntimeApplyFailed
                }
                return try CrossnetControlWire.successData(id: request.id, result: result)
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
                guard !request.params.contains("include_extended") || request.params.bool("include_extended") != nil else {
                    throw CrossnetControlFailure.malformedRequest("include_extended must be boolean")
                }
                let projected = request.params.bool("include_extended") == true ? snapshot :
                    CrossnetControlSettingsSnapshotResult(settings: snapshot.settings.filter {
                        CrossnetControlSettingsProjectionPolicy.allowedSettingIDs.contains($0.id)
                    })
                return try CrossnetControlWire.successData(id: request.id, result: projected)
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

    /// Runtime errors must not fall into the response-encoding failure boundary.
    /// Publish closed reason codes; peer-supplied descriptions stay out of IPC.
    private static func nearbyConnectionFailure(_ error: Error) -> CrossnetControlFailure {
        #if os(macOS)
        if let usb = error as? USBMultiplexError {
            if usb == .deviceUnavailable { return .usbDeviceUnavailable }
            return .sessionMutationRejected("usb_\(usb.rawValue)")
        }
        #endif
        let reason: String
        if let rejection = error as? AuthenticatedRemoteAuthorityRejection {
            reason = "nearby_authority_rejected:\(rejection.rawValue)"
        } else if let discovery = error as? P2PDiscoveryError {
            switch discovery {
            case .deviceNotConnected: reason = "nearby_peer_not_connected"
            case .connectionCancelled: reason = "nearby_connection_cancelled"
            case .timeout: reason = "nearby_connection_timed_out"
            case .scanningFailed: reason = "nearby_scan_failed"
            case .noConnectableEndpoint: reason = "nearby_no_connectable_endpoint"
            case .noLiveControlRoute: reason = "nearby_no_live_control_route"
            case .localDeviceTarget: reason = "nearby_local_device_target"
            case .targetAuthorityConflict: reason = "nearby_identity_conflict"
            case .localNetworkPermissionDenied: reason = "nearby_local_network_permission_denied"
            case .strictPQCTrustPreflightFailed: reason = "nearby_trust_preflight_failed"
            case .peerPQCSuiteUnavailable: return .peerPQCSuiteUnavailable
            }
        } else if error is CancellationError {
            reason = "nearby_connection_cancelled"
        } else {
            reason = "nearby_connection_failed"
        }
        return .sessionMutationRejected(reason)
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
