import Foundation
import CryptoKit
import os.log

/// 星云ID生成器 - 基于雪花算法优化版的分布式ID生成系统
/// 生成格式：NEBULA-{年份}-{唯一标识}
/// 例如：NEBULA-2025-A1B2C3D4E5F6
@MainActor
public final class NebulaIDGenerator: ObservableObject {
    
 // MARK: - 配置常量
    
 /// ID组件配置
    private struct IDConfiguration {
        static let prefix = "NEBULA"
        static let separator = "-"
        static let timestampBits: UInt64 = 41  // 时间戳位数，支持69年
        static let datacenterBits: UInt64 = 5  // 数据中心位数，支持32个数据中心
        static let workerBits: UInt64 = 5      // 工作节点位数，支持32个工作节点
        static let sequenceBits: UInt64 = 12   // 序列号位数，每毫秒支持4096个ID
        
 // 最大值计算
        static let maxDatacenterId: UInt64 = (1 << datacenterBits) - 1
        static let maxWorkerId: UInt64 = (1 << workerBits) - 1
        static let maxSequence: UInt64 = (1 << sequenceBits) - 1
        
 // 位移量
        static let workerIdShift = sequenceBits
        static let datacenterIdShift = sequenceBits + workerBits
        static let timestampShift = sequenceBits + workerBits + datacenterBits
        
 // 基准时间戳 (2025-01-01 00:00:00 UTC)
        static let epoch: UInt64 = 1735689600000
    }
    
 // MARK: - 错误类型
    
    public enum NebulaIDError: LocalizedError {
        case invalidDatacenterId
        case invalidWorkerId
        case clockMovedBackwards
        case sequenceOverflow
        case generationFailed
        
        public var errorDescription: String? {
            switch self {
            case .invalidDatacenterId:
                return "数据中心ID超出范围 (0-31)"
            case .invalidWorkerId:
                return "工作节点ID超出范围 (0-31)"
            case .clockMovedBackwards:
                return "系统时钟回拨，ID生成暂停"
            case .sequenceOverflow:
                return "序列号溢出，请稍后重试"
            case .generationFailed:
                return "ID生成失败"
            }
        }
    }
    
 // MARK: - ID信息结构
    
    public struct NebulaIDInfo: Sendable {
        public let fullId: String           // 完整ID：NEBULA-2025-A1B2C3D4E5F6
        public let rawId: UInt64           // 原始64位ID
        public let year: Int               // 年份
        public let timestamp: UInt64       // 时间戳
        public let datacenterId: UInt64    // 数据中心ID
        public let workerId: UInt64        // 工作节点ID
        public let sequence: UInt64        // 序列号
        public let generatedAt: Date       // 生成时间
        
        public init(fullId: String, rawId: UInt64, year: Int, timestamp: UInt64,
                   datacenterId: UInt64, workerId: UInt64, sequence: UInt64, generatedAt: Date) {
            self.fullId = fullId
            self.rawId = rawId
            self.year = year
            self.timestamp = timestamp
            self.datacenterId = datacenterId
            self.workerId = workerId
            self.sequence = sequence
            self.generatedAt = generatedAt
        }
    }
    
 // MARK: - 属性
    
