import Foundation
import Network
import OSLog
import Combine

// MARK: - 发现诊断服务
/// 收集和展示设备发现相关的诊断信息
/// 帮助用户理解为什么设备发现可能失败
@MainActor
public final class DiscoveryDiagnosticsService: ObservableObject {
    
    // MARK: - 单例
    
    public static let shared = DiscoveryDiagnosticsService()
    
    // MARK: - 发布属性
    
    /// 当前诊断状态
    @Published public private(set) var diagnostics: DiscoveryDiagnostics = DiscoveryDiagnostics()
    
    /// 最近的发现失败记录
    @Published public private(set) var recentFailures: [DiscoveryFailure] = []
    
    /// 是否正在运行诊断
    @Published public private(set) var isRunningDiagnostics = false
    
    // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.diagnostics", category: "Discovery")
    private let maxFailureHistory = 50
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue = DispatchQueue(label: "com.skybridge.pathmonitor")
    
    // MARK: - 数据类型
    
    /// 发现诊断信息
    public struct DiscoveryDiagnostics: Sendable {
        /// 本地网络权限状态
        public var localNetworkPermission: PermissionStatus = .unknown
        
        /// Bonjour 服务白名单状态
        public var bonjourWhitelist: BonjourWhitelistStatus = BonjourWhitelistStatus()
        
        /// 当前网络状态
        public var networkStatus: NetworkStatus = NetworkStatus()
        
        /// 当前扫描的服务类型
        public var activeServiceTypes: [String] = []
        
        /// 上次扫描时间
        public var lastScanTime: Date?
        
        /// 发现的设备数量
        public var discoveredDeviceCount: Int = 0
        
        /// 诊断时间戳
        public var timestamp: Date = Date()
    }
    
    /// 权限状态
    public enum PermissionStatus: String, Sendable {
        case unknown = "未知"
        case granted = "已授权"
        case denied = "已拒绝"
        case notDetermined = "未请求"
        case restricted = "受限"
        
        public var emoji: String {
            switch self {
            case .granted: return "✅"
            case .denied: return "❌"
            case .notDetermined: return "❓"
            case .restricted: return "🚫"
            case .unknown: return "❔"
            }
        }
        
        public var color: String {
            switch self {
            case .granted: return "green"
            case .denied, .restricted: return "red"
            case .notDetermined, .unknown: return "orange"
            }
        }
    }
    
    /// Bonjour 白名单状态
    public struct BonjourWhitelistStatus: Sendable {
        /// Info.plist 中声明的服务类型
        public var declaredServices: [String] = []
        
        /// 实际正在扫描的服务类型
        public var requestedServices: [String] = []
        
        /// 未在白名单中的服务类型（可能导致扫描失败）
        public var missingServices: [String] = []
        
        /// 是否配置正确
        public var isConfigured: Bool {
            missingServices.isEmpty && !declaredServices.isEmpty
        }
    }
    
    /// 网络状态
    public struct NetworkStatus: Sendable {
        /// 是否有网络连接
        public var hasConnectivity: Bool = false
        
        /// 连接类型
        public var connectionType: ConnectionType = .unknown
        
        /// 是否在同一局域网（用于本地发现）
        public var isOnLocalNetwork: Bool = false
        
        /// Wi-Fi SSID（如果可用）
        public var wifiSSID: String?
        
        /// 本地 IP 地址
        public var localIPAddress: String?
        
        public enum ConnectionType: String, Sendable {
            case wifi = "Wi-Fi"
            case ethernet = "以太网"
            case cellular = "蜂窝网络"
            case vpn = "VPN"
            case unknown = "未知"
        }
    }
    
    /// 发现失败记录
    public struct DiscoveryFailure: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let serviceType: String
        public let errorCode: Int?
        public let errorMessage: String
        public let suggestedFix: String?
        public let category: FailureCategory
        
