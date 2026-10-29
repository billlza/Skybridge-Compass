// DEDUPLICATION TARGET — not inherently macOS-only.
//
// 属于 macOS 侧连接编排簇（其类型定义在 ConnectionManager.swift）。阶段 0 只让
// SkyBridgeCore 能为 iOS 编译；采用/合并 iOS 版本是阶段 3 的迁移工作。
// 记录在 Docs/background-wake-capability-ledger.md。
#if os(macOS)
import Foundation
import Network
import OSLog
import SystemConfiguration

/// Wi-Fi连接管理器
public final class WiFiConnectionManager: @unchecked Sendable {

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.connection", category: "WiFiConnectionManager")
    private let connectionQueue = DispatchQueue(label: "wifi.connection.queue", qos: .userInitiated)
    private let stateLock = OSAllocatedUnfairLock()
    private var connections: [UUID: NWConnection] = [:]
    private var stats: [UUID: ConnectionStats] = [:]

 // MARK: - 初始化

    public init() {
        logger.info("Wi-Fi连接管理器已初始化")
    }

 // MARK: - 公共方法

 /// 检查Wi-Fi是否可用
    public func isAvailable() async -> Bool {
        return await withCheckedContinuation { continuation in
            connectionQueue.async {
 // 检查Wi-Fi接口状态
                var ifaddr: UnsafeMutablePointer<ifaddrs>?
                guard getifaddrs(&ifaddr) == 0 else {
                    continuation.resume(returning: false)
                    return
                }

                guard let first = ifaddr else {
                    continuation.resume(returning: false)
                    return
                }

                defer { freeifaddrs(first) }

                var current: UnsafeMutablePointer<ifaddrs>? = first
                while let interfacePointer = current {
                    let interface = interfacePointer.pointee
                    current = interface.ifa_next

                    guard let namePtr = interface.ifa_name else { continue }
 // 统一使用安全的 UTF8 C 字符串解码，替代已弃用的 String(cString:)
                    let name = decodeCString(namePtr)

 // 检查是否为Wi-Fi接口
                    if name.hasPrefix("en") && (interface.ifa_flags & UInt32(IFF_UP)) != 0 {
                        continuation.resume(returning: true)
                        return
                    }
                }

                continuation.resume(returning: false)
            }
        }
    }

 /// 建立Wi-Fi连接
    public func connect(to device: DiscoveredDevice, interface: String) async throws -> ActiveConnection {
        logger.info("建立Wi-Fi连接到设备: \(device.name)")

 // 从设备信息中获取连接地址和端口
        guard let address = device.ipv4 ?? device.ipv6 else {
            throw ConnectionError.networkUnreachable
        }

        let host = NWEndpoint.Host(address)

 // 从端口映射中获取连接端口，默认使用22端口
        let portNumber = device.portMap["ssh"] ?? device.portMap["rdp"] ?? 22
        let port = NWEndpoint.Port(integerLiteral: UInt16(portNumber))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

 // 创建TCP连接参数，指定Wi-Fi接口
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
 // 注意：由于NWInterface构造函数限制，我们让系统自动选择最佳接口
 // parameters.requiredInterface = NWInterface(name: interface)

        let connection = NWConnection(to: endpoint, using: parameters)
        let connectionId = UUID()

        return try await withCheckedThrowingContinuation { continuation in
            let resumedFlag = OSAllocatedUnfairLock(initialState: false)

            connection.stateUpdateHandler = { @Sendable state in
                resumedFlag.withLock { resumed in
                    switch state {
                    case .ready:
                        if !resumed {
                            resumed = true
                            self.stateLock.withLock { self.connections[connectionId] = connection }
                            self.updateStats(for: connectionId)

                            let activeConnection = ActiveConnection(method: .wifi(interface: interface), device: device)
                            self.logger.info("Wi-Fi连接建立成功: \(connectionId)")
                            continuation.resume(returning: activeConnection)
                        }
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            self.logger.error("Wi-Fi连接失败: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: ConnectionError.networkUnreachable)
                        }
                    default:
                        break
                    }
                }
            }

            connection.start(queue: self.connectionQueue)
        }
    }

