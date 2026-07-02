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

    @MainActor
    static func authState() -> CrossnetControlAuthState {
        let accessToken = AuthenticationService.shared.currentAccessToken()
            ?? TenantAccessController.shared.accessToken
        let trimmedToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authLoaded = trimmedToken?.isEmpty == false
        let derivedTenant = CrossNetworkConnectionManager.deriveTenantIdentifier(accessToken: accessToken)
        let tenantBound = !derivedTenant.isEmpty || TenantAccessController.shared.activeTenant != nil
        return CrossnetControlAuthState(authLoaded: authLoaded, tenantBound: tenantBound)
    }
}
#endif