        public enum FailureCategory: String, Sendable {
            case permission = "权限问题"
            case network = "网络问题"
            case bonjour = "Bonjour 配置"
            case timeout = "超时"
            case peerRejection = "对端拒绝"
            case cryptographic = "加密问题"
            case unknown = "未知"
        }
    }
    
    // MARK: - 公开 API
    
    /// 运行完整诊断
    public func runDiagnostics() async {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        
        logger.info("🔍 开始运行发现诊断...")
        
        var newDiagnostics = DiscoveryDiagnostics()
        
        // 1. 检查本地网络权限
        newDiagnostics.localNetworkPermission = await checkLocalNetworkPermission()
        
        // 2. 检查 Bonjour 白名单配置
        newDiagnostics.bonjourWhitelist = checkBonjourWhitelist()
        
        // 3. 检查网络状态
        newDiagnostics.networkStatus = await checkNetworkStatus()
        
        // 4. 获取当前扫描状态
        newDiagnostics.activeServiceTypes = getCurrentActiveServices()
        
        newDiagnostics.timestamp = Date()
        
        diagnostics = newDiagnostics
        isRunningDiagnostics = false
        
        logger.info("✅ 发现诊断完成")
    }
    
    /// 记录发现失败
    public func recordFailure(
        serviceType: String,
        error: Error,
        category: DiscoveryFailure.FailureCategory? = nil
    ) {
        let failure = DiscoveryFailure(
            timestamp: Date(),
            serviceType: serviceType,
            errorCode: (error as NSError).code,
            errorMessage: error.localizedDescription,
            suggestedFix: suggestFix(for: error, serviceType: serviceType),
            category: category ?? categorizeError(error)
        )
        
        recentFailures.insert(failure, at: 0)
        if recentFailures.count > maxFailureHistory {
            recentFailures.removeLast()
        }
        
        logger.warning("📝 记录发现失败: \(serviceType) - \(error.localizedDescription)")
    }
    
    /// 记录握手失败（映射到用户可读消息）
    public func recordHandshakeFailure(
        deviceId: String,
        reason: HandshakeFailureReason
    ) {
        let userMessage = HandshakeErrorLocalizer.localizedMessage(for: reason)
        let suggestedFix = HandshakeErrorLocalizer.suggestedFix(for: reason)
        
        let failure = DiscoveryFailure(
            timestamp: Date(),
            serviceType: "握手: \(deviceId)",
            errorCode: nil,
            errorMessage: userMessage,
            suggestedFix: suggestedFix,
            category: categorizeHandshakeFailure(reason)
        )
        
        recentFailures.insert(failure, at: 0)
        if recentFailures.count > maxFailureHistory {
            recentFailures.removeLast()
        }
        
        logger.warning("🤝 握手失败: \(deviceId) - \(userMessage)")
    }
    
    /// 清除失败历史
    public func clearFailureHistory() {
        recentFailures.removeAll()
        logger.info("🗑️ 失败历史已清除")
    }
    
    /// 更新扫描状态
    public func updateScanStatus(isScanning: Bool, deviceCount: Int, serviceTypes: [String]) {
        diagnostics.activeServiceTypes = serviceTypes
        diagnostics.discoveredDeviceCount = deviceCount
        if isScanning {
            diagnostics.lastScanTime = Date()
        }
    }
    
    // MARK: - 私有方法
    
    /// 检查本地网络权限
    private func checkLocalNetworkPermission() async -> PermissionStatus {
        // iOS 的“本地网络权限”没有可靠的静态查询 API：
        // 只有在发起 Bonjour 浏览/监听时系统才会弹窗或返回失败。
        // 因此这里不做“猜测”，避免把“有网”误判为“已授权”。
#if os(macOS)
        // macOS 没有 iOS 那套 Local Network 权限弹窗机制（以 sandbox/防火墙为主）。
        return .granted
#else
        return .unknown
#endif
    }
    
    /// 检查 Bonjour 白名单配置
    private func checkBonjourWhitelist() -> BonjourWhitelistStatus {
        var status = BonjourWhitelistStatus()
        
        // 从 Info.plist 读取 NSBonjourServices
        if let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] {
            status.declaredServices = services
        }
        
        // Normalize service type strings: plist typically stores without trailing dot,
        // while some APIs/logs display with a trailing dot.
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        // Compute what we *actually* may browse/advertise, based on Settings toggles.
        // Keep this aligned with DeviceDiscoveryService.performBonjourScan().
        var requested: [String] = ["_skybridge._tcp"]
        if SettingsManager.shared.enableCompanionLink {
            requested.append("_companion-link._tcp")
        }
        if SettingsManager.shared.enableCompatibilityMode {
            requested.append(contentsOf: [
                "_services._dns-sd._udp",
                "_airplay._tcp",
                "_rdlink._tcp",
                "_sftp-ssh._tcp",
                "_http._tcp",
                "_https._tcp",
                "_ssh._tcp",
                "_smb._tcp",
                "_afpovertcp._tcp",
                "_printer._tcp",
                "_ipp._tcp",
                "_scanner._tcp",
                "_workstation._tcp"
            ])
        }

        // Keep stable, user-friendly ordering and show without trailing dot.
        status.requestedServices = requested

        let declaredNormalized = Set(status.declaredServices.map(normalize))
        status.missingServices = requested
            .map(normalize)
            .filter { !declaredNormalized.contains($0) }
        
        return status
    }
    
    /// 检查网络状态
    private func checkNetworkStatus() async -> NetworkStatus {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            final class ResumeOnce<T: Sendable>: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                private let continuation: CheckedContinuation<T, Never>

                init(_ continuation: CheckedContinuation<T, Never>) {
                    self.continuation = continuation
                }

                func resume(_ value: sending T) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: value)
                }
            }

            let resumeOnce = ResumeOnce(continuation)

            monitor.pathUpdateHandler = { path in
                monitor.cancel()

                var status = NetworkStatus()
                status.hasConnectivity = path.status == .satisfied

                if path.usesInterfaceType(.wifi) {
                    status.connectionType = .wifi
                    status.isOnLocalNetwork = true
                } else if path.usesInterfaceType(.wiredEthernet) {
                    status.connectionType = .ethernet
                    status.isOnLocalNetwork = true
                } else if path.usesInterfaceType(.cellular) {
                    status.connectionType = .cellular
                    status.isOnLocalNetwork = false
                } else {
                    status.connectionType = .unknown
                }

                // 获取本地 IP（纯函数，不依赖 MainActor 状态）
                status.localIPAddress = Self.getLocalIPAddress()

                resumeOnce.resume(status)
            }

            monitor.start(queue: pathMonitorQueue)

            // 超时保护
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                monitor.cancel()
                resumeOnce.resume(NetworkStatus())
            }
        }
    }
    
    /// 获取本地 IP 地址
    private nonisolated static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer { freeifaddrs(ifaddr) }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    // hostname is NUL-terminated C string
                    address = hostname.withUnsafeBufferPointer { buf in
                        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
            }
        }
        
        return address
    }
    
    /// 获取当前活跃的服务类型
    private func getCurrentActiveServices() -> [String] {
        // Best-effort: mirror what we request (computed in checkBonjourWhitelist).
        // This avoids misleading UI when a hardcoded list drifts from actual scanning logic.
        var requested: [String] = ["_skybridge._tcp"]
        if SettingsManager.shared.enableCompanionLink {
            requested.append("_companion-link._tcp")
        }
        if SettingsManager.shared.enableCompatibilityMode {
            requested.append(contentsOf: [
                "_services._dns-sd._udp",
                "_airplay._tcp",
                "_rdlink._tcp",
                "_sftp-ssh._tcp",
                "_http._tcp",
                "_https._tcp",
                "_ssh._tcp",
                "_smb._tcp",
                "_afpovertcp._tcp",
                "_printer._tcp",
                "_ipp._tcp",
                "_scanner._tcp",
                "_workstation._tcp"
            ])
        }
        return requested
    }
    
    /// 为错误建议修复方案
    private func suggestFix(for error: Error, serviceType: String) -> String? {
        let nsError = error as NSError
        
        switch nsError.domain {
        case "NSNetServicesErrorDomain":
            switch nsError.code {
            case -72000: // NSNetServicesNotFoundError
                return "确保目标设备在同一网络上，并且已启动 SkyBridge 服务"
            case -72003: // NSNetServicesBadArgumentError
                return "检查服务类型配置是否正确"
            case -72004: // NSNetServicesCancelledError
                return "扫描被取消，请重新开始扫描"
            case -72007: // NSNetServicesTimeoutError
                return "扫描超时，请检查网络连接并重试"
            default:
                return nil
            }
        case "NWError":
            if nsError.code == 65 { // EHOSTUNREACH
                return "无法到达目标主机，请检查网络连接"
            }
            return "检查本地网络权限设置（系统偏好设置 > 隐私与安全性 > 本地网络）"
        default:
            return nil
        }
    }
    
    /// 分类错误类型
    private func categorizeError(_ error: Error) -> DiscoveryFailure.FailureCategory {
        let nsError = error as NSError
        
        switch nsError.domain {
        case "NSNetServicesErrorDomain":
            return .bonjour
        case "NWError", "NSURLErrorDomain":
            return .network
        case "NSPOSIXErrorDomain":
            if nsError.code == 1 { // EPERM
                return .permission
            }
            return .network
        default:
            if error.localizedDescription.contains("timeout") ||
               error.localizedDescription.contains("超时") {
                return .timeout
            }
            return .unknown
        }
    }
    
    /// 分类握手失败原因
    private func categorizeHandshakeFailure(_ reason: HandshakeFailureReason) -> DiscoveryFailure.FailureCategory {
        switch reason {
        case .timeout:
            return .timeout
        case .peerRejected:
            return .peerRejection
        case .cryptoError, .signatureVerificationFailed, .keyConfirmationFailed,
             .pqcProviderUnavailable, .suiteNegotiationFailed, .suiteNotSupported,
             .suiteSignatureMismatch:
            return .cryptographic
        case .transportError:
            return .network
        default:
            return .unknown
        }
    }
}

