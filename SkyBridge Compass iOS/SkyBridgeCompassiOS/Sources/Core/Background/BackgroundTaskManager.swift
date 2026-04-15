//
// BackgroundTaskManager.swift
// SkyBridgeCompassiOS
//
// 后台任务管理器 - 管理 iOS 后台任务
// 支持后台刷新、后台传输、推送唤醒等
//

import Foundation
#if os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Background Task Type

/// 后台任务类型
public enum BackgroundTaskType: String, CaseIterable, Sendable {
    /// 设备发现刷新
    case deviceDiscoveryRefresh = "com.skybridge.deviceDiscoveryRefresh"
    /// 消息同步
    case messageSync = "com.skybridge.messageSync"
    /// 文件传输
    case fileTransfer = "com.skybridge.fileTransfer"
    /// 连接保活
    case connectionKeepAlive = "com.skybridge.connectionKeepAlive"
    /// 数据清理
    case dataCleanup = "com.skybridge.dataCleanup"
    
    public var identifier: String { rawValue }
}

// MARK: - Background Task Manager

/// 后台任务管理器
///
/// 注意：此文件在 SwiftPM 下也会被 macOS host 编译（用于共享模块），因此：
/// - iOS：使用 BGTaskScheduler
/// - macOS：提供 no-op stub（避免 BGTask* API 在 macOS 上不可用导致编译失败）
#if os(iOS)
@available(iOS 17.0, *)
@MainActor
public class BackgroundTaskManager: ObservableObject {
    
    public static let shared = BackgroundTaskManager()

    private final class TaskCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didComplete = false

        func complete(_ task: BGTask, success: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !didComplete else { return false }
            didComplete = true
            task.setTaskCompleted(success: success)
            return true
        }
    }
    
    // MARK: - Published Properties
    
    /// 后台任务是否启用
    @Published public var isBackgroundRefreshEnabled: Bool = true
    
    /// 最后刷新时间
    @Published public private(set) var lastRefreshTime: Date?
    
    /// 是否正在后台运行
    @Published public private(set) var isRunningInBackground: Bool = false
    
    // MARK: - Private Properties
    
    private var registeredTasks: Set<String> = []
    private var taskHandlers: [String: () async -> Void] = [:]
    
    // MARK: - Initialization
    
    private init() {
        setupNotifications()
    }
    
    // MARK: - Public Methods
    
    /// 注册所有后台任务
    public func registerBackgroundTasks() {
        for taskType in BackgroundTaskType.allCases {
            registerTask(taskType)
        }
        
        SkyBridgeLogger.shared.info("✅ 已注册 \(BackgroundTaskType.allCases.count) 个后台任务")
    }
    
    /// 注册单个后台任务
    public func registerTask(_ taskType: BackgroundTaskType) {
        guard !registeredTasks.contains(taskType.identifier) else { return }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskType.identifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor [weak self] in
                await self?.handleBackgroundTask(task, type: taskType)
            }
        }
        
        registeredTasks.insert(taskType.identifier)
        SkyBridgeLogger.shared.info("📝 注册后台任务: \(taskType.identifier)")
    }
    
    /// 设置任务处理器
    public func setTaskHandler(for taskType: BackgroundTaskType, handler: @escaping () async -> Void) {
        taskHandlers[taskType.identifier] = handler
    }
    
    /// 调度后台任务
    public func scheduleTask(_ taskType: BackgroundTaskType, earliestBeginDate: Date? = nil) {
        let request: BGTaskRequest
        
        switch taskType {
        case .fileTransfer:
            // 文件传输使用处理任务（允许更长时间）
            let processingRequest = BGProcessingTaskRequest(identifier: taskType.identifier)
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            request = processingRequest
            
        default:
            // 其他任务使用刷新任务
            let refreshRequest = BGAppRefreshTaskRequest(identifier: taskType.identifier)
            request = refreshRequest
        }
        
        request.earliestBeginDate = earliestBeginDate ?? Date(timeIntervalSinceNow: 15 * 60) // 默认15分钟后
        
        do {
            try BGTaskScheduler.shared.submit(request)
            SkyBridgeLogger.shared.info("📅 已调度后台任务: \(taskType.identifier)")
        } catch {
            SkyBridgeLogger.shared.error("❌ 调度后台任务失败: \(error.localizedDescription)")
        }
    }
    
    /// 取消后台任务
    public func cancelTask(_ taskType: BackgroundTaskType) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskType.identifier)
        SkyBridgeLogger.shared.info("🚫 已取消后台任务: \(taskType.identifier)")
    }
    
    /// 取消所有后台任务
    public func cancelAllTasks() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
        SkyBridgeLogger.shared.info("🚫 已取消所有后台任务")
    }
    
    /// 请求后台执行时间
    #if canImport(UIKit)
    public func beginBackgroundTask(name: String, expirationHandler: (() -> Void)? = nil) -> UIBackgroundTaskIdentifier {
        let taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
            expirationHandler?()
        }
        
        SkyBridgeLogger.shared.info("🔄 开始后台任务: \(name)")
        return taskId
    }
    
    /// 结束后台执行
    public func endBackgroundTask(_ taskId: UIBackgroundTaskIdentifier) {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        SkyBridgeLogger.shared.info("✅ 结束后台任务")
    }
    
    /// 获取剩余后台时间
    public var remainingBackgroundTime: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
    #endif
    
    // MARK: - Private Methods
    
    private func handleBackgroundTask(_ task: BGTask, type: BackgroundTaskType) async {
        SkyBridgeLogger.shared.info("🔄 执行后台任务: \(type.identifier)")

        let completionGate = TaskCompletionGate()
        let executionTask = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.runBackgroundTaskWork(for: type)
        }

        task.expirationHandler = { [weak self] in
            executionTask.cancel()

            Task { @MainActor [weak self] in
                self?.cancelUnderlyingWork(for: type)
                self?.finishBackgroundTask(
                    task,
                    type: type,
                    success: false,
                    gate: completionGate,
                    logMessage: "⚠️ 后台任务超时: \(type.identifier)"
                )
            }
        }

        let success = await executionTask.value
        finishBackgroundTask(
            task,
            type: type,
            success: success,
            gate: completionGate,
            logMessage: success
                ? "✅ 后台任务完成: \(type.identifier)"
                : "⚠️ 后台任务提前结束: \(type.identifier)"
        )
    }

    private func runBackgroundTaskWork(for type: BackgroundTaskType) async -> Bool {
        if let handler = taskHandlers[type.identifier] {
            await handler()
        } else {
            await executeDefaultTask(type)
        }

        return !Task.isCancelled
    }

    private func finishBackgroundTask(
        _ task: BGTask,
        type: BackgroundTaskType,
        success: Bool,
        gate: TaskCompletionGate,
        logMessage: String
    ) {
        guard gate.complete(task, success: success) else { return }

        if success {
            lastRefreshTime = Date()
        }

        scheduleTask(type)
        SkyBridgeLogger.shared.info(logMessage)
    }
    
    private func executeDefaultTask(_ type: BackgroundTaskType) async {
        switch type {
        case .deviceDiscoveryRefresh:
            await refreshDeviceDiscovery()
            
        case .messageSync:
            await syncOfflineMessages()
            
        case .connectionKeepAlive:
            await keepConnectionAlive()
            
        case .dataCleanup:
            await cleanupData()
            
        case .fileTransfer:
            // 文件传输由 FileTransferManager 处理
            break
        }
    }
    
    private func refreshDeviceDiscovery() async {
        // 刷新设备发现
        let manager = DeviceDiscoveryManager.instance
        var shouldStopDiscovery = false

        defer {
            if shouldStopDiscovery {
                manager.stopDiscovery()
            }
        }

        try? await manager.startDiscovery()
        shouldStopDiscovery = true
        
        // 等待一段时间
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
    }
    
    private func syncOfflineMessages() async {
        // 同步离线消息
        let queue = OfflineMessageQueue.shared
        queue.cleanupExpiredMessages()
        
        // 检查连接状态并发送待处理消息
        // 实际实现需要与 P2PConnectionManager 配合
    }
    
    private func keepConnectionAlive() async {
        // 保持连接活跃
        // 发送心跳包
    }
    
    private func cleanupData() async {
        // 清理过期数据
        let queue = OfflineMessageQueue.shared
        queue.cleanupExpiredMessages()
        
        // 清理过期的会话密钥
        let keychain = KeychainManager.shared
        keychain.cleanupExpiredSessionKeys()
    }

    private func cancelUnderlyingWork(for type: BackgroundTaskType) {
        switch type {
        case .deviceDiscoveryRefresh:
            DeviceDiscoveryManager.instance.stopDiscovery()
        case .messageSync, .fileTransfer, .connectionKeepAlive, .dataCleanup:
            break
        }
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isRunningInBackground = true
                self?.onEnterBackground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isRunningInBackground = false
                self?.onEnterForeground()
            }
        }
        #endif
    }
    
    private func onEnterBackground() {
        SkyBridgeLogger.shared.info("📱 应用进入后台")
        
        // 调度后台任务
        if isBackgroundRefreshEnabled {
            scheduleTask(.deviceDiscoveryRefresh)
            scheduleTask(.messageSync)
            scheduleTask(.connectionKeepAlive)
        }
    }
    
    private func onEnterForeground() {
        SkyBridgeLogger.shared.info("📱 应用进入前台")
        
        // 取消不必要的后台任务
        cancelTask(.connectionKeepAlive)
    }
}

