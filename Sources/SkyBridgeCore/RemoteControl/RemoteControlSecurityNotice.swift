import Combine
import Foundation

public enum RemoteControlTransportKind: String, Codable, Sendable, Equatable {
    case p2p
    case webrtc

    public var localizationKey: String {
        switch self {
        case .p2p:
            return "remoteControl.securityNotice.transport.p2p"
        case .webrtc:
            return "remoteControl.securityNotice.transport.webrtc"
        }
    }

    public var evidenceValue: String {
        rawValue
    }
}

public enum RemoteControlSecurityDecision: String, Codable, Sendable, Equatable {
    case approved
    case rejected
    case timedOut
    case disconnected
}

public enum RemoteControlSecurityNoticePhase: String, Codable, Sendable, Equatable {
    case awaitingApproval
    case active
}

public struct RemoteControlSecurityIdentity: Codable, Sendable, Equatable {
    public let accountDisplayName: String?
    public let nebulaId: String?
    public let deviceId: String?
    public let deviceName: String?

    public init(
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.accountDisplayName = Self.normalized(accountDisplayName)
        self.nebulaId = Self.normalized(nebulaId)
        self.deviceId = Self.normalized(deviceId)
        self.deviceName = Self.normalized(deviceName)
    }

    public var isEmpty: Bool {
        accountDisplayName == nil
            && nebulaId == nil
            && deviceId == nil
            && deviceName == nil
    }

    public func merging(_ newer: RemoteControlSecurityIdentity) -> RemoteControlSecurityIdentity {
        RemoteControlSecurityIdentity(
            accountDisplayName: newer.accountDisplayName ?? accountDisplayName,
            nebulaId: newer.nebulaId ?? nebulaId,
            deviceId: newer.deviceId ?? deviceId,
            deviceName: newer.deviceName ?? deviceName
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct RemoteControlSecurityDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionId: String
    public let transportKind: RemoteControlTransportKind
    public let remoteIPAddress: String?
    public let remoteDeviceId: String?
    public let remoteDeviceName: String?
    public let remoteAccountDisplayName: String?
    public let remoteNebulaId: String?
    public let localAccountDisplayName: String?
    public let localNebulaId: String?
    public let cryptoSuite: String
    public let createdAt: Date
    public let approvalTimeoutSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        sessionId: String,
        transportKind: RemoteControlTransportKind,
        remoteIPAddress: String?,
        remoteDeviceId: String?,
        remoteDeviceName: String?,
        remoteAccountDisplayName: String?,
        remoteNebulaId: String?,
        localAccountDisplayName: String?,
        localNebulaId: String?,
        cryptoSuite: String,
        createdAt: Date = Date(),
        approvalTimeoutSeconds: TimeInterval = 45
    ) {
        self.id = id
        self.sessionId = Self.normalized(sessionId) ?? id.uuidString
        self.transportKind = transportKind
        self.remoteIPAddress = Self.normalized(remoteIPAddress)
        self.remoteDeviceId = Self.normalized(remoteDeviceId)
        self.remoteDeviceName = Self.normalized(remoteDeviceName)
        self.remoteAccountDisplayName = Self.normalized(remoteAccountDisplayName)
        self.remoteNebulaId = Self.normalized(remoteNebulaId)
        self.localAccountDisplayName = Self.normalized(localAccountDisplayName)
        self.localNebulaId = Self.normalized(localNebulaId)
        self.cryptoSuite = Self.normalized(cryptoSuite) ?? "missing"
        self.createdAt = createdAt
        self.approvalTimeoutSeconds = max(1, approvalTimeoutSeconds)
    }

    public func updatingCryptoSuite(_ cryptoSuite: String) -> Self {
        .init(
            id: id,
            sessionId: sessionId,
            transportKind: transportKind,
            remoteIPAddress: remoteIPAddress,
            remoteDeviceId: remoteDeviceId,
            remoteDeviceName: remoteDeviceName,
            remoteAccountDisplayName: remoteAccountDisplayName,
            remoteNebulaId: remoteNebulaId,
            localAccountDisplayName: localAccountDisplayName,
            localNebulaId: localNebulaId,
            cryptoSuite: cryptoSuite,
            createdAt: createdAt,
            approvalTimeoutSeconds: approvalTimeoutSeconds
        )
    }

    public var missingRequiredNoticeMetadata: [String] {
        var missing: [String] = []
        if !Self.isPresentForNotice(remoteIPAddress) {
            missing.append("remote_ip")
        }
        if !Self.isPresentForNotice(remoteAccountDisplayName) {
            missing.append("remote_account")
        }
        if !Self.isPresentForNotice(remoteNebulaId) {
            missing.append("remote_nebula")
        }
        if !Self.isPresentForNotice(remoteDeviceId),
           !Self.isPresentForNotice(remoteDeviceName) {
            missing.append("remote_device")
        }
        if !Self.isConcreteQuantumSafeSuiteForNotice(cryptoSuite) {
            missing.append("crypto_suite")
        }
        return missing
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isPresentForNotice(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        return trimmed != "-" && trimmed.lowercased() != "missing"
    }

    private static func isConcreteQuantumSafeSuiteForNotice(_ value: String?) -> Bool {
        guard isPresentForNotice(value) else { return false }
        let rendered = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pqcSuffix = " PQC"
        let suiteToken = rendered.hasSuffix(pqcSuffix)
            ? String(rendered.dropLast(pqcSuffix.count))
            : rendered

        let suite: CryptoSuite?
        if suiteToken.hasPrefix("0x"), suiteToken.count == 6,
           let wireID = UInt16(suiteToken.dropFirst(2), radix: 16) {
            suite = CryptoSuite(wireId: wireID)
        } else {
            suite = CryptoSuite(rawValue: suiteToken)
        }
        return suite?.isKnown == true
            && suite?.isPQCGroup == true
            && suite?.isNegotiable == true
    }
}

public struct RemoteControlSecurityNotice: Identifiable, Codable, Sendable, Equatable {
    public let descriptor: RemoteControlSecurityDescriptor
    public let phase: RemoteControlSecurityNoticePhase
    public let approvedAt: Date?

    public var id: UUID { descriptor.id }

    public init(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase,
        approvedAt: Date? = nil
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.approvedAt = approvedAt
    }

    public func updatingPhase(
        _ phase: RemoteControlSecurityNoticePhase,
        approvedAt: Date? = nil
    ) -> Self {
        .init(
            descriptor: descriptor,
            phase: phase,
            approvedAt: approvedAt ?? self.approvedAt
        )
    }

    public func updatingDescriptor(_ descriptor: RemoteControlSecurityDescriptor) -> Self {
        .init(descriptor: descriptor, phase: phase, approvedAt: approvedAt)
    }
}

private final class RemoteControlSecurityIdentityStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteControlSecurityIdentity?

    func store(_ identity: RemoteControlSecurityIdentity?) {
        lock.lock()
        value = identity
        lock.unlock()
    }

    func snapshot() -> RemoteControlSecurityIdentity? {
        lock.lock()
        let identity = value
        lock.unlock()
        return identity
    }
}

private let remoteControlSecurityIdentityStorage = RemoteControlSecurityIdentityStorage()

private final class RemoteControlSecurityPeerIdentityStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var identitiesByAlias: [String: RemoteControlSecurityIdentity] = [:]

