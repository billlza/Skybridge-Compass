import Foundation
import Network
import NetworkExtension
import SystemConfiguration
import Combine

/// P2P网络通信层 - 实现NAT穿透、UDP打洞和TCP fallback机制
@MainActor
public class P2PNetworkLayer: ObservableObject, Sendable {
    
 // MARK: - 发布的属性
    @Published public var connectionState: P2PConnectionStatus = .disconnected
    @Published public var activeConnections: [P2PConnection] = []
    @Published public var networkStatistics: P2PNetworkStatistics = P2PNetworkStatistics()
    @Published public var isNATTraversalEnabled = true
    @Published public var preferredProtocol: P2PProtocol = .udp
    
 /// P2P 直连开关（从 SettingsManager 同步）
 /// 当禁用时，所有连接将通过中继服务器转发
    @Published public var enableP2PDirectConnection: Bool = false {
        didSet {
            let enabled = enableP2PDirectConnection
            SkyBridgeLogger.p2p.info("🔗 P2P 直连已\(enabled ? "启用" : "禁用")")
            if !enabled {
 // 禁用直连时，关闭 NAT 穿透
                isNATTraversalEnabled = false
            }
        }
    }
    
 // MARK: - 发布者属性
 /// 连接状态发布者，用于外部监听连接状态变化
    public var connectionStatePublisher: AnyPublisher<P2PConnectionStatus, Never> {
        return $connectionState.eraseToAnyPublisher()
    }
    
 // MARK: - 私有属性
    
    private let networkQueue: DispatchQueue
    private let connectionQueue: DispatchQueue
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var stunClient: STUNClient?
    private var natTraversal: NATTraversalManager?
    private var securityManager: P2PSecurityManager?
    
 // 连接管理
    private var pendingConnections: [String: PendingP2PConnection] = [:]
    private var establishedConnections: [String: P2PConnection] = [:]
    private var connectionAttempts: [String: Int] = [:]
    private let maxConnectionAttempts = 3
    
 // 网络监控
    private var networkMonitor: NWPathMonitor?
    private var currentNetworkPath: NWPath?
    private var localEndpoints: [NWEndpoint] = []
    
 // 回调和代理
    private var connectionEstablishedCallback: ((P2PConnection) -> Void)?
    private var connectionFailedCallback: ((String, Error) -> Void)?
    private var dataReceivedCallback: ((Data, P2PConnection) -> Void)?
    
 // 配置
    private let configuration: P2PNetworkConfiguration
    
 // 统计信息
    private var statisticsTimer: Timer?
    private var bytesReceived: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var packetsReceived: UInt64 = 0
    private var packetsSent: UInt64 = 0
    
 // MARK: - 初始化
    
    public init(configuration: P2PNetworkConfiguration = P2PNetworkConfiguration.defaultConfiguration) {
        self.configuration = configuration
        self.networkQueue = DispatchQueue(label: "com.skybridge.p2p.network", qos: .userInitiated)
        self.connectionQueue = DispatchQueue(label: "com.skybridge.p2p.connection", qos: .userInitiated)
        
 // 初始化安全管理器
        self.securityManager = P2PSecurityManager()
        
        SkyBridgeLogger.p2p.debugOnly("🌐 P2P网络层初始化")
        SkyBridgeLogger.p2p.debugOnly("📊 配置: 监听端口 \(configuration.listenPort)")
        SkyBridgeLogger.p2p.debugOnly("🔧 STUN服务器: \(configuration.stunServers.first?.host ?? "无")")
        
        setupNetworkMonitoring()
        setupSTUNClient()
        setupNATTraversal()
    }
    
    deinit {
 // 在 deinit 中不能调用主 actor 隔离的方法，直接清理资源
        udpListener?.cancel()
        tcpListener?.cancel()
        networkMonitor?.cancel()
 // 不能访问非Sendable的Timer属性
 // statisticsTimer?.invalidate()
    }
    
 // MARK: - 公共方法
    
 /// 启动网络服务
    public func startNetworking() throws {
        SkyBridgeLogger.p2p.debugOnly("🚀 启动P2P网络服务")
        
 // 启动UDP监听器
        try startUDPListener()
        
 // 启动TCP监听器
        try startTCPListener()
        
 // 发现本地网络端点
        discoverLocalEndpoints()
        
 // 启动网络监控
        startNetworkMonitoring()
        
 // 启动统计信息收集
        startStatisticsCollection()
        
        Task { @MainActor in
            self.connectionState = .listening
        }
        
        SkyBridgeLogger.p2p.debugOnly("✅ P2P网络服务已启动")
    }
    
