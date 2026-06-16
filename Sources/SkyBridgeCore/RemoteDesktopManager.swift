import Foundation
import Combine
import AppKit
import Network
import OSLog
import OrderedCollections
import CryptoKit

#if canImport(FreeRDPBridge)
import FreeRDPBridge
#endif

// MARK: - 错误定义

public enum RemoteDesktopError: Error, LocalizedError, Sendable {
    case missingAddress(DiscoveredDevice)
    case missingPort(DiscoveredDevice)
    case connectionFailed(String)
 // FreeRDP 库不可用
    case freeRDPUnavailable(installGuide: String)
 // Metal 相关错误
    case metalInitializationFailed
    case metalCommandQueueCreationFailed
    case metalCommandCreationFailed
    case metalPipelineCreationFailed
    case metalTextureCreationFailed
 // 编码器相关错误
    case encoderNotInitialized
    case encodingFailed(OSStatus)
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionPreparationFailed(OSStatus)
 // 纹理/缓冲相关错误
    case textureCacheCreationFailed
    case pixelBufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .missingAddress(let device):
            return "设备 \(device.name) 缺少有效的网络地址"
        case .missingPort(let device):
            return "设备 \(device.name) 未公开可用的远程桌面端口"
        case .connectionFailed(let msg):
            return "远程桌面连接失败：\(msg)"
        case .freeRDPUnavailable(let guide):
            return "RDP 远程桌面功能暂不可用\n\n\(guide)"
        case .metalInitializationFailed:
            return "Metal 设备初始化失败"
        case .metalCommandQueueCreationFailed:
            return "Metal 命令队列创建失败"
        case .metalCommandCreationFailed:
            return "Metal 命令创建失败"
        case .metalPipelineCreationFailed:
            return "Metal 管线创建失败"
        case .metalTextureCreationFailed:
            return "Metal 纹理创建失败"
        case .encoderNotInitialized:
            return "编码器未初始化"
        case .encodingFailed(let status):
            return "编码失败：状态码 \(status)"
        case .compressionSessionCreationFailed(let status):
            return "压缩会话创建失败：状态码 \(status)"
        case .compressionSessionPreparationFailed(let status):
            return "压缩会话准备失败：状态码 \(status)"
        case .textureCacheCreationFailed:
            return "纹理缓存创建失败"
        case .pixelBufferCreationFailed:
            return "像素缓冲创建失败"
        }
    }
    
 /// 获取 FreeRDP 安装说明
    public static var freeRDPInstallGuide: String {
        """
        安装方法：
        1. 打开终端 (Terminal.app)
        2. 安装 Homebrew（如未安装）:
           /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        3. 安装 FreeRDP:
           brew install freerdp
        
        安装完成后重启 SkyBridge Compass Pro 即可使用 RDP 功能。
        
        替代方案：您也可以使用 VNC 连接到远程设备。
        """
    }
}

// MARK: - RDP 管理器（只负责 RDP，会和你自研协议那条线并存）

@available(macOSApplicationExtension, unavailable)
@MainActor
public final class RemoteDesktopManager: ObservableObject, Sendable {

    public static let shared = RemoteDesktopManager()

    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteDesktopRDP")

 // UI 用 publisher
    private let sessionsSubject = CurrentValueSubject<[RemoteSessionSummary], Never>([])
    private let metricsSubject  = CurrentValueSubject<RemoteMetricsSnapshot, Never>(
        .init(onlineDevices: 0, activeSessions: 0, transferCount: 0, alertCount: 0, cpuTimeline: [:])
    )

 // 会话表（用并发队列保证线程安全）
    private var activeSessions: [UUID: RemoteDesktopSession] = [:]
    private let sessionQueue = DispatchQueue(label: "com.skybridge.compass.rdp.sessions", attributes: .concurrent)

 // 统一纹理输出（给 SwiftUI / AppKit 绑定用）
    public let textureFeed = RemoteTextureFeed()
    private lazy var textureFeedDeliveryGate = LatestTextureDeliveryGate(feed: textureFeed)

 // 监控 CPU 简单指标（非必须，可删）
    private var monitoringTimer: Timer?
    private var cpuTimeline: OrderedDictionary<Date, Double> = [:]
    
    private var started = false
    
