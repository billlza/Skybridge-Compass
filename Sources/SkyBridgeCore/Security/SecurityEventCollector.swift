// MARK: - SecurityEventCollector.swift
// SkyBridge Compass - Benchmark Evidence Chain Fix
// Copyright © 2024 SkyBridge. All rights reserved.
//
// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5
// 测试期间收集 SecurityEvent 的 actor，用于统计 E_handshakeFailed / E_cryptoDowngrade

import Foundation

/// 测试期间收集 SecurityEvent 的 actor
///
/// **用途**：
/// - 在 benchmark/fault injection 测试期间捕获 SecurityEvent
/// - 统计 handshakeFailed 和 cryptoDowngrade 事件数量
/// - 为论文 Table V 提供 E_handshakeFailed / E_cryptoDowngrade 数据
///
/// **Requirements: 1.1, 1.2, 1.3, 1.4, 1.5**
@available(macOS 14.0, iOS 17.0, *)
public actor SecurityEventCollector {
    
 // MARK: - Properties
    
 /// 收集的事件（按类型分组）
    private var eventsByType: [SecurityEventType: [SecurityEvent]] = [:]
    
 /// 订阅 ID（用于取消订阅）
    private var subscriptionId: UUID?
    
 /// 是否正在收集
    private var isCollecting: Bool = false
    
 /// 使用的 emitter（默认使用 shared，测试时可注入）
    private let emitter: SecurityEventEmitter
    
 // MARK: - Initialization
    
 /// 初始化收集器
 /// - Parameter emitter: SecurityEventEmitter 实例（默认使用 shared）
    public init(emitter: SecurityEventEmitter = .shared) {
        self.emitter = emitter
    }
    
 // MARK: - Public API
    
 /// 开始收集（注册到 SecurityEventEmitter）
 ///
 /// **Requirement 1.2**: 当 SecurityEvent 被发射时，collector 应捕获它
    public func startCollecting() async {
        guard !isCollecting else { return }
        
        isCollecting = true
        
 // 订阅 SecurityEventEmitter
        let id = await emitter.subscribe { [weak self] event in
            await self?.handleEvent(event)
        }
        subscriptionId = id
    }
    
 /// 停止收集（取消订阅）
 ///
 /// **Requirement 5.3**: 测试完成时取消订阅以避免内存泄漏
    public func stopCollecting() async {
        guard isCollecting, let id = subscriptionId else { return }
        
        await emitter.unsubscribe(id)
        subscriptionId = nil
        isCollecting = false
    }
    
 /// 获取指定类型的事件数量
 ///
 /// **Requirement 1.3**: 提供按类型查询事件数量的方法
 /// - Parameter type: 事件类型
 /// - Returns: 该类型的事件数量
    public func count(of type: SecurityEventType) -> Int {
        eventsByType[type]?.count ?? 0
    }
    
 /// 获取 handshakeFailed 事件数量
 ///
 /// **Requirement 2.1**: CSV 输出应包含 E_handshakeFailed 列
    public var handshakeFailedCount: Int {
        count(of: .handshakeFailed)
    }
    
 /// 获取 cryptoDowngrade 事件数量
 ///
 /// **Requirement 2.2**: CSV 输出应包含 E_cryptoDowngrade 列
    public var cryptoDowngradeCount: Int {
        count(of: .cryptoDowngrade)
    }
    
 /// 重置所有收集的事件
 ///
 /// **Requirement 1.4**: 提供 reset() 方法在测试迭代之间清空事件
    public func reset() {
        eventsByType.removeAll()
    }
    
 /// 获取所有收集的事件
 /// - Returns: 所有收集的事件数组
    public func allEvents() -> [SecurityEvent] {
        eventsByType.values.flatMap { $0 }
    }
    
 /// 获取指定类型的所有事件
 /// - Parameter type: 事件类型
 /// - Returns: 该类型的所有事件
    public func events(of type: SecurityEventType) -> [SecurityEvent] {
        eventsByType[type] ?? []
    }
    
 /// 是否正在收集
    public var collecting: Bool {
        isCollecting
    }
    
 // MARK: - Private Methods
    
 /// 处理接收到的事件
    private func handleEvent(_ event: SecurityEvent) {
        var events = eventsByType[event.type] ?? []
        events.append(event)
        eventsByType[event.type] = events
    }
}
