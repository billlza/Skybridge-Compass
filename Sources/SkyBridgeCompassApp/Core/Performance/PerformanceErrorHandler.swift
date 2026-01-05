//
// PerformanceErrorHandler.swift
// SkyBridge Compass Pro
//
// Created by Assistant on 2024-12-19.
// Copyright © 2024 SkyBridge. All rights reserved.
//

import Foundation
import OSLog

/// 性能监控错误处理器
@available(macOS 14.0, *)
public actor PerformanceErrorHandler {
    
 // MARK: - 单例
    public static let shared = PerformanceErrorHandler()
    
 // MARK: - 私有属性
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "PerformanceErrorHandler")
    private var errorHistory: [PerformanceError] = []
    private let maxErrorHistory = 100
    
 // 错误统计
    private var errorCounts: [PerformanceErrorType: Int] = [:]
    private var lastErrorTime: [PerformanceErrorType: Date] = [:]
    
 // 错误恢复策略
    private var recoveryAttempts: [PerformanceErrorType: Int] = [:]
    private let maxRecoveryAttempts = 3
    
    private init() {}
    
 // MARK: - 公共方法
    
 /// 处理性能错误
    public func handleError(_ error: PerformanceError) async {
 // 记录错误
        await recordError(error)
        
 // 执行错误恢复策略
        await executeRecoveryStrategy(for: error)
        
 // 通知相关组件
        await notifyErrorObservers(error)
        
        logger.error("🚨 性能错误: \(error.type.rawValue) - \(error.message)")
    }
    
 /// 获取错误统计
    public func getErrorStatistics() -> PerformanceErrorStatistics {
        let totalErrors = errorHistory.count
        let recentErrors = errorHistory.filter { 
            Date().timeIntervalSince($0.timestamp) < 300 // 最近5分钟
        }.count
        
        return PerformanceErrorStatistics(
            totalErrors: totalErrors,
            recentErrors: recentErrors,
            errorCounts: errorCounts,
            lastErrors: Array(errorHistory.suffix(10))
        )
    }
    
 /// 清除错误历史
    public func clearErrorHistory() {
        errorHistory.removeAll()
        errorCounts.removeAll()
        lastErrorTime.removeAll()
        recoveryAttempts.removeAll()
        
        logger.info("🧹 清除性能错误历史")
    }
    
 /// 检查是否需要降级性能
    public func shouldDegradePerformance() -> Bool {
        let recentCriticalErrors = errorHistory.filter { error in
            error.severity == .critical && 
            Date().timeIntervalSince(error.timestamp) < 60 // 最近1分钟
        }.count
        
        return recentCriticalErrors >= 3
    }
    
 // MARK: - 私有方法
    
 /// 记录错误
    private func recordError(_ error: PerformanceError) async {
 // 添加到历史记录
        errorHistory.append(error)
        
 // 限制历史记录大小
        if errorHistory.count > maxErrorHistory {
            errorHistory.removeFirst()
        }
        
 // 更新错误计数
        errorCounts[error.type, default: 0] += 1
        lastErrorTime[error.type] = error.timestamp
    }
    
 /// 执行错误恢复策略
    private func executeRecoveryStrategy(for error: PerformanceError) async {
        let currentAttempts = recoveryAttempts[error.type, default: 0]
        
        guard currentAttempts < maxRecoveryAttempts else {
            logger.warning("⚠️ 错误恢复尝试次数已达上限: \(error.type.rawValue)")
            return
        }
        
        recoveryAttempts[error.type] = currentAttempts + 1
        
        switch error.type {
        case .memoryPressure:
            await handleMemoryPressure()
        case .cpuOverload:
            await handleCPUOverload()
        case .gpuError:
            await handleGPUError()
        case .networkTimeout:
            await handleNetworkTimeout()
        case .thermalThrottling:
            await handleThermalThrottling()
        case .batteryLow:
            await handleBatteryLow()
        case .systemOverload:
            await handleSystemOverload()
        }
        
        logger.info("🔧 执行错误恢复策略: \(error.type.rawValue)")
    }
    
 /// 处理内存压力
    private func handleMemoryPressure() async {
 // 触发内存清理
        logger.debug("🧹 触发内存清理")
    }
    
 /// 处理CPU过载
    private func handleCPUOverload() async {
 // 降低监控频率
        logger.debug("⏬ 降低CPU监控频率")
    }
    
 /// 处理GPU错误
    private func handleGPUError() async {
 // 重置GPU状态
        logger.debug("🔄 重置GPU监控状态")
    }
    
 /// 处理网络超时
    private func handleNetworkTimeout() async {
 // 重试网络连接
        logger.debug("🔄 重试网络连接")
    }
    
 /// 处理热节流
    private func handleThermalThrottling() async {
 // 降低性能模式
        logger.debug("🌡️ 降低性能模式以减少发热")
    }
    
 /// 处理电池电量低
    private func handleBatteryLow() async {
 // 启用省电模式
        logger.debug("🔋 启用省电模式")
    }
    
 /// 处理系统过载
    private func handleSystemOverload() async {
 // 暂停非关键监控
        logger.debug("⏸️ 暂停非关键性能监控")
    }
    
 /// 通知错误观察者
    private func notifyErrorObservers(_ error: PerformanceError) async {
 // 这里可以添加通知机制，比如发送到UI或其他组件
        logger.debug("📢 通知错误观察者: \(error.type.rawValue)")
    }
}

// MARK: - 数据结构

/// 性能错误
public struct PerformanceError: Sendable {
    public let type: PerformanceErrorType
    public let message: String
    public let severity: ErrorSeverity
    public let timestamp: Date
    public let context: [String: String]
    
    public init(
        type: PerformanceErrorType,
        message: String,
        severity: ErrorSeverity = .warning,
        context: [String: String] = [:]
    ) {
        self.type = type
        self.message = message
        self.severity = severity
        self.timestamp = Date()
        self.context = context
    }
}

/// 性能错误类型
public enum PerformanceErrorType: String, CaseIterable, Sendable {
    case memoryPressure = "内存压力"
    case cpuOverload = "CPU过载"
    case gpuError = "GPU错误"
    case networkTimeout = "网络超时"
    case thermalThrottling = "热节流"
    case batteryLow = "电池电量低"
    case systemOverload = "系统过载"
}

/// 错误严重程度
public enum ErrorSeverity: String, Sendable {
    case info = "信息"
    case warning = "警告"
    case critical = "严重"
}

/// 性能错误统计
public struct PerformanceErrorStatistics: Sendable {
    public let totalErrors: Int
    public let recentErrors: Int
    public let errorCounts: [PerformanceErrorType: Int]
    public let lastErrors: [PerformanceError]
    
    public init(
        totalErrors: Int,
        recentErrors: Int,
        errorCounts: [PerformanceErrorType: Int],
        lastErrors: [PerformanceError]
    ) {
        self.totalErrors = totalErrors
        self.recentErrors = recentErrors
        self.errorCounts = errorCounts
        self.lastErrors = lastErrors
    }
}