    public static let shared = NebulaIDGenerator()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "NebulaIDGenerator")
    private let datacenterId: UInt64
    private let workerId: UInt64
    private var lastTimestamp: UInt64 = 0
    private var sequence: UInt64 = 0
    private let lock = NSLock()
    
 // MARK: - 初始化
    
 /// 初始化星云ID生成器
 /// - Parameters:
 /// - datacenterId: 数据中心ID (0-31)
 /// - workerId: 工作节点ID (0-31)
    public init(datacenterId: UInt64 = 1, workerId: UInt64 = 1) {
 // 验证参数范围
        guard datacenterId <= IDConfiguration.maxDatacenterId else {
            logger.error("数据中心ID超出范围: \(datacenterId)")
            self.datacenterId = IDConfiguration.maxDatacenterId
            self.workerId = workerId
            logger.warning("已回退至最大数据中心ID")
            return
        }
        
        guard workerId <= IDConfiguration.maxWorkerId else {
            logger.error("工作节点ID超出范围: \(workerId)")
            self.datacenterId = datacenterId
            self.workerId = IDConfiguration.maxWorkerId
            logger.warning("已回退至最大工作节点ID")
            return
        }
        
        self.datacenterId = datacenterId
        self.workerId = workerId
        
        logger.info("NebulaIDGenerator initialized - DataCenter: \(datacenterId), Worker: \(workerId)")
    }
    
 // MARK: - ID生成
    
 /// 生成新的星云ID
 /// - Returns: 星云ID信息
 /// - Throws: NebulaIDError
    public func generateID() throws -> NebulaIDInfo {
        return try lock.withLock {
            let currentTimestamp = self.getCurrentTimestamp()
            
 // 检查时钟回拨
            if currentTimestamp < self.lastTimestamp {
                self.logger.error("时钟回拨检测: 当前时间 \(currentTimestamp) < 上次时间 \(self.lastTimestamp)")
                throw NebulaIDError.clockMovedBackwards
            }
            
 // 同一毫秒内生成ID
            if currentTimestamp == self.lastTimestamp {
                self.sequence = (self.sequence + 1) & IDConfiguration.maxSequence
                
 // 序列号溢出，等待下一毫秒
                if self.sequence == 0 {
                    let nextTimestamp = self.waitForNextMillisecond(currentTimestamp)
                    return try self.generateIDWithTimestamp(nextTimestamp)
                }
            } else {
 // 新的毫秒，重置序列号
                self.sequence = 0
            }
            
            return try self.generateIDWithTimestamp(currentTimestamp)
        }
    }
    
 /// 批量生成星云ID
 /// - Parameter count: 生成数量 (最大1000)
 /// - Returns: 星云ID信息数组
 /// - Throws: NebulaIDError
    public func generateBatchIDs(count: Int) throws -> [NebulaIDInfo] {
        guard count > 0 && count <= 1000 else {
            throw NebulaIDError.generationFailed
        }
        
        var ids: [NebulaIDInfo] = []
        ids.reserveCapacity(count)
        
        for _ in 0..<count {
            let id = try generateID()
            ids.append(id)
        }
        
        logger.info("批量生成 \(count) 个星云ID")
        return ids
    }
    
 // MARK: - ID解析
    
 /// 解析星云ID
 /// - Parameter nebulaId: 星云ID字符串
 /// - Returns: 解析后的ID信息，如果解析失败返回nil
    public func parseID(_ nebulaId: String) -> NebulaIDInfo? {
 // 验证格式：NEBULA-YYYY-XXXXXXXXXXXX
        let components = nebulaId.components(separatedBy: IDConfiguration.separator)
        guard components.count == 3,
              components[0] == IDConfiguration.prefix,
              let year = Int(components[1]),
              components[2].count == 12 else {
            return nil
        }
        
 // 解码Base36字符串为64位整数
        guard let rawId = UInt64(components[2], radix: 36) else {
            return nil
        }
        
 // 提取各个组件
        let timestamp = (rawId >> IDConfiguration.timestampShift) + IDConfiguration.epoch
        let datacenterId = (rawId >> IDConfiguration.datacenterIdShift) & IDConfiguration.maxDatacenterId
        let workerId = (rawId >> IDConfiguration.workerIdShift) & IDConfiguration.maxWorkerId
        let sequence = rawId & IDConfiguration.maxSequence
        
        let generatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        
        return NebulaIDInfo(
            fullId: nebulaId,
            rawId: rawId,
            year: year,
            timestamp: timestamp,
            datacenterId: datacenterId,
            workerId: workerId,
            sequence: sequence,
            generatedAt: generatedAt
        )
    }
    
 /// 验证星云ID格式
 /// - Parameter nebulaId: 星云ID字符串
 /// - Returns: 是否为有效格式
    public func isValidID(_ nebulaId: String) -> Bool {
        return parseID(nebulaId) != nil
    }
    
 // MARK: - 私有方法
    
 /// 使用指定时间戳生成ID
    private func generateIDWithTimestamp(_ timestamp: UInt64) throws -> NebulaIDInfo {
        self.lastTimestamp = timestamp
        
 // 构建64位ID
        let adjustedTimestamp = timestamp - IDConfiguration.epoch
        let rawId = (adjustedTimestamp << IDConfiguration.timestampShift) |
                   (self.datacenterId << IDConfiguration.datacenterIdShift) |
                   (self.workerId << IDConfiguration.workerIdShift) |
                   self.sequence
        
 // 生成年份
        let currentYear = Calendar.current.component(.year, from: Date())
        
 // 将64位ID转换为Base36字符串（12位）
        let base36String = String(rawId, radix: 36).uppercased().padding(toLength: 12, withPad: "0", startingAt: 0)
        
 // 构建完整ID
        let fullId = "\(IDConfiguration.prefix)\(IDConfiguration.separator)\(currentYear)\(IDConfiguration.separator)\(base36String)"
        
        let generatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        
        let idInfo = NebulaIDInfo(
            fullId: fullId,
            rawId: rawId,
            year: currentYear,
            timestamp: timestamp,
            datacenterId: self.datacenterId,
            workerId: self.workerId,
            sequence: self.sequence,
            generatedAt: generatedAt
        )
        
        self.logger.debug("生成星云ID: \(fullId)")
        return idInfo
    }
    
 /// 获取当前时间戳（毫秒）
    private func getCurrentTimestamp() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1000)
    }
    
 /// 等待下一毫秒
    private func waitForNextMillisecond(_ lastTimestamp: UInt64) -> UInt64 {
        var timestamp = getCurrentTimestamp()
        while timestamp <= lastTimestamp {
            timestamp = getCurrentTimestamp()
        }
        return timestamp
    }
}

