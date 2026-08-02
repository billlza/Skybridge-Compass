import Foundation
import Network
import OSLog
import SkyBridgeProtocolCore

/// macOS 文件传输入站监听器（iOS ↔ macOS 互传的“最小可用闭环”）
///
/// 设计：
/// - 固定监听端口：8080（与 iOS `FileTransferConstants.defaultPort`、macOS `FileTransferManager.sendFile` 默认值对齐）
/// - 协议解析/落盘逻辑复用现有 `FileTransferManager.receiveFile(from:deviceId:deviceName:)`
@MainActor
public final class FileTransferListenerService: ObservableObject {
    private static let listenerStartTimeout: Duration = .seconds(5)

    private enum ListenerHealthState {
        case stopped
        case starting
        case ready
        case failed
        case cancelled
    }

    private let log = Logger(subsystem: "com.skybridge.transfer", category: "Listener")
    
    private let manager: FileTransferManager
    private let preferredPort: UInt16
    
    private var listener: NWListener?
    private var pendingListener: NWListener?
    private var startTask: Task<Void, Error>?
    private var startTaskToken: UUID?
    private var listenerGeneration: UInt64 = 0
    private let queue = DispatchQueue(label: "com.skybridge.transfer.listener", qos: .userInitiated)
    
    // Bonjour（用于同网段发现/权限触发；并不强依赖）
    private let serviceType = BonjourInteropContract.fileTransferServiceType
    private let serviceDomain = "local."
    public private(set) var activePort: UInt16?
    private var listenerHealthState: ListenerHealthState = .stopped
    private var bonjourPublished = false
    private var inboundAdmission = ClassicTransferInboundAdmission()
    private var inboundConnections: [String: NWConnection] = [:]
    private var inboundTasks: [String: Task<Void, Never>] = [:]
 /// 上次尝试夺回首选端口的时间；用于限频，避免在首选端口长期被占时反复 churn 监听器。
    private var lastPreferredPortReclaimAttempt: Date?
 /// 夺回首选端口的最小重试间隔。
    private let preferredPortReclaimMinInterval: TimeInterval = 30
    
