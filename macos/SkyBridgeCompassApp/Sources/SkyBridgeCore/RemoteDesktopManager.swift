import Foundation
import Combine
import AppKit
import Network
import os.log
@_exported import Foundation
#if canImport(OrderedCollections)
import OrderedCollections
#endif
#if canImport(FreeRDPBridge)
import FreeRDPBridge
#else
enum CBFreeRDPClientState: Int {
    case idle, connecting, connected, failed, disconnected
}
enum CBFreeRDPFrameType: UInt8 { case bgra = 0 }
final class CBFreeRDPClient {
    var state: CBFreeRDPClientState = .idle
    var frameCallback: ((NSData, UInt32, UInt32, UInt32, CBFreeRDPFrameType) -> Void)?
    var stateCallback: ((String) -> Void)?
    init(host: String, port: UInt16, username: String, password: String, domain: String?) {}
    func connect() throws {
        state = .connected
        stateCallback?("connected (stub)")
    }
    func disconnect() {
        state = .disconnected
        stateCallback?("disconnected (stub)")
    }
}
#endif
import IOKit

public enum RemoteDesktopError: Error, LocalizedError, Sendable {
    case missingAddress(DiscoveredDevice)
    case missingPort(DiscoveredDevice)
    case connectionFailed(String)
    // Metal相关错误
    case metalInitializationFailed
    case metalCommandQueueCreationFailed
    case metalPipelineCreationFailed
    case metalCommandCreationFailed
    case metalTextureCreationFailed
    case textureCacheCreationFailed
    case pixelBufferCreationFailed
    case encoderNotInitialized
    case encodingFailed(OSStatus)
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionPreparationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingAddress(let device):
            return "设备 \(device.name) 缺少有效的网络地址"
        case .missingPort(let device):
            return "设备 \(device.name) 未公开可用的远程桌面端口"
        case .connectionFailed(let message):
            return "远程桌面连接失败: \(message)"
        case .metalInitializationFailed:
            return "Metal设备初始化失败"
        case .metalCommandQueueCreationFailed:
            return "Metal命令队列创建失败"
        case .metalPipelineCreationFailed:
            return "Metal计算管线创建失败"
        case .metalCommandCreationFailed:
            return "Metal命令创建失败"
        case .metalTextureCreationFailed:
            return "Metal纹理创建失败"
        case .textureCacheCreationFailed:
            return "纹理缓存创建失败"
        case .pixelBufferCreationFailed:
            return "像素缓冲区创建失败"
        case .encoderNotInitialized:
            return "编码器未初始化"
        case .encodingFailed(let status):
            return "视频编码失败: \(status)"
        case .compressionSessionCreationFailed(let status):
            return "压缩会话创建失败: \(status)"
        case .compressionSessionPreparationFailed(let status):
            return "压缩会话准备失败: \(status)"
        }
    }
}

@available(macOSApplicationExtension, unavailable)
@MainActor
public final class RemoteDesktopManager: ObservableObject {
    private let sessionsSubject = CurrentValueSubject<[RemoteSessionSummary], Never>([])
    private let metricsSubject = CurrentValueSubject<RemoteMetricsSnapshot, Never>(.init(onlineDevices: 0, activeSessions: 0, transferCount: 0, alertCount: 0, cpuTimeline: [:]))
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteDesktop")
    private var monitoringTimer: Timer?
    private var cpuTimeline = OrderedDictionary<Date, Double>()
    private var activeSessions: [UUID: RemoteDesktopSession] = [:]
    private let sessionQueue = DispatchQueue(label: "com.skybridge.compass.remote.sessions", attributes: .concurrent)
    /// UI 桥接：发布来自会话的最新远端帧纹理。
    public let textureFeed = RemoteTextureFeed()
@MainActor private var tenantController: TenantAccessController { TenantAccessController.shared }

    public init() {}

    public var sessions: AnyPublisher<[RemoteSessionSummary], Never> { sessionsSubject.eraseToAnyPublisher() }
    public var metrics: AnyPublisher<RemoteMetricsSnapshot, Never> { metricsSubject.eraseToAnyPublisher() }

    public func bootstrap() {
        startResourceMonitoring()
    }

