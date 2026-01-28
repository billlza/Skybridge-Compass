//
// LiveActivityManager.swift
// SkyBridge Compass iOS
//
// 管理灵动岛 Live Activity
// - 自动在连接/断开时更新
// - 传输进度实时更新
// - 未连接时显示天气
//

import Foundation
import ActivityKit

/// 灵动岛活动管理器
@available(iOS 16.2, *)
@MainActor
public final class LiveActivityManager: ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = LiveActivityManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var isActivityActive: Bool = false
    @Published public private(set) var currentState: SkyBridgeActivityAttributes.ContentState
    
    // MARK: - Private Properties
    
    private var currentActivity: Activity<SkyBridgeActivityAttributes>?
    private var updateTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private init() {
        self.currentState = SkyBridgeActivityAttributes.ContentState()
        
        // 检查是否有正在运行的活动
        Task {
            await checkExistingActivities()
        }
    }
    
    // MARK: - Public API
    
    /// 启动灵动岛活动
    public func startActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            SkyBridgeLogger.shared.warning("⚠️ Live Activities 未启用")
            return
        }
        
        // 如果已有活动，先结束
        if currentActivity != nil {
            await endActivity()
        }
        
        let attributes = SkyBridgeActivityAttributes()
        let initialState = currentState
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            isActivityActive = true
            SkyBridgeLogger.shared.info("✅ 灵动岛活动已启动")
            
            // 监听活动状态
            startObservingActivity(activity)
        } catch {
            SkyBridgeLogger.shared.error("❌ 启动灵动岛活动失败: \(error.localizedDescription)")
        }
    }
    
    /// 更新连接状态
    public func updateConnectionStatus(
        isConnected: Bool,
        deviceName: String? = nil,
        cryptoSuite: String? = nil
    ) async {
        currentState.isConnected = isConnected
        currentState.connectedDeviceName = deviceName
        currentState.cryptoSuite = cryptoSuite
        
        if !isConnected {
            currentState.isTransferring = false
            currentState.transferProgress = 0
            currentState.transferFileName = nil
            currentState.transferSpeed = nil
        }
        
        await updateActivity()
    }
    
    /// 更新传输进度
    public func updateTransferProgress(
        fileName: String,
        progress: Double,
        direction: SkyBridgeActivityAttributes.TransferDirection,
        speed: String? = nil
    ) async {
        currentState.isTransferring = progress < 1.0 && progress > 0
        currentState.transferFileName = fileName
        currentState.transferProgress = min(1.0, max(0, progress))
        currentState.transferDirection = direction
        currentState.transferSpeed = speed
        
        await updateActivity()
    }
    
    /// 传输完成
    public func transferCompleted() async {
        currentState.isTransferring = false
        currentState.transferProgress = 0
        currentState.transferFileName = nil
        currentState.transferSpeed = nil
        currentState.transferDirection = .none
        
        await updateActivity()
    }
    
    /// 更新天气信息（未连接时显示）
    public func updateWeather(
        condition: String,
        temperature: Int,
        description: String
    ) async {
        currentState.weatherCondition = condition
        currentState.temperature = temperature
        currentState.weatherDescription = description
        
        // 只在未连接时更新显示
        if !currentState.isConnected {
            await updateActivity()
        }
    }
    
    /// 结束活动
    public func endActivity() async {
        guard let activity = currentActivity else { return }
        
        await activity.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
        isActivityActive = false
        
        SkyBridgeLogger.shared.info("🛑 灵动岛活动已结束")
    }
    
    // MARK: - Private Methods
    
    private func updateActivity() async {
        guard let activity = currentActivity else {
            // 如果没有活动但需要显示，自动启动
            if currentState.isConnected || !currentState.weatherCondition.isEmpty {
                await startActivity()
            }
            return
        }
        
        await activity.update(
            ActivityContent(state: currentState, staleDate: nil)
        )
    }
    
    private func checkExistingActivities() async {
        for activity in Activity<SkyBridgeActivityAttributes>.activities {
            // 恢复现有活动
            currentActivity = activity
            isActivityActive = true
            currentState = activity.content.state
            startObservingActivity(activity)
            break
        }
    }
    
    private func startObservingActivity(_ activity: Activity<SkyBridgeActivityAttributes>) {
        updateTask?.cancel()
        updateTask = Task {
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    await MainActor.run {
                        self.currentActivity = nil
                        self.isActivityActive = false
                    }
                    break
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

@available(iOS 16.2, *)
extension LiveActivityManager {
    
    /// 从 WeatherInfo 更新天气
    public func updateWeather(from info: WeatherInfo) async {
        await updateWeather(
            condition: info.condition.iconName,
            temperature: Int(info.temperature),
            description: info.condition.rawValue
        )
    }
    
    /// 快速设置为已连接状态
    public func setConnected(deviceName: String, cryptoSuite: String) async {
        await updateConnectionStatus(
            isConnected: true,
            deviceName: deviceName,
            cryptoSuite: cryptoSuite
        )
    }
    
    /// 快速设置为断开状态
    public func setDisconnected() async {
        await updateConnectionStatus(isConnected: false)
    }
}

// MARK: - Integration Helpers

@available(iOS 16.2, *)
extension LiveActivityManager {
    
    /// 自动集成：监听连接状态变化
    public func bindToConnectionManager(_ connectionManager: P2PConnectionManager) {
        // 这个方法由调用方在合适的时机调用
        // 通常在 App 启动时绑定
        
        // 示例：监听连接状态
        // connectionManager.$activeConnections
        //     .receive(on: DispatchQueue.main)
        //     .sink { [weak self] connections in
        //         Task {
        //             if let conn = connections.first {
        //                 await self?.setConnected(deviceName: conn.device.name, cryptoSuite: "ML-KEM-768")
        //             } else {
        //                 await self?.setDisconnected()
        //             }
        //         }
        //     }
        //     .store(in: &cancellables)
    }
}