 // 受信密钥提供者（用于验证远程设备身份）
    private var trustedKeyProvider: (@Sendable () async -> [P256.Signing.PublicKey])?

    public var sessions: AnyPublisher<[RemoteSessionSummary], Never> { sessionsSubject.eraseToAnyPublisher() }
    public var metrics: AnyPublisher<RemoteMetricsSnapshot, Never> { metricsSubject.eraseToAnyPublisher() }

    private init() {}

 // MARK: - 生命周期

    public func start() {
        guard !started else { return }
        started = true
        startResourceMonitoring()
        log.info("🚀 RemoteDesktopManager (RDP) started")
    }

    public func stop() {
        guard started else { return }
        started = false

        monitoringTimer?.invalidate()
        monitoringTimer = nil
        textureFeedDeliveryGate.clear()

        sessionQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
 // 在主线程上安全访问 activeSessions
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sessions = Array(self.activeSessions.values)
                for s in sessions { s.stop() }
                self.activeSessions.removeAll()
                self.sessionsSubject.send([])
                self.metricsSubject.send(.init(onlineDevices: 0, activeSessions: 0,
                                               transferCount: 0, alertCount: 0, cpuTimeline: [:]))
            }
        }

        log.info("🛑 RemoteDesktopManager (RDP) stopped")
    }

 // MARK: - 建立连接（自动 + 手动两种）

    public func connect(to device: DiscoveredDevice, tenant: TenantDescriptor) async throws {
        #if !canImport(FreeRDPBridge)
        throw RemoteDesktopError.freeRDPUnavailable(installGuide: RemoteDesktopError.freeRDPInstallGuide)
        #endif

        let credentials = try await TenantAccessController.shared.credentials(for: tenant.id)
        guard let host = device.ipv4 ?? device.ipv6 else {
            throw RemoteDesktopError.missingAddress(device)
        }
        guard let port = resolvePort(for: device), port > 0, port <= Int(UInt16.max) else {
            throw RemoteDesktopError.missingPort(device)
        }

        let session = RemoteDesktopSession(
            device: device,
            tenant: tenant,
            credentials: credentials,
            host: host,
            port: port,
            renderer: RemoteFrameRenderer(),
            feed: textureFeed,
            summaryChanged: { [weak self] in self?.updateSessionsSnapshot() },
            stateChanged:  { [weak self] in self?.refreshMetrics() }
        )

        try await addAndStartSession(session)
    }

 /// 手动输入 host/port/username/password 的连接方式
    public func connect(host: String,
                        port: Int,
                        username: String,
                        password: String,
                        domain: String? = nil,
                        displayName: String? = nil) async throws {
        #if !canImport(FreeRDPBridge)
        throw RemoteDesktopError.freeRDPUnavailable(installGuide: RemoteDesktopError.freeRDPInstallGuide)
        #endif

        guard port > 0 && port <= Int(UInt16.max) else {
            throw RemoteDesktopError.connectionFailed("非法端口 \(port)")
        }

        let device = DiscoveredDevice(
            id: UUID(),
            name: displayName ?? host,
            ipv4: host,
            ipv6: nil,
            services: ["RDP"],
            portMap: ["RDP": port],
            connectionTypes: [DeviceConnectionType.unknown]
        )

        let tenant = TenantDescriptor(
            displayName: username,
            username: username,
            domain: domain,
            permissions: .remoteDesktop
        )
        let creds = TenantCredential(username: username, password: password, domain: domain)

        let session = RemoteDesktopSession(
            device: device,
            tenant: tenant,
            credentials: creds,
            host: host,
            port: port,
            renderer: RemoteFrameRenderer(),
            feed: textureFeed,
            summaryChanged: { [weak self] in self?.updateSessionsSnapshot() },
            stateChanged:  { [weak self] in self?.refreshMetrics() }
        )

        try await addAndStartSession(session)
    }

    private func addAndStartSession(_ session: RemoteDesktopSession) async throws {
        Task { @MainActor in
            self.activeSessions[session.id] = session
            self.updateSessionsSnapshot()
        }

        do {
 // 连接前把用户持久化的远程桌面设置（分辨率/色深/编码器/帧率/网络等）下发给会话，
 // 否则设置 UI 只写入 UserDefaults 而从不生效（此前 applySettings 没有任何调用方 = 假阳性）。
 // FreeRDP 类参数需在 connect 之前设置，故放在 start() 之前。
            session.applySettings(RemoteDesktopSettingsManager.shared.settings)
            try await session.start()
            refreshMetrics()
        } catch {
            Task { @MainActor in
                self.activeSessions.removeValue(forKey: session.id)
                self.updateSessionsSnapshot()
                self.refreshMetrics()
            }
            throw error
        }
    }

    /// 把当前持久化的远程桌面设置重新下发给所有活跃会话。
    /// 用于设置/质量变更后的即时生效尝试——设置至此真正接入会话（而非只写 UserDefaults）；
    /// FreeRDP 是否支持会话中改参由客户端决定，但链路已接通。
    public func reapplyCurrentSettingsToActiveSessions() {
        let settings = RemoteDesktopSettingsManager.shared.settings
        for session in activeSessions.values {
            session.applySettings(settings)
        }
    }

    public func terminate(sessionID: UUID) {
        Task { @MainActor in
            if let s = activeSessions.removeValue(forKey: sessionID) {
                s.stop()
            }
            updateSessionsSnapshot()
            refreshMetrics()
        }
    }

    public func focus(on sessionID: UUID) {
        Task { @MainActor in
            activeSessions[sessionID]?.focus()
        }
    }
    
 /// 重新加载会话列表（公开接口）
    public func reloadSessions() {
        Task { @MainActor in
            updateSessionsSnapshot()
            refreshMetrics()
        }
    }
    
 /// 引导启动管理器
    public func bootstrap() {
        guard !started else { return }
        started = true

 // 启动监控定时器
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cpu = self.fetchCpuLoad()
                self.refreshMetrics(cpuLoad: cpu)
            }
        }

        log.info("RemoteDesktopManager bootstrap完成")
    }
    
 /// 关闭管理器
    public func shutdown() {
        Task { @MainActor in
            monitoringTimer?.invalidate()
            monitoringTimer = nil
            textureFeedDeliveryGate.clear()
            
 // 断开所有会话
            let sessions = sessionQueue.sync { Array(activeSessions.values) }
            for session in sessions {
                session.stop()
            }
            activeSessions.removeAll()
            updateSessionsSnapshot()
        }
        
        started = false
        log.info("RemoteDesktopManager shutdown完成")
    }
    
 // MARK: - 受信密钥管理
    
 /// 设置受信密钥提供者（用于验证远程设备身份）
 /// - Parameter provider: 异步返回受信公钥列表的闭包
    public func setTrustedKeyProvider(_ provider: @escaping @Sendable () async -> [P256.Signing.PublicKey]) {
        trustedKeyProvider = provider
        log.info("✅ 受信密钥提供者已设置")
    }
    
 /// 从 Supabase 配置受信密钥提供者
 /// - Parameters:
 /// - url: Supabase 项目 URL
 /// - anonKey: Supabase 匿名密钥
 /// - tenantId: 可选的租户 ID
    public func bootstrapTrustedKeysFromSupabase(url: String, anonKey: String, tenantId: String? = nil) {
        setTrustedKeyProvider { @Sendable in
            guard let restURL = URL(string: url + "/rest/v1/user_devices?select=device_id,public_key" + (tenantId != nil ? "&tenant_id=eq." + tenantId! : "")) else {
                return []
            }
            var req = URLRequest(url: restURL)
            req.httpMethod = "GET"
            req.addValue("application/json", forHTTPHeaderField: "Accept")
            req.addValue(anonKey, forHTTPHeaderField: "apikey")
            req.addValue("Bearer " + anonKey, forHTTPHeaderField: "Authorization")
            req.addValue("return=representation", forHTTPHeaderField: "Prefer")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
                guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
                var results: [P256.Signing.PublicKey] = []
                for item in arr {
                    guard let pkStr = item["public_key"] as? String, !pkStr.isEmpty else { continue }
                    if let raw = Data(base64Encoded: pkStr), let pk = try? P256.Signing.PublicKey(x963Representation: raw) {
                        results.append(pk); continue
                    }
                    if let raw = Data(base64Encoded: pkStr), let pk = try? P256.Signing.PublicKey(rawRepresentation: raw) {
                        results.append(pk); continue
                    }
                }
                return results
            } catch {
                return []
            }
        }
    }
    
 /// 获取当前受信密钥列表
    public func getTrustedKeys() async -> [P256.Signing.PublicKey] {
        guard let provider = trustedKeyProvider else { return [] }
        return await provider()
    }

 // MARK: - 输入事件桥接

    public func sendMouseEvent(sessionId: UUID, x: Float, y: Float,
                               eventType: NSEvent.EventType, buttonNumber: Int) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.activeSessions[sessionId]?.sendMouseEvent(x: x, y: y,
                                                               eventType: eventType,
                                                               buttonNumber: buttonNumber)
            }
        }
    }

    public func sendKeyboardEvent(sessionId: UUID, keyCode: UInt16, isPressed: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.activeSessions[sessionId]?.sendKeyboardEvent(keyCode: keyCode,
                                                                  isPressed: isPressed)
            }
        }
    }

    public func sendScrollEvent(sessionId: UUID, deltaX: Float, deltaY: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.activeSessions[sessionId]?.sendScrollEvent(deltaX: deltaX, deltaY: deltaY)
            }
        }
    }

 // MARK: - 会话 & 指标

    private func resolvePort(for device: DiscoveredDevice) -> Int? {
        if let rdp = device.portMap["_rdp._tcp."] { return rdp }
        if let rdp = device.portMap["RDP"]         { return rdp }
        return device.portMap.values.first
    }

    private func updateSessionsSnapshot() {
        let snapshots: [RemoteSessionSummary] = sessionQueue.sync {
            Array(activeSessions.values.map { $0.summary })
        }
        sessionsSubject.send(snapshots)
    }

    private func refreshMetrics(cpuLoad: Double? = nil) {
        if let cpuLoad {
            cpuTimeline[Date()] = cpuLoad
 // 移除最旧的条目，保持只有30个
            while cpuTimeline.count > 30 {
                cpuTimeline.removeFirst()
            }
        }
        let sessions = sessionQueue.sync { Array(activeSessions.values) }
        let activeCount = sessions.filter { $0.clientState == .connected }.count
        let alertCount  = sessions.filter { $0.clientState == .failed }.count
        let snapshot = RemoteMetricsSnapshot(
            onlineDevices: sessions.count,
            activeSessions: activeCount,
            transferCount: 0,
            alertCount: alertCount,
            cpuTimeline: cpuTimeline
        )
        metricsSubject.send(snapshot)
    }

    private func startResourceMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cpu = self.fetchCpuLoad()
                self.refreshMetrics(cpuLoad: cpu)
            }
        }
    }

    private func fetchCpuLoad() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: load) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let total = Double(load.cpu_ticks.0 + load.cpu_ticks.1 + load.cpu_ticks.2 + load.cpu_ticks.3)
        let idle  = Double(load.cpu_ticks.2)
        let usage = (total - idle) / total
        return max(0, min(1, usage))
    }
}

