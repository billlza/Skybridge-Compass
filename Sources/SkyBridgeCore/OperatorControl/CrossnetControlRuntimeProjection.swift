import Foundation

public struct CrossnetControlAuthState: Sendable, Equatable {
    public let authLoaded: Bool
    public let tenantBound: Bool

    public init(authLoaded: Bool, tenantBound: Bool) {
        self.authLoaded = authLoaded
        self.tenantBound = tenantBound
    }
}

public struct CrossnetControlConnectionRuntimeSnapshot: Sendable {
    public let connectionStatus: CrossNetworkConnectionManager.CrossNetworkConnectionStatus
    public let readiness: CrossNetworkConnectionManager.CrossNetworkReadiness
    public let activeSessionSnapshot: ActiveSessionSnapshot?
    public let currentConnectionID: String?
    public let signalingHealth: SignalingSessionHealth

    public init(
        connectionStatus: CrossNetworkConnectionManager.CrossNetworkConnectionStatus,
        readiness: CrossNetworkConnectionManager.CrossNetworkReadiness,
        activeSessionSnapshot: ActiveSessionSnapshot?,
        currentConnectionID: String?,
        signalingHealth: SignalingSessionHealth
    ) {
        self.connectionStatus = connectionStatus
        self.readiness = readiness
        self.activeSessionSnapshot = activeSessionSnapshot
        self.currentConnectionID = currentConnectionID
        self.signalingHealth = signalingHealth
    }
}

public struct CrossnetControlSettingsRuntimeSnapshot: Sendable, Equatable {
    public let enableVerboseLogging: Bool
    public let logLevel: String
    public let showRealtimeFPS: Bool
    public let showTopBarIPLocation: Bool
    public let showTopBarNetworkSpeed: Bool
    public let showTopBarNetworkLatency: Bool
    public let preferXWingHybrid: Bool
    public let pqcSignatureAlgorithm: String
    public let remoteDesktopTargetFrameRate: Int
    public let remoteDesktopResolution: String

    public init(
        enableVerboseLogging: Bool,
        logLevel: String,
        showRealtimeFPS: Bool,
        showTopBarIPLocation: Bool,
        showTopBarNetworkSpeed: Bool,
        showTopBarNetworkLatency: Bool,
        preferXWingHybrid: Bool,
        pqcSignatureAlgorithm: String,
        remoteDesktopTargetFrameRate: Int,
        remoteDesktopResolution: String
    ) {
        self.enableVerboseLogging = enableVerboseLogging
        self.logLevel = logLevel
        self.showRealtimeFPS = showRealtimeFPS
        self.showTopBarIPLocation = showTopBarIPLocation
        self.showTopBarNetworkSpeed = showTopBarNetworkSpeed
        self.showTopBarNetworkLatency = showTopBarNetworkLatency
        self.preferXWingHybrid = preferXWingHybrid
        self.pqcSignatureAlgorithm = pqcSignatureAlgorithm
        self.remoteDesktopTargetFrameRate = remoteDesktopTargetFrameRate
        self.remoteDesktopResolution = remoteDesktopResolution
    }
}

public enum CrossnetControlRuntimeProjection {
    public static func hello(
        engineVersion: String,
        auth: CrossnetControlAuthState
    ) -> CrossnetControlHelloResult {
        CrossnetControlHelloResult(
            engineVersion: engineVersion,
            authLoaded: auth.authLoaded,
            tenantBound: auth.tenantBound
        )
    }

    public static func status(
        auth: CrossnetControlAuthState,
        connection: CrossnetControlConnectionRuntimeSnapshot
    ) -> CrossnetControlStatusResult {
        let sessionID = sessionIdentifier(connection)
        let sessionPresent = sessionID != nil || isWaitingForPeer(connection.connectionStatus)
        let failure = statusFailure(auth: auth, connectionStatus: connection.connectionStatus)

        return CrossnetControlStatusResult(
            connectionStatus: connectionStatusString(connection.connectionStatus),
            readiness: readinessString(connection.readiness),
            sessionPresent: sessionPresent,
            sessionRef: sessionID.map(CrossnetControlSessionRef.redacted),
            suite: negotiatedSuite(connection),
            signalingHealth: signalingHealthString(connection.signalingHealth),
            failureCode: failure?.code,
            failureClass: failure?.failureClass,
            authLoaded: auth.authLoaded,
            tenantBound: auth.tenantBound
        )
    }

