import Foundation
import OSLog
import MultipeerConnectivity

/// Wi‑Fi Aware 被动发现适配器（以 MultipeerConnectivity 的"仅浏览"模式实现被动邻居发现）
/// 设计要求：
/// - 纯被动：不发送邀请、不建立会话、不进行底层连接
/// - 作用：在同一链路层（Wi‑Fi/同一网络）发现附近设备的"存在与标识"，供上层列表展示与去重，不触发连接
///
/// Swift 6.2.1 并发模型：
/// - 类本身不使用 @MainActor 隔离，允许委托在任何线程调用
/// - 回调闭包在主线程执行，确保 UI 更新安全
/// - 使用 NSLock 保护共享状态
public final class WiFiAwareDiscovery: NSObject {
    
    public struct AwarePeer: Sendable, Hashable {
        public let id: String
        public let name: String
        public let serviceType: String
    }
    
 // Swift 6.2.1 最佳实践：使用 @MainActor 闭包确保回调在主线程执行
    public var onPeerDiscovered: (@MainActor @Sendable (AwarePeer) -> Void)?
    public var onPeerLost: (@MainActor @Sendable (String) -> Void)?
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "WiFiAware")
    private let lock = NSLock()
    private var _isRunning = false
    
    private var isRunning: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isRunning
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isRunning = newValue
        }
    }
    
 // MultipeerConnectivity 组件（仅浏览，不发起邀请）
    private var peerID: MCPeerID?
    private var browser: MCNearbyServiceBrowser?
    
 // 采用与现有系统一致的服务前缀，避免冲突并利于跨端识别
    private let serviceType = "skyaware" // 必须 <=15 字符、字母数字与连字符
    
    public override init() {
        super.init()
    }
    
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
 // 使用本机名派生 peerID，避免泄露隐私可做 Hash；此处沿用系统名便于开发调试
        let name = Host.current().localizedName ?? "Mac"
        let id = MCPeerID(displayName: name)
        peerID = id
        
        let browser = MCNearbyServiceBrowser(peer: id, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        
        logger.info("Wi‑Fi Aware (MCNearbyServiceBrowser) started. service=\(self.serviceType, privacy: .public)")
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        peerID = nil
        
        logger.info("Wi‑Fi Aware (MCNearbyServiceBrowser) stopped.")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate（仅浏览，不邀请）
// Swift 6.2.1 最佳实践：委托方法在任何线程执行，通过 显式调度到主线程
extension WiFiAwareDiscovery: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
 // 仅上报发现事件；不调用 invitePeer
        let peer = AwarePeer(id: peerID.displayName, name: peerID.displayName, serviceType: serviceType)
        logger.debug("Aware peer found: \(peerID.displayName, privacy: .public)")
        
 // Swift 6.2.1：显式调度到主线程调用闭包
        let handler = onPeerDiscovered  // 避免在 Task 中捕获 self
        Task { @MainActor in
            handler?(peer)
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let displayName = peerID.displayName
        logger.debug("Aware peer lost: \(displayName, privacy: .public)")
        
 // Swift 6.2.1：显式调度到主线程调用闭包
        let handler = onPeerLost  // 避免在 Task 中捕获 self
        Task { @MainActor in
            handler?(displayName)
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        logger.error("Aware browse failed: \(error.localizedDescription, privacy: .public)")
    }
}


