import Foundation
import Network
import CryptoKit
import AppKit

/// P2P设备发现服务 - 使用Bonjour/mDNS实现局域网设备自动发现
@MainActor
public class P2PDiscoveryService: NSObject, ObservableObject {
    
    // MARK: - 发布的属性
    @Published public var discoveredDevices: [P2PDevice] = []
    @Published public var isAdvertising = false
    @Published public var isDiscovering = false
    @Published public var connectionRequests: [P2PConnectionRequest] = []
    
    // MARK: - 私有属性
    private var netServiceBrowser: NetServiceBrowser?
    private var netService: NetService?
    private var listener: NWListener?
    private let serviceType = "_skybridge._tcp"
    private let serviceDomain = "local."
    
    // 设备信息
    private let deviceInfo: P2PDeviceInfo
    private let securityManager: P2PSecurityManager
    
    // MARK: - 初始化
    public override init() {
        self.deviceInfo = P2PDeviceInfo.current()
        self.securityManager = P2PSecurityManager()
        
        super.init()
        setupNotifications()
    }
    
    nonisolated deinit {
        // 在deinit中清理资源，使用局部变量避免访问非Sendable属性
        // 注意：这里我们不能直接访问属性，所以只能忽略清理
        // 系统会在对象销毁时自动处理这些资源
    }
    
    // MARK: - 公共方法
    