    public static func settingsSnapshot(
        _ settings: CrossnetControlSettingsRuntimeSnapshot
    ) -> CrossnetControlSettingsSnapshotResult {
        CrossnetControlSettingsSnapshotResult(settings: [
            setting(id: "logging.verbose", value: .bool(settings.enableVerboseLogging)),
            setting(id: "logging.level", value: .string(settings.logLevel)),
            setting(id: "ui.show_realtime_fps", value: .bool(settings.showRealtimeFPS)),
            setting(id: "ui.top_bar_ip_location", value: .bool(settings.showTopBarIPLocation)),
            setting(id: "ui.top_bar_network_speed", value: .bool(settings.showTopBarNetworkSpeed)),
            setting(id: "ui.top_bar_network_latency", value: .bool(settings.showTopBarNetworkLatency)),
            setting(
                id: "pqc.prefer_xwing_hybrid",
                value: .bool(settings.preferXWingHybrid),
                note: "policy_preference_not_runtime_proof"
            ),
            setting(
                id: "pqc.signature_algorithm",
                value: .string(settings.pqcSignatureAlgorithm),
                note: "policy_preference_not_runtime_proof"
            ),
            setting(
                id: "remote_desktop.target_fps",
                value: .int(settings.remoteDesktopTargetFrameRate),
                note: CrossnetControlSettingsProjectionPolicy.remoteDesktopCaptureNote
            ),
            setting(
                id: "remote_desktop.resolution",
                value: .string(settings.remoteDesktopResolution),
                note: CrossnetControlSettingsProjectionPolicy.remoteDesktopCaptureNote
            )
        ])
    }

    private static func setting(
        id: String,
        value: CrossnetControlJSONValue,
        note: String? = nil
    ) -> CrossnetControlSettingSnapshot {
        CrossnetControlSettingSnapshot(
            id: id,
            valueType: value.valueType,
            value: value,
            mutable: false,
            note: note
        )
    }

    public static func connectionStatusString(
        _ status: CrossNetworkConnectionManager.CrossNetworkConnectionStatus
    ) -> String {
        switch status {
        case .idle:
            return "idle"
        case .generating:
            return "generating"
        case .waiting:
            return "waiting"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .failed:
            return "failed"
        }
    }

    public static func readinessString(
        _ readiness: CrossNetworkConnectionManager.CrossNetworkReadiness
    ) -> String {
        switch readiness {
        case .idle:
            return "idle"
        case .transportReady:
            return "transport_ready"
        case .handshakeComplete:
            return "handshake_complete"
        }
    }

    private static func signalingHealthString(_ health: SignalingSessionHealth) -> String {
        switch health {
        case .healthy:
            return "healthy"
        case .degradedRecoverable:
            return "degraded_recoverable"
        case .degradedFatal:
            return "degraded_fatal"
        }
    }

    private static func statusFailure(
        auth: CrossnetControlAuthState,
        connectionStatus: CrossNetworkConnectionManager.CrossNetworkConnectionStatus
    ) -> CrossnetControlStatusFailure? {
        if !auth.authLoaded {
            return CrossnetControlStatusFailure(
                code: .authRequired,
                failureClass: .operatorPrecondition
            )
        }
        if !auth.tenantBound {
            return CrossnetControlStatusFailure(
                code: .tenantRequired,
                failureClass: .operatorPrecondition
            )
        }
        if case .failed = connectionStatus {
            return CrossnetControlStatusFailure(
                code: .runtimeFailed,
                failureClass: .runtimeFailure
            )
        }
        return nil
    }

    private static func negotiatedSuite(_ connection: CrossnetControlConnectionRuntimeSnapshot) -> String? {
        switch connection.readiness {
        case .handshakeComplete(_, let suite):
            return suite
        case .transportReady, .idle:
            return connection.activeSessionSnapshot?.negotiatedSuite
        }
    }

    private static func sessionIdentifier(_ connection: CrossnetControlConnectionRuntimeSnapshot) -> String? {
        switch connection.readiness {
        case .transportReady(let sessionID), .handshakeComplete(let sessionID, _):
            return sessionID
        case .idle:
            if let snapshotSessionID = connection.activeSessionSnapshot?.sessionId,
               !snapshotSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return snapshotSessionID
            }
            if let connectionID = connection.currentConnectionID,
               !connectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !CrossNetworkConnectionCodePolicy.isSupportedLength(connectionID.count) {
                return connectionID
            }
            return nil
        }
    }

    private static func isWaitingForPeer(
        _ status: CrossNetworkConnectionManager.CrossNetworkConnectionStatus
    ) -> Bool {
        if case .waiting = status {
            return true
        }
        return false
    }
}

private struct CrossnetControlStatusFailure {
    let code: CrossnetControlStatusFailureCode
    let failureClass: CrossnetControlStatusFailureClass
}