    public func shutdown() {
        // 停止资源监控定时器
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        // 使用屏障任务确保所有会话操作完成后再清理
        sessionQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                // 停止所有活跃会话
                for session in self.activeSessions.values {
                    session.stop()  // stop 方法不是异步的，移除 await
                }
                
                // 清空会话字典
                self.activeSessions.removeAll()
                
                // 在主线程更新UI状态
                self.cpuTimeline.removeAll()
                self.sessionsSubject.send([])
                self.metricsSubject.send(.init(onlineDevices: 0, activeSessions: 0, transferCount: 0, alertCount: 0, cpuTimeline: [:]))
            }
        }
    }

    public func connect(to device: DiscoveredDevice, tenant: TenantDescriptor) async throws {
        let credentials = try await tenantController.credentials(for: tenant.id)
        guard let host = device.ipv4 ?? device.ipv6 else {
            throw RemoteDesktopError.missingAddress(device)
        }
        guard let port = resolvePort(for: device), port <= Int(UInt16.max) else {
            throw RemoteDesktopError.missingPort(device)
        }

        let session = RemoteDesktopSession(
            device: device,
            tenant: tenant,
            credentials: credentials,
            host: host,
            port: port,
            renderer: RemoteFrameRenderer(),
            feed: textureFeed
        ) { [weak self] in
            self?.updateSessionsSnapshot()
        } stateChanged: { [weak self] in
            self?.refreshMetrics()
        }

        sessionQueue.async(flags: .barrier) { [weak self] in
            self?.activeSessions[session.id] = session
        }
        updateSessionsSnapshot()

        do {
            try await session.start()
            refreshMetrics()
        } catch {
            sessionQueue.async(flags: .barrier) { [weak self] in
                self?.activeSessions.removeValue(forKey: session.id)
            }
            updateSessionsSnapshot()
            throw error
        }
    }

    @available(*, deprecated, message: "Use tenant-specific connect")
    public func connect(to device: DiscoveredDevice) async throws {
        let tenant = try await tenantController.requirePermission(.remoteDesktop)
        try await connect(to: device, tenant: tenant)
    }

    public func focus(on sessionID: UUID) {
        Task { @MainActor in
            activeSessions[sessionID]?.focus()
        }
    }

    public func terminate(sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                if let session = activeSessions.removeValue(forKey: sessionID) {
                    session.stop()
                }
                updateSessionsSnapshot()
                refreshMetrics()
                continuation.resume()
            }
        }
    }

    private func updateSessionsSnapshot() {
        let summaries = sessionQueue.sync { Array(self.activeSessions.values.map { $0.summary }) }
        sessionsSubject.send(summaries)
    }

    private func refreshMetrics(cpuLoad: Double? = nil) {
        if let cpuLoad {
            cpuTimeline[Date()] = cpuLoad
            while cpuTimeline.count > 30 {
                cpuTimeline.removeFirst()
            }
        }
        let sessionStates = sessionQueue.sync { Array(self.activeSessions.values) }
        let activeCount = sessionStates.filter { $0.clientState == .connected }.count
        let alertCount = sessionStates.filter { $0.clientState == .failed }.count
        let snapshot = RemoteMetricsSnapshot(
            onlineDevices: sessionStates.count,
            activeSessions: activeCount,
            transferCount: 0,
            alertCount: alertCount,
            cpuTimeline: cpuTimeline
        )
        metricsSubject.send(snapshot)
    }

    private func startResourceMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let cpuLoad = self.fetchCpuLoad()
                self.refreshMetrics(cpuLoad: cpuLoad)
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
        let totalTicks = Double(load.cpu_ticks.0 + load.cpu_ticks.1 + load.cpu_ticks.2 + load.cpu_ticks.3)
        let idleTicks = Double(load.cpu_ticks.2)
        let usage = (totalTicks - idleTicks) / totalTicks
        return max(0, min(1, usage))
    }

    private func resolvePort(for device: DiscoveredDevice) -> Int? {
        if let rdp = device.portMap["_rdp._tcp."] { return rdp }
        if let vnc = device.portMap["_rfb._tcp."] { return vnc }
        return device.portMap.values.first
    }
}

