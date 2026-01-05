import Foundation
import Network

/// 画质与成本决策策略层
/// 统一管理基于场景、用户档位和AI额度的画质决策
public final class QualityGovernor: @unchecked Sendable {
    
    public static let shared = QualityGovernor()
    
    private init() {}
    
 // MARK: - 基础类型定义
    
 /// 连接场景
    public enum ConnectionScenario {
        case localNearField      // 本地近场 (P2P/LAN)
        case remoteRelay         // 远场中继 (Relay)
        case remoteP2P           // 远场直连 (P2P)
    }
    
 /// 用户档位
    public enum UserTier {
        case free                // 免费用户
        case pro                 // 专业版
        case vip                 // VIP/企业版
    }
    
 /// AI 任务额度状态
    public enum AIQuotaStatus {
        case sufficient          // 充足
        case low                 // 低额度
        case exhausted           // 耗尽
    }
    
 /// 画质配置文件
    public struct QualityProfile: Sendable {
 /// 最大码率 (bps)
        public let maxBitrate: Int
 /// 目标帧率 (fps)
        public let targetFPS: Int
 /// 分辨率缩放因子 (0.0 - 1.0)
        public let resolutionScale: Double
 /// 是否启用 HDR
        public let enableHDR: Bool
 /// 是否启用 AI 超分
        public let enableAISuperResolution: Bool
 /// 编码预设 (速度 vs 质量)
        public let encodingPreset: String
        
        public static let balanced = QualityProfile(
            maxBitrate: 8_000_000,
            targetFPS: 60,
            resolutionScale: 1.0,
            enableHDR: false,
            enableAISuperResolution: false,
            encodingPreset: "medium"
        )
    }
    
 // MARK: - 决策接口
    
 /// 根据当前上下文决策画质配置
 /// - Parameters:
 /// - scenario: 连接场景
 /// - tier: 用户档位
 /// - aiQuota: AI 额度状态
 /// - Returns: 推荐的画质配置
    public func decideQuality(
        scenario: ConnectionScenario,
        tier: UserTier,
        aiQuota: AIQuotaStatus
    ) -> QualityProfile {
        
 // 1. 本地近场：总是最高画质，不受额度限制
        if scenario == .localNearField {
            return QualityProfile(
                maxBitrate: 100_000_000, // 100 Mbps
                targetFPS: 120, // 支持高刷
                resolutionScale: 1.0, // 原生分辨率
                enableHDR: true,
                enableAISuperResolution: false, // 本地带宽足够，无需AI超分
                encodingPreset: "fast" // 低延迟优先
            )
        }
        
 // 2. 远场场景：根据档位和额度进行策略分级
        switch tier {
        case .vip:
            return decideVIPRemoteQuality(scenario: scenario, aiQuota: aiQuota)
        case .pro:
            return decideProRemoteQuality(scenario: scenario, aiQuota: aiQuota)
        case .free:
            return decideFreeRemoteQuality(scenario: scenario)
        }
    }
    
 // MARK: - 私有策略实现
    
    private func decideVIPRemoteQuality(scenario: ConnectionScenario, aiQuota: AIQuotaStatus) -> QualityProfile {
 // VIP 用户：优先保证画质
        let useAI = aiQuota != .exhausted
        
        return QualityProfile(
            maxBitrate: scenario == .remoteP2P ? 20_000_000 : 10_000_000,
            targetFPS: 60,
            resolutionScale: 1.0,
            enableHDR: true,
            enableAISuperResolution: useAI, // 有额度时启用AI增强
            encodingPreset: "slow" // 质量优先
        )
    }
    
    private func decideProRemoteQuality(scenario: ConnectionScenario, aiQuota: AIQuotaStatus) -> QualityProfile {
 // Pro 用户：平衡画质与流畅度
        let useAI = aiQuota == .sufficient
        
        return QualityProfile(
            maxBitrate: scenario == .remoteP2P ? 10_000_000 : 5_000_000,
            targetFPS: 60,
            resolutionScale: scenario == .remoteRelay ? 0.75 : 1.0,
            enableHDR: false,
            enableAISuperResolution: useAI,
            encodingPreset: "medium"
        )
    }
    
    private func decideFreeRemoteQuality(scenario: ConnectionScenario) -> QualityProfile {
 // 免费用户：基础画质，节省带宽成本
        return QualityProfile(
            maxBitrate: 2_000_000,
            targetFPS: 30,
            resolutionScale: 0.5, // 降低分辨率
            enableHDR: false,
            enableAISuperResolution: false,
            encodingPreset: "fast"
        )
    }
}