    func record(
        identity: RemoteControlSecurityIdentity,
        aliases rawAliases: [String]
    ) {
        guard !identity.isEmpty else { return }
        let aliases = Self.normalizedAliases(
            rawAliases + [identity.deviceId, identity.deviceName].compactMap { $0 }
        )
        guard !aliases.isEmpty else { return }

        lock.lock()
        let merged = aliases.reduce(identity) { result, alias in
            identitiesByAlias[alias]?.merging(result) ?? result
        }
        for alias in aliases {
            identitiesByAlias[alias] = merged
        }
        lock.unlock()
    }

    func identity(forAliases rawAliases: [String]) -> RemoteControlSecurityIdentity? {
        let aliases = Self.normalizedAliases(rawAliases)
        guard !aliases.isEmpty else { return nil }

        lock.lock()
        let identity = aliases.lazy
            .compactMap { self.identitiesByAlias[$0] }
            .first { !$0.isEmpty }
        lock.unlock()
        return identity
    }

    private static func normalizedAliases(_ rawAliases: [String]) -> [String] {
        var aliases: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return
            }
            let normalized = raw.lowercased()
            guard seen.insert(normalized).inserted else { return }
            aliases.append(normalized)
        }

        func appendExpanded(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lowercased = trimmed.lowercased()
            append(lowercased)

            for prefix in ["host:", "peer:", "id:", "recent:"] {
                guard lowercased.hasPrefix(prefix) else { continue }
                append(String(lowercased.dropFirst(prefix.count)))
                return
            }

            append("host:\(lowercased)")
            append("peer:\(lowercased)")
            append("id:\(lowercased)")
        }

        for alias in rawAliases {
            appendExpanded(alias)
        }
        return aliases
    }
}

