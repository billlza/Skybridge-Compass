import Foundation
import Network
import OSLog

/// 远程桌面/控制入站服务（iPhone → Mac）
///
/// - 监听：TCP 5901（避免与系统 VNC 5900 冲突）
/// - 广播：Bonjour `_skybridge-remote._tcp`
/// - 协议：复用 `RemoteControlManager` 的长度前缀帧封装与 ScreenData/RemoteMouseEvent/RemoteKeyboardEvent
@MainActor
public final class RemoteControlServer: ObservableObject {
    private final class StartState: @unchecked Sendable {
        var finished = false
    }

    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteControlServer")
    
    private let manager: RemoteControlManager
    private let preferredPort: UInt16
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.skybridge.remote.server", qos: .userInitiated)
    
    private let serviceType = "_skybridge-remote._tcp"
    private let serviceDomain = "local."
    private var netService: NetService?
    public private(set) var activePort: UInt16?
    public private(set) var isBonjourPublished = false
    
    public init(manager: RemoteControlManager, port: UInt16 = 5901) {
        self.manager = manager
        self.preferredPort = port
    }
    
    public func start() async throws {
        guard listener == nil else { return }
        
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
        ServiceEndpointRegistry.shared.setRemoteControlPort(boundPort)
        if #available(macOS 14.0, *) {
            let identitySnapshot = await SelfIdentityProvider.shared.snapshotEnsuringProtocolDeviceId(allowCreate: false)
            configureBonjour(on: boundListener, port: boundPort, identitySnapshot: identitySnapshot)
        } else {
            configureBonjour(on: boundListener, port: boundPort, identitySnapshot: nil)
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        isBonjourPublished = false
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
        txt["capabilities"] = "remote_desktop"
        txt["remotePort"] = String(port)
        txt["port"] = String(port)

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
            "model": Data("Mac".utf8),
            "capabilities": Data("remote_desktop".utf8),
            "remotePort": Data(String(port).utf8),
            "port": Data(String(port).utf8)
        ]
        let stableId = (deviceId?.isEmpty == false) ? deviceId! : serviceName
        txt["deviceId"] = Data(stableId.utf8)
        txt["uniqueId"] = Data(stableId.utf8)
        if let pubKeyFP, !pubKeyFP.isEmpty {
            txt["pubKeyFP"] = Data(pubKeyFP.utf8)
        }
        return txt
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
            log.warning("⚠️ RemoteControl preferred port \(preferredPort) busy, falling back to dynamic port")
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
                        let boundPort = listener.port?.rawValue ?? 0
                        self.activePort = boundPort
                        ServiceEndpointRegistry.shared.setRemoteControlPort(boundPort)
                        self.log.info("✅ RemoteControlServer ready on \(boundPort)")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(returning: boundPort)
                        }
                    case .failed(let error):
                        self.log.error("❌ RemoteControlServer failed: \(String(describing: error))")
                        if !startState.finished {
                            startState.finished = true
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
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
    
    private func handleIncoming(_ connection: NWConnection) {
        final class IncomingConnectionLifecycle: @unchecked Sendable {
            var didHandOffToManager = false
        }

        let deviceId = resolveInboundPeerIdentifier(for: connection.endpoint)
        let lifecycle = IncomingConnectionLifecycle()

        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            print("🧪 mac remote server incoming endpoint=\(String(describing: connection.endpoint)) deviceId=\(deviceId)")
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
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
                self.log.info("🔐 RemoteControlServer connection state: peer=\(deviceId, privacy: .public) state=\(rendered, privacy: .public)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac remote server state peer=\(deviceId) state=\(rendered)")
                }

                guard case .ready = state, lifecycle.didHandOffToManager == false else { return }
                lifecycle.didHandOffToManager = true
                self.log.info("🔐 RemoteControlServer handing ready connection to manager: peer=\(deviceId, privacy: .public)")
                await self.manager.allowRemoteControl(from: deviceId, connection: connection)
            }
        }
        
        connection.start(queue: queue)
    }
}