#else

@available(macOS 14.0, *)
@MainActor
public class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()

    @Published public var isBackgroundRefreshEnabled: Bool = false
    @Published public private(set) var lastRefreshTime: Date?
    @Published public private(set) var isRunningInBackground: Bool = false

    private init() {}

    public func registerBackgroundTasks() {}
    public func registerTask(_ taskType: BackgroundTaskType) {}
    public func setTaskHandler(for taskType: BackgroundTaskType, handler: @escaping () async -> Void) {}
    public func scheduleTask(_ taskType: BackgroundTaskType, earliestBeginDate: Date? = nil) {}
    public func cancelTask(_ taskType: BackgroundTaskType) {}
    public func cancelAllTasks() {}
}

#endif

// MARK: - Background URL Session

/// 后台 URL 会话管理
@available(iOS 17.0, *)
public final class BackgroundURLSessionManager: NSObject, @unchecked Sendable {
    
    public static let shared = BackgroundURLSessionManager()
    
    /// 后台会话配置
    public lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.skybridge.backgroundTransfer")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    /// 完成处理器（由 AppDelegate 设置）
    public var backgroundCompletionHandler: (() -> Void)?
    
    private override init() {
        super.init()
    }
    
    /// 创建后台下载任务
    public func downloadTask(with url: URL) -> URLSessionDownloadTask {
        backgroundSession.downloadTask(with: url)
    }
    
    /// 创建后台上传任务
    public func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        backgroundSession.uploadTask(with: request, fromFile: fileURL)
    }
}

// MARK: - URLSessionDelegate

@available(iOS 17.0, *)
extension BackgroundURLSessionManager: URLSessionDelegate, URLSessionDownloadDelegate {
    
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 处理下载完成
        SkyBridgeLogger.shared.info("✅ 后台下载完成: \(location.lastPathComponent)")
    }
    
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            SkyBridgeLogger.shared.error("❌ 后台任务失败: \(error.localizedDescription)")
        }
    }
}