// MARK: - 单个 RDP 会话

@MainActor
final class RemoteDesktopSession {

    let id = UUID()
    let device: DiscoveredDevice
    let tenant: TenantDescriptor
    let credentials: TenantCredential

    private let host: String
    private let port: Int

    private let renderer: RemoteFrameRenderer
    private weak var feed: RemoteTextureFeed?
    private let textureFeedDeliveryGate: LatestTextureDeliveryGate

    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteSessionRDP")

    private let client: CBFreeRDPClient
    private let summaryChanged: () -> Void
    private let stateChanged:  () -> Void

    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private let continuationLock = NSLock()
    private var lastPointerLocation: CGPoint?
    private var hasEstablishedConnection = false

    private(set) var clientState: CBFreeRDPClientState = .idle
    private(set) var summary: RemoteSessionSummary

    init(device: DiscoveredDevice,
         tenant: TenantDescriptor,
         credentials: TenantCredential,
         host: String,
         port: Int,
         renderer: RemoteFrameRenderer,
         feed: RemoteTextureFeed,
         summaryChanged: @escaping () -> Void,
         stateChanged: @escaping () -> Void) {

        self.device = device
        self.tenant = tenant
        self.credentials = credentials
        self.host = host
        self.port = port
        self.renderer = renderer
        self.feed = feed
        self.textureFeedDeliveryGate = LatestTextureDeliveryGate(feed: feed)
        self.summaryChanged = summaryChanged
        self.stateChanged = stateChanged

        self.client = CBFreeRDPClient(
            host: host,
            port: UInt16(port),
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain
        )

        self.summary = RemoteSessionSummary(
            id: id,
            targetName: device.name,
            protocolDescription: "RDP",
            bandwidthMbps: 0,
            frameLatencyMilliseconds: 0,
            status: .connecting
        )

        configureCallbacks()
    }

