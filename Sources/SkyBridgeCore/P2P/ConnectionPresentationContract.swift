import Foundation

public enum ConnectionPresentationPhase: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

public enum ConnectionDisplayState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case reconnecting
    case connectedClassic
    case connectedApplePQC
    case connectedDegradedSignaling
}

public enum SignalingSessionHealth: String, Sendable, Equatable {
    case healthy
    case degradedRecoverable
    case degradedFatal
}

public enum SessionDisconnectKind: String, Sendable, Equatable {
    case explicit
    case remoteLeave
    case transient
}

public enum ActiveSessionSnapshotSource: String, Sendable, Equatable {
    case p2p
    case qr
    case code
    case icloud
    case reused
}

public enum ActiveSessionSnapshotPhase: String, Sendable, Equatable {
    case connecting
    case transportReady
    case handshakeComplete
    case reconnecting
    case disconnecting
}

public struct ConnectionPresentationLabels: Sendable, Equatable {
    public let connectedText: String
    public let disconnectedText: String
    public let connectingText: String
    public let reconnectingText: String
    public let defaultGuardStatus: String
    public let crossNetworkGuardStatus: String

    public init(
        connectedText: String = "已连接",
        disconnectedText: String = "未连接",
        connectingText: String = "连接中",
        reconnectingText: String = "重连中",
        defaultGuardStatus: String = "守护中",
        crossNetworkGuardStatus: String = "跨网已连接"
    ) {
        self.connectedText = connectedText
        self.disconnectedText = disconnectedText
        self.connectingText = connectingText
        self.reconnectingText = reconnectingText
        self.defaultGuardStatus = defaultGuardStatus
        self.crossNetworkGuardStatus = crossNetworkGuardStatus
    }
}

public struct ConnectionPresentationPeer: Sendable, Equatable {
    public let displayName: String
    public let cryptoKind: String?
    public let suite: String?
    public let guardStatus: String?
    public let connectedAt: Date

    public init(
        displayName: String,
        cryptoKind: String? = nil,
        suite: String? = nil,
        guardStatus: String? = nil,
        connectedAt: Date = Date()
    ) {
        self.displayName = displayName
        self.cryptoKind = cryptoKind
        self.suite = suite
        self.guardStatus = guardStatus
        self.connectedAt = connectedAt
    }
}

public struct ActiveSessionSnapshot: Sendable, Equatable {
    public let snapshotToken: UUID
    public let sessionId: String
    public let source: ActiveSessionSnapshotSource
    public let phase: ActiveSessionSnapshotPhase
    public let deviceId: String?
    public let deviceName: String?
    public let negotiatedSuite: String?
    public let updatedAt: Date

    public init(
        snapshotToken: UUID = UUID(),
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.snapshotToken = snapshotToken
        self.sessionId = sessionId
        self.source = source
        self.phase = phase
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.negotiatedSuite = negotiatedSuite
        self.updatedAt = updatedAt
    }
}

public struct ConnectionPresentationInput: Sendable, Equatable {
    public let labels: ConnectionPresentationLabels
    public let fileTransferActive: Bool
    public let latestPeerConnection: ConnectionPresentationPeer?
    public let latestConnectedDevice: ConnectionPresentationPeer?
    public let activeSessionSnapshot: ActiveSessionSnapshot?
    public let crossNetworkFallback: ActiveSessionSnapshot?
    public let defaultPQCModeLabel: String?
    public let compatibilityModeEnabled: Bool
    public let signalingHealth: SignalingSessionHealth?

    public init(
        labels: ConnectionPresentationLabels = ConnectionPresentationLabels(),
        fileTransferActive: Bool,
        latestPeerConnection: ConnectionPresentationPeer?,
        latestConnectedDevice: ConnectionPresentationPeer?,
        activeSessionSnapshot: ActiveSessionSnapshot?,
        crossNetworkFallback: ActiveSessionSnapshot? = nil,
        defaultPQCModeLabel: String? = nil,
        compatibilityModeEnabled: Bool,
        signalingHealth: SignalingSessionHealth? = nil
    ) {
        self.labels = labels
        self.fileTransferActive = fileTransferActive
        self.latestPeerConnection = latestPeerConnection
        self.latestConnectedDevice = latestConnectedDevice
        self.activeSessionSnapshot = activeSessionSnapshot
        self.crossNetworkFallback = crossNetworkFallback
        self.defaultPQCModeLabel = defaultPQCModeLabel
        self.compatibilityModeEnabled = compatibilityModeEnabled
        self.signalingHealth = signalingHealth
    }
}

