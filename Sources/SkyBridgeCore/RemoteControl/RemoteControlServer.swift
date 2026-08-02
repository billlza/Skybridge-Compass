// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import Network
import OSLog

final class RemoteControlInboundAdmission: @unchecked Sendable {
    struct Lease: @unchecked Sendable {
        fileprivate let connectionID: ObjectIdentifier
        fileprivate let endpointKey: String
    }

    private struct Record {
        let connection: NWConnection
        let endpointKey: String
    }

    private let lock = NSLock()
    private let maximumConnections: Int
    private let maximumConnectionsPerEndpoint: Int
    private var records: [ObjectIdentifier: Record] = [:]
    private var countsByEndpoint: [String: Int] = [:]

    init(maximumConnections: Int = 32, maximumConnectionsPerEndpoint: Int = 4) {
        precondition(maximumConnections > 0)
        precondition(maximumConnectionsPerEndpoint > 0)
        precondition(maximumConnectionsPerEndpoint <= maximumConnections)
        self.maximumConnections = maximumConnections
        self.maximumConnectionsPerEndpoint = maximumConnectionsPerEndpoint
    }

    func reserve(connection: NWConnection, endpointKey: String) -> Lease? {
        let connectionID = ObjectIdentifier(connection)
        lock.lock()
        defer { lock.unlock() }

        if let existing = records[connectionID] {
            return Lease(connectionID: connectionID, endpointKey: existing.endpointKey)
        }
        guard records.count < maximumConnections,
              countsByEndpoint[endpointKey, default: 0] < maximumConnectionsPerEndpoint else {
            return nil
        }

        records[connectionID] = Record(connection: connection, endpointKey: endpointKey)
        countsByEndpoint[endpointKey, default: 0] += 1
        return Lease(connectionID: connectionID, endpointKey: endpointKey)
    }

    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records.removeValue(forKey: lease.connectionID) else { return }
        let remaining = countsByEndpoint[record.endpointKey, default: 0] - 1
        if remaining > 0 {
            countsByEndpoint[record.endpointKey] = remaining
        } else {
            countsByEndpoint.removeValue(forKey: record.endpointKey)
        }
    }

    func cancelAll() {
        lock.lock()
        let connections = records.values.map(\.connection)
        records.removeAll(keepingCapacity: false)
        countsByEndpoint.removeAll(keepingCapacity: false)
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    func activeConnectionCount(for endpointKey: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return countsByEndpoint[endpointKey, default: 0]
    }
}

/// 远程桌面/控制入站服务（iPhone → Mac）
///
/// - 监听：默认由系统分配 TCP 端口，并通过 Bonjour/TXT 发布实际端口
/// - 广播：Bonjour `_skybridge-rd._tcp`
/// - 协议：复用 `RemoteControlManager` 的长度前缀帧封装与 ScreenData/RemoteMouseEvent/RemoteKeyboardEvent
@MainActor
public final class RemoteControlServer: ObservableObject {
    private static let listenerStartTimeout: Duration = .seconds(5)

    private final class IncomingConnectionLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        var didHandOffToManager = false

