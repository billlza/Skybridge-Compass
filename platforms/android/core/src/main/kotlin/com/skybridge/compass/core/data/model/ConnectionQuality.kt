package com.skybridge.compass.core.data.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 连接质量数据模型
 * 统一的连接质量定义，供所有模块使用
 */
@Parcelize
@Serializable
data class ConnectionQuality(
    val quality: Quality,
    val score: Float, // 0.0 - 1.0
    val latency: Long,
    val bandwidth: Long,
    val packetLoss: Float,
    val jitter: Long,
    val signalStrength: Float = 1.0f,
    val stability: Float = 1.0f,
    val recommendation: QualityRecommendation = QualityRecommendation.GOOD
) : Parcelable {
    
    /**
     * 质量等级枚举
     */
    @Serializable
    enum class Quality {
        EXCELLENT,  // 优秀
        GOOD,       // 良好
        FAIR,       // 一般
        POOR,       // 差
        UNKNOWN     // 未知
    }
    
    /**
     * 质量建议枚举
     */
    @Serializable
    enum class QualityRecommendation {
        EXCELLENT,      // 优秀
        GOOD,           // 良好
        FAIR,           // 一般
        POOR,           // 较差
        UNUSABLE        // 不可用
    }
    
    companion object {
        /**
         * 创建默认的连接质量
         */
        fun default() = ConnectionQuality(
            quality = Quality.UNKNOWN,
            score = 0.0f,
            latency = 0L,
            bandwidth = 0L,
            packetLoss = 0.0f,
            jitter = 0L,
            signalStrength = 0.0f,
            stability = 0.0f,
            recommendation = QualityRecommendation.POOR
        )
        
        /**
         * 根据分数创建连接质量
         */
        fun fromScore(score: Float, latency: Long = 0L, bandwidth: Long = 0L): ConnectionQuality {
            val quality = when {
                score >= 0.9f -> Quality.EXCELLENT
                score >= 0.7f -> Quality.GOOD
                score >= 0.5f -> Quality.FAIR
                score >= 0.3f -> Quality.POOR
                else -> Quality.UNKNOWN
            }
            
            val recommendation = when {
                score >= 0.9f -> QualityRecommendation.EXCELLENT
                score >= 0.7f -> QualityRecommendation.GOOD
                score >= 0.5f -> QualityRecommendation.FAIR
                score >= 0.3f -> QualityRecommendation.POOR
                else -> QualityRecommendation.UNUSABLE
            }
            
            return ConnectionQuality(
                quality = quality,
                score = score,
                latency = latency,
                bandwidth = bandwidth,
                packetLoss = 1.0f - score,
                jitter = latency / 10,
                signalStrength = score,
                stability = score,
                recommendation = recommendation
            )
        }
    }
}