 /// 断开连接
    public func disconnect(_ connectionId: UUID) async {
        logger.info("断开Wi-Fi连接: \(connectionId)")

        let connection = stateLock.withLock { () -> NWConnection? in
            let conn = connections[connectionId]
            connections.removeValue(forKey: connectionId)
            stats.removeValue(forKey: connectionId)
            return conn
        }
        connection?.cancel()
    }

 /// 发送数据
    public func sendData(_ data: Data, connectionId: UUID) async throws {
        guard let connection = stateLock.withLock({ connections[connectionId] }) else {
            throw ConnectionError.connectionNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

 /// 获取连接统计信息
    public func getStats(_ connectionId: UUID) -> ConnectionStats? {
        return stateLock.withLock { stats[connectionId] }
    }

 // MARK: - 私有方法

 /// 更新连接统计信息（基于路径属性的启发式估算，非端到端真实测量）
    private func updateStats(for connectionId: UUID) {
        guard let connection = stateLock.withLock({ connections[connectionId] }) else { return }

 // 启发式估算：基于 NWConnection 的路径属性推断带宽（非 iperf/RTT 真实测量）
 // 默认值：普通 Wi-Fi 5 (802.11ac) 水平
        var bandwidth: Double = 100.0 // Mbps
        var latency: Double = 10.0 // ms
        var packetLoss: Double = 0.02 // 2%

// 从 NWConnection 的 currentPath 获取接口类型和质量
// 仅在连接 ready 后再访问，避免 Network.framework 打印 "unconnected nw_connection" 警告刷屏
        if case .ready = connection.state, let path = connection.currentPath {
            if path.status == .satisfied {
 // 根据接口类型估算带宽
                if path.usesInterfaceType(.wifi) {
 // 🔍 Wi-Fi 代际推断与性能估算
 // 虽然 Network 框架无法直接区分 Wi-Fi 6/6E/7，但我们可以通过路径属性推断链路质量

                    if path.isConstrained {
 // 受限网络 (可能是公共热点或信号差)：Wi-Fi 4/5 边缘水平
                        bandwidth = 20.0
                        latency = 50.0
                        packetLoss = 0.05
                    } else if path.isExpensive {
 // 计费网络 (可能是移动热点)：Wi-Fi 5 水平
                        bandwidth = 50.0
                        latency = 20.0
                        packetLoss = 0.02
                    } else {
 // 高质量非受限网络：假设为 Wi-Fi 6/6E/7
 // Wi-Fi 6 (802.11ax): 实际 200-800 Mbps
 // Wi-Fi 6E (6GHz): 实际 500-1200 Mbps, 低延迟
 // Wi-Fi 7 (802.11be): 实际 1000-3000 Mbps, 极低延迟 (MLO)

 // 这里的估算策略：
 // 这是基于路径属性的启发式估计（非真实测量），给出一个基于现代网络环境的乐观估计值
 // 实际项目中应结合 iperf 或应用层心跳 RTT 来校准

                        bandwidth = 800.0 // 乐观估计：Wi-Fi 6/6E 高吞吐
                        latency = 3.0     // Wi-Fi 6E/7 的低延迟特性 (<5ms)
                        packetLoss = 0.005 // 0.5% 极低丢包

 // 如果是 Wi-Fi 7 (理论上更稳)，我们可以通过更激进的平滑策略在 QualityGovernor 中体现
                    }
                } else if path.usesInterfaceType(.wiredEthernet) {
 // 有线以太网 (1Gbps / 10Gbps)
                    bandwidth = 1000.0
                    latency = 0.5
                    packetLoss = 0.0001
                }
            } else {
 // 连接不满意
                bandwidth = 5.0
                latency = 100.0
                packetLoss = 0.15
            }
        }

        let stats = ConnectionStats(
            connectionId: connectionId,
            bandwidth: bandwidth,
            latency: latency,
            packetLoss: packetLoss,
            uptime: Date().timeIntervalSince1970
        )

        stateLock.withLock { self.stats[connectionId] = stats }
    }
}
#endif
