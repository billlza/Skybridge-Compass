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
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteControlServer")
    
    private let manager: RemoteControlManager
    private let port: UInt16
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.skybridge.remote.server", qos: .userInitiated)
    
    private let serviceType = "_skybridge-remote._tcp"
    private let serviceDomain = "local."
    private var netService: NetService?
    
    public init(manager: RemoteControlManager, port: UInt16 = 5901) {
        self.manager = manager
        self.port = port
    }
    
    public func start() throws {
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
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(port))
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.log.info("✅ RemoteControlServer ready on \(self.port)")
                case .failed(let error):
                    self.log.error("❌ RemoteControlServer failed: \(String(describing: error))")
                case .cancelled:
                    self.log.info("⏹️ RemoteControlServer cancelled")
                default:
                    break
                }
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleIncoming(connection)
            }
        }
        
        listener?.start(queue: queue)
        publishBonjour()
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        netService?.stop()
        netService = nil
    }
    
    private func publishBonjour() {
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
        log.info("📡 Bonjour published \(self.serviceType) port=\(self.port)")
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

