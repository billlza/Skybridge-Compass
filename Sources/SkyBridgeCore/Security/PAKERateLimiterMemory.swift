// MARK: - PAKERateLimiterMemory.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.
//
// PAKE 服务内存管理 - 实现有界内存使用的速率限制器
// Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6

import Foundation

// MARK: - PAKERecord

/// PAKE 失败记录
/// - Requirements: 5.1, 5.6
public struct PAKERecord: Sendable {
 /// 标识符 (deviceId/IP)
    public let identifier: String
    
 /// 失败尝试次数
    public let failedAttempts: Int
    
 /// 最后一次尝试时间戳 (用于 LRU 和 TTL)
    public let lastAttemptTimestamp: ContinuousClock.Instant
    
 /// 锁定截止时间 (nil 表示未锁定)
    public let lockoutUntil: ContinuousClock.Instant?
    
 /// 退避级别 (用于指数退避计算)
    public let backoffLevel: Int
    
    public init(
        identifier: String,
        failedAttempts: Int,
        lastAttemptTimestamp: ContinuousClock.Instant,
        lockoutUntil: ContinuousClock.Instant?,
        backoffLevel: Int
    ) {
        self.identifier = identifier
        self.failedAttempts = failedAttempts
        self.lastAttemptTimestamp = lastAttemptTimestamp
        self.lockoutUntil = lockoutUntil
        self.backoffLevel = backoffLevel
    }
    
 /// 创建新记录 (首次失败)
    public static func newRecord(identifier: String, now: ContinuousClock.Instant) -> PAKERecord {
        PAKERecord(
            identifier: identifier,
            failedAttempts: 1,
            lastAttemptTimestamp: now,
            lockoutUntil: nil,
            backoffLevel: 1
        )
    }
    
 /// 增加失败次数
    public func incrementFailure(
        now: ContinuousClock.Instant,
        maxAttempts: Int,
        lockoutDuration: Duration
    ) -> PAKERecord {
        let newAttempts = failedAttempts + 1
        let newBackoffLevel = min(backoffLevel + 1, 10) // 最大退避级别
        
 // 达到最大失败次数，设置锁定
        let newLockout: ContinuousClock.Instant?
        if newAttempts >= maxAttempts {
            newLockout = now + lockoutDuration
        } else {
            newLockout = lockoutUntil
        }
        
        return PAKERecord(
            identifier: identifier,
            failedAttempts: newAttempts,
            lastAttemptTimestamp: now,
            lockoutUntil: newLockout,
            backoffLevel: newBackoffLevel
        )
    }
    
 /// 检查记录是否过期 (TTL)
    public func isExpired(now: ContinuousClock.Instant, ttl: Duration) -> Bool {
        let expirationTime = lastAttemptTimestamp + ttl
        return now >= expirationTime
    }
    
 /// 检查锁定是否过期
    public func isLockoutExpired(now: ContinuousClock.Instant) -> Bool {
        guard let lockout = lockoutUntil else { return true }
        return now >= lockout
    }
}


// MARK: - PAKERateLimiterMemory