public struct ConnectionPresentation: Sendable, Equatable {
    public let phase: ConnectionPresentationPhase
    public let isConnected: Bool
    public let displayState: ConnectionDisplayState
    public let statusText: String
    public let detailText: String?

    public init(
        phase: ConnectionPresentationPhase,
        isConnected: Bool,
        displayState: ConnectionDisplayState = .disconnected,
        statusText: String,
        detailText: String?
    ) {
        self.phase = phase
        self.isConnected = isConnected
        self.displayState = displayState
        self.statusText = statusText
        self.detailText = detailText
    }
}

public enum ActiveSessionSnapshotContract {
    public static func activate(
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String?,
        deviceName: String?,
        negotiatedSuite: String?,
        snapshotToken: UUID = UUID(),
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            snapshotToken: snapshotToken,
            sessionId: sessionId,
            source: source,
            phase: phase,
            deviceId: deviceId,
            deviceName: deviceName,
            negotiatedSuite: negotiatedSuite,
            updatedAt: updatedAt
        )
    }

    public static func update(
        current: ActiveSessionSnapshot?,
        sessionId: String,
        snapshotToken: UUID,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot? {
        guard let current,
              current.sessionId == sessionId,
              current.snapshotToken == snapshotToken else {
            return current
        }

        return ActiveSessionSnapshot(
            snapshotToken: current.snapshotToken,
            sessionId: current.sessionId,
            source: current.source,
            phase: phase,
            deviceId: deviceId ?? current.deviceId,
            deviceName: deviceName ?? current.deviceName,
            negotiatedSuite: negotiatedSuite ?? current.negotiatedSuite,
            updatedAt: updatedAt
        )
    }

    public static func disconnect(
        current: ActiveSessionSnapshot?,
        sessionId: String,
        snapshotToken: UUID,
        kind: SessionDisconnectKind,
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot? {
        guard let current,
              current.sessionId == sessionId,
              current.snapshotToken == snapshotToken else {
            return current
        }

        switch kind {
        case .explicit, .remoteLeave:
            return nil
        case .transient:
            return ActiveSessionSnapshot(
                snapshotToken: current.snapshotToken,
                sessionId: current.sessionId,
                source: current.source,
                phase: .reconnecting,
                deviceId: current.deviceId,
                deviceName: current.deviceName,
                negotiatedSuite: current.negotiatedSuite,
                updatedAt: updatedAt
            )
        }
    }
}

public enum ConnectionPresentationContract {
    public static func evaluate(_ input: ConnectionPresentationInput) -> ConnectionPresentation {
        if let reconnectingPresentation = reconnectingPresentation(for: input.activeSessionSnapshot, input: input) {
            return reconnectingPresentation
        }

        if let reconnectingFallback = reconnectingPresentation(for: input.crossNetworkFallback, input: input) {
            return reconnectingFallback
        }

        if let peer = input.latestPeerConnection {
            return connectedPresentation(
                displayName: peer.displayName,
                kind: peer.cryptoKind,
                suite: peer.suite,
                guardStatus: peer.guardStatus ?? input.labels.defaultGuardStatus,
                input: input
            )
        }

        if let snapshotPresentation = connectedSnapshotPresentation(for: input.activeSessionSnapshot, input: input) {
            return snapshotPresentation
        }

        if let fallbackPresentation = connectedSnapshotPresentation(for: input.crossNetworkFallback, input: input) {
            return fallbackPresentation
        }

        if let device = input.latestConnectedDevice {
            return connectedPresentation(
                displayName: device.displayName,
                kind: device.cryptoKind,
                suite: device.suite,
                guardStatus: device.guardStatus ?? input.labels.defaultGuardStatus,
                input: input
            )
        }

        if input.fileTransferActive {
            return ConnectionPresentation(
                phase: .connected,
                isConnected: true,
                statusText: connectedStatusText(kind: nil, suite: nil, input: input),
                detailText: nil
            )
        }

        if let connectingPresentation = connectingPresentation(for: input.activeSessionSnapshot, input: input) {
            return connectingPresentation
        }

        if let fallbackConnecting = connectingPresentation(for: input.crossNetworkFallback, input: input) {
            return fallbackConnecting
        }

        return ConnectionPresentation(
            phase: .disconnected,
            isConnected: false,
            statusText: input.labels.disconnectedText,
            detailText: nil
        )
    }

    private static func reconnectingPresentation(
        for snapshot: ActiveSessionSnapshot?,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation? {
        guard let snapshot, snapshot.phase == .reconnecting else {
            return nil
        }

        let detail = [input.labels.reconnectingText, snapshot.deviceName]
            .compactMap { normalized($0) }
            .joined(separator: " · ")
        return ConnectionPresentation(
            phase: .reconnecting,
            isConnected: true,
            displayState: .reconnecting,
            statusText: input.labels.reconnectingText,
            detailText: detail.isEmpty ? input.labels.reconnectingText : detail
        )
    }

    private static func connectedSnapshotPresentation(
        for snapshot: ActiveSessionSnapshot?,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation? {
        guard let snapshot,
              snapshot.phase == .transportReady || snapshot.phase == .handshakeComplete else {
            return nil
        }

        let detail = ConnectionCryptoPresentation.detailText(
            kind: nil,
            suite: snapshot.negotiatedSuite,
            guardStatus: input.labels.crossNetworkGuardStatus
        ) ?? normalized(snapshot.deviceName) ?? input.labels.crossNetworkGuardStatus
        let degraded = input.signalingHealth == .degradedRecoverable || input.signalingHealth == .degradedFatal
        let effectiveDetail = degraded ? [detail, "信令降级"].joined(separator: " · ") : detail
        return ConnectionPresentation(
            phase: .connected,
            isConnected: true,
            displayState: connectedDisplayState(
                kind: nil,
                suite: snapshot.negotiatedSuite,
                input: input,
                signalingHealth: input.signalingHealth
            ),
            statusText: connectedStatusText(
                kind: nil,
                suite: snapshot.negotiatedSuite,
                input: input
            ),
            detailText: effectiveDetail
        )
    }

    private static func connectingPresentation(
        for snapshot: ActiveSessionSnapshot?,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation? {
        guard let snapshot, snapshot.phase == .connecting else {
            return nil
        }

        return ConnectionPresentation(
            phase: .connecting,
            isConnected: false,
            displayState: .connecting,
            statusText: input.labels.connectingText,
            detailText: normalized(snapshot.deviceName)
        )
    }

    private static func connectedPresentation(
        displayName: String,
        kind: String?,
        suite: String?,
        guardStatus: String?,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation {
        ConnectionPresentation(
            phase: .connected,
            isConnected: true,
            displayState: connectedDisplayState(
                kind: kind,
                suite: suite,
                input: input,
                signalingHealth: nil
            ),
            statusText: connectedStatusText(kind: kind, suite: suite, input: input),
            detailText: ConnectionCryptoPresentation.detailText(
                kind: kind,
                suite: suite,
                guardStatus: guardStatus
            ) ?? normalized(displayName)
        )
    }

    private static func connectedStatusText(
        kind: String?,
        suite: String?,
        input: ConnectionPresentationInput
    ) -> String {
        let base = input.labels.connectedText
        let explicit = ConnectionCryptoPresentation.connectedStatusText(
            kind: kind,
            suite: suite,
            baseConnectedText: base
        )
        if explicit != base {
            return explicit
        }
        guard normalized(kind) != nil || normalized(suite) != nil else {
            return base
        }
        let suiteToken = suite?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if (suiteToken.contains("ml-kem") || suiteToken.contains("mlkem") || suiteToken.contains("mldsa")),
           let fallbackMode = normalized(input.defaultPQCModeLabel) {
            return "\(fallbackMode)\(base)"
        }
        return ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
            kind: kind,
            suite: suite,
            baseConnectedText: base,
            compatibilityModeEnabled: input.compatibilityModeEnabled
        )
    }

    private static func connectedDisplayState(
        kind: String?,
        suite: String?,
        input: ConnectionPresentationInput,
        signalingHealth: SignalingSessionHealth?
    ) -> ConnectionDisplayState {
        if signalingHealth == .degradedRecoverable || signalingHealth == .degradedFatal {
            return .connectedDegradedSignaling
        }

        let lowerKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lowerSuite = suite?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let fallbackMode = input.defaultPQCModeLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let looksLikeApplePQC =
            lowerKind.contains("apple pqc") ||
            lowerSuite.contains("ml-kem") ||
            lowerSuite.contains("mlkem") ||
            lowerSuite.contains("ml-dsa") ||
            lowerSuite.contains("mldsa") ||
            fallbackMode == "apple pqc"

        return looksLikeApplePQC ? .connectedApplePQC : .connectedClassic
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
