import Combine
import Foundation
import SkyBridgeCore

#if os(macOS)
public extension CrossnetControlRuntime {
    @MainActor
    static func live() -> CrossnetControlRuntime {
        live(engineVersion: OperatorControlRuntimeFactory.defaultEngineVersion())
    }

    @MainActor
    static func live(engineVersion: String) -> CrossnetControlRuntime {
        CrossnetControlRuntime(
            hello: {
                // The GUI's authenticated paths refresh an expired token before
                // resolving tenant identity; the operator gate must match, or a
                // stale stored token reads as auth-loaded-but-tenant-unbound
                // while the GUI works fine.
                let auth = await OperatorControlRuntimeFactory.refreshedAuthState()
                return await MainActor.run {
                    CrossnetControlRuntimeProjection.hello(
                        engineVersion: engineVersion,
                        auth: auth
                    )
                }
            },
            status: {
                await MainActor.run {
                    OperatorControlRuntimeFactory.status(manager: .shared)
                }
            },
            settingsSnapshot: {
                await MainActor.run {
                    OperatorControlRuntimeFactory.settingsSnapshot(
                        settingsManager: .shared,
                        remoteDesktopSettingsManager: .shared
                    )
                }
            },
            applySetting: { request in
                try await MainActor.run {
                    try OperatorControlRuntimeFactory.applySetting(
                        request,
                        settingsManager: .shared,
                        remoteDesktopSettingsManager: .shared
                    )
                }
            },
            hostSession: { leaseMode in
                try await OperatorControlRuntimeFactory.hostSession(
                    leaseMode,
                    manager: await MainActor.run { CrossNetworkConnectionManager.shared }
                )
            },
            connectSession: { code in
                try await OperatorControlRuntimeFactory.connectSession(
                    code,
                    manager: await MainActor.run { CrossNetworkConnectionManager.shared }
                )
            },
            disconnectSession: {
                await OperatorControlRuntimeFactory.disconnectSession(
                    manager: await MainActor.run { CrossNetworkConnectionManager.shared }
                )
            },
            navigate: { destination in
                try await OperatorControlRuntimeFactory.navigate(
                    to: destination,
                    coordinator: await MainActor.run { OperatorNavigationCoordinator.shared }
                )
            },
            listOnlineDevices: {
                await MainActor.run {
                    OperatorControlRuntimeFactory.listOnlineDevices(manager: .shared)
                }
            },
            connectOnlineDevice: { deviceRef in
                try await OperatorControlRuntimeFactory.connectOnlineDevice(
                    deviceRef,
                    manager: await MainActor.run { UnifiedOnlineDeviceManager.shared }
                )
            },
            statusEvents: {
                OperatorControlRuntimeFactory.liveStatusEvents()
            }
        )
    }
}

/// Wire lease vocabulary <-> runtime lease vocabulary.
///
/// Kept in the app layer so the `crossnet-control/1` wire enum stays a pure
/// protocol type and does not take a dependency on the connection manager's
/// own lease vocabulary.
private extension CrossnetControlHostLeaseMode {
    var runtimeLeaseMode: CrossNetworkConnectionManager.ConnectionCodeLeaseMode {
        switch self {
        case .short:
            return .shortLived
        case .long:
            return .dayStable
        }
    }

    init?(runtime: CrossNetworkConnectionManager.ConnectionCodeLeaseMode) {
        switch runtime {
        case .shortLived:
            self = .short
        case .dayStable:
            self = .long
        }
    }
}