/// PAKE 服务内存管理 - 有界内存使用的速率限制器
///
/// 设计要点：
/// - 确定性清理触发 (writesCount % cleanupInterval == 0)
/// - LRU 淘汰 (基于 lastAttemptTimestamp)
/// - TTL 过期 (默认 10 分钟)
/// - 有界内存 (maxRecords 限制)
///
/// Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
public actor PAKERateLimiterMemory {
    
 // MARK: - Properties
    
 /// 安全限制配置
    private let limits: SecurityLimits
    
 /// 失败记录 (identifier -> PAKERecord)
    private var records: [String: PAKERecord] = [:]
    
 /// 写入计数 (用于确定性清理触发)
    private var writesCount: Int = 0
    
 /// 时钟 (用于测试注入)
    private let clock: ContinuousClock
    
 /// 最大失败尝试次数 (达到后锁定)
    private let maxAttempts: Int
    
 /// 锁定持续时间
    private let lockoutDuration: Duration
    
 /// 指数退避基础时间 (秒)
    private let backoffBaseSeconds: Double
    
 /// 指数退避最大时间 (秒)
    private let backoffMaxSeconds: Double
    
 // MARK: - Initialization
    
 /// 初始化 PAKE 速率限制器
 /// - Parameters:
 /// - limits: 安全限制配置
 /// - clock: 时钟 (默认 ContinuousClock，可注入用于测试)
 /// - maxAttempts: 最大失败尝试次数 (默认 5)
 /// - lockoutDuration: 锁定持续时间 (默认 5 分钟)
 /// - backoffBaseSeconds: 指数退避基础时间 (默认 1 秒)
 /// - backoffMaxSeconds: 指数退避最大时间 (默认 60 秒)
    public init(
        limits: SecurityLimits = .default,
        clock: ContinuousClock = ContinuousClock(),
        maxAttempts: Int = 5,
        lockoutDuration: Duration = .seconds(300),
        backoffBaseSeconds: Double = 1.0,
        backoffMaxSeconds: Double = 60.0
    ) {
        self.limits = limits
        self.clock = clock
        self.maxAttempts = maxAttempts
        self.lockoutDuration = lockoutDuration
        self.backoffBaseSeconds = backoffBaseSeconds
        self.backoffMaxSeconds = backoffMaxSeconds
    }
    
 // MARK: - Public Methods
    
 /// 记录失败尝试
 /// - Parameter identifier: 设备/IP 标识符
 /// - Requirements: 5.1, 5.2, 5.6
    public func recordFailedAttempt(identifier: String) {
        let now = clock.now
        
 // 更新或创建记录
        if let existing = records[identifier] {
            records[identifier] = existing.incrementFailure(
                now: now,
                maxAttempts: maxAttempts,
                lockoutDuration: lockoutDuration
            )
        } else {
            records[identifier] = PAKERecord.newRecord(identifier: identifier, now: now)
        }
        
 // 增加写入计数
        writesCount += 1
        
 // 确定性清理触发 (Requirements: 5.2)
        cleanupIfNeeded()
    }
    
 /// 记录成功 (重置记录)
 /// - Parameter identifier: 设备/IP 标识符
    public func recordSuccess(identifier: String) {
        records[identifier] = nil
        
 // 成功也计入写入计数
        writesCount += 1
        cleanupIfNeeded()
    }
    
 /// 检查是否被锁定
 /// - Parameter identifier: 设备/IP 标识符
 /// - Returns: 是否被锁定
 /// - Requirements: 5.4
    public func isLockedOut(identifier: String) -> Bool {
        guard let record = records[identifier] else { return false }
        guard let lockoutUntil = record.lockoutUntil else { return false }
        
        let now = clock.now
        return now < lockoutUntil
    }
    
 /// 获取速率限制状态
 /// - Parameter identifier: 设备/IP 标识符
 /// - Returns: 速率限制结果
    public func checkRateLimit(identifier: String) -> RateLimitResult {
        let now = clock.now
        
        guard let record = records[identifier] else {
            return .allowed
        }
        
 // 检查锁定
        if let lockoutUntil = record.lockoutUntil, now < lockoutUntil {
            let remaining = lockoutUntil - now
            return .lockedOut(until: lockoutUntil, remaining: remaining)
        }

 // 检查指数退避
        let backoffSeconds = calculateBackoff(level: record.backoffLevel)
        let backoffDuration = Duration.seconds(backoffSeconds)
        let nextAllowed = record.lastAttemptTimestamp + backoffDuration
        
        if now < nextAllowed {
            let remaining = nextAllowed - now
            return .rateLimited(retryAfter: remaining)
        }
        
        return .allowed
    }
    
 /// 获取当前记录数 (用于监控和测试)
    public var recordCount: Int {
        records.count
    }
    
 /// 获取当前写入计数 (用于测试)
    public var currentWritesCount: Int {
        writesCount
    }
    
 /// 获取指定标识符的记录 (用于测试)
    public func getRecord(for identifier: String) -> PAKERecord? {
        records[identifier]
    }
    
 // MARK: - Private Methods
    
 /// 确定性清理触发
 /// - Requirements: 5.2
    private func cleanupIfNeeded() {
 // 确定性触发：writesCount % cleanupInterval == 0
        guard writesCount % limits.pakeCleanupInterval == 0 else { return }
        performCleanup()
    }
    
 /// 执行清理
 /// - Requirements: 5.1, 5.3, 5.4, 5.5, 5.6
    private func performCleanup() {
        let now = clock.now
        let ttl = Duration.seconds(limits.pakeRecordTTL)
        
 // 1. 清理所有过期记录 (TTL) - Requirements: 5.1, 5.5
        purgeExpired(now: now, ttl: ttl)
        
 // 2. 清理过期锁定 - Requirements: 5.4
        purgeExpiredLockouts(now: now)
        
 // 3. LRU 淘汰 (如果超过 maxRecords) - Requirements: 5.3, 5.6
        evictOldestIfNeeded()
    }
    
 /// 清理所有过期记录
 /// - Requirements: 5.1, 5.5
    private func purgeExpired(now: ContinuousClock.Instant, ttl: Duration) {
        records = records.filter { _, record in
            !record.isExpired(now: now, ttl: ttl)
        }
    }
    
 /// 清理过期锁定
 /// - Requirements: 5.4
    private func purgeExpiredLockouts(now: ContinuousClock.Instant) {
        for (identifier, record) in records {
            if let lockoutUntil = record.lockoutUntil, now >= lockoutUntil {
 // 锁定过期，重置记录 (保留但清除锁定和失败计数)
                records[identifier] = PAKERecord(
                    identifier: identifier,
                    failedAttempts: 0,
                    lastAttemptTimestamp: record.lastAttemptTimestamp,
                    lockoutUntil: nil,
                    backoffLevel: 0
                )
            }
        }
    }
    
 /// LRU 淘汰
 /// - Requirements: 5.3, 5.6
    private func evictOldestIfNeeded() {
        guard records.count > limits.pakeMaxRecords else { return }
        
 // 按 lastAttemptTimestamp 排序，淘汰最旧的
        let sortedRecords = records.values.sorted { $0.lastAttemptTimestamp < $1.lastAttemptTimestamp }
        let toRemoveCount = records.count - limits.pakeMaxRecords
        
        for i in 0..<toRemoveCount {
            let record = sortedRecords[i]
            records.removeValue(forKey: record.identifier)
        }
    }
    
 /// 计算指数退避时间
    private func calculateBackoff(level: Int) -> Double {
 // 防止 level 过大导致溢出
        let clampedLevel = min(level, 20)
        let backoff = backoffBaseSeconds * pow(2.0, Double(clampedLevel - 1))
        return min(backoff, backoffMaxSeconds)
    }
}

// MARK: - RateLimitResult

/// 速率限制检查结果
public enum RateLimitResult: Sendable, Equatable {
 /// 允许操作
    case allowed
    
 /// 被速率限制 (需要等待)
    case rateLimited(retryAfter: Duration)
    
 /// 被锁定 (达到最大失败次数)
    case lockedOut(until: ContinuousClock.Instant, remaining: Duration)
    
 /// 是否允许
    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}