    /// 开始广播设备信息
    public func startAdvertising() async throws {
        guard !isAdvertising else { return }
        
        // 创建监听器
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: .any)
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleIncomingConnection(connection)
            }
        }
        
        listener?.start(queue: .global(qos: .userInitiated))
        
        // 等待监听器准备就绪
        guard let port = listener?.port else {
            throw P2PError.failedToStartListener
        }
        
        // 创建并发布NetService
        let serviceName = deviceInfo.name
        netService = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(port.rawValue))
        
        // 设置TXT记录包含设备信息
        let txtData = createTXTRecord()
        netService?.setTXTRecord(txtData)
        
        netService?.delegate = self
        netService?.publish()
        
        isAdvertising = true
        print("📡 开始广播设备: \(serviceName) 在端口: \(port)")
    }
    
    /// 停止广播设备信息
    public func stopAdvertising() {
        guard isAdvertising else { return }
        
        netService?.stop()
        netService = nil
        
        listener?.cancel()
        listener = nil
        
        isAdvertising = false
        print("📡 停止广播设备")
    }
    
    /// 开始发现局域网设备
    public func startDiscovery() {
        guard !isDiscovering else { return }
        
        netServiceBrowser = NetServiceBrowser()
        netServiceBrowser?.delegate = self
        netServiceBrowser?.searchForServices(ofType: serviceType, inDomain: serviceDomain)
        
        isDiscovering = true
        print("🔍 开始发现局域网设备")
    }
    
    /// 停止发现设备
    public func stopDiscovery() {
        guard isDiscovering else { return }
        
        netServiceBrowser?.stop()
        netServiceBrowser = nil
        
        discoveredDevices.removeAll()
        isDiscovering = false
        print("🔍 停止发现设备")
    }
    
    /// 刷新设备列表
    public func refreshDevices() async {
        print("🔄 刷新设备列表")
        
        // 如果正在发现设备，先停止再重新开始
        if isDiscovering {
            stopDiscovery()
            // 等待一小段时间确保停止完成
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        
        // 重新开始发现设备
        startDiscovery()
    }
    
    /// 请求连接到指定设备
    public func requestConnection(to device: P2PDevice) async throws -> P2PConnection {
        print("🤝 请求连接到设备: \(device.name)")
        
        // 创建连接
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(device.address), port: NWEndpoint.Port(integerLiteral: device.port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        // 发送连接请求
        let request = P2PConnectionRequest(
            sourceDevice: deviceInfo,
            targetDevice: device,
            timestamp: Date(),
            signature: try securityManager.signConnectionRequest(to: device)
        )
        
        let requestData = try JSONEncoder().encode(request)
        connection.send(content: requestData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ 发送连接请求失败: \(error)")
            }
        })
        
        return try await establishConnection(connection, with: device)
    }
    
    /// 接受连接请求
    public func acceptConnectionRequest(_ request: P2PConnectionRequest) async throws -> P2PConnection {
        print("✅ 接受来自 \(request.sourceDevice.name) 的连接请求")
        
        // 验证请求签名
        guard try securityManager.verifyConnectionRequest(request) else {
            throw P2PError.invalidSignature
        }
        
        // 从待处理请求中移除
        connectionRequests.removeAll { $0.id == request.id }
        
        // 建立连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(request.sourceDevice.address),
            port: NWEndpoint.Port(integerLiteral: request.sourceDevice.port)
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        let device = P2PDevice(from: request.sourceDevice)
        return try await establishConnection(connection, with: device)
    }
    
    /// 拒绝连接请求
    public func rejectConnectionRequest(_ request: P2PConnectionRequest) {
        print("❌ 拒绝来自 \(request.sourceDevice.name) 的连接请求")
        connectionRequests.removeAll { $0.id == request.id }
    }
    
    // MARK: - 私有方法
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await self?.startAdvertising()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAdvertising()
            }
        }
    }
    
    private func createTXTRecord() -> Data {
        let txtDict: [String: Data] = [
            "deviceId": deviceInfo.id.data(using: .utf8) ?? Data(),
            "deviceType": deviceInfo.type.rawValue.data(using: .utf8) ?? Data(),
            "osVersion": deviceInfo.osVersion.data(using: .utf8) ?? Data(),
            "capabilities": deviceInfo.capabilities.joined(separator: ",").data(using: .utf8) ?? Data(),
            "publicKey": securityManager.publicKeyData
        ]
        
        return NetService.data(fromTXTRecord: txtDict)
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) async {
        print("📞 收到连接请求")
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                await self?.processConnectionRequest(data: data, connection: connection, error: error)
            }
        }
    }
    
    private func processConnectionRequest(data: Data?, connection: NWConnection, error: NWError?) async {
        guard let data = data, error == nil else {
            print("❌ 接收连接请求数据失败: \(error?.localizedDescription ?? "未知错误")")
            connection.cancel()
            return
        }
        
        do {
            let request = try JSONDecoder().decode(P2PConnectionRequest.self, from: data)
            print("📨 收到来自 \(request.sourceDevice.name) 的连接请求")
            
            // 添加到待处理请求列表
            connectionRequests.append(request)
            
            // 发送通知给用户
            await showConnectionRequestNotification(request)
            
        } catch {
            print("❌ 解析连接请求失败: \(error)")
            connection.cancel()
        }
    }
    
    private func establishConnection(_ connection: NWConnection, with device: P2PDevice) async throws -> P2PConnection {
        return try await withCheckedThrowingContinuation { continuation in
            let p2pConnection = P2PConnection(device: device, connection: connection, securityManager: securityManager)
            
            // 监听连接状态变化
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: p2pConnection)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            
            connection.start(queue: .main)
        }
    }
    
    private func showConnectionRequestNotification(_ request: P2PConnectionRequest) async {
        // 在macOS上显示通知
        print("🔔 显示连接请求通知: \(request.sourceDevice.name)")
    }
}

// MARK: - NetServiceDelegate
extension P2PDiscoveryService: NetServiceDelegate {
    nonisolated public func netServiceDidPublish(_ sender: NetService) {
        print("📡 设备广播成功")
    }
    
    nonisolated public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("❌ 设备广播失败: \(errorDict)")
    }
    
    nonisolated public func netServiceDidStop(_ sender: NetService) {
        print("📡 设备广播已停止")
    }
}