 // MARK: - 连接生命周期

    func start() async throws {
        clientState = .connecting
        stateChanged()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            if connectionContinuation != nil {
                continuationLock.unlock()
                cont.resume(throwing: RemoteDesktopError.connectionFailed("重复连接请求"))
                return
            }
            connectionContinuation = cont
            continuationLock.unlock()

            do {
                try client.connect()
            } catch {
                self.clientState = .failed
                self.stateChanged()
                self.resolveConnectionContinuation(.failure(error))
            }
        }
    }

    func stop() {
        if hasEstablishedConnection {
            RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
                sessionID: id.uuidString,
                deviceName: device.name,
                transport: "rdp",
                kind: .normal,
                reason: "rdp_terminate"
            )
        }
        renderer.teardown()
        client.disconnect()
        client.frameCallback = nil
        client.stateCallback = nil
        textureFeedDeliveryGate.clear()
        feed = nil
        clientState = .disconnected
        stateChanged()
    }

    func focus() {
        log.info("focus session \(self.device.name)")
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: 0, y: 0))
    }

 // MARK: - 输入事件

    func sendMouseEvent(x: Float, y: Float,
                        eventType: NSEvent.EventType,
                        buttonNumber: Int) {
        guard clientState == .connected else {
            log.warning("尝试发送鼠标事件到未连接会话")
            return
        }

        let interactionSettings = RemoteDesktopSettingsManager.shared.settings.interactionSettings
        guard interactionSettings.enableContextMenu || !Self.isRightMouseEvent(eventType) else {
            return
        }

        var mask: UInt16 = 0

        switch eventType {
        case .leftMouseDown:  mask = 0x0001
        case .leftMouseUp:    mask = 0x0000
        case .rightMouseDown: mask = 0x0002
        case .rightMouseUp:   mask = 0x0000
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            mask = 0x0800
        default:
            mask = 0
        }

        let adjustedPoint = adjustedPointerLocation(
            CGPoint(x: CGFloat(x), y: CGFloat(y)),
            eventType: eventType,
            settings: interactionSettings
        )
        let nx = UInt16(max(0, min(65535, adjustedPoint.x)))
        let ny = UInt16(max(0, min(65535, adjustedPoint.y)))
        client.submitPointerEvent(with: nx, y: ny, buttonMask: mask)
    }

    func sendKeyboardEvent(keyCode: UInt16, isPressed: Bool) {
        guard clientState == .connected else {
            log.warning("尝试发送键盘事件到未连接会话")
            return
        }
        client.submitKeyboardEvent(withCode: keyCode, down: isPressed)
    }

    func sendScrollEvent(deltaX: Float, deltaY: Float) {
        guard clientState == .connected else {
            log.warning("尝试发送滚轮事件到未连接会话")
            return
        }
        let interactionSettings = RemoteDesktopSettingsManager.shared.settings.interactionSettings
        guard interactionSettings.enableTrackpadGestures else {
            return
        }
        let scaledDeltaY = Double(deltaY) * max(0.1, min(interactionSettings.scrollSensitivity, 5.0))
        let mask: UInt16 = scaledDeltaY > 0 ? 0x0078 : 0x0088
        let repeatCount = max(1, min(8, Int((abs(scaledDeltaY) / 8).rounded(.up))))
 // 使用当前光标附近的坐标（RDP 这边一般不敏感）
        for _ in 0..<repeatCount {
            client.submitPointerEvent(with: 400, y: 300, buttonMask: mask)
        }
    }

    private static func isRightMouseEvent(_ eventType: NSEvent.EventType) -> Bool {
        eventType == .rightMouseDown || eventType == .rightMouseUp || eventType == .rightMouseDragged
    }

    private static func isPointerMovementEvent(_ eventType: NSEvent.EventType) -> Bool {
        eventType == .mouseMoved || eventType == .leftMouseDragged || eventType == .rightMouseDragged
    }

    private func adjustedPointerLocation(
        _ location: CGPoint,
        eventType: NSEvent.EventType,
        settings: InteractionSettings
    ) -> CGPoint {
        defer { lastPointerLocation = location }
        guard Self.isPointerMovementEvent(eventType),
              let previous = lastPointerLocation else {
            return location
        }

        let sensitivity = max(0.1, min(settings.mouseSensitivity, 5.0))
        let deltaX = location.x - previous.x
        let deltaY = location.y - previous.y
        let distance = hypot(deltaX, deltaY)
        let acceleration = settings.enableMouseAcceleration
            ? max(1.0, min(2.0, distance / 48.0))
            : 1.0
        return CGPoint(
            x: previous.x + (deltaX * sensitivity * acceleration),
            y: previous.y + (deltaY * sensitivity * acceleration)
        )
    }

 // MARK: - 回调配置

    private func configureCallbacks() {
 // 帧回调：FreeRDPBridge 把解码后的 BGRA/H.264 帧交给我们
        renderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            self.textureFeedDeliveryGate.submit(texture: texture, backing: backing)
        }

        client.frameCallback = { [weak self] data, width, height, stride, frameType in
            guard let self else { return }
            Task { @MainActor in
                let mapped = RemoteFrameType(rawValue: UInt(frameType.rawValue)) ?? .bgra
                let metrics = self.renderer.processFrame(
                    data: data as Data,
                    width: Int(width),
                    height: Int(height),
                    stride: Int(stride),
                    type: mapped
                )

                self.summary = RemoteSessionSummary(
                    id: self.summary.id,
                    targetName: self.summary.targetName,
                    protocolDescription: "RDP",
                    bandwidthMbps: metrics.bandwidthMbps,
                    frameLatencyMilliseconds: metrics.latencyMilliseconds,
                    status: self.mapState(self.clientState)
                )
                self.summaryChanged()
            }
        }

        client.stateCallback = { [weak self] desc in
            guard let self else { return }
            Task { @MainActor in
                self.log.info("RDP state: \(desc)")
                self.clientState = self.client.state
                self.stateChanged()
                self.summary = RemoteSessionSummary(
                    id: self.summary.id,
                    targetName: self.summary.targetName,
                    protocolDescription: "RDP",
                    bandwidthMbps: self.summary.bandwidthMbps,
                    frameLatencyMilliseconds: self.summary.frameLatencyMilliseconds,
                    status: self.mapState(self.clientState)
                )
                self.summaryChanged()

                switch self.clientState {
                case .connected:
                    self.hasEstablishedConnection = true
                    RemoteDesktopSessionNotificationService.shared.beginSession(
                        sessionID: self.id.uuidString,
                        transport: "rdp"
                    )
                    self.resolveConnectionContinuation(.success(()))
                case .failed:
                    if self.hasEstablishedConnection {
                        RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
                            sessionID: self.id.uuidString,
                            deviceName: self.device.name,
                            transport: "rdp",
                            kind: .interrupted,
                            reason: desc
                        )
                    }
                    self.resolveConnectionContinuation(.failure(
                        RemoteDesktopError.connectionFailed(desc)
                    ))
                case .disconnected:
                    if self.hasEstablishedConnection {
                        RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
                            sessionID: self.id.uuidString,
                            deviceName: self.device.name,
                            transport: "rdp",
                            kind: .interrupted,
                            reason: "rdp_disconnected"
                        )
                    }
                    self.resolveConnectionContinuation(.failure(
                        RemoteDesktopError.connectionFailed("RDP 会话已断开")
                    ))
                default:
                    break
                }
            }
        }
    }

    private func mapState(_ state: CBFreeRDPClientState) -> SessionStatus {
        switch state {
        case .idle:         return .connecting
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .disconnecting:return .disconnected
        case .failed:       return .failed
        case .disconnected: return .disconnected
        @unknown default:   return .disconnected
        }
    }

    private func resolveConnectionContinuation(_ result: Result<Void, Error>) {
        continuationLock.lock()
        guard let cont = connectionContinuation else {
            continuationLock.unlock()
            return
        }
        connectionContinuation = nil
        continuationLock.unlock()

        switch result {
        case .success:          cont.resume(returning: ())
        case .failure(let err): cont.resume(throwing: err)
        }
    }

 // MARK: - 应用设置（映射到 FreeRDP）

    func applySettings(_ settings: RemoteDesktopSettings) {
        var dict: [String: Any] = [:]

 // 显示相关：分辨率/色深/编码器等，交给 FreeRDPBridge 映射到 /gfx-h264, /bpp 等
        var display: [String: Any] = [
            "colorDepth": settings.displaySettings.colorDepth.rawValue,
            "fullScreen": settings.displaySettings.fullScreenMode,
            "multiMonitor": settings.displaySettings.multiMonitorSupport,
            "preferredCodec": settings.displaySettings.preferredCodec.rawValue,
            "targetFrameRate": settings.displaySettings.targetFrameRate,
            "keyFrameInterval": settings.displaySettings.keyFrameInterval,
            "compressionLevel": settings.displaySettings.boundedCompressionLevelPercent
        ]
        if let dim = settings.displaySettings.resolution.dimensions {
            display["width"] = dim.width
            display["height"] = dim.height
        }
        dict["displaySettings"] = display

 // 网络相关：LAN/WAN、自适应质量等
        let network: [String: Any] = [
            "connectionType": settings.networkSettings.connectionType.rawValue,
            "enableEncryption": settings.networkSettings.enableEncryption,
            "enableUDPTransport": settings.networkSettings.enableUDPTransport,
            "enableAdaptiveQuality": settings.networkSettings.enableAdaptiveQuality,
            "connectionTimeout": settings.networkSettings.boundedConnectionTimeoutSeconds * 1_000,
            "compressionLevel": settings.networkSettings.boundedCompressionLevel,
            "enableNetworkStats": settings.networkSettings.enableNetworkStats,
            "maxReconnectAttempts": settings.networkSettings.boundedMaxReconnectAttempts,
            "reconnectBackoffInitialMs": settings.networkSettings.boundedReconnectBackoffInitialMilliseconds,
            "reconnectBackoffMaxMs": settings.networkSettings.boundedReconnectBackoffMaxMilliseconds,
            "reconnectBackoffMultiplier": settings.networkSettings.boundedReconnectBackoffMultiplier
        ]
        dict["networkSettings"] = network

        client.applyAllSettings(dict)
    }
}

