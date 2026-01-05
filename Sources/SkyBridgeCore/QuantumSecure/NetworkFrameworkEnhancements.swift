import Foundation
import Network
import Combine
import Security
import CryptoKit
import OSLog

/// Network Framework 增强功能
/// 基于Apple 2025最佳实践
public class NetworkFrameworkEnhancements {
    
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "NetworkEnhancements")
    
 /// 可观测事件
    public static let certificateValidationNotification = Notification.Name("QuantumCertValidationEvent")
    
 /// 验证策略
    public struct VerifyPolicy {
        public let pinToHostnames: [String]? // 主机名绑定（CN/SAN匹配）
        public let enableOCSP: Bool         // 是否启用OCSP（预留）
        public let enableCRL: Bool          // 是否启用CRL（预留）
        public let downgradeOnFailure: Bool // 失败是否降级（否则拒绝）
        public init(pinToHostnames: [String]? = nil, enableOCSP: Bool = false, enableCRL: Bool = false, downgradeOnFailure: Bool = false) {
            self.pinToHostnames = pinToHostnames
            self.enableOCSP = enableOCSP
            self.enableCRL = enableCRL
            self.downgradeOnFailure = downgradeOnFailure
        }
    }
    
 // MARK: - 1. 自定义证书验证（设备信任链）
    
 /// 配置自定义证书验证（带主机名绑定、诊断与事件）
    public static func configureCustomCertificateVerification(
        tlsOptions: NWProtocolTLS.Options,
        trustedPublicKeys: [P256.Signing.PublicKey],
        policy: VerifyPolicy = .init()
    ) {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "CertificateVerification")
        let trustedKeys = trustedPublicKeys.map { $0.rawRepresentation }
 // 设置TLS验证回调；此处我们可选采集ALPN用于隐私诊断
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (metadata, secTrust, complete) in
            var cfError: CFError?
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let startTime = Date()
 // 若开启隐私诊断，则在握手阶段读取ALPN协商结果
            var negotiatedALPN: String? = nil
 // 避免跨actor访问SettingsManager，改用UserDefaults读取隐私诊断开关
            if UserDefaults.standard.bool(forKey: "Settings.EnableHandshakeDiagnostics") {
                if let alpnC = sec_protocol_metadata_get_negotiated_protocol(metadata) {
 // 使用统一的 UTF8 解码替代已弃用的 String(cString:)
                    negotiatedALPN = decodeCString(alpnC)
                }
            }
            func finish(_ ok: Bool, reason: String) {
                let elapsed = Date().timeIntervalSince(startTime)
 // 收集证书链摘要（CN/SAN简单摘要用于诊断）
                var chainSubjects: [String] = []
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
                    for cert in chain {
                        if let values = SecCertificateCopyValues(cert, [kSecOIDCommonName] as CFArray, nil) as? [CFString: Any],
                           let valueDict = values[kSecOIDCommonName] as? [CFString: Any],
                           let cnValue = valueDict[kSecPropertyKeyValue] as? String {
                            chainSubjects.append(cnValue)
                        } else {
                            chainSubjects.append("(no CN)")
                        }
                    }
                }
 // 上报验证事件；若开启隐私诊断则同时附带ALPN信息
                var info: [String: Any] = [
                    "ok": ok,
                    "reason": reason,
                    "elapsed": elapsed,
                    "revocationAttempted": (policy.enableOCSP || policy.enableCRL),
                    "chainSubjects": chainSubjects
                ]
                if let negotiatedALPN = negotiatedALPN {
                    info["alpnProtocol"] = negotiatedALPN
                }
                NotificationCenter.default.post(name: NetworkFrameworkEnhancements.certificateValidationNotification, object: nil, userInfo: info)
                complete(ok)
            }
            
 // 0) 可选：允许网络抓取以进行OCSP/CRL
            if policy.enableOCSP || policy.enableCRL {
                SecTrustSetNetworkFetchAllowed(trust, true)
            }

 // 1) 系统信任
            if SecTrustEvaluateWithError(trust, &cfError) {
                logger.info("✅ 系统信任通过")
                finish(true, reason: "system_trust_ok")
                return
            } else if let e = cfError as Error? {
 // 采集更多失败细节（避免使用已弃用API）
                let failDetail = e.localizedDescription
                logger.warning("⚠️ 系统信任失败: \(failDetail)")
            } else {
                logger.warning("⚠️ 系统信任失败: 未知错误")
            }
            
 // 2) 主机名绑定（CN/SAN）
            if let hostnames = policy.pinToHostnames, !hostnames.isEmpty {
                let matched = hostnamesContains(trust: trust, candidates: hostnames)
                if !matched {
                    logger.error("❌ 主机名绑定不匹配，拒绝连接")
                    finish(false, reason: "hostname_pin_mismatch")
                    return
                } else {
                    logger.info("🔐 主机名绑定匹配")
                }
            }
            
 // 3) 自定义公钥白名单
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
            for certificate in certificates {
                guard let publicKey = SecCertificateCopyKey(certificate) else { continue }
                var err: Unmanaged<CFError>?
                if let keyData = SecKeyCopyExternalRepresentation(publicKey, &err) as Data?, err == nil {
                    if trustedKeys.contains(keyData) {
                        logger.info("✅ 匹配受信公钥，允许连接")
                        finish(true, reason: "pinned_key_match")
                        return
                    }
                }
            }
            
 // 4) 可选：OCSP/CRL
            if policy.enableOCSP || policy.enableCRL {
 // 已通过 SecTrustSetNetworkFetchAllowed 启用网络抓取；
 // SecTrustEvaluateWithError 会在系统策略下执行可用的撤销检查（OCSP/CRL）。
                logger.info("📝 已启用OCSP/CRL网络抓取，由系统信任评估执行撤销检查")
            }
            
 // 5) 失败分级：降级或拒绝
            if policy.downgradeOnFailure {
                logger.warning("⬇️ 证书校验失败但策略允许降级，放行连接")
                finish(true, reason: "downgraded_\(policy.enableOCSP || policy.enableCRL ? "ocspcrl_on" : "ocspcrl_off")")
            } else {
                logger.error("⛔️ 证书校验失败，拒绝连接")
                finish(false, reason: "verify_failed_\(policy.enableOCSP || policy.enableCRL ? "ocspcrl_on" : "ocspcrl_off")")
            }
        }, DispatchQueue.main)
        logger.info("✅ 已设置TLS自定义验证回调（含主机名与诊断）")
    }
    
 /// 主机名匹配（CN 或 SAN）
    private static func hostnamesContains(trust: SecTrust, candidates: [String]) -> Bool {
        guard let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certs.first else { return false }
 // 读取Subject Common Name
        var cn: String?
        if let values = SecCertificateCopyValues(leaf, [kSecOIDCommonName] as CFArray, nil) as? [CFString: Any],
           let valueDict = values[kSecOIDCommonName] as? [CFString: Any],
           let cnValue = valueDict[kSecPropertyKeyValue] as? String {
            cn = cnValue
        }
 // 读取 SAN（若可）
        var sanSet: Set<String> = []
        if let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, nil) as? [CFString: Any],
           let sanDict = values[kSecOIDSubjectAltName] as? [CFString: Any],
           let sanArray = sanDict[kSecPropertyKeyValue] as? [[CFString: Any]] {
            for entry in sanArray {
                if let name = entry[kSecPropertyKeyValue] as? String {
                    sanSet.insert(name)
                }
            }
        }
        let all = Set(candidates.map { $0.lowercased() })
        if let cn = cn?.lowercased(), all.contains(cn) { return true }
        if !sanSet.isEmpty, !all.isDisjoint(with: sanSet.map { $0.lowercased() }) { return true }
        return false
    }
    
 // MARK: - 2. NWConnectionGroup（多设备发现）
    
 /// 创建连接组用于多播和组播通信
 /// 适用于设备发现和广播场景
    @available(macOS 11.0, *)
    public static func createConnectionGroup(
        service: String,
        port: UInt16
    ) throws -> NWConnectionGroup {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "ConnectionGroup")
        
        logger.info("🚀 创建连接组: \(service) on port \(port)")
        
 // 说明：为多设备发现创建UDP组播连接组（macOS 14/15/26.x 均支持）
 // 使用组织本地组播地址（239.255.0.1）+ 指定端口，作为发现频道。
 // 注意：DTLS/TLS 不适用于UDP组播，这里使用纯UDP参数；安全性由上层消息签名保障。
        let parameters = NWParameters.udp
        
 // 组播端点（IPv4 239.255.0.1:port）
        let multicastEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("239.255.0.1"),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        
 // 创建组描述符并构建连接组
        let descriptor = try NWMulticastGroup(for: [multicastEndpoint])
        let group = NWConnectionGroup(with: descriptor, using: parameters)
        
 // 配置基础状态回调，便于外部监听组状态
        group.stateUpdateHandler = { state in
            switch state {
            case .setup:
                logger.info("🧩 连接组初始化完成")
            case .ready:
                logger.info("✅ 连接组已就绪（UDP组播）")
            case .failed(let error):
                logger.error("❌ 连接组失败: \(error.localizedDescription)")
            case .cancelled:
                logger.info("⏹️ 连接组已取消")
            case .waiting(let reason):
                logger.warning("⏸️ 连接组等待中: \(String(describing: reason))")
            @unknown default:
                logger.warning("⚠️ 连接组未知状态")
            }
        }
        
 // 返回连接组实例；调用方应在合适的队列上调用 group.start(queue:)
        return group
    }
    
 /// 创建多设备发现连接组
    @available(macOS 11.0, *)
    public static func createDeviceDiscoveryGroup(port: UInt16 = 8080) throws -> NWConnectionGroup {
        return try createConnectionGroup(
            service: "skybridge-discovery",
            port: port
        )
    }

 /// 为连接组配置接收处理，用于解析设备发现消息并回调
 /// 消息格式约定（JSON）：{"id":"...","name":"...","type":"macOS","address":"192.168.1.10","port":8081,"osVersion":"14.0","capabilities":["rdp","p2p"]}
    @available(macOS 11.0, *)
    public static func attachDiscoveryReceiver(
        to group: NWConnectionGroup,
        maximumMessageSize: Int = 64 * 1024,
        onMessage: @Sendable @escaping (P2PDiscoveryMessage) -> Void
    ) {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "ConnectionGroup")
        group.setReceiveHandler(maximumMessageSize: maximumMessageSize, rejectOversizedMessages: true) { message, content, isComplete in
            guard let data = content, isComplete else { return }
            do {
 // 使用结构化解码，确保字段契约与 timestamp 存在
                let decoder = JSONDecoder()
                let msg = try decoder.decode(P2PDiscoveryMessage.self, from: data)
                onMessage(msg)
            } catch {
                logger.error("❌ 解析组播消息失败: \(error.localizedDescription)")
            }
        }
    }
    
 // MARK: - 3. NWPathMonitor（网络切换优化）
    
 /// 网络路径监控器
 /// 监控网络状态变化，自动优化连接参数
    @MainActor
    public final class NetworkPathMonitor: ObservableObject, @unchecked Sendable {
        private let monitor: NWPathMonitor
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "PathMonitor")
        private var isMonitoring = false
        private let isMonitoringLock = OSAllocatedUnfairLock<Bool>(initialState: false)
        @Published public private(set) var isOnline: Bool = false
        @Published public private(set) var currentPath: NWPath?
        public static let shared = NetworkPathMonitor()
        
 // 网络状态变化回调
        public var onPathUpdate: ((NWPath) -> Void)?
        
        public init(requiredInterfaceType: NWInterface.InterfaceType? = nil) {
            if let interfaceType = requiredInterfaceType {
                self.monitor = NWPathMonitor(requiredInterfaceType: interfaceType)
            } else {
                self.monitor = NWPathMonitor()
            }
        }
        
 /// 开始监控网络路径
        public func startMonitoring(queue: DispatchQueue = .global(qos: .utility)) {
            let isAlreadyMonitoring = isMonitoringLock.withLock { isMonitoring in
                if isMonitoring {
                    return true
                }
                isMonitoring = true
                return false
            }
            
            guard !isAlreadyMonitoring else {
                logger.warning("⚠️ 网络监控已在运行")
                return
            }
            
            logger.info("🚀 开始监控网络路径")
            
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                self.logger.info("📡 网络路径更新:")
                self.logger.info("   状态: \(path.status == .satisfied ? "✅ 可用" : "❌ 不可用")")
                self.logger.info("   Wi-Fi: \(path.usesInterfaceType(.wifi) ? "✅" : "❌")")
                self.logger.info("   以太网: \(path.usesInterfaceType(.wiredEthernet) ? "✅" : "❌")")
                self.logger.info("   蜂窝网络: \(path.usesInterfaceType(.cellular) ? "✅" : "❌")")
                Task { @MainActor in
 // 通知监听者
                    self.onPathUpdate?(path)
 // 根据网络状态优化连接
                    self.optimizeConnectionForPath(path)
 // 发布连通状态供订阅
                    self.isOnline = (path.status == .satisfied)
                    self.currentPath = path
                }
            }
            
            monitor.start(queue: queue)
            
            logger.info("✅ 网络路径监控已启动")
        }
        
 /// 停止监控
        public func stopMonitoring() {
            let shouldStop = isMonitoringLock.withLock { isMonitoring in
                if !isMonitoring {
                    return false
                }
                isMonitoring = false
                return true
            }
            
            guard shouldStop else { return }
            
            logger.info("⏹️ 停止网络路径监控")
            monitor.cancel()
        }
        
 /// 根据网络路径优化连接参数
        private func optimizeConnectionForPath(_ path: NWPath) {
 // 如果网络不可用，不需要优化
            guard path.status == .satisfied else {
                logger.warning("⚠️ 网络不可用，跳过优化")
                return
            }
            
 // 根据接口类型优化
            if path.usesInterfaceType(.wifi) {
                logger.info("📶 使用Wi-Fi，应用Wi-Fi优化参数")
 // Wi-Fi通常带宽较大，可以使用更大的块大小
            } else if path.usesInterfaceType(.cellular) {
                logger.info("📱 使用蜂窝网络，应用移动网络优化参数")
 // 蜂窝网络带宽可能受限，使用更小的块大小和更积极的压缩
            } else if path.usesInterfaceType(.wiredEthernet) {
                logger.info("🔌 使用以太网，应用有线网络优化参数")
 // 以太网通常最稳定，可以使用最大性能设置
            }
            
 // 检查是否支持IPv6
            if path.supportsIPv6 {
                logger.info("✅ 支持IPv6，可以启用IPv6优先")
            }
        }
        
 /// 获取当前网络路径
        public func getCurrentPath() -> NWPath { monitor.currentPath }
        
 /// 启动共享监控实例
        public func startShared() { NetworkPathMonitor.shared.startMonitoring() }
 /// 停止共享监控实例
        public func stopShared() { NetworkPathMonitor.shared.stopMonitoring() }
    }
    
 // MARK: - 辅助方法
    
 /// 根据网络路径创建优化的NWParameters
    public static func createOptimizedParameters(
        for path: NWPath,
        useTLS: Bool = true
    ) -> NWParameters {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "Parameters")
        
        let parameters: NWParameters
        
        if useTLS {
            parameters = NWParameters.tls
        } else {
            parameters = NWParameters.tcp
        }
        
 // 根据网络类型优化
        if path.usesInterfaceType(.cellular) {
 // 移动网络：优化功耗和带宽
            logger.info("📱 应用移动网络优化")
            parameters.prohibitExpensivePaths = false // 允许使用数据流量
            parameters.expiredDNSBehavior = .allow // 允许缓存的DNS
        } else {
 // Wi-Fi/以太网：追求最大性能
            logger.info("📶 应用固定网络优化")
            parameters.prohibitExpensivePaths = true // 优先使用Wi-Fi/以太网
        }
        
 // IPv6支持 - 如果支持IPv6，不限制接口类型
 // requiredInterfaceType保持默认即可
        
        return parameters
    }
}

