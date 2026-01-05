import Foundation
import os.log

/// 行为分析器 - 用于检测人机行为差异
///
/// 通过分析用户的滑动轨迹、点击行为等特征，识别机器人行为
/// 主要用于滑动验证码的验证
@available(macOS 14.0, *)
public actor BehaviorAnalyzer {
    
 // MARK: - 单例
    
    public static let shared = BehaviorAnalyzer()
    
 // MARK: - 数据模型
    
 /// 轨迹点
    public struct TrackPoint: Sendable, Codable {
        public let x: Double
        public let y: Double
        public let timestamp: TimeInterval  // 相对于开始时间的毫秒数
        
        public init(x: Double, y: Double, timestamp: TimeInterval) {
            self.x = x
            self.y = y
            self.timestamp = timestamp
        }
    }
    
 /// 滑动轨迹
    public struct SlideTrack: Sendable, Codable {
        public let points: [TrackPoint]
        public let startTime: Date
        public let endTime: Date
        public let targetX: Double  // 目标位置X
        public let actualX: Double  // 实际滑动到的位置X
        
        public init(points: [TrackPoint], startTime: Date, endTime: Date, targetX: Double, actualX: Double) {
            self.points = points
            self.startTime = startTime
            self.endTime = endTime
            self.targetX = targetX
            self.actualX = actualX
        }
        
 /// 滑动总时长（毫秒）
        public var duration: TimeInterval {
            endTime.timeIntervalSince(startTime) * 1000
        }
        
 /// 滑动距离
        public var distance: Double {
            guard let first = points.first, let last = points.last else { return 0 }
            return sqrt(pow(last.x - first.x, 2) + pow(last.y - first.y, 2))
        }
        
 /// 位置误差
        public var positionError: Double {
            abs(actualX - targetX)
        }
    }
    
 /// 分析结果
    public struct AnalysisResult: Sendable {
        public let isHuman: Bool
        public let confidence: Double  // 0.0 - 1.0
        public let score: Double       // 综合评分
        public let details: AnalysisDetails
        public let reason: String?
        
        public struct AnalysisDetails: Sendable {
            public let durationScore: Double
            public let smoothnessScore: Double
            public let velocityScore: Double
            public let accelerationScore: Double
            public let positionScore: Double
            public let entropyScore: Double
        }
    }
    
 /// 分析配置
    public struct AnalysisConfig: Sendable {
 /// 最小滑动时长（毫秒）
        public let minDuration: TimeInterval
 /// 最大滑动时长（毫秒）
        public let maxDuration: TimeInterval
 /// 位置误差容忍度（像素）
        public let positionTolerance: Double
 /// 最小轨迹点数
        public let minTrackPoints: Int
 /// 人类判定阈值
        public let humanThreshold: Double
        
        public static let `default` = AnalysisConfig(
            minDuration: 200,
            maxDuration: 5000,
            positionTolerance: 5,
            minTrackPoints: 10,
            humanThreshold: 0.6
        )
        
        public static let strict = AnalysisConfig(
            minDuration: 300,
            maxDuration: 4000,
            positionTolerance: 3,
            minTrackPoints: 15,
            humanThreshold: 0.7
        )
    }
    
 // MARK: - 属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "BehaviorAnalyzer")
    private var config: AnalysisConfig
    
 // MARK: - 初始化
    
    private init(config: AnalysisConfig = .default) {
        self.config = config
    }
    
 /// 更新配置
    public func updateConfig(_ newConfig: AnalysisConfig) {
        self.config = newConfig
    }
    
 // MARK: - 核心分析方法
    
 /// 分析滑动轨迹
 /// - Parameter track: 滑动轨迹
 /// - Returns: 分析结果
    public func analyzeSlideTrack(_ track: SlideTrack) -> AnalysisResult {
        logger.info("开始分析滑动轨迹: 点数=\(track.points.count), 时长=\(track.duration)ms")
        
 // 基础检查
        if track.points.count < config.minTrackPoints {
            logger.warning("轨迹点数不足: \(track.points.count) < \(self.config.minTrackPoints)")
            return AnalysisResult(
                isHuman: false,
                confidence: 0.9,
                score: 0,
                details: .empty,
                reason: "轨迹数据不足"
            )
        }
        
 // 计算各项评分
        let durationScore = calculateDurationScore(track.duration)
        let smoothnessScore = calculateSmoothnessScore(track.points)
        let velocityScore = calculateVelocityScore(track.points)
        let accelerationScore = calculateAccelerationScore(track.points)
        let positionScore = calculatePositionScore(track.positionError)
        let entropyScore = calculateEntropyScore(track.points)
        
 // 综合评分（加权平均）
        let weights: [Double] = [0.15, 0.20, 0.15, 0.20, 0.15, 0.15]
        let scores = [durationScore, smoothnessScore, velocityScore, accelerationScore, positionScore, entropyScore]
        let totalScore = zip(weights, scores).reduce(0.0) { $0 + $1.0 * $1.1 }
        
        let details = AnalysisResult.AnalysisDetails(
            durationScore: durationScore,
            smoothnessScore: smoothnessScore,
            velocityScore: velocityScore,
            accelerationScore: accelerationScore,
            positionScore: positionScore,
            entropyScore: entropyScore
        )
        
        let isHuman = totalScore >= config.humanThreshold
        let confidence = calculateConfidence(totalScore)
        
        logger.info("分析完成: 评分=\(String(format: "%.2f", totalScore)), 是否人类=\(isHuman)")
        
        return AnalysisResult(
            isHuman: isHuman,
            confidence: confidence,
            score: totalScore,
            details: details,
            reason: isHuman ? nil : generateRejectionReason(details)
        )
    }
    
 // MARK: - 评分计算
    
 /// 计算时长评分
    private func calculateDurationScore(_ duration: TimeInterval) -> Double {
 // 时长过短或过长都可疑
        if duration < config.minDuration {
            return 0.1  // 太快，可能是脚本
        }
        if duration > config.maxDuration {
            return 0.3  // 太慢，可能是调试或脚本
        }
        
 // 正常范围内，越接近中间值越高分
        let optimalDuration = (config.minDuration + config.maxDuration) / 2
        let deviation = abs(duration - optimalDuration) / optimalDuration
        return max(0.3, 1.0 - deviation * 0.5)
    }
    
 /// 计算平滑度评分
 /// - 机器人轨迹通常过于平滑（直线或完美曲线）
    private func calculateSmoothnessScore(_ points: [TrackPoint]) -> Double {
        guard points.count >= 3 else { return 0.5 }
        
        var totalAngleChange: Double = 0
        var angleChanges: [Double] = []
        
        for i in 1..<(points.count - 1) {
            let p1 = points[i - 1]
            let p2 = points[i]
            let p3 = points[i + 1]
            
 // 计算方向变化角度
            let angle1 = atan2(p2.y - p1.y, p2.x - p1.x)
            let angle2 = atan2(p3.y - p2.y, p3.x - p2.x)
            var angleDiff = abs(angle2 - angle1)
            
 // 归一化到 [0, π]
            if angleDiff > .pi {
                angleDiff = 2 * .pi - angleDiff
            }
            
            angleChanges.append(angleDiff)
            totalAngleChange += angleDiff
        }
        
 // 计算角度变化的标准差
        let avgAngleChange = totalAngleChange / Double(angleChanges.count)
        let variance = angleChanges.reduce(0.0) { $0 + pow($1 - avgAngleChange, 2) } / Double(angleChanges.count)
        let stdDev = sqrt(variance)
        
 // 人类轨迹有适度的抖动，不会太平滑也不会太乱
 // 标准差太小（太平滑）或太大（太乱）都扣分
        if stdDev < 0.01 {
            return 0.2  // 过于平滑，可能是脚本
        }
        if stdDev > 0.5 {
            return 0.4  // 过于杂乱，可能是随机生成
        }
        
 // 适中的抖动给高分
        return min(1.0, 0.5 + stdDev * 2)
    }
    
 /// 计算速度评分
    private func calculateVelocityScore(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0.5 }
        
        var velocities: [Double] = []
        
        for i in 1..<points.count {
            let p1 = points[i - 1]
            let p2 = points[i]
            
            let distance = sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
            let timeDiff = p2.timestamp - p1.timestamp
            
            if timeDiff > 0 {
                velocities.append(distance / timeDiff)
            }
        }
        
        guard !velocities.isEmpty else { return 0.5 }
        
 // 计算速度的变异系数（标准差/平均值）
        let avgVelocity = velocities.reduce(0, +) / Double(velocities.count)
        let variance = velocities.reduce(0.0) { $0 + pow($1 - avgVelocity, 2) } / Double(velocities.count)
        let stdDev = sqrt(variance)
        let cv = avgVelocity > 0 ? stdDev / avgVelocity : 0
        
 // 人类的速度变化有一定规律，不会完全均匀也不会太随机
        if cv < 0.1 {
            return 0.3  // 速度太均匀，可能是脚本
        }
        if cv > 1.5 {
            return 0.4  // 速度变化太大
        }
        
        return min(1.0, 0.5 + cv * 0.5)
    }
    
 /// 计算加速度评分
    private func calculateAccelerationScore(_ points: [TrackPoint]) -> Double {
        guard points.count >= 3 else { return 0.5 }
        
        var velocities: [Double] = []
        var timestamps: [TimeInterval] = []
        
        for i in 1..<points.count {
            let p1 = points[i - 1]
            let p2 = points[i]
            
            let distance = sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
            let timeDiff = p2.timestamp - p1.timestamp
            
            if timeDiff > 0 {
                velocities.append(distance / timeDiff)
                timestamps.append(p2.timestamp)
            }
        }
        
        guard velocities.count >= 2 else { return 0.5 }
        
        var accelerations: [Double] = []
        for i in 1..<velocities.count {
            let timeDiff = timestamps[i] - timestamps[i - 1]
            if timeDiff > 0 {
                accelerations.append((velocities[i] - velocities[i - 1]) / timeDiff)
            }
        }
        
        guard !accelerations.isEmpty else { return 0.5 }
        
 // 检查是否有明显的加速-减速模式（人类特征）
        let hasAcceleration = accelerations.contains { $0 > 0.01 }
        let hasDeceleration = accelerations.contains { $0 < -0.01 }
        
        if hasAcceleration && hasDeceleration {
            return 0.9  // 有加速-减速模式，很可能是人类
        }
        
 // 计算加速度的正负变化次数
        var signChanges = 0
        for i in 1..<accelerations.count {
            if (accelerations[i] > 0 && accelerations[i - 1] < 0) ||
               (accelerations[i] < 0 && accelerations[i - 1] > 0) {
                signChanges += 1
            }
        }
        
        let changeRatio = Double(signChanges) / Double(accelerations.count)
        
 // 适度的加速度变化给高分
        if changeRatio < 0.1 {
            return 0.3  // 加速度太平稳
        }
        if changeRatio > 0.8 {
            return 0.4  // 加速度变化太频繁
        }
        
        return min(1.0, 0.5 + changeRatio)
    }
    
 /// 计算位置精度评分
    private func calculatePositionScore(_ error: Double) -> Double {
 // 误差在容忍范围内给满分
        if error <= config.positionTolerance {
            return 1.0
        }
        
 // 误差越大，分数越低
        let normalizedError = error / config.positionTolerance
        return max(0.0, 1.0 - (normalizedError - 1) * 0.2)
    }
    
 /// 计算熵值评分（轨迹的不可预测性）
    private func calculateEntropyScore(_ points: [TrackPoint]) -> Double {
        guard points.count >= 5 else { return 0.5 }
        
 // 计算X坐标差值的分布熵
        var xDiffs: [Int] = []
        for i in 1..<points.count {
            let diff = Int((points[i].x - points[i - 1].x) * 10)  // 量化到整数
            xDiffs.append(diff)
        }
        
 // 统计各差值的频率
        var frequency: [Int: Int] = [:]
        for diff in xDiffs {
            frequency[diff, default: 0] += 1
        }
        
 // 计算香农熵
        let total = Double(xDiffs.count)
        var entropy: Double = 0
        for (_, count) in frequency {
            let p = Double(count) / total
            if p > 0 {
                entropy -= p * log2(p)
            }
        }
        
 // 归一化熵值
        let maxEntropy = log2(total)
        let normalizedEntropy = maxEntropy > 0 ? entropy / maxEntropy : 0
        
 // 人类轨迹的熵值应该在中等范围
        if normalizedEntropy < 0.2 {
            return 0.3  // 太规律，可能是脚本
        }
        if normalizedEntropy > 0.9 {
            return 0.4  // 太随机，可能是噪声
        }
        
        return min(1.0, normalizedEntropy + 0.3)
    }
    
 /// 计算置信度
    private func calculateConfidence(_ score: Double) -> Double {
 // 分数越接近阈值，置信度越低
        let distanceFromThreshold = abs(score - config.humanThreshold)
        return min(1.0, 0.5 + distanceFromThreshold)
    }
    
 /// 生成拒绝原因
    private func generateRejectionReason(_ details: AnalysisResult.AnalysisDetails) -> String {
        var reasons: [String] = []
        
        if details.durationScore < 0.4 {
            reasons.append("滑动速度异常")
        }
        if details.smoothnessScore < 0.4 {
            reasons.append("轨迹过于规则")
        }
        if details.velocityScore < 0.4 {
            reasons.append("速度变化异常")
        }
        if details.accelerationScore < 0.4 {
            reasons.append("加速度模式异常")
        }
        if details.positionScore < 0.5 {
            reasons.append("位置精度不足")
        }
        if details.entropyScore < 0.4 {
            reasons.append("轨迹可预测性过高")
        }
        
        if reasons.isEmpty {
            return "行为特征异常"
        }
        
        return reasons.joined(separator: "、")
    }
}