// MARK: - 握手错误本地化
/// 将握手失败原因映射为用户可读的消息
public enum HandshakeErrorLocalizer {
    
    /// 获取用户可读的错误消息
    public static func localizedMessage(for reason: HandshakeFailureReason) -> String {
        switch reason {
        case .timeout:
            return "连接超时 - 对方设备未响应"
            
        case .peerRejected(let message):
            if message.isEmpty {
                return "对方拒绝了连接请求"
            }
            return "对方拒绝连接：\(message)"
            
        case .cryptoError(let detail):
            let lowered = detail.lowercased()
            if lowered.contains("cryptokiterror error 3") || lowered.contains("cryptokit.cryptokiterror error 3") {
                // CryptoKitError(3) is most commonly an AEAD authentication failure (wrong key / wrong transcript binding).
                // In our PQC handshake, this can happen if one side uses Apple CryptoKit PQC and the other side uses liboqs.
                return "安全验证失败：解密认证失败（可能是两端后量子加密实现不兼容或应用构建未启用 Apple PQC）"
            }
            return "安全验证失败：\(simplifyTechnicalMessage(detail))"
            
        case .transportError(let detail):
            return "网络传输错误：\(simplifyTechnicalMessage(detail))"
            
        case .cancelled:
            return "连接已取消"
            
        case .versionMismatch(let local, let remote):
            return "协议版本不兼容（本地 v\(local)，对方 v\(remote)），请更新应用"
            
        case .suiteNegotiationFailed:
            return "无法协商安全加密方式 - 两台设备的加密能力不匹配"
            
        case .signatureVerificationFailed:
            return "身份验证失败 - 对方设备的身份无法验证"
            
        case .invalidMessageFormat:
            return "收到无效的握手消息 - 可能是版本不兼容"
            
        case .identityMismatch(let expected, _):
            return "设备身份不匹配 - 期望连接到「\(expected)」但对方身份不符"
            
        case .replayDetected:
            return "检测到重放攻击，连接已中止"
            
        case .secureEnclavePoPRequired:
            return "此连接需要安全芯片验证，但对方设备不支持"
            
        case .secureEnclaveSignatureInvalid:
            return "安全芯片验证失败"
            
        case .keyConfirmationFailed:
            return "密钥确认失败 - 安全通道建立失败"
            
        case .suiteSignatureMismatch(let suite, _):
            return "安全配置不匹配（\(simplifyTechnicalMessage(suite))）"
            
        case .pqcProviderUnavailable:
            return "后量子加密不可用 - 需要 macOS 26/iOS 26 或更高版本"
            
        case .suiteNotSupported:
            return "不支持的加密套件 - 请更新应用"
        }
    }
    