 /// 停止网络服务
    public func stopNetworking() {
        SkyBridgeLogger.p2p.debugOnly("⏹️ 停止P2P网络服务")
        
 // 停止监听器
        udpListener?.cancel()
        tcpListener?.cancel()
        udpListener = nil
        tcpListener = nil
        
 // 关闭所有连接
        closeAllConnections()
        
 // 停止网络监控
        networkMonitor?.cancel()
        networkMonitor = nil
        
 // 停止统计信息收集
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        
        connectionState = .disconnected
        
        SkyBridgeLogger.p2p.debugOnly("✅ P2P网络服务已停止")
    }
    
 /// 连接到远程设备
    public func connectToDevice(_ device: P2PDevice,
                               connectionEstablished: @escaping (P2PConnection) -> Void,
                               connectionFailed: @escaping (String, Error) -> Void) {
        
        SkyBridgeLogger.p2p.debugOnly("🔗 尝试连接到设备: \(device.name)")
        
        self.connectionEstablishedCallback = connectionEstablished
        self.connectionFailedCallback = connectionFailed
        
        let deviceId = device.id
        
 // 检查是否已有连接
        if let existingConnection = establishedConnections[deviceId] {
            SkyBridgeLogger.p2p.debugOnly("✅ 设备已连接，复用现有连接")
            connectionEstablished(existingConnection)
            return
        }
        
 // 检查连接尝试次数
        let attempts = connectionAttempts[deviceId] ?? 0
        if attempts >= maxConnectionAttempts {
            let error = P2PNetworkError.maxAttemptsExceeded
            SkyBridgeLogger.p2p.error("❌ 连接尝试次数超限: \(deviceId, privacy: .private)")
            connectionFailed(deviceId, error)
            return
        }
        
        connectionAttempts[deviceId] = attempts + 1
        
 // 开始连接流程
        let deviceCopy = device // 创建本地副本避免数据竞争
        connectionQueue.async { [weak self] in
            Task { @MainActor in
                self?.initiateConnection(to: deviceCopy)
            }
        }
    }
    
 /// 发送数据到指定连接
    public func sendData(_ data: Data, to connection: P2PConnection) throws {
        guard connection.status == .connected else {
            throw P2PNetworkError.connectionNotEstablished
        }
        
        performSendData(data, to: connection)
    }
    
