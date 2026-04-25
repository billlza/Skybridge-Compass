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
    private final class StartState: @unchecked Sendable {
        var finished = false
    }

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
    
    public init(manager: FileTransferManager, port: UInt16 = 8080) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        guard listener == nil else { return }
        listenerHealthState = .starting
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

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

        guard needsRestart else { return }

        log.warning(
            "⚠️ FileTransfer listener unhealthy, restarting: state=\(String(describing: self.listenerHealthState), privacy: .public) activePort=\(self.activePort.map(String.init) ?? "-", privacy: .public) registryPort=\(registryPort.map(String.init) ?? "-", privacy: .public) bonjour=\(self.bonjourPublished, privacy: .public)"
        )
        stop()
        try await start()
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
        txt["capabilities"] = "file_transfer,\(ClassicTransferCapability.classicResume)"
        txt["transferPort"] = String(port)
        txt["port"] = String(port)
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
            "model": Data("Mac".utf8),
            "capabilities": Data("file_transfer,\(ClassicTransferCapability.classicResume)".utf8),
            "transferPort": Data(String(port).utf8),
            "port": Data(String(port).utf8)
        ]
        // placeholder（启动后异步更新为强身份）；必须唯一，避免 iOS 端“合并错设备”
        let stableId = (deviceId?.isEmpty == false) ? deviceId! : serviceName
        d["deviceId"] = Data(stableId.utf8)
        d["uniqueId"] = Data(stableId.utf8)
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
            let startState = StartState()

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.listenerHealthState = .ready
                        let boundPort = listener.port?.rawValue ?? 0
                        self.activePort = boundPort
                        ServiceEndpointRegistry.shared.setFileTransferPort(boundPort)
                        self.log.info("✅ FileTransfer listener ready on \(boundPort)")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(returning: boundPort)
                        }
                    case .failed(let error):
                        self.listenerHealthState = .failed
                        self.activePort = nil
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.error("❌ FileTransfer listener failed: \(String(describing: error))")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        self.listenerHealthState = .cancelled
                        self.activePort = nil
                        self.bonjourPublished = false
                        ServiceEndpointRegistry.shared.setFileTransferPort(nil)
                        self.log.info("⏹️ FileTransfer listener cancelled")
                        if !startState.finished {
                            startState.finished = true
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
                try await self.manager.receiveFile(
                    from: connection,
                    peerContext: FileTransferPeerContext(
                        declaredSenderDeviceId: nil,
                        endpointHostOrIP: deviceId,
                        peerLabel: deviceName,
                        transferId: "pending"
                    )
                )
            } catch {
                self.log.error("❌ receiveFile failed: \(error.localizedDescription)")
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
    }
}
