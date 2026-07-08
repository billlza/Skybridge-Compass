import Foundation
import Network
import OSLog

/// 远程桌面/控制入站服务（iPhone → Mac）
///
/// - 监听：默认由系统分配 TCP 端口，并通过 Bonjour/TXT 发布实际端口
/// - 广播：Bonjour `_skybridge-remote._tcp`
/// - 协议：复用 `RemoteControlManager` 的长度前缀帧封装与 ScreenData/RemoteMouseEvent/RemoteKeyboardEvent
@MainActor
public final class RemoteControlServer: ObservableObject {
    private final class StartState: @unchecked Sendable {
        var finished = false
    }

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
    private let queue = DispatchQueue(label: "com.skybridge.remote.server", qos: .userInteractive)
    
    private let serviceType = "_skybridge-remote._tcp"
    private let serviceDomain = "local."
    private nonisolated static let remoteRoutePreflightProbePayload = Data(
        "SKYBRIDGE_REMOTE_ROUTE_PROBE_V1\n".utf8
    )
    nonisolated private static func emitSmokeLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        smokeLog.info("\(message, privacy: .public)")
    }
    private var netService: NetService?
    public private(set) var activePort: UInt16?
    public private(set) var isBonjourPublished = false
    private var listenerHealthState: ListenerHealthState = .stopped
    private var listenerGeneration: UInt64 = 0
    private var startTask: Task<Void, Error>?
    
    public init(manager: RemoteControlManager, port: UInt16 = 0) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        if let startTask {
            try await startTask.value
            return
        }

        guard listener == nil else { return }
        let task = Task { @MainActor in
            try await self.startFresh()
        }
        startTask = task
        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }

    private func startFresh() async throws {
        guard listener == nil else { return }
        listenerHealthState = .starting
        listenerGeneration &+= 1
        let generation = listenerGeneration
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        let (boundListener, boundPort) = try await makeStartedListener(
            parameters: parameters,
            preferredPort: preferredPort,
            generation: generation
        )
        guard listenerGeneration == generation else {
            boundListener.cancel()
            throw POSIXError(.ECANCELED)
        }
        listener = boundListener
        activePort = boundPort
        ServiceEndpointRegistry.shared.setRemoteControlPort(boundPort)
        if #available(macOS 14.0, *) {
            let identitySnapshot = await SelfIdentityProvider.shared.snapshotEnsuringProtocolDeviceId(allowCreate: false)
            guard listenerGeneration == generation else {
                boundListener.cancel()
                throw POSIXError(.ECANCELED)
            }
            configureBonjour(on: boundListener, port: boundPort, identitySnapshot: identitySnapshot)
        } else {
            configureBonjour(on: boundListener, port: boundPort, identitySnapshot: nil)
        }
    }

    public func ensureHealthy() async throws {
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
        stop()
        try await start()
    }
    
    public func stop() {
        startTask?.cancel()
        startTask = nil
        listenerGeneration &+= 1
        listener?.cancel()
        listener = nil
        activePort = nil
        isBonjourPublished = false
        listenerHealthState = .stopped
        ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
        netService?.stop()
        netService = nil
    }

    private func configureBonjour(
        on listener: NWListener?,
        port: UInt16,
        identitySnapshot: SelfIdentitySnapshot?
    ) {
        guard let listener else { return }
        netService?.stop()

        let serviceName = Host.current().localizedName ?? "Mac"
        var txt = NWTXTRecord()
        txt["platform"] = "macos"
        txt["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        txt["name"] = serviceName
        txt["model"] = "Mac"
        BonjourInteropContract.attachRemoteControlAdvertisementTXT(to: &txt, port: port)
        LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &txt)

        var txtData = makeNetServiceTXTData(
            serviceName: serviceName,
            deviceId: nil,
            pubKeyFP: nil,
            port: port
        )
        if let identitySnapshot {
            if !identitySnapshot.deviceId.isEmpty {
                txt["deviceId"] = identitySnapshot.deviceId
                txt["uniqueId"] = identitySnapshot.deviceId
                txtData["deviceId"] = Data(identitySnapshot.deviceId.utf8)
                txtData["uniqueId"] = Data(identitySnapshot.deviceId.utf8)
            } else {
                txt["deviceId"] = serviceName
                txt["uniqueId"] = serviceName
            }

            if !identitySnapshot.pubKeyFP.isEmpty {
                txt["pubKeyFP"] = identitySnapshot.pubKeyFP
                txtData["pubKeyFP"] = Data(identitySnapshot.pubKeyFP.utf8)
            }
        } else {
            txt["deviceId"] = serviceName
            txt["uniqueId"] = serviceName
        }

        listener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: serviceDomain,
            txtRecord: txt
        )
        isBonjourPublished = true
        log.info("📡 NWListener.service advertised \(self.serviceType) port=\(port)")

        netService = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(port))
        netService?.setTXTRecord(NetService.data(fromTXTRecord: txtData))
        netService?.publish()
        log.info("📡 NetService fallback published \(self.serviceType) port=\(port)")
    }

    private func makeNetServiceTXTData(
        serviceName: String,
        deviceId: String?,
        pubKeyFP: String?,
        port: UInt16
    ) -> [String: Data] {
        var txt: [String: Data] = [
            "platform": Data("macos".utf8),
            "osVersion": Data(ProcessInfo.processInfo.operatingSystemVersionString.utf8),
            "name": Data(serviceName.utf8),
            "model": Data("Mac".utf8)
        ]
        BonjourInteropContract.attachRemoteControlAdvertisementTXT(to: &txt, port: port)
        let stableId = (deviceId?.isEmpty == false) ? deviceId! : serviceName
        txt["deviceId"] = Data(stableId.utf8)
        txt["uniqueId"] = Data(stableId.utf8)
        LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &txt)
        if let pubKeyFP, !pubKeyFP.isEmpty {
            txt["pubKeyFP"] = Data(pubKeyFP.utf8)
        }
        return txt
    }

    private func makeStartedListener(
        parameters: NWParameters,
        preferredPort: UInt16,
        generation: UInt64
    ) async throws -> (NWListener, UInt16) {
        guard preferredPort > 0 else {
            let listener = try NWListener(using: parameters)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        }

        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(preferredPort))
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        } catch {
            guard isAddressInUse(error) else { throw error }
            log.warning("⚠️ RemoteControl preferred port \(preferredPort) busy, falling back to dynamic port")
            let listener = try NWListener(using: parameters)
            let port = try await start(listener: listener, generation: generation)
            return (listener, port)
        }
    }

    private func start(listener: NWListener, generation: UInt64) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let startState = StartState()

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    guard self.listenerGeneration == generation else {
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(throwing: POSIXError(.ECANCELED))
                        }
                        return
                    }
                    switch state {
                    case .ready:
                        self.listenerHealthState = .ready
                        let boundPort = listener.port?.rawValue ?? 0
                        self.activePort = boundPort
                        ServiceEndpointRegistry.shared.setRemoteControlPort(boundPort)
                        self.log.info("✅ RemoteControlServer ready on \(boundPort)")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(returning: boundPort)
                        }
                    case .failed(let error):
                        self.listenerHealthState = .failed
                        self.activePort = nil
                        self.isBonjourPublished = false
                        ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                        self.log.error("❌ RemoteControlServer failed: \(String(describing: error))")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        self.listenerHealthState = .cancelled
                        self.activePort = nil
                        self.isBonjourPublished = false
                        ServiceEndpointRegistry.shared.setRemoteControlPort(nil)
                        self.log.info("⏹️ RemoteControlServer cancelled")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(throwing: POSIXError(.ECANCELED))
                        }
                    default:
                        break
                    }
                }
            }

            let connectionQueue = queue
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncoming(connection, on: connectionQueue)
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
                    on: connectionQueue
                )
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
            connection?.cancel()
        }
        connectionQueue.asyncAfter(deadline: .now() + .seconds(8), execute: idleDeadline)

        receiveInitialConnectionBytes(
            from: connection,
            endpointDescription: endpointDescription,
            buffered: Data(),
            probePayload: probePayload,
            lifecycle: lifecycle,
            on: connectionQueue
        )
    }

    private nonisolated func receiveInitialConnectionBytes(
        from connection: NWConnection,
        endpointDescription: String,
        buffered: Data,
        probePayload: Data,
        lifecycle: IncomingConnectionLifecycle,
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
                        on: connectionQueue
                    )
                    return
                }

                guard lifecycle.finishReadyInspection() else { return }
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