private let remoteControlSecurityPeerIdentityStorage = RemoteControlSecurityPeerIdentityStorage()

public enum RemoteControlSecurityPeerIdentityStore {
    public static func record(
        identity: RemoteControlSecurityIdentity,
        aliases: [String]
    ) {
        remoteControlSecurityPeerIdentityStorage.record(identity: identity, aliases: aliases)
    }

    public static func identity(forAliases aliases: [String]) -> RemoteControlSecurityIdentity? {
        remoteControlSecurityPeerIdentityStorage.identity(forAliases: aliases)
    }
}

@MainActor
public enum RemoteControlSecurityNoticePresenter {
    public static func appName() -> String {
        LocalizationManager.shared.localizedString("remoteControl.securityNotice.appName")
    }

    public static func transportName(_ kind: RemoteControlTransportKind) -> String {
        LocalizationManager.shared.localizedString(kind.localizationKey)
    }

    public static func unavailableValue() -> String {
        LocalizationManager.shared.localizedString("remoteControl.securityNotice.valueUnavailable")
    }

    public static func maskedIdentity(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return unavailableValue()
        }
        let characterCount = trimmed.count
        if characterCount <= 4 {
            return String(trimmed.prefix(1)) + "***"
        }
        if characterCount <= 8 {
            return String(trimmed.prefix(2)) + "***" + String(trimmed.suffix(1))
        }
        return String(trimmed.prefix(3)) + "***" + String(trimmed.suffix(3))
    }

    public static func deviceIdentity(_ descriptor: RemoteControlSecurityDescriptor) -> String {
        if let name = descriptor.remoteDeviceName, let id = descriptor.remoteDeviceId {
            return "\(name) (\(maskedIdentity(id)))"
        }
        if let name = descriptor.remoteDeviceName {
            return name
        }
        return maskedIdentity(descriptor.remoteDeviceId)
    }
}

enum RemoteControlSecurityAdmissionPolicy {
    static func allowsInboundPayload(
        _ type: RemoteMessage.MessageType,
        isApproved: Bool
    ) -> Bool {
        guard !isApproved else { return true }
        switch type {
        case .streamConfiguration, .screenData, .damageReport, .cursorUpdate, .overlayUpdate,
             .mouseEvent, .keyboardEvent, .clipboard:
            return false
        }
    }

    static func allowsInboundWebRTCPayload(
        _ type: RemoteMessageTypeWire,
        isApproved: Bool
    ) -> Bool {
        guard !isApproved else { return true }
        switch type {
        case .streamConfiguration, .streamConfigurationAck, .screenData, .damageReport, .cursorUpdate, .overlayUpdate,
             .mouseEvent, .keyboardEvent, .clipboard:
            return false
        }
    }
}

@MainActor
public final class RemoteControlSecurityNoticeCenter: ObservableObject {
    public static let shared = RemoteControlSecurityNoticeCenter()

    public typealias LocalIdentityProvider = @MainActor () -> RemoteControlSecurityIdentity?
    public typealias DisconnectHandler = @MainActor () -> Void

    @Published public private(set) var currentNotice: RemoteControlSecurityNotice?