#if !canImport(FreeRDPBridge)
// MARK: - FreeRDPBridge 缺失时的降级桩（保证可编译）
//
// 目标：
// - 让 SkyBridgeCore 在不包含 FreeRDPBridge / FreeRDP 二进制依赖的环境里仍可编译
// - 运行时若调用 RDP 功能，给出明确的不可用错误，而不是编译期 #error 直接阻断

enum CBFreeRDPClientState: Int {
    case idle
    case connecting
    case connected
    case disconnecting
    case failed
    case disconnected
}

enum CBFreeRDPFrameType: UInt {
    case bgra = 0
    case h264 = 1
    case hevc = 2
}

final class CBFreeRDPClient {
    var frameCallback: ((Data, UInt32, UInt32, UInt32, CBFreeRDPFrameType) -> Void)?
    var stateCallback: ((String) -> Void)?

    private(set) var state: CBFreeRDPClientState = .idle

    init(host: String, port: UInt16, username: String, password: String, domain: String?) {
        _ = host
        _ = port
        _ = username
        _ = password
        _ = domain
    }

    func connect() throws {
        state = .failed
        throw RemoteDesktopError.freeRDPUnavailable(installGuide: RemoteDesktopError.freeRDPInstallGuide)
    }

    func disconnect() {
        state = .disconnected
    }

    func submitPointerEvent(with x: UInt16, y: UInt16, buttonMask: UInt16) {
        _ = x
        _ = y
        _ = buttonMask
    }

    func submitKeyboardEvent(withCode code: UInt16, down: Bool) {
        _ = code
        _ = down
    }

    func applyAllSettings(_ dict: [String: Any]) {
        _ = dict
    }
}
#endif
