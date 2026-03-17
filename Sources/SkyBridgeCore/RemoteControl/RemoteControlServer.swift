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
    private(set) var activePort: UInt16?
    
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
        publishBonjour(port: boundPort)
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        netService?.stop()
        netService = nil
    }
    
    private func publishBonjour(port: UInt16) {
        netService?.stop()

        let serviceName = Host.current().localizedName ?? "Mac"
        netService = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(port))

        // TXT: iOS 端用于展示“可远控(端口)”以及系统信息
        var txt: [String: Data] = [
            "platform": "macos".data(using: .utf8) ?? Data(),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString.data(using: .utf8) ?? Data(),
            "name": serviceName.data(using: .utf8) ?? Data(),
            "model": "Mac".data(using: .utf8) ?? Data(),
            "capabilities": "remote_desktop".data(using: .utf8) ?? Data(),
            "remotePort": "\(port)".data(using: .utf8) ?? Data(),
            "port": "\(port)".data(using: .utf8) ?? Data()
        ]
        // placeholder（启动后异步更新为强身份）；必须唯一，避免 iOS 端“合并错设备”
        txt["deviceId"] = serviceName.data(using: .utf8) ?? Data()
        txt["uniqueId"] = serviceName.data(using: .utf8) ?? Data()

        netService?.setTXTRecord(NetService.data(fromTXTRecord: txt))
        netService?.publish()

        // 异步补齐 deviceId/pubKeyFP（不阻塞 start）
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 14.0, *) {
                let snap = await SelfIdentityProvider.shared.snapshot()
                var updated = txt
                if !snap.deviceId.isEmpty { updated["deviceId"] = snap.deviceId.data(using: .utf8) ?? Data() }
                if !snap.pubKeyFP.isEmpty { updated["pubKeyFP"] = snap.pubKeyFP.data(using: .utf8) ?? Data() }
                updated["uniqueId"] = (snap.deviceId.isEmpty ? serviceName : snap.deviceId).data(using: .utf8) ?? Data()
                self.netService?.setTXTRecord(NetService.data(fromTXTRecord: updated))
            }
        }
        log.info("📡 Bonjour published \(self.serviceType) port=\(port)")
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
    
    private func handleIncoming(_ connection: NWConnection) {
        let deviceId: String
        if case let .hostPort(host, _) = connection.endpoint {
            deviceId = "\(host)"
        } else {
            deviceId = UUID().uuidString
        }
        
        connection.start(queue: queue)
        
        Task { @MainActor in
            await self.manager.allowRemoteControl(from: deviceId, connection: connection)
        }
    }
}
