import Foundation
import Combine
import Network
import os.log

public struct DiscoveryState {
    public var devices: [DiscoveredDevice]
    public var statusDescription: String

    public init(devices: [DiscoveredDevice], statusDescription: String) {
        self.devices = devices
        self.statusDescription = statusDescription
    }
}

/// 设备发现服务，负责在本地网络中扫描和发现可连接的设备
@available(macOS 14.0, *)
public final class DeviceDiscoveryService: ObservableObject {
    private let queue = DispatchQueue(label: "skybridge.discovery")
    private let browsers: [String: NWBrowser]
    private var latestResults: [String: Set<NWBrowser.Result>] = [:]
    private let subject = CurrentValueSubject<DiscoveryState, Never>(.init(devices: [], statusDescription: "初始化扫描"))
    private let log = Logger(subsystem: "com.skybridge.compass", category: "Discovery")
    
    // 添加Apple Silicon优化相关属性
    @available(macOS 14.0, *)
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeviceDiscoveryService")
    
    // 添加设备发现相关属性
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isScanning: Bool = false
    private var activeBrowsers: [NWBrowser] = []

    public var discoveryState: AnyPublisher<DiscoveryState, Never> {
        subject.eraseToAnyPublisher()
    }

    public init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let bonjourTypes = ["_rdp._tcp.", "_rfb._tcp.", "_skybridge._tcp."]
        var created: [String: NWBrowser] = [:]
        for type in bonjourTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
            created[type] = browser
            latestResults[type] = []
        }
        browsers = created
    }

    public func start() async {
        subject.send(.init(devices: [], statusDescription: "正在发现局域网设备"))
        for (type, browser) in browsers {
            browser.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("Bonjour discovery ready for \(type)")
            case .failed(let error):
                self.log.error("Bonjour discovery failed for \(type): \(error.localizedDescription)")
            default:
                break
            }
            }

            browser.browseResultsChangedHandler = { [weak self] results, changes in
                guard let self = self else { return }
                self.latestResults[type] = results
                self.publishResults()
            }

            browser.start(queue: queue)
        }
    }

    private func publishResults() {
        let allResults = latestResults.values.flatMap { $0 }
        let devices = allResults.compactMap { result -> DiscoveredDevice? in
            switch result.endpoint {
            case .service(let name, let type, let domain, let interface):
                return DiscoveredDevice(
                    id: UUID(),
                    name: name,
                    ipv4: nil,
                    ipv6: nil,
                    services: [type],
                    portMap: [:]
                )
            default:
                return nil
            }
        }

        let uniqueDevices = Array(Set(devices))
        let statusDescription = uniqueDevices.isEmpty ? "未发现设备" : "发现 \(uniqueDevices.count) 台设备"

        subject.send(.init(devices: uniqueDevices, statusDescription: statusDescription))
    }

    public func refresh() {
        Task {
            await start()
        }
    }

    public func stop() {
        for browser in browsers.values {
            browser.cancel()
        }
        subject.send(.init(devices: [], statusDescription: "扫描已停止"))
    }
     
    /// 开始设备发现
    public func startDiscovery() {
        guard !isScanning else { return }
        
        isScanning = true
        discoveredDevices.removeAll()
        
        // 使用Apple Silicon优化的并发扫描
        if optimizer?.isAppleSilicon == true {
            startOptimizedDiscovery()
        } else {
            startStandardDiscovery()
        }
        
        logger.info("设备发现已启动 - 优化模式: \(self.optimizer?.isAppleSilicon ?? false)")
    }
    
    /// Apple Silicon优化的设备发现
    private func startOptimizedDiscovery() {
        let scanTasks = [
            ("Bonjour服务", TaskType.networkRequest),
            ("网络扫描", TaskType.networkRequest),
            ("端口检测", TaskType.networkRequest)
        ]
        
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (taskName, taskType) in scanTasks {
                    let capturedTaskName = taskName
                    let capturedTaskType = taskType
                    group.addTask { @Sendable [weak self] in
                        guard let self = self else { return }
                        
                        if #available(macOS 14.0, *), let optimizer = self.optimizer {
                            let qos = optimizer.recommendedQoS(for: capturedTaskType)
                            let queue = DispatchQueue.appleSiliconOptimized(
                                label: "discovery.\(capturedTaskName.lowercased().replacingOccurrences(of: " ", with: ""))",
                                for: capturedTaskType
                            )
                            
                            queue.async {
                                switch capturedTaskName {
                                case "Bonjour服务":
                                    self.performBonjourScan()
                                case "网络扫描":
                                    self.performNetworkScan()
                                case "端口检测":
                                    self.performPortScan()
                                default:
                                    break
                                }
                            }
                        } else {
                            // 为旧版本或非Apple Silicon设备使用标准队列
                            let queue = DispatchQueue(label: "discovery.\(capturedTaskName.lowercased().replacingOccurrences(of: " ", with: ""))")
                            
                            queue.async {
                                switch capturedTaskName {
                                case "Bonjour服务":
                                    self.performBonjourScan()
                                case "网络扫描":
                                    self.performNetworkScan()
                                case "端口检测":
                                    self.performPortScan()
                                default:
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// 标准设备发现
    private func startStandardDiscovery() {
        // 原有的标准发现逻辑
        performBonjourScan()
        performNetworkScan()
        performPortScan()
    }
    
    /// 执行Bonjour服务扫描
    private func performBonjourScan() {
        // 使用优化的并行处理扫描多个服务类型
        let serviceTypes = ["_ssh._tcp", "_vnc._tcp", "_rdp._tcp", "_http._tcp", "_https._tcp"]
        
        if optimizer?.isAppleSilicon == true {
            // 使用向量化操作优化服务类型处理
            Task {
                await optimizer?.performParallelComputation(
                    iterations: serviceTypes.count,
                    qos: .userInitiated
                ) { index in
                    let serviceType = serviceTypes[index]
                    self.scanBonjourService(serviceType)
                    return serviceType
                }
            }
        } else {
            // 标准串行扫描
            for serviceType in serviceTypes {
                scanBonjourService(serviceType)
            }
        }
    }
    
    /// 扫描特定Bonjour服务
    private func scanBonjourService(_ serviceType: String) {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.debug("Bonjour浏览器就绪: \(serviceType)")
            case .failed(let error):
                self?.logger.error("Bonjour浏览器失败: \(serviceType) - \(error.localizedDescription)")
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    let device = DiscoveredDevice(
                        id: UUID(),
                        name: name,
                        ipv4: nil, // 将在连接时解析
                        ipv6: nil,
                        services: [type],
                        portMap: [:]
                    )
                    
                    DispatchQueue.main.async {
                        if !self.discoveredDevices.contains(where: { $0.name == device.name }) {
                            self.discoveredDevices.append(device)
                            self.logger.debug("发现设备: \(device.name) - 服务: \(type)")
                        }
                    }
                }
            }
        }
        
        let queue = optimizer?.isAppleSilicon == true ? 
            DispatchQueue.appleSiliconOptimized(label: "bonjour.\(serviceType)", for: .networkRequest) :
            DispatchQueue.global(qos: .userInitiated)
        
        browser.start(queue: queue)
        
        // 保存浏览器引用以防止被释放
        activeBrowsers.append(browser)
    }
    
    /// 执行网络扫描
    private func performNetworkScan() {
        // 获取本地网络信息
        guard let localIP = getLocalIPAddress() else {
            logger.warning("无法获取本地IP地址")
            return
        }
        
        let networkPrefix = String(localIP.prefix(while: { $0 != "." }))
        
        if optimizer?.isAppleSilicon == true {
            // 使用Apple Silicon优化的并行网络扫描
            Task {
                await optimizer?.performParallelComputation(
                    iterations: 254,
                    qos: .utility
                ) { index in
                    let ip = "\(networkPrefix).\(index + 1)"
                    self.pingHost(ip)
                    return ip
                }
            }
        } else {
            // 标准扫描
            for i in 1...254 {
                let ip = "\(networkPrefix).\(i)"
                pingHost(ip)
            }
        }
    }
    
    /// 执行端口扫描
    private func performPortScan() {
        let commonPorts = [22, 80, 443, 3389, 5900, 8080]
        
        for device in discoveredDevices {
            guard let ip = device.ipv4 ?? device.ipv6 else { continue }
            
            if optimizer?.isAppleSilicon == true {
                // 使用优化的并行端口扫描
                Task {
                    await optimizer?.performParallelComputation(
                        iterations: commonPorts.count,
                        qos: .utility
                    ) { index in
                        let port = commonPorts[index]
                        self.scanPort(ip: ip, port: port)
                        return port
                    }
                }
            } else {
                // 标准端口扫描
                for port in commonPorts {
                    scanPort(ip: ip, port: port)
                }
            }
        }
    }
    
    /// 停止设备发现
    public func stopDiscovery() {
        isScanning = false
        
        // 停止所有活动的浏览器
        for browser in activeBrowsers {
            browser.cancel()
        }
        activeBrowsers.removeAll()
        
        logger.info("设备发现已停止")
    }
}

// 扩展以支持Apple Silicon优化
@available(macOS 14.0, *)
extension DeviceDiscoveryService {
    /// 获取本地IP地址
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                
                if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        return address
    }
    
    /// Ping主机检测
    private func pingHost(_ ip: String) {
        // 简化的ping实现，实际应用中可以使用更复杂的网络检测
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 80, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // 主机可达，添加到发现列表
                let device = DiscoveredDevice(
                    id: UUID(),
                    name: ip,
                    ipv4: ip,
                    ipv6: nil,
                    services: [],
                    portMap: [:]
                )
                
                DispatchQueue.main.async {
                    if !(self?.discoveredDevices.contains(where: { $0.ipv4 == ip }) ?? true) {
                        self?.discoveredDevices.append(device)
                    }
                }
                connection.cancel()
            case .failed(_):
                connection.cancel()
            default:
                break
            }
        }
        
        let queue = optimizer?.isAppleSilicon == true ? 
            DispatchQueue.appleSiliconOptimized(label: "ping.\(ip)", for: .networkRequest) :
            DispatchQueue.global(qos: .utility)
        
        connection.start(queue: queue)
        
        // 设置超时
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            connection.cancel()
        }
    }
    
    /// 扫描特定端口
    private func scanPort(ip: String, port: Int) {
        let connection = NWConnection(
            host: NWEndpoint.Host(ip), 
            port: NWEndpoint.Port(integerLiteral: UInt16(port)), 
            using: .tcp
        )
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // 端口开放，更新设备服务信息
                DispatchQueue.main.async {
                    if let deviceIndex = self?.discoveredDevices.firstIndex(where: { $0.ipv4 == ip }) {
                        let serviceType = self?.getServiceType(for: port) ?? "unknown"
                        if !(self?.discoveredDevices[deviceIndex].services.contains(serviceType) ?? true) {
                            self?.discoveredDevices[deviceIndex].services.append(serviceType)
                        }
                    }
                }
                connection.cancel()
            case .failed(_):
                connection.cancel()
            default:
                break
            }
        }
        
        let queue = optimizer?.isAppleSilicon == true ? 
            DispatchQueue.appleSiliconOptimized(label: "port.\(ip).\(port)", for: .networkRequest) :
            DispatchQueue.global(qos: .utility)
        
        connection.start(queue: queue)
        
        // 设置超时
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            connection.cancel()
        }
    }
    
    /// 根据端口号获取服务类型
    private func getServiceType(for port: Int) -> String {
        switch port {
        case 22: return "_ssh._tcp"
        case 80: return "_http._tcp"
        case 443: return "_https._tcp"
        case 3389: return "_rdp._tcp"
        case 5900: return "_vnc._tcp"
        case 8080: return "_http-alt._tcp"
        default: return "port_\(port)"
        }
    }
}

@available(macOS 14.0, *)
extension DeviceDiscoveryService: @unchecked Sendable {}
