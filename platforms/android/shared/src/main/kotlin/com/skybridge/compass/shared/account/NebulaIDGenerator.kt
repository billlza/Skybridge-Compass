package com.skybridge.compass.shared.account

import android.util.Log
import java.util.Calendar
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * 星云ID生成器 - 基于雪花算法优化版的分布式ID生成系统
 * 生成格式：NEBULA-{年份}-{唯一标识}
 * 例如：NEBULA-2025-A1B2C3D4E5F6
 *
 * 与 Mac/iOS 版本完全兼容，确保跨平台账号统一
 */
class NebulaIDGenerator private constructor(
    private val datacenterId: ULong,
    private val workerId: ULong
) {

    companion object {
        private const val TAG = "NebulaIDGenerator"

        // ID组件配置
        private const val PREFIX = "NEBULA"
        private const val SEPARATOR = "-"
        private const val TIMESTAMP_BITS: Int = 41    // 时间戳位数，支持69年
        private const val DATACENTER_BITS: Int = 5    // 数据中心位数，支持32个数据中心
        private const val WORKER_BITS: Int = 5        // 工作节点位数，支持32个工作节点
        private const val SEQUENCE_BITS: Int = 12     // 序列号位数，每毫秒支持4096个ID

        // 最大值计算
        private val MAX_DATACENTER_ID: ULong = (1UL shl DATACENTER_BITS) - 1UL
        private val MAX_WORKER_ID: ULong = (1UL shl WORKER_BITS) - 1UL
        private val MAX_SEQUENCE: ULong = (1UL shl SEQUENCE_BITS) - 1UL

        // 位移量
        private const val WORKER_ID_SHIFT: Int = SEQUENCE_BITS
        private const val DATACENTER_ID_SHIFT: Int = SEQUENCE_BITS + WORKER_BITS
        private const val TIMESTAMP_SHIFT: Int = SEQUENCE_BITS + WORKER_BITS + DATACENTER_BITS

        // 基准时间戳 (2025-01-01 00:00:00 UTC) - 与 Mac 版本一致
        private const val EPOCH: ULong = 1735689600000UL

        // 单例实例
        @Volatile
        private var instance: NebulaIDGenerator? = null

        /**
         * 获取共享实例（默认 datacenterId=1, workerId=1）
         */
        val shared: NebulaIDGenerator
            get() = instance ?: synchronized(this) {
                instance ?: NebulaIDGenerator(1UL, 1UL).also { instance = it }
            }

        /**
         * 创建自定义配置的生成器
         */
        fun create(datacenterId: ULong = 1UL, workerId: ULong = 1UL): NebulaIDGenerator {
            val safeDatacenterId = if (datacenterId > MAX_DATACENTER_ID) {
                Log.w(TAG, "数据中心ID超出范围: $datacenterId, 回退至最大值")
                MAX_DATACENTER_ID
            } else datacenterId

            val safeWorkerId = if (workerId > MAX_WORKER_ID) {
                Log.w(TAG, "工作节点ID超出范围: $workerId, 回退至最大值")
                MAX_WORKER_ID
            } else workerId

            return NebulaIDGenerator(safeDatacenterId, safeWorkerId)
        }
    }

    // 状态变量
    private var lastTimestamp: ULong = 0UL
    private var sequence: ULong = 0UL
    private val lock = ReentrantLock()

    init {
        Log.i(TAG, "NebulaIDGenerator initialized - DataCenter: $datacenterId, Worker: $workerId")
    }

    /**
     * 星云ID错误类型
     */
    sealed class NebulaIDError : Exception() {
        object InvalidDatacenterId : NebulaIDError() {
            override val message = "数据中心ID超出范围 (0-31)"
        }
        object InvalidWorkerId : NebulaIDError() {
            override val message = "工作节点ID超出范围 (0-31)"
        }
        object ClockMovedBackwards : NebulaIDError() {
            override val message = "系统时钟回拨，ID生成暂停"
        }
        object SequenceOverflow : NebulaIDError() {
            override val message = "序列号溢出，请稍后重试"
        }
        object GenerationFailed : NebulaIDError() {
            override val message = "ID生成失败"
        }
    }

    /**
     * 星云ID信息结构
     */
    data class NebulaIDInfo(
        val fullId: String,           // 完整ID：NEBULA-2025-A1B2C3D4E5F6
        val rawId: ULong,             // 原始64位ID
        val year: Int,                // 年份
        val timestamp: ULong,         // 时间戳
        val datacenterId: ULong,      // 数据中心ID
        val workerId: ULong,          // 工作节点ID
        val sequence: ULong,          // 序列号
        val generatedAt: String       // 生成时间（ISO 8601 格式）
    )

    /**
     * 生成新的星云ID
     * @return 星云ID信息
     * @throws NebulaIDError
     */
    @Throws(NebulaIDError::class)
    fun generateID(): NebulaIDInfo = lock.withLock {
        val currentTimestamp = getCurrentTimestamp()

        // 检查时钟回拨
        if (currentTimestamp < lastTimestamp) {
            Log.e(TAG, "时钟回拨检测: 当前时间 $currentTimestamp < 上次时间 $lastTimestamp")
            throw NebulaIDError.ClockMovedBackwards
        }

        // 同一毫秒内生成ID
        if (currentTimestamp == lastTimestamp) {
            sequence = (sequence + 1UL) and MAX_SEQUENCE

            // 序列号溢出，等待下一毫秒
            if (sequence == 0UL) {
                val nextTimestamp = waitForNextMillisecond(currentTimestamp)
                return@withLock generateIDWithTimestamp(nextTimestamp)
            }
        } else {
            // 新的毫秒，重置序列号
            sequence = 0UL
        }

        generateIDWithTimestamp(currentTimestamp)
    }

    /**
     * 批量生成星云ID
     * @param count 生成数量 (最大1000)
     * @return 星云ID信息列表
     * @throws NebulaIDError
     */
    @Throws(NebulaIDError::class)
    fun generateBatchIDs(count: Int): List<NebulaIDInfo> {
        require(count in 1..1000) { "批量生成数量必须在1-1000之间" }

        return (1..count).map { generateID() }.also {
            Log.i(TAG, "批量生成 $count 个星云ID")
        }
    }

    /**
     * 解析星云ID
     * @param nebulaId 星云ID字符串
     * @return 解析后的ID信息，如果解析失败返回null
     */
    fun parseID(nebulaId: String): NebulaIDInfo? {
        // 验证格式：NEBULA-YYYY-XXXXXXXXXXXX
        val components = nebulaId.split(SEPARATOR)
        if (components.size != 3 ||
            components[0] != PREFIX ||
            components[2].length != 12) {
            return null
        }

        val year = components[1].toIntOrNull() ?: return null

        // 解码Base36字符串为64位整数
        val rawId = components[2].toULongOrNull(36) ?: return null

        // 提取各个组件
        val timestamp = (rawId shr TIMESTAMP_SHIFT) + EPOCH
        val parsedDatacenterId = (rawId shr DATACENTER_ID_SHIFT) and MAX_DATACENTER_ID
        val parsedWorkerId = (rawId shr WORKER_ID_SHIFT) and MAX_WORKER_ID
        val parsedSequence = rawId and MAX_SEQUENCE

        return NebulaIDInfo(
            fullId = nebulaId,
            rawId = rawId,
            year = year,
            timestamp = timestamp,
            datacenterId = parsedDatacenterId,
            workerId = parsedWorkerId,
            sequence = parsedSequence,
            generatedAt = formatIso8601(timestamp.toLong())
        )
    }

    /**
     * 验证星云ID格式
     * @param nebulaId 星云ID字符串
     * @return 是否为有效格式
     */
    fun isValidID(nebulaId: String): Boolean = parseID(nebulaId) != null

    /**
     * 生成用户注册ID
     * @return 用于用户注册的星云ID
     */
    @Throws(NebulaIDError::class)
    fun generateUserRegistrationID(): NebulaIDInfo {
        return generateID().also {
            Log.i(TAG, "生成用户注册ID: ${it.fullId}")
        }
    }

    /**
     * 生成会话ID
     * @return 用于会话管理的星云ID
     */
    @Throws(NebulaIDError::class)
    fun generateSessionID(): NebulaIDInfo {
        return generateID().also {
            Log.i(TAG, "生成会话ID: ${it.fullId}")
        }
    }

    /**
     * 生成企业ID
     * @return 用于企业标识的星云ID
     */
    @Throws(NebulaIDError::class)
    fun generateCompanyID(): NebulaIDInfo {
        return generateID().also {
            Log.i(TAG, "生成企业ID: ${it.fullId}")
        }
    }

    /**
     * ID生成统计信息
     */
    data class GenerationStats(
        val totalGenerated: ULong,
        val currentSequence: ULong,
        val lastTimestamp: ULong,
        val datacenterId: ULong,
        val workerId: ULong,
        val uptime: Long
    )

    /**
     * 获取生成统计信息
     * @return 统计信息
     */
    fun getGenerationStats(): GenerationStats = lock.withLock {
        GenerationStats(
            totalGenerated = sequence,
            currentSequence = sequence,
            lastTimestamp = lastTimestamp,
            datacenterId = datacenterId,
            workerId = workerId,
            uptime = System.currentTimeMillis()
        )
    }

    // MARK: - 私有方法

    /**
     * 使用指定时间戳生成ID
     */
    private fun generateIDWithTimestamp(timestamp: ULong): NebulaIDInfo {
        lastTimestamp = timestamp

        // 构建64位ID
        val adjustedTimestamp = timestamp - EPOCH
        val rawId = (adjustedTimestamp shl TIMESTAMP_SHIFT) or
                   (datacenterId shl DATACENTER_ID_SHIFT) or
                   (workerId shl WORKER_ID_SHIFT) or
                   sequence

        // 生成年份
        val currentYear = Calendar.getInstance().get(Calendar.YEAR)

        // 将64位ID转换为Base36字符串（12位）- 与 macOS Swift 行为一致：
        // `String(rawId, radix: 36).uppercased().padding(toLength: 12, withPad: "0", startingAt: 0)`
        // - 右侧补 0 到 12 位
        // - 超过 12 位则截断
        var base36String = rawId.toString(36).uppercase()
        if (base36String.length < 12) {
            base36String = base36String.padEnd(12, '0')
        }
        if (base36String.length > 12) {
            base36String = base36String.substring(0, 12)
        }

        // 构建完整ID
        val fullId = "$PREFIX$SEPARATOR$currentYear$SEPARATOR$base36String"

        Log.d(TAG, "生成星云ID: $fullId")

        return NebulaIDInfo(
            fullId = fullId,
            rawId = rawId,
            year = currentYear,
            timestamp = timestamp,
            datacenterId = datacenterId,
            workerId = workerId,
            sequence = sequence,
            generatedAt = formatIso8601(timestamp.toLong())
        )
    }

    /**
     * 获取当前时间戳（毫秒）
     */
    private fun getCurrentTimestamp(): ULong {
        return System.currentTimeMillis().toULong()
    }

    /**
     * 等待下一毫秒
     */
    private fun waitForNextMillisecond(lastTimestamp: ULong): ULong {
        var timestamp = getCurrentTimestamp()
        while (timestamp <= lastTimestamp) {
            timestamp = getCurrentTimestamp()
        }
        return timestamp
    }

    /**
     * 格式化时间戳为 ISO 8601 格式
     */
    private fun formatIso8601(timestampMs: Long): String {
        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return sdf.format(java.util.Date(timestampMs))
    }
}