    public init(manager: FileTransferManager, port: UInt16 = 8080) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        if listener != nil, listenerHealthState == .ready, bonjourPublished {
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
            try await self.performStart(generation: generation, token: token)
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

    private func performStart(generation: UInt64, token: UUID) async throws {
        guard listenerGeneration == generation,
              startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }

        // Resolve the canonical authority before opening or advertising a listener.
        // Publishing a host-name placeholder first lets peers cache a weak identity
        // in the active Bonjour namespace and cannot be repaired reliably in place.
        let identity: CanonicalBonjourAdvertisementIdentity
        do {
            identity = try await CanonicalBonjourAdvertisementIdentityProvider.current(
                allowCreateDeviceId: true
            )
        } catch {
            if listenerGeneration == generation, startTaskToken == token {
                listenerHealthState = .failed
                bonjourPublished = false
                log.error(
                    "File-transfer listener startup blocked because identity authority is unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
        try Task.checkCancellation()
        guard listenerGeneration == generation,
              startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }

        let parameters = makeListenerParameters()
        let boundListener: NWListener
        let boundPort: UInt16
        do {
            (boundListener, boundPort) = try await makeStartedListener(
                parameters: parameters,
                preferredPort: preferredPort,
                identity: identity,
                generation: generation
            )
        } catch {
            if listenerGeneration == generation, startTaskToken == token {
                if let pendingListener {
                    Self.cancelListener(pendingListener)
                }
                pendingListener = nil
                listenerHealthState = .failed
                bonjourPublished = false
                ServiceEndpointRegistry.shared.setFileTransferPort(nil)
            }
            throw error
        }
        try Task.checkCancellation()
        guard listenerGeneration == generation,
              startTaskToken == token,
              listener === boundListener,
              activePort == boundPort,
              listenerHealthState == .ready,
              bonjourPublished else {
            Self.cancelListener(boundListener)
            if listener === boundListener {
                listener = nil
                activePort = nil
                listenerHealthState = .failed
                bonjourPublished = false
                ServiceEndpointRegistry.shared.setFileTransferPort(nil)
            }
            throw POSIXError(.ECANCELED)
        }
        log.info("✅ FileTransfer listener and Bonjour registration ready on \(boundPort)")
    }

    public func ensureHealthy() async throws {
        if let startTask {
            try await startTask.value
            return
        }
        let registryPort = ServiceEndpointRegistry.shared.snapshot().fileTransferPort
        let needsRestart = listener == nil
            || activePort == nil
            || listenerHealthState == .failed
            || listenerHealthState == .cancelled
            || registryPort == nil
            || registryPort != activePort
            || !bonjourPublished

        if needsRestart {
            log.warning(
                "⚠️ FileTransfer listener unhealthy, restarting: state=\(String(describing: self.listenerHealthState), privacy: .public) activePort=\(self.activePort.map(String.init) ?? "-", privacy: .private) registryPort=\(registryPort.map(String.init) ?? "-", privacy: .private) bonjour=\(self.bonjourPublished, privacy: .public)"
            )
            stopListenerPreservingAcceptedConnections()
            try await start()
            return
        }

 // 健康，但被困在动态回退端口上（启动时首选端口被占用）：周期性尝试夺回众所周知的首选端口，
 // 否则会长期停留在随机端口，与按固定端口预期的对端产生端口错位（pairing/heartbeat 端口与 Bonjour SRV 不一致）。
        if let activePort, activePort != preferredPort {
            await reclaimPreferredPortIfPossible(currentPort: activePort)
        }
    }

 /// 构建监听器参数（与 `start()` 一致），供 `start()` 与首选端口探测复用。
    private func makeListenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        return parameters
    }

 /// 当监听器被困在回退端口时，限频尝试迁回首选端口。
 /// 先用一次性探测监听器确认首选端口确实可绑定（不打扰当前监听器），仅在可用时才 stop()+start() 迁回。
 /// 已建立的传输连接走各自独立的 NWConnection，不受监听器重启影响；重启窗口仅短暂暂停“接受新连接”。
    private func reclaimPreferredPortIfPossible(currentPort: UInt16) async {
        let now = Date()
        if let last = lastPreferredPortReclaimAttempt,
           now.timeIntervalSince(last) < preferredPortReclaimMinInterval {
            return
        }
        lastPreferredPortReclaimAttempt = now

        guard await preferredPortIsBindable() else { return }

        log.warning(
            "♻️ FileTransfer 首选端口恢复可用，正在从回退监听器迁回: preferred=\(self.preferredPort, privacy: .private) current=\(currentPort, privacy: .private)"
        )
        stopListenerPreservingAcceptedConnections()
        do {
            try await start()
        } catch {
            let failure = error as NSError
            log.error(
                "❌ FileTransfer 首选端口迁回失败: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
        }
    }

 /// 用一次性探测监听器判断首选端口此刻是否可绑定。绑定成功后立即取消探测器，不影响现有监听器。
    private func preferredPortIsBindable() async -> Bool {
        let parameters = makeListenerParameters()
        let probe: NWListener
        do {
            probe = try NWListener(
                using: parameters,
                on: NWEndpoint.Port.validated(preferredPort)
            )
        } catch {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let startupGate = NetworkListenerStartupGate()
            probe.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    guard startupGate.observe(.ready) == .completesStartup else { return }
                    Self.cancelListener(probe)
                    continuation.resume(returning: true)
                case .failed:
                    guard startupGate.observe(.failed) == .completesStartup else { return }
                    Self.cancelListener(probe)
                    continuation.resume(returning: false)
                case .cancelled:
                    guard startupGate.observe(.cancelled) == .completesStartup else { return }
                    Self.clearListenerHandlers(probe)
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            probe.start(queue: queue)
 // 兜底超时：若探测器卡在 .setup/.waiting 永不就绪，强制以“不可绑定”收尾，避免 continuation 永不 resume。
            queue.asyncAfter(deadline: .now() + 2.0) {
                guard startupGate.claimTimeout() else { return }
                Self.cancelListener(probe)
                continuation.resume(returning: false)
            }
        }
    }
    
    public func stop() {
        stopListenerPreservingAcceptedConnections()
        for task in inboundTasks.values {
            task.cancel()
        }
        inboundTasks.removeAll()
        for connection in inboundConnections.values {
            Self.clearConnectionHandlers(connection)
            connection.cancel()
        }
        inboundConnections.removeAll()
        inboundAdmission.removeAll()
    }

    private func stopListenerPreservingAcceptedConnections() {
        listenerGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        startTaskToken = nil
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
        listenerHealthState = .stopped
        bonjourPublished = false
        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
    }
    
    private func configureBonjour(
        on listener: NWListener,
        identity: CanonicalBonjourAdvertisementIdentity
    ) throws {
        let serviceName = LocalHostName.localizedName ?? "Mac"
        let txt = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
            deviceId: identity.deviceId,
            pubKeyFingerprint: identity.protocolPublicKeyFingerprint,
            platform: .macOS,
            role: .dedicatedService
        )
        listener.service = NWListener.Service(name: serviceName, type: serviceType, domain: serviceDomain, txtRecord: txt)
    }
    
    private func makeStartedListener(
        parameters: NWParameters,
        preferredPort: UInt16,
        identity: CanonicalBonjourAdvertisementIdentity,
        generation: UInt64
    ) async throws -> (NWListener, UInt16) {
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(preferredPort))
            pendingListener = listener
            try configureBonjour(on: listener, identity: identity)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        } catch {
            guard isAddressInUse(error) else { throw error }
            guard listenerGeneration == generation, !Task.isCancelled else {
                throw POSIXError(.ECANCELED)
            }
            log.warning("⚠️ FileTransfer preferred port \(preferredPort) busy, falling back to dynamic port")
            let listener = try NWListener(using: parameters)
            pendingListener = listener
            try configureBonjour(on: listener, identity: identity)
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
                            self.bonjourPublished = false
                            ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                            self.log.error("FileTransfer listener became ready without a bound port")
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
                            self.bonjourPublished = true
                            ServiceEndpointRegistry.shared.setFileTransferPort(self.activePort)
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
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.error("❌ FileTransfer listener failed: \(String(describing: error))")
                        if observation == .completesStartup {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        let observation = startupGate.observeTerminal()
                        Self.clearListenerHandlers(listener)
                        if self.pendingListener === listener { self.pendingListener = nil }
                        if self.listener === listener {
                            self.listener = nil
                            self.activePort = nil
                        }
                        self.listenerHealthState = .cancelled
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.info("⏹️ FileTransfer listener cancelled")
                        if observation == .completesStartup {
                            continuation.resume(throwing: POSIXError(.ECANCELED))
                        }
                    case .waiting:
                        _ = startupGate.observeSocketUnavailable()
                        if self.listener === listener {
                            self.listenerHealthState = .starting
                            self.bonjourPublished = false
                            ServiceEndpointRegistry.shared.setFileTransferPort(nil)
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
                            self.bonjourPublished = true
                            ServiceEndpointRegistry.shared.setFileTransferPort(self.activePort)
                        case .runtimeDegraded:
                            self.listenerHealthState = .starting
                            self.bonjourPublished = false
                            ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                            self.log.warning("⚠️ FileTransfer Bonjour registration removed")
                        case .pending, .runtimeTerminal, .ignored:
                            break
                        }
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self,
                              self.listenerGeneration == generation,
                              self.listener === listener,
                              self.bonjourPublished else {
                            Self.clearConnectionHandlers(connection)
                            connection.cancel()
                            return
                        }
                        self.handleIncoming(connection)
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
                    self?.bonjourPublished = false
                    ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                    self?.log.error("FileTransfer listener or Bonjour registration timed out")
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
        bonjourPublished = true
        ServiceEndpointRegistry.shared.setFileTransferPort(port)
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
    
    private func handleIncoming(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        guard inboundAdmission.reserve(connectionID: connectionId) else {
            log.warning(
                "FileTransfer inbound connection rejected: reason=capacity limit=\(ClassicTransferInboundPolicy.maximumConcurrentConnections, privacy: .public)"
            )
            Self.clearConnectionHandlers(connection)
            connection.cancel()
            return
        }
        inboundConnections[connectionId] = connection

        let deviceId: String
        let deviceName: String
        let endpointDescription = String(describing: connection.endpoint)
        if case let .hostPort(host, _) = connection.endpoint {
            deviceId = "\(host)"
            deviceName = "\(host)"
        } else {
            deviceId = UUID().uuidString
            deviceName = "Unknown"
        }

        log.info("📥 FileTransfer incoming connection accepted")
        RemoteControlSmokeStatusWriter.append(
            "file-transfer inbound-accepted endpoint=\(Self.sanitizeForSmoke(endpointDescription))"
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let rendered: String
            switch state {
            case .setup:
                rendered = "setup"
            case .waiting:
                rendered = "waiting"
            case .preparing:
                rendered = "preparing"
            case .ready:
                rendered = "ready"
            case .failed:
                rendered = "failed"
            case .cancelled:
                rendered = "cancelled"
            @unknown default:
                rendered = "unknown"
            }
            self.log.info(
                "📥 FileTransfer connection state: state=\(rendered, privacy: .public)"
            )
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.inboundTasks[connectionId]?.cancel()
                    self?.finishInboundConnection(
                        connectionId: connectionId,
                        cancelConnection: false
                    )
                }
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        let inboundTask = Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            defer {
                self.finishInboundConnection(
                    connectionId: connectionId,
                    cancelConnection: true
                )
            }
            do {
                self.log.info("📥 FileTransfer handing connection to receiveFile")
                RemoteControlSmokeStatusWriter.append(
                    "file-transfer inbound-handler-start peer=\(Self.sanitizeForSmoke(deviceId))"
                )
                try await self.manager.receiveFile(
                    from: connection,
                    peerContext: FileTransferPeerContext(
                        declaredSenderDeviceId: nil,
                        endpointHostOrIP: deviceId,
                        peerLabel: deviceName,
                        transferId: "pending"
                    )
                )
            } catch FileTransferError.inboundConnectionClosedBeforeMetadata {
                self.log.info("📥 FileTransfer inbound connection closed before metadata")
                RemoteControlSmokeStatusWriter.append(
                    """
                    file-transfer inbound-pre-metadata-disconnect \
                    fatal=0 phase=initial_header bytesRead=0 \
                    peer=\(Self.sanitizeForSmoke(deviceId)) \
                    endpoint=\(Self.sanitizeForSmoke(endpointDescription))
                    """
                )
            } catch FileTransferError.inboundInvalidInitialHeader {
                self.log.info("📥 FileTransfer inbound connection rejected before metadata")
                RemoteControlSmokeStatusWriter.append(
                    """
                    file-transfer inbound-rejected \
                    fatal=0 phase=initial_header reason=invalid_header \
                    peer=\(Self.sanitizeForSmoke(deviceId)) \
                    endpoint=\(Self.sanitizeForSmoke(endpointDescription))
                    """
                )
            } catch {
                self.log.error("❌ receiveFile failed: \(error.localizedDescription)")
                let phase = Self.fileTransferFailurePhase(for: error)
                RemoteControlSmokeStatusWriter.append(
                    "failed stage=file-transfer phase=\(phase) detail=\(Self.sanitizeForSmoke(error.localizedDescription))"
                )
            }
        }
        inboundTasks[connectionId] = inboundTask
    }

    private func finishInboundConnection(
        connectionId: String,
        cancelConnection: Bool
    ) {
        inboundAdmission.release(connectionID: connectionId)
        guard let connection = inboundConnections.removeValue(forKey: connectionId) else {
            inboundTasks.removeValue(forKey: connectionId)
            return
        }
        inboundTasks.removeValue(forKey: connectionId)
        Self.clearConnectionHandlers(connection)
        if cancelConnection {
            connection.cancel()
        }
    }

    private nonisolated static func clearListenerHandlers(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private nonisolated static func cancelListener(_ listener: NWListener) {
        clearListenerHandlers(listener)
        listener.cancel()
    }

    private nonisolated static func clearConnectionHandlers(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.betterPathUpdateHandler = nil
        connection.pathUpdateHandler = nil
    }

    private nonisolated static func sanitizeForSmoke(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private nonisolated static func fileTransferFailurePhase(for error: Error) -> String {
        guard let transferError = error as? FileTransferError else {
            return "mac_receive_file_unknown"
        }
        switch transferError {
        case .invalidHeader:
            return "mac_receive_file_invalid_header"
        case .inboundInvalidInitialHeader:
            return "mac_receive_file_initial_header_rejected"
        case .integrityCheckFailed:
            return "mac_receive_file_integrity_check_failed"
        case .transferCancelled:
            return "mac_receive_file_transfer_cancelled"
        case .connectionClosed:
            return "mac_receive_file_connection_closed"
        case .inboundConnectionClosedBeforeMetadata:
            return "mac_receive_file_pre_metadata_closed"
        case .fileNotFound:
            return "mac_receive_file_file_not_found"
        case .timeout:
            return "mac_receive_file_timeout"
        case .receiptWaitFailed(let stage, _):
            return "mac_receive_file_\(stage.rawValue)"
        case .receiverNotConfirmed:
            return "mac_receive_file_receiver_not_confirmed"
        case .receiverRejected:
            return "mac_receive_file_receiver_rejected"
        case .secureSessionRequired:
            return "mac_receive_file_secure_session_required"
        case .securityThreatDetected:
            return "mac_receive_file_security_threat_detected"
        case .securityScanReviewRequired:
            return "mac_receive_file_security_scan_review_required"
        case .securityScanIncomplete:
            return "mac_receive_file_security_scan_incomplete"
        case .partialFileCleanupFailed:
            return "mac_receive_file_partial_cleanup_failed"
        case .sourceFileCloseFailed:
            return "mac_receive_file_source_close_failed"
        case .committedFileReleaseFailed:
            return "mac_receive_file_committed_file_release_failed"
        case .resumeStatePersistenceFailed:
            return "mac_receive_file_resume_state_failed"
        case .resumeStateCleanupFailed:
            return "mac_receive_file_resume_state_cleanup_failed"
        case .automaticResumeFailed:
            return "mac_receive_file_automatic_resume_failed"
        case .capacityExceeded:
            return "mac_receive_file_capacity_exceeded"
        case .ambiguousTarget:
            return "mac_receive_file_ambiguous_target"
        case .invalidPort:
            return "mac_receive_file_invalid_port"
        case .deliveryConfirmationUnknown:
            return "mac_receive_file_delivery_confirmation_unknown"
        case .invalidTransferState:
            return "mac_receive_file_invalid_transfer_state"
        }
    }
}