// MARK: - 扩展方法

extension NebulaIDGenerator {
    
 /// 生成用户注册ID
 /// - Returns: 用于用户注册的星云ID
    public func generateUserRegistrationID() throws -> NebulaIDInfo {
        let id = try generateID()
        logger.info("生成用户注册ID: \(id.fullId)")
        return id
    }
    
 /// 生成会话ID
 /// - Returns: 用于会话管理的星云ID
    public func generateSessionID() throws -> NebulaIDInfo {
        let id = try generateID()
        logger.info("生成会话ID: \(id.fullId)")
        return id
    }
    
 /// 生成企业ID
 /// - Returns: 用于企业标识的星云ID
    public func generateCompanyID() throws -> NebulaIDInfo {
        let id = try generateID()
        logger.info("生成企业ID: \(id.fullId)")
        return id
    }
}

// MARK: - 统计信息

extension NebulaIDGenerator {
    
 /// ID生成统计信息
    public struct GenerationStats: Sendable {
        public let totalGenerated: UInt64
        public let currentSequence: UInt64
        public let lastTimestamp: UInt64
        public let datacenterId: UInt64
        public let workerId: UInt64
        public let uptime: TimeInterval
        
        public init(totalGenerated: UInt64, currentSequence: UInt64, lastTimestamp: UInt64,
                   datacenterId: UInt64, workerId: UInt64, uptime: TimeInterval) {
            self.totalGenerated = totalGenerated
            self.currentSequence = currentSequence
            self.lastTimestamp = lastTimestamp
            self.datacenterId = datacenterId
            self.workerId = workerId
            self.uptime = uptime
        }
    }
    
 /// 获取生成统计信息
 /// - Returns: 统计信息
    public func getGenerationStats() -> GenerationStats {
        return lock.withLock {
            GenerationStats(
                totalGenerated: self.sequence,
                currentSequence: self.sequence,
                lastTimestamp: self.lastTimestamp,
                datacenterId: self.datacenterId,
                workerId: self.workerId,
                uptime: Date().timeIntervalSince1970
            )
        }
    }
}