    /// 获取建议的修复方案
    public static func suggestedFix(for reason: HandshakeFailureReason) -> String? {
        switch reason {
        case .cryptoError(let detail):
            let lowered = detail.lowercased()
            if lowered.contains("cryptokiterror error 3") || lowered.contains("cryptokit.cryptokiterror error 3") {
                return "请更新两台设备的应用到同一版本，并确保 macOS 端是用 Xcode 26+ 构建且已启用 Apple PQC（HAS_APPLE_PQC_SDK）。"
            }
            return "请更新两台设备的应用，并重试连接；如仍失败可在诊断面板查看详细原因"
            
        case .timeout:
            return "请确保两台设备在同一网络上，或检查防火墙设置"
            
        case .peerRejected:
            return "请在对方设备上确认连接请求"
            
        case .versionMismatch:
            return "请更新两台设备上的 SkyBridge 应用到最新版本"
            
        case .suiteNegotiationFailed:
            return "请更新两台设备的应用，或在设置中调整加密策略"
            
        case .signatureVerificationFailed, .identityMismatch:
            return "如果这是一台新设备，请在信任设置中添加它"
            
        case .pqcProviderUnavailable:
            return "更新系统到 macOS 26/iOS 26 以启用后量子加密，或在设置中启用经典加密兼容模式"
            
        case .transportError:
            return "检查网络连接，确保没有使用可能干扰的 VPN 或代理"
            
        case .secureEnclavePoPRequired, .secureEnclaveSignatureInvalid:
            return "请确保两台设备都支持 Secure Enclave，或调整安全策略设置"
            
        default:
            return nil
        }
    }
    
    /// 简化技术性消息
    private static func simplifyTechnicalMessage(_ message: String) -> String {
        // 移除技术细节，保留用户可理解的部分
        var simplified = message
        
        // 移除常见的技术前缀
        let prefixesToRemove = [
            "Error Domain=",
            "Code=",
            "NSError:",
            "Swift.DecodingError.",
            "CryptoKit."
        ]
        
        for prefix in prefixesToRemove {
            if let range = simplified.range(of: prefix) {
                // 尝试找到下一个分隔符
                if let endRange = simplified[range.upperBound...].firstIndex(where: { $0 == " " || $0 == ":" }) {
                    simplified.removeSubrange(range.lowerBound..<simplified.index(after: endRange))
                }
            }
        }
        
        // 如果消息太长，截断
        if simplified.count > 100 {
            simplified = String(simplified.prefix(100)) + "..."
        }
        
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