enum OperatorControlRuntimeFactory {
    @MainActor
    static func defaultEngineVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let normalizedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedVersion, !normalizedVersion.isEmpty,
           let normalizedBuild, !normalizedBuild.isEmpty {
            return "\(normalizedVersion)+\(normalizedBuild)"
        }
        if let normalizedVersion, !normalizedVersion.isEmpty {
            return normalizedVersion
        }
        return "development"
    }

    @MainActor
    static func status(manager: CrossNetworkConnectionManager) -> CrossnetControlStatusResult {
        let auth = authState()
        return CrossnetControlRuntimeProjection.status(
            auth: auth,
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: manager.connectionStatus,
                readiness: manager.readiness,
                activeSessionSnapshot: manager.activeSessionSnapshot,
                currentConnectionID: manager.currentConnection?.id,
                signalingHealth: manager.signalingHealth
            )
        )
    }

    @MainActor
    static func settingsSnapshot(
        settingsManager: SettingsManager,
        remoteDesktopSettingsManager: RemoteDesktopSettingsManager
    ) -> CrossnetControlSettingsSnapshotResult {
        let display = remoteDesktopSettingsManager.settings.displaySettings
        return CrossnetControlRuntimeProjection.settingsSnapshot(
            CrossnetControlSettingsRuntimeSnapshot(
                enableVerboseLogging: settingsManager.enableVerboseLogging,
                logLevel: settingsManager.logLevel,
                showRealtimeFPS: settingsManager.showRealtimeFPS,
                showTopBarIPLocation: settingsManager.showTopBarIPLocation,
                showTopBarNetworkSpeed: settingsManager.showTopBarNetworkSpeed,
                showTopBarNetworkLatency: settingsManager.showTopBarNetworkLatency,
                preferXWingHybrid: settingsManager.preferXWingHybrid,
                pqcSignatureAlgorithm: settingsManager.pqcSignatureAlgorithm,
                remoteDesktopTargetFrameRate: display.targetFrameRate,
                remoteDesktopResolution: display.resolution.rawValue
            )
        )
    }

    /// Writes one allowlisted setting to the live `SettingsManager`, runs the
    /// runtime apply hook, then re-reads the property so the reported
    /// `observed_value` is the runtime's own state rather than the request echo.
    ///
    /// The router rejects the result when the read-back does not match, so a
    /// property whose `didSet` clamps or refuses the value cannot be reported as
    /// applied.
    @MainActor
    static func applySetting(
        _ request: CrossnetControlSettingsMutationRequest,
        settingsManager: SettingsManager,
        remoteDesktopSettingsManager: RemoteDesktopSettingsManager
    ) throws -> CrossnetControlSettingsMutationResult {
        switch (request.id, request.value) {
        case ("logging.verbose", .bool(let value)):
            settingsManager.enableVerboseLogging = value
        case ("ui.show_realtime_fps", .bool(let value)):
            settingsManager.showRealtimeFPS = value
        case ("ui.top_bar_ip_location", .bool(let value)):
            settingsManager.showTopBarIPLocation = value
        case ("ui.top_bar_network_speed", .bool(let value)):
            settingsManager.showTopBarNetworkSpeed = value
        case ("ui.top_bar_network_latency", .bool(let value)):
            settingsManager.showTopBarNetworkLatency = value
        case ("logging.level", .string(let value)):
            settingsManager.logLevel = value
        case ("remote_desktop.target_fps", .int(let value)):
            remoteDesktopSettingsManager.settings.displaySettings.targetFrameRate = value
        case ("remote_desktop.resolution", .string(let value)):
            guard let resolution = ResolutionSetting(rawValue: value) else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            remoteDesktopSettingsManager.settings.displaySettings.resolution = resolution
        default:
            throw CrossnetControlFailure.settingInvalidValue
        }

        settingsManager.applyRuntimeSettingsSnapshot()
        remoteDesktopSettingsManager.saveSettings()

        let observed = try observedSettingValue(
            request.id,
            settingsManager: settingsManager,
            remoteDesktopSettingsManager: remoteDesktopSettingsManager
        )
        return CrossnetControlSettingsMutationResult(
            id: request.id,
            valueType: request.value.valueType,
            requestedValue: request.value,
            observedValue: observed,
            runtimeApplied: true
        )
    }

    @MainActor
    private static func observedSettingValue(
        _ id: String,
        settingsManager: SettingsManager,
        remoteDesktopSettingsManager: RemoteDesktopSettingsManager
    ) throws -> CrossnetControlJSONValue {
        switch id {
        case "logging.verbose":
            return .bool(settingsManager.enableVerboseLogging)
        case "logging.level":
            return .string(settingsManager.logLevel)
        case "ui.show_realtime_fps":
            return .bool(settingsManager.showRealtimeFPS)
        case "ui.top_bar_ip_location":
            return .bool(settingsManager.showTopBarIPLocation)
        case "ui.top_bar_network_speed":
            return .bool(settingsManager.showTopBarNetworkSpeed)
        case "ui.top_bar_network_latency":
            return .bool(settingsManager.showTopBarNetworkLatency)
        case "remote_desktop.target_fps":
            return .int(remoteDesktopSettingsManager.settings.displaySettings.targetFrameRate)
        case "remote_desktop.resolution":
            return .string(
                remoteDesktopSettingsManager.settings.displaySettings.resolution.rawValue
            )
        default:
            throw CrossnetControlFailure.settingNotFound
        }
    }

    /// Issues a connection code through the live `CrossNetworkConnectionManager`.
    ///
    /// Uses `issueConnectionCode(leaseMode:)` — the manager's documented
    /// operator entry point — rather than `generateConnectionCode()`, so a
    /// one-shot CLI argument is never expressed by writing the GUI's
    /// `connectionCodeLeaseMode` preference.
    static func hostSession(
        _ leaseMode: CrossnetControlHostLeaseMode,
        manager: CrossNetworkConnectionManager
    ) async throws -> CrossnetControlHostResult {
        let issued: CrossNetworkConnectionManager.IssuedConnectionCode
        do {
            issued = try await manager.issueConnectionCode(leaseMode: leaseMode.runtimeLeaseMode)
        } catch {
            throw Self.sessionMutationFailure(error)
        }
        // Report the lease the runtime actually applied. The router rejects a
        // mismatch, so a downgraded lease cannot be presented as the requested
        // one.
        guard let appliedLease = CrossnetControlHostLeaseMode(runtime: issued.leaseMode) else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        return CrossnetControlHostResult(
            code: issued.code,
            sessionRef: CrossnetControlSessionRef.redacted(issued.sessionID),
            expiresAt: issued.expiresAt.map { $0.formatted(.iso8601) },
            leaseMode: appliedLease
        )
    }

    /// Redeems a connection code through the live manager and reports the
    /// readiness read back afterwards.
    ///
    /// `connectWithCode` returns once the offer session has started, not once
    /// the peer has answered, so readiness is re-read from the manager instead
    /// of being asserted by this function.
    static func connectSession(
        _ code: String,
        manager: CrossNetworkConnectionManager
    ) async throws -> CrossnetControlConnectResult {
        let connection: RemoteConnection
        do {
            connection = try await manager.connectWithCode(code)
        } catch {
            throw Self.sessionMutationFailure(error)
        }
        let observed = await MainActor.run {
            (
                readiness: CrossnetControlRuntimeProjection.readinessString(manager.readiness),
                status: CrossnetControlRuntimeProjection
                    .connectionStatusString(manager.connectionStatus)
            )
        }
        let deviceName = connection.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CrossnetControlConnectResult(
            sessionRef: CrossnetControlSessionRef.redacted(connection.id),
            remoteDeviceName: deviceName.isEmpty ? nil : deviceName,
            readiness: observed.readiness,
            connectionStatus: observed.status
        )
    }

    /// Tears down the live cross-network session and reports the post-teardown
    /// read-back.
    ///
    /// `disconnect()` is non-throwing, so honesty here comes entirely from
    /// re-reading the manager afterwards: the router rejects the result when a
    /// session is still present.
    static func disconnectSession(
        manager: CrossNetworkConnectionManager
    ) async -> CrossnetControlDisconnectResult {
        let hadSession = await MainActor.run {
            manager.currentConnection != nil
                || manager.activeSessionSnapshot != nil
                || manager.readiness != .idle
        }
        await manager.disconnect()
        let after = await MainActor.run {
            (
                present: manager.currentConnection != nil
                    || manager.activeSessionSnapshot != nil
                    || manager.readiness != .idle,
                status: CrossnetControlRuntimeProjection
                    .connectionStatusString(manager.connectionStatus)
            )
        }
        return CrossnetControlDisconnectResult(
            disconnected: hadSession && !after.present,
            sessionPresentBefore: hadSession,
            sessionPresentAfter: after.present,
            connectionStatus: after.status
        )
    }

    /// Maps a manager error onto an operator-visible failure without echoing
    /// server-supplied text.
    private static func sessionMutationFailure(_ error: Error) -> CrossnetControlFailure {
        if error is CancellationError {
            return .sessionRuntimeApplyFailed
        }
        if let crossNetworkError = error as? CrossNetworkConnectionError {
            return .sessionMutationRejected(String(describing: crossNetworkError))
        }
        return .sessionMutationRejected("session_mutation_unavailable")
    }

    /// Navigates the app UI through the app-owned coordinator and reports the
    /// destination the UI confirmed presenting.
    ///
    /// The read-back is the DashboardView's own `confirmPresented` call from its
    /// selection change, so a request no mounted view applied times out and
    /// fails closed instead of echoing the request.
    static func navigate(
        to destination: CrossnetControlNavigationDestination,
        coordinator: OperatorNavigationCoordinator
    ) async throws -> CrossnetControlNavigateResult {
        // The wire vocabulary must map onto a real sidebar item; a destination
        // the app cannot represent is refused before touching any state.
        guard NavigationItem(operatorWire: destination.rawValue) != nil else {
            throw CrossnetControlFailure.navigationDestinationInvalid
        }
        await MainActor.run {
            coordinator.requestNavigation(to: destination.rawValue)
        }
        let confirmed = await coordinator.awaitPresentation(of: destination.rawValue)
        let presented = await MainActor.run { coordinator.presentedDestination }
        guard confirmed, let presented else {
            throw CrossnetControlFailure.navigationApplyFailed
        }
        return CrossnetControlNavigateResult(
            destination: destination.rawValue,
            presentedDestination: presented,
            runtimeApplied: true
        )
    }

    /// Live push source for `crossnet.status --watch`.
    ///
    /// Pushes a fresh status projection whenever the connection manager's
    /// observable state settles, deduplicated so a watcher only sees real
    /// changes. Auth flags are re-read with each pushed snapshot; an auth-only
    /// change with no connection-state change does not itself push.
    static func liveStatusEvents() -> AsyncStream<CrossnetControlStatusResult> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let anchor = Task { @MainActor in
                let manager = CrossNetworkConnectionManager.shared
                var lastPushed: CrossnetControlStatusResult?
                // `objectWillChange.values` is demand-driven: events that fire
                // while this task is settling are simply not buffered, which is
                // exactly the coalesce-to-latest behaviour a watcher wants — we
                // always project the manager's CURRENT state after the burst.
                for await _ in manager.objectWillChange.values {
                    // Let the mutation that announced itself actually land.
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { break }
                    let snapshot = OperatorControlRuntimeFactory.status(manager: manager)
                    guard snapshot != lastPushed else { continue }
                    lastPushed = snapshot
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in anchor.cancel() }
        }
    }

    @MainActor
    static func authState() -> CrossnetControlAuthState {
        // Uses the SAME authority snapshot the GUI's authenticated request
        // context builds from, so the operator projection cannot disagree with
        // what the app itself would send to the control plane.
        let snapshot = CrossNetworkConnectionManager.currentSignalServerAuthoritySnapshot()
        let trimmedToken = snapshot.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authLoaded = trimmedToken?.isEmpty == false
        let tenantBound: Bool
        do {
            let resolvedTenant = try CrossNetworkConnectionManager.resolveTenantIdentifier(
                accessToken: snapshot.accessToken,
                explicitTenantID: ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"],
                sessionTenantID: snapshot.sessionTenantID,
                sessionUserIdentifier: snapshot.sessionUserIdentifier
            )
            tenantBound = !resolvedTenant.isEmpty
        } catch {
            // This is a read-only status projection. Invalid identity binding is represented as
            // unbound; admission uses the throwing resolver and preserves the concrete error.
            tenantBound = false
        }
        return CrossnetControlAuthState(authLoaded: authLoaded, tenantBound: tenantBound)
    }

    /// Refreshes an expired access token first — exactly what the GUI's
    /// authenticated paths do — then projects the auth state.
    static func refreshedAuthState() async -> CrossnetControlAuthState {
        _ = try? await AuthenticationService.shared.validAccessToken()
        return await MainActor.run { authState() }
    }

    /// Projects the app's unified online-device list for the operator surface.
    ///
    /// Only the redacted reference, display name, platform, and online flag
    /// cross the wire; raw identifiers, IPs, MACs, and serials never do.
    @MainActor
    static func listOnlineDevices(
        manager: UnifiedOnlineDeviceManager
    ) -> CrossnetControlDevicesResult {
        var seen = Set<String>()
        let entries = manager.onlineDevices.compactMap { device -> CrossnetControlDeviceEntry? in
            let reference = CrossnetControlSessionRef.redacted(device.uniqueIdentifier)
            guard seen.insert(reference).inserted else { return nil }
            return CrossnetControlDeviceEntry(
                deviceRef: reference,
                name: device.name.trimmingCharacters(in: .whitespacesAndNewlines),
                platform: device.platformName,
                online: true
            )
        }
        return CrossnetControlDevicesResult(devices: entries)
    }

    /// One-click join: resolves the redacted reference against the live
    /// device list, dials through the app's own online-device coordinator
    /// (the peer admits via pinned trust), and reports the device manager's
    /// own connected read-back.
    static func connectOnlineDevice(
        _ deviceRef: String,
        manager: UnifiedOnlineDeviceManager
    ) async throws -> CrossnetControlConnectDeviceResult {
        let target = await MainActor.run {
            manager.onlineDevices.first { device in
                CrossnetControlSessionRef.redacted(device.uniqueIdentifier) == deviceRef
            }
        }
        guard let target else {
            throw CrossnetControlFailure.deviceNotFound
        }
        do {
            try await OnlineDeviceConnectionCoordinator.connect(to: target)
        } catch {
            // Connect is idempotent over its goal state: a peer answering
            // "already_connected" means the goal already holds, so fall
            // through to the read-back below — which still decides the
            // outcome. Every other failure surfaces its stable case name
            // (sanitized/truncated by the wire encoder, no addresses).
            let description = String(describing: error)
            guard description.contains("already_connected") else {
                throw CrossnetControlFailure.sessionMutationRejected(
                    "device_connect_failed:\(description)"
                )
            }
        }
        let readBack = await MainActor.run {
            manager.onlineDevices.first { device in
                CrossnetControlSessionRef.redacted(device.uniqueIdentifier) == deviceRef
            }
        }
        let connected = readBack?.connectionStatus == .connected
        return CrossnetControlConnectDeviceResult(
            deviceRef: deviceRef,
            name: readBack?.name.trimmingCharacters(in: .whitespacesAndNewlines),
            connected: connected
        )
    }
}
#endif