@MainActor
private final class RemoteDesktopSession {
    let id = UUID()
    let device: DiscoveredDevice
    let tenant: TenantDescriptor
    private let credentials: TenantCredential
    private let renderer: RemoteFrameRenderer
    private weak var feed: RemoteTextureFeed?
    private let client: CBFreeRDPClient
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteSession")
    private let summaryChanged: () -> Void
    private let stateChanged: () -> Void

    private let continuationLock = NSLock()
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    private(set) var summary: RemoteSessionSummary
    private(set) var clientState: CBFreeRDPClientState = .idle

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
        self.renderer = renderer
        self.feed = feed
        self.summaryChanged = summaryChanged
        self.stateChanged = stateChanged
        self.summary = RemoteSessionSummary(
            id: id,
            targetName: device.name,
            protocolDescription: device.services.first ?? "RDP",
            bandwidthMbps: 0,
            frameLatencyMilliseconds: 0
        )
        self.client = CBFreeRDPClient(
            host: host,
            port: UInt16(port),
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain
        )
        configureCallbacks()
    }

    func start() async throws {
        clientState = .connecting
        stateChanged()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            if connectionContinuation != nil {
                continuationLock.unlock()
                continuation.resume(throwing: RemoteDesktopError.connectionFailed("重复的连接请求"))
                return
            }
            connectionContinuation = continuation
            continuationLock.unlock()

            do {
                try self.client.connect()
                return
            } catch {
                self.clientState = .failed
                self.stateChanged()
                let failure = error
                self.resolveConnectionContinuation(.failure(failure))
            }
        }
    }

    func stop() {
        // 清理渲染器资源
        renderer.teardown()
        
        // 断开客户端连接
        client.disconnect()
        
        // 清理回调引用，避免循环引用
        client.frameCallback = nil
        client.stateCallback = nil
        renderer.frameHandler = nil
        
        // 清理弱引用
        feed = nil
        
        // 更新状态
        clientState = .disconnected
        stateChanged()
    }

    @MainActor
    func focus() {
        log.info("Focus requested for session \(self.device.name)")
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: 0, y: 0))
    }

    private func configureCallbacks() {
        // 将渲染输出纹理桥接到 UI。遵循 Apple 的建议，在主线程驱动 UI 绘制。
        renderer.frameHandler = { [weak self] texture in
            guard let self else { return }
            Task { @MainActor in
                self.feed?.update(texture: texture)
            }
        }
        client.frameCallback = { [weak self] data, width, height, stride, frameType in
            guard let self else { return }
            Task { @MainActor in
                // 将 FreeRDP 帧类型安全地映射到内部枚举。
                let mappedType = RemoteFrameType(rawValue: UInt(frameType.rawValue)) ?? .bgra
                let metrics = self.renderer.processFrame(
                    data: data as Data,
                    width: Int(width),
                    height: Int(height),
                    stride: Int(stride),
                    type: mappedType
                )
                self.summary = RemoteSessionSummary(
                    id: self.summary.id,
                    targetName: self.summary.targetName,
                    protocolDescription: self.summary.protocolDescription,
                    bandwidthMbps: metrics.bandwidthMbps,
                    frameLatencyMilliseconds: metrics.latencyMilliseconds
                )
                self.summaryChanged()
            }
        }

        client.stateCallback = { [weak self] description in
            guard let self else { return }
            Task { @MainActor in
                self.log.info("Session state updated \(description)")
                let newState = self.client.state
                self.clientState = newState
                self.stateChanged()

                switch newState {
                case .connected:
                    self.resolveConnectionContinuation(.success(()))
                case .failed:
                    self.resolveConnectionContinuation(.failure(RemoteDesktopError.connectionFailed(description)))
                case .disconnected:
                    self.resolveConnectionContinuation(.failure(RemoteDesktopError.connectionFailed("FreeRDP 会话已断开")))
                default:
                    break
                }
            }
        }
    }

    private func resolveConnectionContinuation(_ result: Result<Void, Error>) {
        continuationLock.lock()
        guard let continuation = connectionContinuation else {
            continuationLock.unlock()
            return
        }
        connectionContinuation = nil
        continuationLock.unlock()

        switch result {
        case .success:
            continuation.resume(returning: ())
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
