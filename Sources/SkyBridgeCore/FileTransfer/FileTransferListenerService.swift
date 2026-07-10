import Foundation
import Network
import OSLog

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
    private let queue = DispatchQueue(label: "com.skybridge.transfer.listener", qos: .userInitiated)
    
    // Bonjour（用于同网段发现/权限触发；并不强依赖）
    private let serviceType = "_skybridge-transfer._tcp"
    private let serviceDomain = "local."
    private var netService: NetService?
    public private(set) var activePort: UInt16?
    private var listenerHealthState: ListenerHealthState = .stopped
    private var bonjourPublished = false
 /// 上次尝试夺回首选端口的时间；用于限频，避免在首选端口长期被占时反复 churn 监听器。
    private var lastPreferredPortReclaimAttempt: Date?
 /// 夺回首选端口的最小重试间隔。
    private let preferredPortReclaimMinInterval: TimeInterval = 30
    
    public init(manager: FileTransferManager, port: UInt16 = 8080) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        guard listener == nil else { return }
        listenerHealthState = .starting

        let parameters = makeListenerParameters()
        let (boundListener, boundPort) = try await makeStartedListener(parameters: parameters, preferredPort: preferredPort)
        listener = boundListener
        activePort = boundPort
        ServiceEndpointRegistry.shared.setFileTransferPort(boundPort)
        configureBonjour(on: boundListener, port: boundPort)
    }

    public func ensureHealthy() async throws {
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
                "⚠️ FileTransfer listener unhealthy, restarting: state=\(String(describing: self.listenerHealthState), privacy: .public) activePort=\(self.activePort.map(String.init) ?? "-", privacy: .public) registryPort=\(registryPort.map(String.init) ?? "-", privacy: .public) bonjour=\(self.bonjourPublished, privacy: .public)"
            )
            stop()
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
        parameters.includePeerToPeer = false
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
            "♻️ FileTransfer 首选端口 \(self.preferredPort, privacy: .public) 现已可用，从回退端口 \(currentPort, privacy: .public) 迁回"
        )
        stop()
        do {
            try await start()
        } catch {
            log.error("❌ FileTransfer 首选端口迁回失败: \(String(describing: error), privacy: .public)")
        }
    }

 /// 用一次性探测监听器判断首选端口此刻是否可绑定。绑定成功后立即取消探测器，不影响现有监听器。
    private func preferredPortIsBindable() async -> Bool {
        let parameters = makeListenerParameters()
        guard let probe = try? NWListener(using: parameters, on: NWEndpoint.Port.validated(preferredPort)) else {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let startupGate = NetworkListenerStartupGate()
            probe.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    guard startupGate.observe(.ready) == .completesStartup else { return }
                    probe.cancel()
                    continuation.resume(returning: true)
                case .failed:
                    guard startupGate.observe(.failed) == .completesStartup else { return }
                    continuation.resume(returning: false)
                case .cancelled:
                    guard startupGate.observe(.cancelled) == .completesStartup else { return }
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            probe.start(queue: queue)
 // 兜底超时：若探测器卡在 .setup/.waiting 永不就绪，强制以“不可绑定”收尾，避免 continuation 永不 resume。
            queue.asyncAfter(deadline: .now() + 2.0) {
                guard startupGate.claimTimeout() else { return }
                probe.cancel()
                continuation.resume(returning: false)
            }
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        listenerHealthState = .stopped
        bonjourPublished = false
        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
        netService?.stop()
        netService = nil
    }
    
    /// Prefer advertising via `NWListener.service` (Network.framework) so iOS `NWBrowser` sees it reliably.
    /// We still keep a NetService fallback for older stacks / debugging.
    private func configureBonjour(on listener: NWListener?, port: UInt16) {
        guard let listener else { return }
        
        let serviceName = Host.current().localizedName ?? "Mac"
        var txt = NWTXTRecord()
        txt["platform"] = "macos"
        txt["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        txt["name"] = serviceName
        txt["model"] = "Mac"
        BonjourInteropContract.attachFileTransferAdvertisementTXT(to: &txt, port: port)
        LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &txt)
        // Mirror TXT for NetService fallback (Bonjour TXTRecord is [String: Data])
        let txtData = makeNetServiceTXTData(serviceName: serviceName, deviceId: nil, pubKeyFP: nil, port: port)
        
        // Try to include stable identity if available (best-effort, non-blocking).
        if #available(macOS 14.0, *) {
            Task { [weak self] in
                guard let self else { return }
                let snap = await SelfIdentityProvider.shared.snapshotEnsuringProtocolDeviceId(allowCreate: false)
                var updated = txt
                if !snap.deviceId.isEmpty { updated["deviceId"] = snap.deviceId }
                if !snap.pubKeyFP.isEmpty { updated["pubKeyFP"] = snap.pubKeyFP }
                updated["uniqueId"] = (snap.deviceId.isEmpty ? serviceName : snap.deviceId)
                LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &updated)
                listener.service = NWListener.Service(name: serviceName, type: self.serviceType, domain: self.serviceDomain, txtRecord: updated)

                // Keep NetService fallback TXT in sync (best-effort).
                var updatedData = self.makeNetServiceTXTData(
                    serviceName: serviceName,
                    deviceId: snap.deviceId.isEmpty ? nil : snap.deviceId,
                    pubKeyFP: snap.pubKeyFP.isEmpty ? nil : snap.pubKeyFP,
                    port: port
                )
                // Ensure uniqueId aligns with deviceId when available.
                if !snap.deviceId.isEmpty {
                    updatedData["uniqueId"] = snap.deviceId.data(using: .utf8) ?? Data()
                }
                LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &updatedData)
                self.netService?.setTXTRecord(NetService.data(fromTXTRecord: updatedData))
            }
        }
        
        listener.service = NWListener.Service(name: serviceName, type: serviceType, domain: serviceDomain, txtRecord: txt)
        bonjourPublished = true
        log.info("📡 NWListener.service advertised \(self.serviceType) port=\(port)")
        
        // Fallback NetService (optional)
        publishBonjourFallback(serviceName: serviceName, txtData: txtData, port: port)
    }
    
    private func publishBonjourFallback(serviceName: String, txtData: [String: Data], port: UInt16) {
        netService?.stop()
        netService = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(port))

        netService?.setTXTRecord(NetService.data(fromTXTRecord: txtData))
        netService?.publish()
        bonjourPublished = true
        log.info("📡 NetService fallback published \(self.serviceType) port=\(port)")
    }
    
    private func makeNetServiceTXTData(serviceName: String, deviceId: String?, pubKeyFP: String?, port: UInt16) -> [String: Data] {
        var d: [String: Data] = [
            "platform": Data("macos".utf8),
            "osVersion": Data(ProcessInfo.processInfo.operatingSystemVersionString.utf8),
            "name": Data(serviceName.utf8),
            "model": Data("Mac".utf8)
        ]
        BonjourInteropContract.attachFileTransferAdvertisementTXT(to: &d, port: port)
        // placeholder（启动后异步更新为强身份）；必须唯一，避免 iOS 端“合并错设备”
        let stableId = (deviceId?.isEmpty == false) ? deviceId! : serviceName
        d["deviceId"] = Data(stableId.utf8)
        d["uniqueId"] = Data(stableId.utf8)
        LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &d)
        if let pubKeyFP, !pubKeyFP.isEmpty {
            d["pubKeyFP"] = Data(pubKeyFP.utf8)
        }
        return d
    }

    private func makeStartedListener(
        parameters: NWParameters,
        preferredPort: UInt16
    ) async throws -> (NWListener, UInt16) {
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(preferredPort))
            let port = try await start(listener: listener)
            return (listener, port)
        } catch {
            guard isAddressInUse(error) else { throw error }
            log.warning("⚠️ FileTransfer preferred port \(preferredPort) busy, falling back to dynamic port")
            let listener = try NWListener(using: parameters)
            let port = try await start(listener: listener)
            return (listener, port)
        }
    }

    private func start(listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let startupGate = NetworkListenerStartupGate()

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        let boundPort = listener.port?.rawValue ?? 0
                        guard boundPort > 0 else {
                            guard startupGate.observe(.failed) == .completesStartup else { return }
                            listener.cancel()
                            self.listenerHealthState = .failed
                            self.activePort = nil
                            self.bonjourPublished = false
                            ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                            self.log.error("FileTransfer listener became ready without a bound port")
                            continuation.resume(throwing: POSIXError(.EADDRNOTAVAIL))
                            return
                        }
                        let observation = startupGate.observe(.ready)
                        guard observation != .ignored else { return }
                        self.listenerHealthState = .ready
                        self.activePort = boundPort
                        ServiceEndpointRegistry.shared.setFileTransferPort(boundPort)
                        self.log.info("✅ FileTransfer listener ready on \(boundPort)")
                        if observation == .completesStartup {
                            continuation.resume(returning: boundPort)
                        }
                    case .failed(let error):
                        let observation = startupGate.observe(.failed)
                        guard observation != .ignored else { return }
                        self.listenerHealthState = .failed
                        self.activePort = nil
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.error("❌ FileTransfer listener failed: \(String(describing: error))")
                        if observation == .completesStartup {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        let observation = startupGate.observe(.cancelled)
                        guard observation != .ignored else { return }
                        self.listenerHealthState = .cancelled
                        self.activePort = nil
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.info("⏹️ FileTransfer listener cancelled")
                        if observation == .completesStartup {
                            continuation.resume(throwing: POSIXError(.ECANCELED))
                        }
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleIncoming(connection)
                }
            }

            listener.start(queue: queue)
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.listenerStartTimeout)
                } catch is CancellationError {
                    return
                } catch {
                    guard startupGate.observe(.failed) == .completesStartup else { return }
                    listener.cancel()
                    self?.listenerHealthState = .failed
                    self?.activePort = nil
                    self?.bonjourPublished = false
                    ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                    self?.log.error("FileTransfer listener timeout task failed: \(String(describing: error))")
                    continuation.resume(throwing: error)
                    return
                }
                guard startupGate.claimTimeout() else { return }
                listener.cancel()
                self?.listenerHealthState = .failed
                self?.activePort = nil
                self?.bonjourPublished = false
                ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                self?.log.error("FileTransfer listener start timed out")
                continuation.resume(throwing: POSIXError(.ETIMEDOUT))
            }
        }
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

        log.info(
            "📥 FileTransfer incoming connection accepted: peer=\(deviceId, privacy: .public) endpoint=\(endpointDescription, privacy: .public)"
        )
        RemoteControlSmokeStatusWriter.append(
            "file-transfer inbound-accepted endpoint=\(Self.sanitizeForSmoke(endpointDescription))"
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let rendered: String
            switch state {
            case .setup:
                rendered = "setup"
            case .waiting(let error):
                rendered = "waiting \(error)"
            case .preparing:
                rendered = "preparing"
            case .ready:
                rendered = "ready"
            case .failed(let error):
                rendered = "failed \(error)"
            case .cancelled:
                rendered = "cancelled"
            @unknown default:
                rendered = "unknown"
            }
            self.log.info(
                "📥 FileTransfer connection state: peer=\(deviceId, privacy: .public) state=\(rendered, privacy: .public)"
            )
        }
        
        connection.start(queue: queue)
        
        Task { @MainActor in
            do {
                self.log.info("📥 FileTransfer handing connection to receiveFile: peer=\(deviceId, privacy: .public)")
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
                self.log.info(
                    "📥 FileTransfer inbound connection closed before metadata: peer=\(deviceId, privacy: .public)"
                )
                RemoteControlSmokeStatusWriter.append(
                    """
                    file-transfer inbound-pre-metadata-disconnect \
                    fatal=0 phase=initial_header bytesRead=0 \
                    peer=\(Self.sanitizeForSmoke(deviceId)) \
                    endpoint=\(Self.sanitizeForSmoke(endpointDescription))
                    """
                )
                connection.stateUpdateHandler = nil
                connection.cancel()
            } catch FileTransferError.inboundInvalidInitialHeader {
                self.log.info(
                    "📥 FileTransfer inbound connection rejected before metadata: peer=\(deviceId, privacy: .public)"
                )
                RemoteControlSmokeStatusWriter.append(
                    """
                    file-transfer inbound-rejected \
                    fatal=0 phase=initial_header reason=invalid_header \
                    peer=\(Self.sanitizeForSmoke(deviceId)) \
                    endpoint=\(Self.sanitizeForSmoke(endpointDescription))
                    """
                )
                connection.stateUpdateHandler = nil
                connection.cancel()
            } catch {
                self.log.error("❌ receiveFile failed: \(error.localizedDescription)")
                let phase = Self.fileTransferFailurePhase(for: error)
                RemoteControlSmokeStatusWriter.append(
                    "failed stage=file-transfer phase=\(phase) detail=\(Self.sanitizeForSmoke(error.localizedDescription))"
                )
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
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
        }
    }
}