    private var approvalContinuations: [UUID: CheckedContinuation<RemoteControlSecurityDecision, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var disconnectHandlers: [UUID: DisconnectHandler] = [:]
    private var localIdentityProvider: LocalIdentityProvider?

    init() {}

    public func setLocalIdentityProvider(_ provider: LocalIdentityProvider?) {
        localIdentityProvider = provider
    }

    public func localIdentitySnapshot() -> RemoteControlSecurityIdentity? {
        let identity = localIdentityProvider?()
        remoteControlSecurityIdentityStorage.store(identity)
        return identity
    }

    public nonisolated static func cachedLocalIdentitySnapshot() -> RemoteControlSecurityIdentity? {
        remoteControlSecurityIdentityStorage.snapshot()
    }

    public func setDisconnectHandler(
        for noticeId: UUID,
        handler: @escaping DisconnectHandler
    ) {
        disconnectHandlers[noticeId] = handler
    }

    public func recordPanelPresentedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase,
        frame: String,
        visibleFrame: String,
        windowLevel: String,
        collectionBehavior: [String],
        buttons: [String],
        topCentered: Bool
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticePanelPresented session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            phase=\(phase.rawValue) \
            frame=\(Self.statusValue(frame)) \
            visibleFrame=\(Self.statusValue(visibleFrame)) \
            level=\(Self.statusValue(windowLevel)) \
            collectionBehavior=\(Self.statusValue(collectionBehavior.joined(separator: ","))) \
            topCentered=\(topCentered ? "1" : "0") \
            buttons=\(Self.statusValue(buttons.joined(separator: ",")))
            """
        )
    }

    public func recordPanelHiddenEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        phase: RemoteControlSecurityNoticePhase
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticePanelHidden session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            phase=\(phase.rawValue)
            """
        )
    }

    public func requestApproval(
        _ descriptor: RemoteControlSecurityDescriptor
    ) async -> RemoteControlSecurityDecision {
        if let notice = currentNotice, notice.phase == .active {
            if notice.descriptor.sessionId == descriptor.sessionId,
               notice.descriptor.transportKind == descriptor.transportKind {
                updateCryptoSuite(
                    descriptor.cryptoSuite,
                    sessionId: descriptor.sessionId,
                    transportKind: descriptor.transportKind
                )
                return .approved
            }

            appendConcurrentRequestRejectedEvidence(
                descriptor: descriptor,
                activeDescriptor: notice.descriptor
            )
            return .rejected
        }

        let missingMetadata = descriptor.missingRequiredNoticeMetadata
        guard missingMetadata.isEmpty else {
            appendMissingMetadataRejectedEvidence(
                descriptor: descriptor,
                missingMetadata: missingMetadata
            )
            cleanupNoticeState(id: descriptor.id)
            return .rejected
        }

        rejectPendingNoticeIfNeeded()

        let notice = RemoteControlSecurityNotice(
            descriptor: descriptor,
            phase: .awaitingApproval
        )

        if Self.shouldAutoApproveForSmoke() {
            currentNotice = notice
            appendEvidence(event: "Shown", descriptor: descriptor)
            currentNotice = notice.updatingPhase(.active, approvedAt: Date())
            appendEvidence(event: "Approved", descriptor: descriptor)
            appendEvidence(event: "Active", descriptor: descriptor)
            return .approved
        }

        return await withCheckedContinuation { continuation in
            approvalContinuations[descriptor.id] = continuation
            timeoutTasks[descriptor.id] = Task { @MainActor [weak self] in
                let nanoseconds = UInt64(descriptor.approvalTimeoutSeconds * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.resolvePendingNotice(
                    id: descriptor.id,
                    decision: .timedOut
                )
            }
            currentNotice = notice
            appendEvidence(event: "Shown", descriptor: descriptor)
        }
    }

    public func approveCurrentNotice() {
        guard let notice = currentNotice, notice.phase == .awaitingApproval else { return }
        currentNotice = notice.updatingPhase(.active, approvedAt: Date())
        appendEvidence(event: "Approved", descriptor: notice.descriptor)
        appendEvidence(event: "Active", descriptor: notice.descriptor)
        resolveContinuation(id: notice.id, decision: .approved)
    }

    public func rejectCurrentNotice() {
        guard let notice = currentNotice else { return }
        resolvePendingNotice(id: notice.id, decision: .rejected)
    }

    public func closeCurrentNoticeFailClosed() {
        guard let notice = currentNotice else { return }
        switch notice.phase {
        case .awaitingApproval:
            resolvePendingNotice(id: notice.id, decision: .rejected)
        case .active:
            disconnectCurrentNotice()
        }
    }

    public func disconnectCurrentNotice() {
        guard let notice = currentNotice else { return }
        let handler = notice.phase == .active ? disconnectHandlers[notice.id] : nil
        appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
        currentNotice = nil
        if notice.phase == .awaitingApproval {
            resolveContinuation(id: notice.id, decision: .disconnected)
            cleanupNoticeState(id: notice.id)
            return
        }
        cleanupNoticeState(id: notice.id)
        handler?()
    }

    public func endNotice(
        sessionId: String,
        transportKind: RemoteControlTransportKind
    ) {
        guard let notice = currentNotice,
              notice.descriptor.sessionId == sessionId,
              notice.descriptor.transportKind == transportKind else {
            return
        }
        if notice.phase == .awaitingApproval {
            resolvePendingNotice(id: notice.id, decision: .disconnected)
        } else {
            appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
            currentNotice = nil
            cleanupNoticeState(id: notice.id)
        }
    }

    public func updateCryptoSuite(
        _ cryptoSuite: String,
        sessionId: String,
        transportKind: RemoteControlTransportKind
    ) {
        guard let notice = currentNotice,
              notice.descriptor.sessionId == sessionId,
              notice.descriptor.transportKind == transportKind else {
            return
        }
        let descriptor = notice.descriptor.updatingCryptoSuite(cryptoSuite)
        currentNotice = notice.updatingDescriptor(descriptor)
        appendEvidence(event: "CryptoUpdated", descriptor: descriptor)
    }

    private func rejectPendingNoticeIfNeeded() {
        guard let notice = currentNotice, notice.phase == .awaitingApproval else { return }
        resolvePendingNotice(id: notice.id, decision: .disconnected)
    }

    private func resolvePendingNotice(
        id: UUID,
        decision: RemoteControlSecurityDecision
    ) {
        guard let notice = currentNotice, notice.id == id else {
            resolveContinuation(id: id, decision: decision)
            cleanupNoticeState(id: id)
            return
        }

        switch decision {
        case .approved:
            currentNotice = notice.updatingPhase(.active, approvedAt: Date())
            appendEvidence(event: "Approved", descriptor: notice.descriptor)
            appendEvidence(event: "Active", descriptor: notice.descriptor)
        case .rejected:
            appendEvidence(event: "Rejected", descriptor: notice.descriptor)
            currentNotice = nil
        case .timedOut:
            appendEvidence(event: "TimedOut", descriptor: notice.descriptor)
            currentNotice = nil
        case .disconnected:
            appendEvidence(event: "Disconnected", descriptor: notice.descriptor)
            currentNotice = nil
        }

        resolveContinuation(id: id, decision: decision)
        if decision != .approved {
            cleanupNoticeState(id: id)
        }
    }

    private func resolveContinuation(
        id: UUID,
        decision: RemoteControlSecurityDecision
    ) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        approvalContinuations.removeValue(forKey: id)?.resume(returning: decision)
    }

    private func cleanupNoticeState(id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        approvalContinuations.removeValue(forKey: id)
        disconnectHandlers.removeValue(forKey: id)
    }

    private static func shouldAutoApproveForSmoke() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return false }
        return environment["SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE"] == "1"
    }

    private func appendEvidence(
        event: String,
        descriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNotice\(event) session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            remoteIP=\(Self.statusValue(descriptor.remoteIPAddress)) \
            remoteAccount=\(Self.maskedStatusValue(descriptor.remoteAccountDisplayName)) \
            remoteNebula=\(Self.maskedStatusValue(descriptor.remoteNebulaId)) \
            localAccount=\(Self.maskedStatusValue(descriptor.localAccountDisplayName)) \
            localNebula=\(Self.maskedStatusValue(descriptor.localNebulaId)) \
            device=\(Self.statusValue(descriptor.remoteDeviceName ?? descriptor.remoteDeviceId)) \
            cryptoSuite=\(Self.statusValue(descriptor.cryptoSuite))
            """
        )
    }

    private func appendConcurrentRequestRejectedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        activeDescriptor: RemoteControlSecurityDescriptor
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeConcurrentRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            activeSession=\(Self.statusValue(activeDescriptor.sessionId)) \
            activeTransport=\(activeDescriptor.transportKind.evidenceValue) \
            reason=active_notice_already_visible
            """
        )
    }

    private func appendMissingMetadataRejectedEvidence(
        descriptor: RemoteControlSecurityDescriptor,
        missingMetadata: [String]
    ) {
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlNoticeRejected session=\(Self.statusValue(descriptor.sessionId)) \
            transport=\(descriptor.transportKind.evidenceValue) \
            reason=missing_required_notice_metadata \
            missing=\(Self.statusValue(missingMetadata.joined(separator: ",")))
            """
        )
    }

    private static func statusValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "missing"
        }
        return value
            .map { character in
                if character.isWhitespace || character == "|" || character == "\"" {
                    return "_"
                }
                return character
            }
            .reduce(into: "") { result, character in
                result.append(character)
            }
    }

    private static func maskedStatusValue(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return "missing"
        }
        let characterCount = trimmed.count
        let masked: String
        if characterCount <= 4 {
            masked = String(trimmed.prefix(1)) + "***"
        } else if characterCount <= 8 {
            masked = String(trimmed.prefix(2)) + "***" + String(trimmed.suffix(1))
        } else {
            masked = String(trimmed.prefix(3)) + "***" + String(trimmed.suffix(3))
        }
        return statusValue(masked)
    }
}