// MARK: - 扩展

@available(macOS 14.0, *)
extension BehaviorAnalyzer.AnalysisResult.AnalysisDetails {
    static let empty = BehaviorAnalyzer.AnalysisResult.AnalysisDetails(
        durationScore: 0,
        smoothnessScore: 0,
        velocityScore: 0,
        accelerationScore: 0,
        positionScore: 0,
        entropyScore: 0
    )
}

// MARK: - 轨迹记录器

/// 轨迹记录器 - 用于收集用户的滑动轨迹
@available(macOS 14.0, *)
public class TrackRecorder: ObservableObject {
    
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var points: [BehaviorAnalyzer.TrackPoint] = []
    
    private var startTime: Date?
    
    public init() {}
    
 /// 开始记录
    public func startRecording() {
        isRecording = true
        points = []
        startTime = Date()
    }
    
 /// 记录一个点
    public func recordPoint(x: Double, y: Double) {
        guard isRecording, let startTime = startTime else { return }
        
        let timestamp = Date().timeIntervalSince(startTime) * 1000  // 毫秒
        let point = BehaviorAnalyzer.TrackPoint(x: x, y: y, timestamp: timestamp)
        points.append(point)
    }
    
 /// 停止记录并返回轨迹
    public func stopRecording(targetX: Double, actualX: Double) -> BehaviorAnalyzer.SlideTrack? {
        guard isRecording, let startTime = startTime else { return nil }
        
        isRecording = false
        
        let track = BehaviorAnalyzer.SlideTrack(
            points: points,
            startTime: startTime,
            endTime: Date(),
            targetX: targetX,
            actualX: actualX
        )
        
        return track
    }
    
 /// 重置
    public func reset() {
        isRecording = false
        points = []
        startTime = nil
    }
}

