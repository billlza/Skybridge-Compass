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
                await MainActor.run {
                    let auth = OperatorControlRuntimeFactory.authState()
                    return CrossnetControlRuntimeProjection.hello(
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
                    OperatorControlRuntimeFactory.settingsSnapshot(settingsManager: .shared)
                }
            },
            applySetting: { request in
                try await MainActor.run {
                    try OperatorControlRuntimeFactory.applySetting(
                        request,
                        settingsManager: .shared
                    )
                }
            }
        )
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
    static func settingsSnapshot(settingsManager: SettingsManager) -> CrossnetControlSettingsSnapshotResult {
        CrossnetControlRuntimeProjection.settingsSnapshot(CrossnetControlSettingsRuntimeSnapshot(
            enableVerboseLogging: settingsManager.enableVerboseLogging,
            logLevel: settingsManager.logLevel,
            showRealtimeFPS: settingsManager.showRealtimeFPS,
            showTopBarIPLocation: settingsManager.showTopBarIPLocation,
            showTopBarNetworkSpeed: settingsManager.showTopBarNetworkSpeed,
            showTopBarNetworkLatency: settingsManager.showTopBarNetworkLatency,
            preferXWingHybrid: settingsManager.preferXWingHybrid,
            pqcSignatureAlgorithm: settingsManager.pqcSignatureAlgorithm
        ))
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
        settingsManager: SettingsManager
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
        default:
            throw CrossnetControlFailure.settingInvalidValue
        }

        settingsManager.applyRuntimeSettingsSnapshot()

        let observed = try observedSettingValue(request.id, settingsManager: settingsManager)
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
        settingsManager: SettingsManager
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
        default:
            throw CrossnetControlFailure.settingNotFound
        }
    }

    @MainActor
    static func authState() -> CrossnetControlAuthState {
        let session = AuthenticationService.shared.currentSessionSnapshot()
        let accessToken = session?.accessToken ?? TenantAccessController.shared.accessToken
        let trimmedToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authLoaded = trimmedToken?.isEmpty == false
        let tenantBound: Bool
        do {
            let resolvedTenant = try CrossNetworkConnectionManager.resolveTenantIdentifier(
                accessToken: accessToken,
                explicitTenantID: ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"],
                sessionTenantID: session?.nebulaId
                    ?? TenantAccessController.shared.activeTenant?.id.uuidString,
                sessionUserIdentifier: session?.userIdentifier
            )
            tenantBound = !resolvedTenant.isEmpty
        } catch {
            // This is a read-only status projection. Invalid identity binding is represented as
            // unbound; admission uses the throwing resolver and preserves the concrete error.
            tenantBound = false
        }
        return CrossnetControlAuthState(authLoaded: authLoaded, tenantBound: tenantBound)
    }
}
#endif