// MARK: - NetServiceBrowserDelegate  
extension P2PDiscoveryService: NetServiceBrowserDelegate {
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("🔍 发现设备: \(service.name)")
        service.delegate = self
        service.resolve(withTimeout: 10.0)
    }
    
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let serviceName = service.name
        Task { @MainActor in
            discoveredDevices.removeAll { $0.name == serviceName }
        }
    }
    
    nonisolated public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("🔍 设备发现已停止")
    }
    
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("❌ 设备发现失败: \(errorDict)")
    }
}

// MARK: - NetService Resolution
extension P2PDiscoveryService {
    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txtData = sender.txtRecordData(),
              let addresses = sender.addresses else {
            return
        }
        
        let txtRecord = NetService.dictionary(fromTXTRecord: txtData)
        // 提取需要的数据而不是传递整个 sender 对象
        let serviceName = sender.name
        let serviceType = sender.type
        let serviceDomain = sender.domain
        let servicePort = sender.port
        
        Task { @MainActor in
            // 创建一个临时的 NetService 对象用于 createP2PDevice 方法
            let tempService = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(servicePort))
            if let device = createP2PDevice(from: tempService, txtRecord: txtRecord, addresses: addresses) {
                // 检查是否已存在
                if !discoveredDevices.contains(where: { $0.id == device.id }) {
                    discoveredDevices.append(device)
                    print("✅ 添加设备: \(device.name)")
                }
            }
        }
    }
    
    nonisolated public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("❌ 设备解析失败: \(errorDict)")
    }
    
    private func createP2PDevice(from service: NetService, txtRecord: [String: Data], addresses: [Data]) -> P2PDevice? {
        // 提取设备信息
        guard let deviceIdData = txtRecord["deviceId"],
              let deviceId = String(data: deviceIdData, encoding: .utf8),
              let deviceTypeData = txtRecord["deviceType"],
              let deviceTypeString = String(data: deviceTypeData, encoding: .utf8),
              let deviceType = P2PDeviceType(rawValue: deviceTypeString),
              let osVersionData = txtRecord["osVersion"],
              let osVersion = String(data: osVersionData, encoding: .utf8),
              let capabilitiesData = txtRecord["capabilities"],
              let capabilitiesString = String(data: capabilitiesData, encoding: .utf8),
              let publicKeyData = txtRecord["publicKey"],
              let ipAddress = extractIPAddress(from: addresses) else {
            return nil
        }
        
        let capabilities = capabilitiesString.components(separatedBy: ",")
        
        return P2PDevice(
            id: deviceId,
            name: service.name,
            type: deviceType,
            address: ipAddress,
            port: UInt16(service.port),
            osVersion: osVersion,
            capabilities: capabilities,
            publicKey: publicKeyData,
            lastSeen: Date()
        )
    }
    
    private func extractIPAddress(from addresses: [Data]) -> String? {
        for addressData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = addressData.withUnsafeBytes { bytes in
                let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress!
                return getnameinfo(sockaddr, socklen_t(addressData.count),
                                 &hostname, socklen_t(hostname.count),
                                 nil, 0, NI_NUMERICHOST)
            }
            
            if result == 0 {
                // 使用现代API替代已弃用的String(cString:)，先截断null终止符
                let truncatedHostname: [UInt8] = hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                let address = String(decoding: truncatedHostname, as: UTF8.self)
                // 优先返回IPv4地址
                if !address.contains(":") {
                    return address
                }
            }
        }
        return nil
    }
}

// MARK: - 错误定义
public enum P2PError: LocalizedError {
    case failedToStartListener
    case invalidSignature
    case connectionCancelled
    case deviceNotFound
    case authenticationFailed
    
    public var errorDescription: String? {
        switch self {
        case .failedToStartListener:
            return "无法启动网络监听器"
        case .invalidSignature:
            return "连接请求签名无效"
        case .connectionCancelled:
            return "连接已取消"
        case .deviceNotFound:
            return "未找到目标设备"
        case .authenticationFailed:
            return "设备认证失败"
        }
    }
}