 /// 广播数据到所有连接
    public func broadcastData(_ data: Data) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                for connection in self.establishedConnections.values {
                    if connection.status == .connected {
                        self.performSendData(data, to: connection)
                    }
                }
            }
        }
    }
    
 /// 断开指定连接
    public func disconnectFromDevice(_ deviceId: String) {
        SkyBridgeLogger.p2p.debugOnly("🔌 断开设备连接: \(deviceId)")
        
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let connection = self.establishedConnections[deviceId] {
                    self.closeConnection(connection)
                }
                
                self.pendingConnections.removeValue(forKey: deviceId)
                self.connectionAttempts.removeValue(forKey: deviceId)
            }
        }
    }
    
 /// 设置数据接收回调
    public func setDataReceivedCallback(_ callback: @escaping (Data, P2PConnection) -> Void) {
        self.dataReceivedCallback = callback
    }
    
 /// 获取网络质量信息
    public func getNetworkQuality() -> P2PNetworkQuality {
        guard let path = currentNetworkPath else {
            return P2PNetworkQuality(
                latency: 0,
                bandwidth: 0,
                packetLoss: 0,
                jitter: 0,
                quality: .poor
            )
        }
        
 // 基于网络路径和统计信息计算网络质量
        let isWiFi = path.usesInterfaceType(.wifi)
        let isEthernet = path.usesInterfaceType(.wiredEthernet)
        let isCellular = path.usesInterfaceType(.cellular)
        
        var quality: NetworkQualityLevel = .good
        var estimatedBandwidth: UInt64 = 0
        var estimatedLatency: TimeInterval = 0
        
        if isEthernet {
            quality = .excellent
            estimatedBandwidth = 1_000_000_000 // 1 Gbps
            estimatedLatency = 0.001 // 1ms
        } else if isWiFi {
            quality = .good
            estimatedBandwidth = 100_000_000 // 100 Mbps
            estimatedLatency = 0.005 // 5ms
        } else if isCellular {
            quality = .fair
            estimatedBandwidth = 50_000_000 // 50 Mbps
            estimatedLatency = 0.050 // 50ms
        } else {
            quality = .poor
            estimatedBandwidth = 1_000_000 // 1 Mbps
            estimatedLatency = 0.100 // 100ms
        }
        
        return P2PNetworkQuality(
            latency: estimatedLatency,
            bandwidth: estimatedBandwidth,
            packetLoss: 0, // 需要实际测量
            jitter: 0, // 需要实际测量
            quality: quality
        )
    }
    
 // MARK: - 私有方法 - 网络设置
    
 /// 设置网络监控
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathUpdate(path)
            }
        }
    }
    
 /// 设置STUN客户端
    private func setupSTUNClient() {
        guard let p2pStunServer = configuration.stunServers.first else {
            SkyBridgeLogger.p2p.debugOnly("⚠️ 未配置STUN服务器")
            return
        }
        
 // 将P2PSTUNServer转换为STUNServer
        let stunServer = STUNServer(host: p2pStunServer.host, port: p2pStunServer.port)
        stunClient = STUNClient(server: stunServer)
        SkyBridgeLogger.p2p.debugOnly("🎯 STUN客户端已配置: \(stunServer.host):\(stunServer.port)")
    }
    
 /// 设置NAT穿透管理器
    private func setupNATTraversal() {
        natTraversal = NATTraversalManager(configuration: configuration)
        SkyBridgeLogger.p2p.debugOnly("🔓 NAT穿透管理器已配置")
    }
    
 /// 启动UDP监听器
    private func startUDPListener() throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        udpListener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: configuration.listenPort))
        
        udpListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewUDPConnection(connection)
            }
        }
        
        udpListener?.start(queue: networkQueue)
        SkyBridgeLogger.p2p.debugOnly("📡 UDP监听器已启动，端口: \(configuration.listenPort)")
    }
    
 /// 启动TCP监听器
    private func startTCPListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        tcpListener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: configuration.listenPort + 1))
        
        tcpListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewTCPConnection(connection)
            }
        }
        
        tcpListener?.start(queue: networkQueue)
        SkyBridgeLogger.p2p.debugOnly("📡 TCP监听器已启动，端口: \(configuration.listenPort + 1)")
    }
    
 /// 发现本地网络端点
    private func discoverLocalEndpoints() {
        Task { @MainActor in
            var endpoints: [NWEndpoint] = []
            
 // 获取本地IP地址
            if let addresses = self.getLocalIPAddresses() {
                for address in addresses {
                    let udpEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(address),
                        port: NWEndpoint.Port(integerLiteral: self.configuration.listenPort)
                    )
                    endpoints.append(udpEndpoint)
                    
                    let tcpEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(address),
                        port: NWEndpoint.Port(integerLiteral: self.configuration.listenPort + 1)
                    )
                    endpoints.append(tcpEndpoint)
                }
            }
            
            self.localEndpoints = endpoints
 // 统一使用结构化日志替代 print
            SkyBridgeLogger.network.info("🏠 发现本地端点: \(endpoints.count)个")
        }
    }
    
 /// 获取本地IP地址
    @MainActor
    private func getLocalIPAddresses() -> [String]? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                guard let namePtr = interface.ifa_name else { continue }
 // 使用统一的 UTF8 安全解码替代已弃用的 String(cString:)
                let name = decodeCString(namePtr)
                
 // 过滤回环和无效接口
                if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("ipsec") {
                    continue
                }
                
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    socklen_t(0),
                    NI_NUMERICHOST
                )
                
                if result == 0 {
 // 使用现代API替代已弃用的String(cString:)，先截断null终止符
                    let truncatedHostname: [UInt8] = hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    let address = String(decoding: truncatedHostname, as: UTF8.self)
                    addresses.append(address)
                }
            }
        }
        
        return addresses.isEmpty ? nil : addresses
    }
    
 // MARK: - 私有方法 - 连接管理
    
 /// 发起连接
 /// 根据 enableP2PDirectConnection 设置决定连接策略
    @MainActor
    private func initiateConnection(to device: P2PDevice) {
 // 统一使用结构化日志替代 print
        SkyBridgeLogger.network.info("🔄 发起连接到设备: \(device.name)")
        
 // 检查 P2P 直连是否启用
        guard enableP2PDirectConnection else {
            SkyBridgeLogger.network.info("🔗 P2P 直连已禁用，尝试中继连接")
            attemptRelayConnection(to: device)
            return
        }
        
        let pendingConnection = PendingP2PConnection(
            device: device,
            startTime: Date(),
            attempts: connectionAttempts[device.id] ?? 0
        )
        
        pendingConnections[device.id] = pendingConnection
        
 // 尝试不同的连接方法
        if isNATTraversalEnabled {
 // 首先尝试NAT穿透
            attemptNATTraversal(to: device)
        } else {
 // 直接尝试连接
            attemptDirectConnection(to: device)
        }
    }
    
 /// 尝试通过中继服务器连接（当 P2P 直连禁用时）
    @MainActor
    private func attemptRelayConnection(to device: P2PDevice) {
        SkyBridgeLogger.network.info("🔄 尝试中继连接到设备: \(device.name)")
        
 // 使用 TCP fallback 作为中继连接
 // 在生产环境中，这里应该连接到专用的中继服务器
        let pendingConnection = PendingP2PConnection(
            device: device,
            startTime: Date(),
            attempts: connectionAttempts[device.id] ?? 0
        )
        
        pendingConnections[device.id] = pendingConnection
        
 // 使用直接连接作为中继方式（TCP fallback）
        attemptDirectConnection(to: device)
    }
    
 /// 尝试NAT穿透连接
    private func attemptNATTraversal(to device: P2PDevice) {
        SkyBridgeLogger.p2p.debugOnly("🔓 尝试NAT穿透连接: \(device.name)")
        
        guard let natTraversal = natTraversal else {
            SkyBridgeLogger.p2p.error("❌ NAT穿透管理器未初始化")
            attemptDirectConnection(to: device)
            return
        }
        
 // 创建打洞会话
        let session = HolePunchingSession(sessionId: UUID().uuidString, targetDevice: device)
        
        Task {
            do {
 // 执行直接连接（替代performHolePunching方法）
                try await natTraversal.performDirectConnection(to: session)
                SkyBridgeLogger.p2p.debugOnly("✅ NAT穿透成功")
                
 // 使用设备的第一个端点建立连接
                if let endpointString = device.endpoints.first {
                    let components = endpointString.split(separator: ":")
                    if components.count == 2,
                       let host = components.first,
                       let portString = components.last,
                       let port = UInt16(portString) {
                        let endpoint = NWEndpoint.hostPort(
                            host: NWEndpoint.Host(String(host)),
                            port: NWEndpoint.Port(integerLiteral: port)
                        )
                        self.establishConnection(to: device, via: endpoint, protocol: .udp)
                    }
                }
            } catch {
                SkyBridgeLogger.p2p.error("❌ NAT穿透失败: \(error.localizedDescription, privacy: .private)")
                self.attemptDirectConnection(to: device)
            }
        }
    }
    
 /// 尝试直接连接
    private func attemptDirectConnection(to device: P2PDevice) {
        SkyBridgeLogger.p2p.debugOnly("🔗 尝试直接连接到设备: \(device.name)")
        
 // 将字符串端点转换为NWEndpoint
        let nwEndpoints = device.endpoints.compactMap { endpointString -> NWEndpoint? in
            let components = endpointString.split(separator: ":")
            guard components.count == 2,
                  let host = components.first,
                  let portString = components.last,
                  let port = UInt16(portString) else {
                return nil
            }
            return NWEndpoint.hostPort(host: NWEndpoint.Host(String(host)), port: NWEndpoint.Port(integerLiteral: port))
        }
        
        for endpoint in nwEndpoints {
            establishConnection(to: device, via: endpoint, protocol: preferredProtocol)
        }
    }
    
 /// 建立连接
    private func establishConnection(to device: P2PDevice, via endpoint: NWEndpoint, protocol: P2PProtocol) {
        SkyBridgeLogger.p2p.debugOnly("🔗 建立连接到 \(device.name) via \(String(describing: endpoint))")
        
        let parameters: NWParameters
        switch `protocol` {
        case .tcp:
            parameters = .tcp
        case .udp:
            parameters = .udp
        default:
            parameters = .tcp
        }
        
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        guard let securityManager = securityManager else {
            SkyBridgeLogger.p2p.error("P2P 安全管理器未初始化，无法建立连接")
            return
        }
        _ = P2PConnection(device: device, connection: nwConnection, securityManager: securityManager)
        
        pendingConnections[device.id] = PendingP2PConnection(device: device, startTime: Date(), attempts: 1)
        
        nwConnection.start(queue: .global())
    }
    
 /// 处理连接状态变化
    private func handleConnectionStateChange(_ connection: P2PConnection, state: NWConnection.State) {
        SkyBridgeLogger.p2p.debugOnly("🔄 连接状态变化: \(connection.device.name) -> \(state)")
        
        switch state {
        case .ready:
            handleConnectionEstablished(connection)
            
        case .failed(let error):
            handleConnectionFailed(connection, error: error)
            
        case .cancelled:
            handleConnectionCancelled(connection)
            
        default:
            break
        }
    }
    
 /// 处理连接建立成功
    private func handleConnectionEstablished(_ connection: P2PConnection) {
 // 获取连接的协议类型
        let connectionProtocol = connection.connection.endpoint.debugDescription.contains("tcp") ? "TCP" : "UDP"
        SkyBridgeLogger.p2p.debugOnly("✅ 连接建立成功: \(connection.device.name) (\(connectionProtocol))")
        
        let deviceId = connection.device.id
        
 // 更新连接状态
        connection.status = P2PConnectionStatus.connected
        connection.lastActivity = Date()
        
 // 添加到已建立连接
        establishedConnections[deviceId] = connection
        
 // 清理待处理连接
        pendingConnections.removeValue(forKey: deviceId)
        connectionAttempts.removeValue(forKey: deviceId)
        
 // 更新UI状态
        Task { @MainActor in
            self.activeConnections = Array(self.establishedConnections.values)
            if self.connectionState == .connecting {
                self.connectionState = .connected
            }
        }
        
 // 调用回调
        connectionEstablishedCallback?(connection)
    }
    
 /// 处理连接失败
    private func handleConnectionFailed(_ connection: P2PConnection, error: Error) {
 // 获取连接的协议类型
        let connectionProtocol = connection.connection.endpoint.debugDescription.contains("tcp") ? "TCP" : "UDP"
        SkyBridgeLogger.p2p.error("❌ 连接失败: \(connection.device.name, privacy: .private) (\(connectionProtocol)) - \(error.localizedDescription, privacy: .private)")
        
        let deviceId = connection.device.id
        
 // 检查是否还有其他连接尝试
        if let pendingConnection = pendingConnections[deviceId] {
 // 如果是UDP连接失败，尝试TCP fallback
            let connectionProtocol = connection.connection.endpoint.debugDescription.contains("tcp") ? P2PProtocol.tcp : P2PProtocol.udp
            if connectionProtocol == .udp {
                SkyBridgeLogger.p2p.debugOnly("🔄 UDP连接失败，尝试TCP fallback")
                attemptDirectConnection(to: pendingConnection.device)
                return
            }
        }
        
 // 清理连接
        pendingConnections.removeValue(forKey: deviceId)
        
 // 调用失败回调
        connectionFailedCallback?(deviceId, error)
    }
    
 /// 处理连接取消
    private func handleConnectionCancelled(_ connection: P2PConnection) {
        SkyBridgeLogger.p2p.debugOnly("🔌 连接已取消: \(connection.device.name)")
        
        let deviceId = connection.device.id
        establishedConnections.removeValue(forKey: deviceId)
        
        Task { @MainActor in
            self.activeConnections = Array(self.establishedConnections.values)
            if self.establishedConnections.isEmpty {
                self.connectionState = .disconnected
            }
        }
    }
    
 // MARK: - 私有方法 - 数据传输
    
 /// 设置数据接收
    private func setupDataReceiving(for connection: P2PConnection) {
 // 检查连接状态
        Task { @MainActor in
            for connection in self.activeConnections {
                if connection.status == .connected {
                    connection.lastActivity = Date()
                }
            }
        }
        
        connection.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data {
                connection.bytesReceived += UInt64(data.count)
                connection.lastActivity = Date()
                
 // 处理接收到的数据
                self.handleDataReceived(data, from: connection)
            }
            
            if let error = error {
                SkyBridgeLogger.p2p.error("❌ 接收数据错误: \(error.localizedDescription, privacy: .private)")
            }
            
            if !isComplete {
 // 继续接收数据
                Task { @MainActor in
                    self.setupDataReceiving(for: connection)
                }
            }
        }
    }
    
 /// 处理接收到的数据
    nonisolated private func handleDataReceived(_ data: Data, from connection: P2PConnection) {
        SkyBridgeLogger.p2p.debugOnly("📥 接收数据: \(data.count)字节 来自 \(connection.device.name)")
        
 // 在主线程上更新统计信息并调用回调
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.bytesReceived += UInt64(data.count)
            self.packetsReceived += 1
 // 调用数据接收回调
            self.dataReceivedCallback?(data, connection)
        }
    }
    
 /// 执行数据发送
    private func performSendData(_ data: Data, to connection: P2PConnection) {
        connection.connection.send(content: data, completion: .contentProcessed { [weak self] (error: NWError?) in
            if let error = error {
                SkyBridgeLogger.p2p.error("❌ 数据发送失败: \(error.localizedDescription, privacy: .private)")
            } else {
                SkyBridgeLogger.p2p.debugOnly("📤 数据发送成功: \(data.count)字节 到 \(connection.device.name)")
                
 // 在主线程上更新统计信息，避免数据竞争
                Task { @MainActor in
                    self?.bytesSent += UInt64(data.count)
                    self?.packetsSent += 1
                }
            }
        })
    }
    
 // MARK: - 私有方法 - 连接处理
    
 /// 处理新的UDP连接
    private func handleNewUDPConnection(_ nwConnection: NWConnection) {
        SkyBridgeLogger.p2p.debugOnly("📡 新的UDP连接: \(String(describing: nwConnection.endpoint))")
        
 // 创建临时设备对象用于握手
        let tempDevice = P2PDevice(
            id: "unknown",
            name: "Unknown",
            type: .macOS,
            address: "unknown",
            port: 8080, // 使用默认P2P端口
            osVersion: "unknown",
            capabilities: [],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: []
        )
        
 // 创建临时连接对象处理握手
        let tempConnection = P2PConnection(
            device: tempDevice,
            connection: nwConnection,
            securityManager: P2PSecurityManager()
        )
        
 // 设置数据接收以处理握手
        Task { @MainActor in
            setupDataReceiving(for: tempConnection)
        }
        
        nwConnection.start(queue: connectionQueue)
    }
    
 /// 处理新的TCP连接
    private func handleNewTCPConnection(_ nwConnection: NWConnection) {
        SkyBridgeLogger.p2p.debugOnly("📡 新的TCP连接: \(String(describing: nwConnection.endpoint))")
        
 // 创建临时设备对象用于握手
        let tempDevice = P2PDevice(
            id: "unknown",
            name: "Unknown",
            type: .macOS,
            address: "unknown",
            port: 8080, // 使用默认P2P端口
            osVersion: "unknown",
            capabilities: [],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: []
        )
        
 // 创建临时连接对象处理握手
        let tempConnection = P2PConnection(
            device: tempDevice,
            connection: nwConnection,
            securityManager: P2PSecurityManager()
        )
        
 // 设置数据接收以处理握手
        Task { @MainActor in
            setupDataReceiving(for: tempConnection)
        }
        
        nwConnection.start(queue: connectionQueue)
    }
    
 /// 关闭所有连接
    private func closeAllConnections() {
        for connection in establishedConnections.values {
            closeConnection(connection)
        }
        
        establishedConnections.removeAll()
        pendingConnections.removeAll()
        connectionAttempts.removeAll()
        
        Task { @MainActor in
            self.activeConnections.removeAll()
        }
    }
    
 /// 关闭单个连接
    public func closeConnection(_ connection: P2PConnection) {
        SkyBridgeLogger.p2p.debugOnly("🔌 关闭连接: \(connection.device.name)")
        
        connection.connection.cancel()
        connection.status = .disconnected
        
        establishedConnections.removeValue(forKey: connection.device.id)
        
        Task { @MainActor in
            self.activeConnections = Array(self.establishedConnections.values)
        }
    }
    
 // MARK: - 私有方法 - 网络监控
    
 /// 启动网络监控
    private func startNetworkMonitoring() {
        networkMonitor?.start(queue: networkQueue)
    }
    
 /// 处理网络路径更新
    private func handleNetworkPathUpdate(_ path: NWPath) {
        SkyBridgeLogger.p2p.debugOnly("🌐 网络路径更新: \(path.status)")
        
        currentNetworkPath = path
        
        if path.status == .satisfied {
            SkyBridgeLogger.p2p.debugOnly("✅ 网络连接正常")
            
 // 重新发现本地端点
            discoverLocalEndpoints()
            
        } else {
            SkyBridgeLogger.p2p.error("❌ 网络连接异常")
            
 // 处理网络断开
            Task { @MainActor in
                if self.connectionState != .disconnected {
                    self.connectionState = .networkUnavailable
                }
            }
        }
    }
    
 /// 启动统计信息收集
    private func startStatisticsCollection() {
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateNetworkStatistics()
            }
        }
    }
    
 /// 更新网络统计信息
    @MainActor
    private func updateNetworkStatistics() {
        let currentTime = Date()
        let connections = Array(establishedConnections.values)
        
        networkStatistics = P2PNetworkStatistics(
            activeConnections: connections.count,
            totalBytesReceived: bytesReceived,
            totalBytesSent: bytesSent,
            totalPacketsReceived: packetsReceived,
            totalPacketsSent: packetsSent,
            averageLatency: calculateAverageLatency(for: connections),
            connectionUptime: calculateConnectionUptime(for: connections),
            lastUpdated: currentTime
        )
    }
    
 /// 计算平均延迟
 /// 基于实际连接的 RTT 测量计算平均延迟
    private func calculateAverageLatency(for connections: [P2PConnection]) -> TimeInterval {
        guard !connections.isEmpty else { return 0.0 }
        
 // 从每个连接获取延迟数据
        var totalLatency: TimeInterval = 0.0
        var validCount = 0
        
        for connection in connections {
 // 使用连接质量中的延迟数据
            let latency = connection.quality.latency
            if latency > 0 {
                totalLatency += latency
                validCount += 1
            }
        }
        
 // 如果没有有效测量，返回默认估算值
        guard validCount > 0 else {
 // 根据网络类型估算
            switch currentNetworkPath?.status {
            case .satisfied:
 // 正常网络，估算 20ms
                return 0.020
            case .unsatisfied, .requiresConnection:
 // 网络不佳，估算 100ms
                return 0.100
            default:
                return 0.050 // 默认 50ms
            }
        }
        
        return totalLatency / Double(validCount)
    }
    
 /// 计算连接正常运行时间
    private func calculateConnectionUptime(for connections: [P2PConnection]) -> TimeInterval {
        guard !connections.isEmpty else { return 0 }
        
        let currentTime = Date()
        let totalUptime = connections.compactMap { connection in
 // 使用 lastActivity 作为连接时间的替代
            connection.lastActivity.timeIntervalSince(currentTime)
        }.reduce(0, +)
        
        return abs(totalUptime) / Double(connections.count)
    }
}

// MARK: - 支持结构体和枚举

/// 待处理的P2P连接
private struct PendingP2PConnection {
    let device: P2PDevice
    let startTime: Date
    let attempts: Int
}

// MARK: - 错误定义

public enum P2PNetworkError: LocalizedError {
    case listenerCreationFailed
    case connectionNotEstablished
    case maxAttemptsExceeded
    case networkUnavailable
    case stunServerUnavailable
    case natTraversalFailed
    case invalidEndpoint
    case dataTransmissionFailed
    case protocolMismatch
    case authenticationFailed
    
    public var errorDescription: String? {
        switch self {
        case .listenerCreationFailed:
            return "网络监听器创建失败"
        case .connectionNotEstablished:
            return "连接未建立"
        case .maxAttemptsExceeded:
            return "连接尝试次数超限"
        case .networkUnavailable:
            return "网络不可用"
        case .stunServerUnavailable:
            return "STUN服务器不可用"
        case .natTraversalFailed:
            return "NAT穿透失败"
        case .invalidEndpoint:
            return "无效的网络端点"
        case .dataTransmissionFailed:
            return "数据传输失败"
        case .protocolMismatch:
            return "协议不匹配"
        case .authenticationFailed:
            return "身份验证失败"
        }
    }
}
