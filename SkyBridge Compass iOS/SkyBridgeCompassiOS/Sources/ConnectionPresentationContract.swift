import Foundation

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
        if let snapshot = input.activeSessionSnapshot, snapshot.phase == .reconnecting {
            let detail = [input.labels.reconnectingText, snapshot.deviceName]
                .compactMap { normalized($0) }
                .joined(separator: " · ")
            return ConnectionPresentation(
                phase: .reconnecting,
                isConnected: true,
                statusText: input.labels.reconnectingText,
                detailText: detail.isEmpty ? input.labels.reconnectingText : detail,
                securityEvidence: .none
            )
        }

        if let peer = input.latestPeerConnection {
            return connectedPresentation(
                displayName: peer.displayName,
                kind: peer.cryptoKind,
                suite: peer.suite,
                guardStatus: peer.guardStatus ?? input.labels.defaultGuardStatus,
                isRekeying: peer.isRekeying,
                input: input
            )
        }

        if let snapshot = input.activeSessionSnapshot,
           snapshot.phase == .handshakeComplete {
            let detail = detailText(
                kind: nil,
                suite: snapshot.negotiatedSuite,
                guardStatus: input.labels.crossNetworkGuardStatus
            ) ?? normalized(snapshot.deviceName) ?? input.labels.crossNetworkGuardStatus
            return ConnectionPresentation(
                phase: .connected,
                isConnected: true,
                statusText: connectedStatusText(kind: nil, suite: snapshot.negotiatedSuite, isRekeying: false, input: input),
                detailText: detail,
                securityEvidence: securityEvidence(kind: nil, suite: snapshot.negotiatedSuite)
            )
        }

        if let device = input.latestConnectedDevice {
            return connectedPresentation(
                displayName: device.displayName,
                kind: device.cryptoKind,
                suite: device.suite,
                guardStatus: device.guardStatus ?? input.labels.defaultGuardStatus,
                isRekeying: device.isRekeying,
                input: input
            )
        }

        if let pendingPeer = input.latestPendingPeer {
            return pendingPresentation(peer: pendingPeer, input: input)
        }

        if input.fileTransferActive {
            return ConnectionPresentation(
                phase: .connected,
                isConnected: true,
                statusText: connectedStatusText(kind: nil, suite: nil, isRekeying: false, input: input),
                detailText: nil,
                securityEvidence: .none
            )
        }

        if let snapshot = input.activeSessionSnapshot,
           snapshot.phase == .connecting || snapshot.phase == .transportReady {
            return ConnectionPresentation(
                phase: .connecting,
                isConnected: false,
                statusText: input.labels.connectingText,
                detailText: normalized(snapshot.deviceName),
                securityEvidence: .none
            )
        }

        return ConnectionPresentation(
            phase: .disconnected,
            isConnected: false,
            statusText: input.labels.disconnectedText,
            detailText: nil,
            securityEvidence: .none
        )
    }

    private static func pendingPresentation(
        peer: ConnectionPresentationPendingPeer,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation {
        let baseText = peer.phase == .reconnecting
            ? input.labels.reconnectingText
            : input.labels.connectingText
        return ConnectionPresentation(
            phase: peer.phase,
            isConnected: peer.phase == .reconnecting,
            statusText: modeAwareStatusText(
                baseText: baseText,
                kind: peer.cryptoKind,
                suite: peer.suite,
                defaultPQCModeLabel: input.defaultPQCModeLabel
            ),
            detailText: rekeyDetailText(
                kind: peer.cryptoKind,
                suite: peer.suite,
                guardStatus: peer.guardStatus,
                isRekeying: peer.isRekeying
            ) ?? detailText(
                kind: peer.cryptoKind,
                suite: peer.suite,
                guardStatus: peer.guardStatus
            ) ?? normalized(peer.displayName),
            securityEvidence: .none
        )
    }

    private static func connectedPresentation(
        displayName: String,
        kind: String?,
        suite: String?,
        guardStatus: String?,
        isRekeying: Bool,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation {
        ConnectionPresentation(
            phase: .connected,
            isConnected: true,
            statusText: connectedStatusText(kind: kind, suite: suite, isRekeying: isRekeying, input: input),
            detailText: rekeyDetailText(kind: kind, suite: suite, guardStatus: guardStatus, isRekeying: isRekeying)
                ?? detailText(kind: kind, suite: suite, guardStatus: guardStatus)
                ?? normalized(displayName),
            securityEvidence: securityEvidence(kind: kind, suite: suite)
        )
    }

    private static func connectedStatusText(
        kind: String?,
        suite: String?,
        isRekeying: Bool,
        input: ConnectionPresentationInput
    ) -> String {
        modeAwareStatusText(
            baseText: input.labels.connectedText,
            kind: kind,
            suite: suite,
            defaultPQCModeLabel: input.defaultPQCModeLabel
        )
    }

    public static func modeAwareStatusText(
        baseText: String,
        kind: String?,
        suite: String?,
        defaultPQCModeLabel: String? = nil
    ) -> String {
        guard let mode = modeLabel(
            kind: kind,
            suite: suite,
            defaultPQCModeLabel: defaultPQCModeLabel
        ) else {
            return baseText
        }
        return "\(mode) \(baseText)"
    }

    private static func rekeyDetailText(
        kind: String?,
        suite: String?,
        guardStatus: String?,
        isRekeying: Bool
    ) -> String? {
        guard isRekeying else {
            return nil
        }

        var components: [String] = []
        if let kind = normalized(kind) {
            components.append(kind)
        } else if let suite = normalized(suite) {
            components.append(suite)
        }
        if let guardStatus = normalized(guardStatus) {
            components.append(guardStatus)
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func detailText(kind: String?, suite: String?, guardStatus: String?) -> String? {
        let mode = modeLabel(kind: kind, suite: suite, defaultPQCModeLabel: nil)
        let trimmedSuite = normalized(suite)
        let trimmedGuard = normalized(guardStatus)

        var components: [String] = []
        if let mode {
            components.append(mode)
        }
        if let trimmedSuite, !shouldSuppressSuite(mode: mode, suite: trimmedSuite) {
            components.append(trimmedSuite)
        }
        if let trimmedGuard {
            components.append(trimmedGuard)
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func modeLabel(kind: String?, suite: String?, defaultPQCModeLabel: String?) -> String? {
        let suiteToken = normalizedToken(suite)
        if suiteToken.contains("xwing") {
            return "X-Wing"
        }
        if suiteToken.contains("x25519") || suiteToken.contains("p256") {
            return "Classic"
        }

        let kindToken = normalizedToken(currentModeComponent(from: kind))
        if kindToken.contains("xwing") {
            return "X-Wing"
        }
        if kindToken.contains("x25519") || kindToken.contains("p256") {
            return "Classic"
        }
        if kindToken.contains("liboqs") || kindToken.contains("oqs") {
            return "liboqs"
        }
        if kindToken.contains("apple"),
           suiteToken.contains("mlkem") || suiteToken.contains("mldsa") || suiteToken.contains("xwing") {
            return "Apple PQC"
        }
        if kindToken.contains("classic") {
            return "Classic"
        }

        if suiteToken.contains("mlkem") || suiteToken.contains("mldsa") {
            return "PQC"
        }

        return nil
    }

    private static func securityEvidence(
        kind: String?,
        suite: String?
    ) -> ConnectionSecurityEvidence {
        let suiteToken = normalizedToken(suite)
        if suiteToken.contains("xwing")
            || suiteToken.contains("mlkem")
            || suiteToken.contains("mldsa") {
            return .pqc
        }
        if suiteToken.contains("x25519") || suiteToken.contains("p256") {
            return .classic
        }

        let kindToken = normalizedToken(currentModeComponent(from: kind))
        if kindToken.contains("x25519") || kindToken.contains("p256") || kindToken.contains("classic") {
            return .classic
        }

        return .none
    }

    private static func currentModeComponent(from kind: String?) -> String? {
        guard let normalizedKind = normalized(kind) else { return nil }
        for separator in ["→", "->"] {
            if let range = normalizedKind.range(of: separator) {
                return normalized(String(normalizedKind[..<range.lowerBound]))
            }
        }
        return normalizedKind
    }

    private static func shouldSuppressSuite(mode: String?, suite: String) -> Bool {
        guard let mode else { return false }
        let modeToken = normalizedToken(mode)
        let suiteToken = normalizedToken(suite)
        if modeToken == suiteToken {
            return true
        }
        if modeToken == "xwing" && suiteToken.contains("xwing") {
            return true
        }
        return false
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedToken(_ value: String?) -> String {
        guard let raw = normalized(value)?.lowercased() else { return "" }
        var token = ""
        token.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            token.unicodeScalars.append(scalar)
        }
        return token
    }
}