        func finishReadyInspection() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didHandOffToManager else { return false }
            didHandOffToManager = true
            return true
        }
    }

    private enum ListenerHealthState {
        case stopped
        case starting
        case ready
        case failed
        case cancelled
    }

    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteControlServer")
    nonisolated private static let smokeLog = Logger(
        subsystem: "com.skybridge.compass",
        category: "RemoteControlSmoke"
    )
    
    private let manager: RemoteControlManager
    private let preferredPort: UInt16
    
    private var listener: NWListener?
    private var pendingListener: NWListener?
    private let queue = DispatchQueue(label: "com.skybridge.remote.server", qos: .userInteractive)
    nonisolated private let inboundAdmission = RemoteControlInboundAdmission()
    
    private let serviceType = BonjourInteropContract.remoteControlServiceType
    private let serviceDomain = "local."
    private nonisolated static let remoteRoutePreflightProbePayload = Data(
        "SKYBRIDGE_REMOTE_ROUTE_PROBE_V1\n".utf8
    )
    nonisolated private static func emitSmokeLog(_ message: String) {
#if DEBUG || SKYBRIDGE_TESTING
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        smokeLog.info("\(message, privacy: .public)")
#endif
    }
    public private(set) var activePort: UInt16?
    public private(set) var isBonjourPublished = false
    private var listenerHealthState: ListenerHealthState = .stopped
    private var listenerGeneration: UInt64 = 0
    private var startTask: Task<Void, Error>?
    private var startTaskToken: UUID?
    
    public init(manager: RemoteControlManager, port: UInt16 = 0) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        if listener != nil, listenerHealthState == .ready, isBonjourPublished {
            return
        }
        if let startTask {
            try await startTask.value
            return
        }

        if listener != nil || pendingListener != nil {
            stopListenerPreservingAcceptedConnections()
        }
        listenerGeneration &+= 1
        let generation = listenerGeneration
        let token = UUID()
        listenerHealthState = .starting
        let task = Task { @MainActor [weak self] in
            guard let self else { throw POSIXError(.ECANCELED) }
            try await self.startFresh(generation: generation, token: token)
        }
        startTask = task
        startTaskToken = token
        do {
            try await task.value
            finishStartTask(token: token)
        } catch {
            finishStartTask(token: token)
            throw error
        }
    }

    private func startFresh(generation: UInt64, token: UUID) async throws {
        guard listenerGeneration == generation, startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }
        let identitySnapshot: CanonicalBonjourAdvertisementIdentity
        do {
            identitySnapshot = try await CanonicalBonjourAdvertisementIdentityProvider.current(
                allowCreateDeviceId: true
            )
        } catch {
            if listenerGeneration == generation, startTaskToken == token {
                listenerHealthState = .failed
                isBonjourPublished = false
                ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
            }
            throw error
        }
        try Task.checkCancellation()
        guard listenerGeneration == generation, startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        let boundListener: NWListener
        let boundPort: UInt16
        do {
            (boundListener, boundPort) = try await makeStartedListener(
                parameters: parameters,
                preferredPort: preferredPort,
                identitySnapshot: identitySnapshot,
                generation: generation
            )
        } catch {
            if listenerGeneration == generation, startTaskToken == token {
                if let pendingListener { Self.cancelListener(pendingListener) }
                pendingListener = nil
                listenerHealthState = .failed
                isBonjourPublished = false
                ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
            }
            throw error
        }
        try Task.checkCancellation()
        guard listenerGeneration == generation,
              startTaskToken == token,
              listener === boundListener,
              activePort == boundPort,
              listenerHealthState == .ready,
              isBonjourPublished else {
            Self.cancelListener(boundListener)
            if listener === boundListener {
                listener = nil
                activePort = nil
                listenerHealthState = .failed
                isBonjourPublished = false
                ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
            }
            throw POSIXError(.ECANCELED)
        }
        log.info("✅ RemoteControl listener and Bonjour registration ready on \(boundPort)")
    }

    public func ensureHealthy() async throws {
        if let startTask {
            try await startTask.value
            return
        }
        let registryPort = ServiceEndpointRegistry.shared.snapshot().remoteControlPort
        let needsRestart = listener == nil
            || activePort == nil
            || listenerHealthState == .failed
            || listenerHealthState == .cancelled
            || registryPort == nil
            || registryPort != activePort
            || !isBonjourPublished

        guard needsRestart else { return }

        log.warning(
            "⚠️ RemoteControl listener unhealthy, restarting: state=\(String(describing: self.listenerHealthState), privacy: .public) activePort=\(self.activePort.map(String.init) ?? "-", privacy: .public) registryPort=\(registryPort.map(String.init) ?? "-", privacy: .public) bonjour=\(self.isBonjourPublished, privacy: .public)"
        )
        stopListenerPreservingAcceptedConnections()
        try await start()
    }
    
    public func stop() {
        stopListenerPreservingAcceptedConnections()
        inboundAdmission.cancelAll()
    }

    private func stopListenerPreservingAcceptedConnections() {
        startTask?.cancel()
        startTask = nil
        startTaskToken = nil
        listenerGeneration &+= 1
        if let pendingListener {
            pendingListener.newConnectionHandler = nil
            pendingListener.serviceRegistrationUpdateHandler = nil
            pendingListener.cancel()
        }
        pendingListener = nil
        if let listener {
            Self.cancelListener(listener)
        }
        listener = nil
        activePort = nil
        isBonjourPublished = false
        listenerHealthState = .stopped
        ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
    }

    private func configureBonjour(
        on listener: NWListener,
        identitySnapshot: CanonicalBonjourAdvertisementIdentity
    ) throws {
        let serviceName = LocalHostName.localizedName ?? "Mac"
        let txt = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
            deviceId: identitySnapshot.deviceId,
            pubKeyFingerprint: identitySnapshot.protocolPublicKeyFingerprint,
            platform: .macOS,
            role: .dedicatedService
        )
        listener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: serviceDomain,
            txtRecord: txt
        )
    }

    private nonisolated static func cancelListener(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    private func makeStartedListener(
        parameters: NWParameters,
        preferredPort: UInt16,
        identitySnapshot: CanonicalBonjourAdvertisementIdentity,
        generation: UInt64
    ) async throws -> (NWListener, UInt16) {
        guard preferredPort > 0 else {
            let listener = try NWListener(using: parameters)
            pendingListener = listener
            try configureBonjour(on: listener, identitySnapshot: identitySnapshot)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        }

        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(preferredPort))
            pendingListener = listener
            try configureBonjour(on: listener, identitySnapshot: identitySnapshot)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        } catch {
            guard isAddressInUse(error) else { throw error }
            guard listenerGeneration == generation, !Task.isCancelled else {
                throw POSIXError(.ECANCELED)
            }
            log.warning("⚠️ RemoteControl preferred port \(preferredPort) busy, falling back to dynamic port")
            let listener = try NWListener(using: parameters)
            pendingListener = listener
            try configureBonjour(on: listener, identitySnapshot: identitySnapshot)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        }
    }

    private func start(listener: NWListener, generation: UInt64) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                let startupGate = BonjourRegistrationReadinessGate()

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.listenerGeneration == generation,
                              self.pendingListener === listener || self.listener === listener else {
                            if startupGate.observeTerminal() == .completesStartup {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                            }
                            return
                        }
                        switch state {
                        case .ready:
                            let boundPort = listener.port?.rawValue ?? 0
                            guard boundPort > 0 else {
                                guard startupGate.observeTerminal() == .completesStartup else { return }
                                Self.cancelListener(listener)
                                self.listenerHealthState = .failed
                                self.isBonjourPublished = false
                                ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                                self.log.error("RemoteControlServer became ready without a bound port")
                                continuation.resume(throwing: POSIXError(.EADDRNOTAVAIL))
                                return
                            }
                            let observation = startupGate.observeSocketReady()
                            if observation == .completesStartup {
                                guard self.commitListenerStartup(
                                    listener,
                                    generation: generation,
                                    port: boundPort
                                ) else {
                                    Self.cancelListener(listener)
                                    continuation.resume(throwing: POSIXError(.ECANCELED))
                                    return
                                }
                                continuation.resume(returning: boundPort)
                            } else if observation == .runtimeReady {
                                self.listenerHealthState = .ready
                                self.isBonjourPublished = true
                                ServiceEndpointRegistry.shared.setRemoteControlPort(self.activePort)
                            }
                        case .failed(let error):
                            let observation = startupGate.observeTerminal()
                            Self.cancelListener(listener)
                            if self.pendingListener === listener { self.pendingListener = nil }
                            if self.listener === listener {
                                self.listener = nil
                                self.activePort = nil
                            }
                            self.listenerHealthState = .failed
                            self.isBonjourPublished = false
                            ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                            self.log.error("❌ RemoteControlServer failed: \(String(describing: error))")
                            if observation == .completesStartup {
                                continuation.resume(throwing: error)
                            }
                        case .cancelled:
                            let observation = startupGate.observeTerminal()
                            Self.cancelListener(listener)
                            if self.pendingListener === listener { self.pendingListener = nil }
                            if self.listener === listener {
                                self.listener = nil
                                self.activePort = nil
                            }
                            self.listenerHealthState = .cancelled
                            self.isBonjourPublished = false
                            ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                            self.log.info("⏹️ RemoteControlServer cancelled")
                            if observation == .completesStartup {
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                            }
                        case .waiting:
                            _ = startupGate.observeSocketUnavailable()
                            if self.listener === listener {
                                self.listenerHealthState = .starting
                                self.isBonjourPublished = false
                                ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                            }
                        default:
                            break
                        }
                    }
                }

                listener.serviceRegistrationUpdateHandler = { [weak self] change in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.listenerGeneration == generation,
                              self.pendingListener === listener || self.listener === listener else {
                            if startupGate.observeTerminal() == .completesStartup {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                            }
                            return
                        }
                        let observation: BonjourRegistrationReadinessGate.Observation
                        switch change {
                        case .add(let endpoint):
                            observation = startupGate.observeRegistrationAdded(
                                endpoint.debugDescription
                            )
                        case .remove(let endpoint):
                            observation = startupGate.observeRegistrationRemoved(
                                endpoint.debugDescription
                            )
                        @unknown default:
                            Self.cancelListener(listener)
                            if startupGate.observeTerminal() == .completesStartup {
                                continuation.resume(throwing: POSIXError(.EPROTO))
                            }
                            return
                        }

                        switch observation {
                        case .completesStartup:
                            guard let port = listener.port?.rawValue, port > 0 else {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.EADDRNOTAVAIL))
                                return
                            }
                            guard self.commitListenerStartup(
                                listener,
                                generation: generation,
                                port: port
                            ) else {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                                return
                            }
                            continuation.resume(returning: port)
                        case .runtimeReady:
                            self.listenerHealthState = .ready
                            self.isBonjourPublished = true
                            ServiceEndpointRegistry.shared.setRemoteControlPort(self.activePort)
                        case .runtimeDegraded:
                            self.listenerHealthState = .starting
                            self.isBonjourPublished = false
                            ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                            self.log.warning("⚠️ RemoteControl Bonjour registration removed")
                        case .pending, .runtimeTerminal, .ignored:
                            break
                        }
                    }
                }

                let connectionQueue = queue
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    Task { @MainActor in
                        guard self.listenerGeneration == generation,
                              self.listener === listener,
                              self.isBonjourPublished else {
                            connection.cancel()
                            return
                        }
                        self.handleIncoming(connection, on: connectionQueue)
                    }
                }

                listener.start(queue: queue)
                Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: Self.listenerStartTimeout)
                    } catch {
                        return
                    }
                    guard startupGate.claimTimeout() else { return }
                    Self.cancelListener(listener)
                    if self?.pendingListener === listener {
                        self?.pendingListener = nil
                    }
                    self?.listenerHealthState = .failed
                    self?.isBonjourPublished = false
                    ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                    self?.log.error("RemoteControl listener or Bonjour registration timed out")
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                }
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private func commitListenerStartup(
        _ candidate: NWListener,
        generation: UInt64,
        port: UInt16
    ) -> Bool {
        guard listenerGeneration == generation,
              pendingListener === candidate,
              port > 0 else {
            return false
        }
        pendingListener = nil
        listener = candidate
        activePort = port
        listenerHealthState = .ready
        isBonjourPublished = true
        ServiceEndpointRegistry.shared.setRemoteControlPort(port)
        return true
    }

    private func finishStartTask(token: UUID) {
        guard startTaskToken == token else { return }
        startTask = nil
        startTaskToken = nil
    }

    private func isAddressInUse(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .EADDRINUSE {
            return true
        }
        if let nwError = error as? NWError,
           case .posix(let code) = nwError,
           code == .EADDRINUSE {
            return true
        }
        return (error as NSError).code == 48
    }

    private func resolveInboundPeerIdentifier(for endpoint: NWEndpoint) -> String {
        let fallback = Self.fallbackPeerIdentifier(for: endpoint)

        switch endpoint {
        case .hostPort(let host, _):
            let hostText = String(describing: host)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let discovered = P2PDiscoveryService.shared.discoveredDevices
            if let match = discovered.first(where: {
                $0.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == hostText
                    || $0.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == hostText
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceId.isEmpty {
                    return deviceId
                }
                if let uniqueIdentifier = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !uniqueIdentifier.isEmpty {
                    return PeerTrustLookup.persistentDeviceId(from: uniqueIdentifier) ?? uniqueIdentifier
                }
            }
            return fallback
        case .service(let name, _, let domain, _):
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDomain = (domain.isEmpty ? "local." : domain)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let discovered = P2PDiscoveryService.shared.discoveredDevices
            if let match = discovered.first(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceId.isEmpty {
                    return deviceId
                }
                if let uniqueIdentifier = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !uniqueIdentifier.isEmpty {
                    return PeerTrustLookup.persistentDeviceId(from: uniqueIdentifier) ?? uniqueIdentifier
                }
            }
            return "bonjour:\(normalizedName)@\(normalizedDomain)"
        default:
            return fallback
        }
    }

    private nonisolated static func fallbackPeerIdentifier(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            let value = String(describing: host).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : "peer:\(value.lowercased())"
        case .service(let name, _, let domain, _):
            let resolvedDomain = domain.isEmpty ? "local." : domain
            return "bonjour:\(name)@\(resolvedDomain)"
        default:
            return endpoint.debugDescription
        }
    }
    
    private nonisolated func handleIncoming(_ connection: NWConnection, on connectionQueue: DispatchQueue) {
        let endpointKey = Self.fallbackPeerIdentifier(for: connection.endpoint)
        guard let admissionLease = inboundAdmission.reserve(
            connection: connection,
            endpointKey: endpointKey
        ) else {
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-inbound rejected reason=capacity endpoint=\(endpointKey)"
            )
            connection.cancel()
            return
        }
        let lifecycle = IncomingConnectionLifecycle()
        let endpointDescription = String(describing: connection.endpoint)
        RemoteControlSmokeStatusWriter.append("mac-remote-inbound accepted endpoint=\(endpointDescription)")

        Self.emitSmokeLog("🧪 mac remote server incoming endpoint=\(endpointDescription)")

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            let rendered = Self.renderConnectionState(state)

            Self.emitSmokeLog("🧪 mac remote server state endpoint=\(endpointDescription) state=\(rendered)")
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-inbound state=\(rendered.replacingOccurrences(of: " ", with: "_")) endpoint=\(endpointDescription)"
            )

            if case .ready = state {
                self?.inspectReadyConnectionBeforeHandoff(
                    connection,
                    endpointDescription: endpointDescription,
                    lifecycle: lifecycle,
                    admissionLease: admissionLease,
                    on: connectionQueue
                )
            }
            if case .failed = state {
                self?.inboundAdmission.release(admissionLease)
            } else if case .cancelled = state {
                self?.inboundAdmission.release(admissionLease)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let deviceId = self.resolveInboundPeerIdentifier(for: connection.endpoint)
                self.log.info("🔐 RemoteControlServer connection state: peer=\(deviceId, privacy: .public) state=\(rendered, privacy: .public)")
                Self.emitSmokeLog("🧪 mac remote server state peer=\(deviceId) state=\(rendered)")
            }
        }
        
        connection.start(queue: connectionQueue)
    }

    private nonisolated func inspectReadyConnectionBeforeHandoff(
        _ connection: NWConnection,
        endpointDescription: String,
        lifecycle: IncomingConnectionLifecycle,
        admissionLease: RemoteControlInboundAdmission.Lease,
        on connectionQueue: DispatchQueue
    ) {
        let probePayload = Self.remoteRoutePreflightProbePayload
        RemoteControlSmokeStatusWriter.append(
            "mac-remote-inbound initial-inspect-start endpoint=\(endpointDescription)"
        )
        let idleDeadline = DispatchWorkItem { [weak connection] in
            guard lifecycle.finishReadyInspection() else { return }
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-inbound idle-timeout endpoint=\(endpointDescription)"
            )
            self.inboundAdmission.release(admissionLease)
            connection?.cancel()
        }
        connectionQueue.asyncAfter(deadline: .now() + .seconds(8), execute: idleDeadline)

        receiveInitialConnectionBytes(
            from: connection,
            endpointDescription: endpointDescription,
            buffered: Data(),
            probePayload: probePayload,
            lifecycle: lifecycle,
            admissionLease: admissionLease,
            on: connectionQueue
        )
    }

    private nonisolated func receiveInitialConnectionBytes(
        from connection: NWConnection,
        endpointDescription: String,
        buffered: Data,
        probePayload: Data,
        lifecycle: IncomingConnectionLifecycle,
        admissionLease: RemoteControlInboundAdmission.Lease,
        on connectionQueue: DispatchQueue
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var initialData = buffered
            if let data, !data.isEmpty {
                initialData.append(data)
            }
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-inbound initial-read endpoint=\(endpointDescription) chunk=\(data?.count ?? 0) buffered=\(initialData.count) complete=\(isComplete)"
            )

            if let error {
                guard lifecycle.finishReadyInspection() else { return }
                self.inboundAdmission.release(admissionLease)
                RemoteControlSmokeStatusWriter.append(
                    "mac-remote-inbound initial-read-failed endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                )
                connection.cancel()
                return
            }

            if !initialData.isEmpty {
                if Self.isPrefix(initialData, of: probePayload), initialData.count < probePayload.count {
                    self.receiveInitialConnectionBytes(
                        from: connection,
                        endpointDescription: endpointDescription,
                        buffered: initialData,
                        probePayload: probePayload,
                        lifecycle: lifecycle,
                        admissionLease: admissionLease,
                        on: connectionQueue
                    )
                    return
                }

                guard lifecycle.finishReadyInspection() else { return }
                inboundAdmission.release(admissionLease)
                if initialData == probePayload {
                    RemoteControlSmokeStatusWriter.append(
                        "mac-remote-inbound probe=remote-route-preflight bytes=\(initialData.count) endpoint=\(endpointDescription)"
                    )
                    connection.cancel()
                    return
                }

                let handoffConnection = connection
                let handoffData = initialData
                RemoteControlSmokeStatusWriter.append(
                    "mac-remote-inbound handoff-scheduled bytes=\(handoffData.count) endpoint=\(endpointDescription)"
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let deviceId = self.resolveInboundPeerIdentifier(for: handoffConnection.endpoint)
                    RemoteControlSmokeStatusWriter.append(
                        "mac-remote-inbound handoff-manager peer=\(deviceId) bytes=\(handoffData.count) endpoint=\(endpointDescription)"
                    )
                    self.log.info(
                        "🔐 RemoteControlServer handing ready connection to manager: peer=\(deviceId, privacy: .public) initialBytes=\(handoffData.count, privacy: .public)"
                    )
                    await self.manager.allowRemoteControl(
                        from: deviceId,
                        connection: handoffConnection,
                        initialData: handoffData
                    )
                }
                return
            }

            if isComplete {
                guard lifecycle.finishReadyInspection() else { return }
                inboundAdmission.release(admissionLease)
                RemoteControlSmokeStatusWriter.append(
                    "mac-remote-inbound closed-before-handshake endpoint=\(endpointDescription)"
                )
                connection.cancel()
                return
            }

            self.receiveInitialConnectionBytes(
                from: connection,
                endpointDescription: endpointDescription,
                buffered: initialData,
                probePayload: probePayload,
                lifecycle: lifecycle,
                admissionLease: admissionLease,
                on: connectionQueue
            )
        }
    }

    private nonisolated static func isPrefix(_ data: Data, of probePayload: Data) -> Bool {
        guard data.count <= probePayload.count else { return false }
        return probePayload.prefix(data.count).elementsEqual(data)
    }

    private nonisolated static func renderConnectionState(_ state: NWConnection.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .waiting(let error):
            return "waiting \(error)"
        case .preparing:
            return "preparing"
        case .ready:
            return "ready"
        case .failed(let error):
            return "failed \(error)"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }
}
#endif
