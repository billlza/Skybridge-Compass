import Foundation
import OSLog

/// NebulaIDGenerator（与 macOS 端一致）
/// 生成格式：NEBULA-{年份}-{唯一标识}，例如：NEBULA-2025-A1B2C3D4E5F6
@MainActor
public final class NebulaIDGenerator: ObservableObject {
    private struct IDConfiguration {
        static let prefix = "NEBULA"
        static let separator = "-"
        static let timestampBits: UInt64 = 41
        static let datacenterBits: UInt64 = 5
        static let workerBits: UInt64 = 5
        static let sequenceBits: UInt64 = 12

        static let maxDatacenterId: UInt64 = (1 << datacenterBits) - 1
        static let maxWorkerId: UInt64 = (1 << workerBits) - 1
        static let maxSequence: UInt64 = (1 << sequenceBits) - 1

        static let workerIdShift = sequenceBits
        static let datacenterIdShift = sequenceBits + workerBits
        static let timestampShift = sequenceBits + workerBits + datacenterBits

        // 基准时间戳 (2025-01-01 00:00:00 UTC)
        static let epoch: UInt64 = 1_735_689_600_000
    }

    public enum NebulaIDError: LocalizedError {
        case clockMovedBackwards
        case generationFailed

        public var errorDescription: String? {
            switch self {
            case .clockMovedBackwards: return "系统时钟回拨，ID生成暂停"
            case .generationFailed: return "ID生成失败"
            }
        }
    }

    public struct NebulaIDInfo: Sendable, Equatable {
        public let fullId: String
        public let rawId: UInt64
        public let year: Int
        public let timestamp: UInt64
        public let datacenterId: UInt64
        public let workerId: UInt64
        public let sequence: UInt64
        public let generatedAt: Date
    }

    public static let shared = NebulaIDGenerator()

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "NebulaIDGenerator")
    private let datacenterId: UInt64
    private let workerId: UInt64
    private var lastTimestamp: UInt64 = 0
    private var sequence: UInt64 = 0
    private let lock = NSLock()

    public init(datacenterId: UInt64 = 1, workerId: UInt64 = 1) {
        self.datacenterId = min(datacenterId, IDConfiguration.maxDatacenterId)
        self.workerId = min(workerId, IDConfiguration.maxWorkerId)
        logger.info("NebulaIDGenerator initialized - DataCenter: \(self.datacenterId), Worker: \(self.workerId)")
    }

    public func generateID() throws -> NebulaIDInfo {
        try lock.withLock {
            let currentTimestamp = self.getCurrentTimestamp()

            if currentTimestamp < self.lastTimestamp {
                self.logger.error("时钟回拨检测: 当前时间 \(currentTimestamp) < 上次时间 \(self.lastTimestamp)")
                throw NebulaIDError.clockMovedBackwards
            }

            if currentTimestamp == self.lastTimestamp {
                self.sequence = (self.sequence + 1) & IDConfiguration.maxSequence
                if self.sequence == 0 {
                    let nextTimestamp = self.waitForNextMillisecond(currentTimestamp)
                    return try self.generateIDWithTimestamp(nextTimestamp)
                }
            } else {
                self.sequence = 0
            }

            return try self.generateIDWithTimestamp(currentTimestamp)
        }
    }

    public func generateUserRegistrationID() throws -> NebulaIDInfo {
        let id = try generateID()
        logger.info("生成用户注册ID: \(id.fullId)")
        return id
    }

    private func generateIDWithTimestamp(_ timestamp: UInt64) throws -> NebulaIDInfo {
        lastTimestamp = timestamp

        let adjustedTimestamp = timestamp - IDConfiguration.epoch
        let rawId = (adjustedTimestamp << IDConfiguration.timestampShift)
        | (datacenterId << IDConfiguration.datacenterIdShift)
        | (workerId << IDConfiguration.workerIdShift)
        | sequence

        let currentYear = Calendar.current.component(.year, from: Date())
        let base36String = String(rawId, radix: 36).uppercased().padding(toLength: 12, withPad: "0", startingAt: 0)
        let fullId = "\(IDConfiguration.prefix)\(IDConfiguration.separator)\(currentYear)\(IDConfiguration.separator)\(base36String)"
        let generatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)

        return NebulaIDInfo(
            fullId: fullId,
            rawId: rawId,
            year: currentYear,
            timestamp: timestamp,
            datacenterId: datacenterId,
            workerId: workerId,
            sequence: sequence,
            generatedAt: generatedAt
        )
    }

    private func getCurrentTimestamp() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func waitForNextMillisecond(_ lastTimestamp: UInt64) -> UInt64 {
        var timestamp = getCurrentTimestamp()
        while timestamp <= lastTimestamp {
            timestamp = getCurrentTimestamp()
        }
        return timestamp
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

