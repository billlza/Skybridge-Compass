package com.skybridge.compass.core.data

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * 单一读取面：运行时参数只从这里取，消除「写入即生效」的错觉（design §7、R7.4）。
 *
 * 运行时消费方**不得**直接读取 [NetworkSettings.portRangeStart] / [NetworkSettings.portRangeEnd] /
 * [NetworkSettings.discoveryTimeoutMs] / [NetworkSettings.maxReconnectAttempts]；一律经由本接口，
 * 使「界面可改的值」与「运行时真正生效的值」保持同一来源。
 */
interface RuntimeNetworkParameters {
    /** LAN 传输/控制通道监听端口与本地节点广播端口的可选范围（`portRangeStart..portRangeEnd`）。 */
    val listenPortRange: IntRange

    /** 发现窗口时长（`discoveryTimeoutMs`）。 */
    val discoveryWindow: Duration

    /** 重连尝试上限（0..10），接线到 `ReconnectPolicy.maxAttempts`。 */
    val maxReconnectAttempts: Int
}

/**
 * [RuntimeNetworkParameters] 的取值入口。
 *
 * [current] 每次调用都重新读取持久化值，因此**新建立的会话/新发起的操作**按最新设置运行，
 * 而已在进行中的会话仍沿用其建立时读到的快照（R7.4）。消费方应在会话建立点调用一次 [current]
 * 并把结果当作该会话的不变量，不要把返回值缓存成进程级单例。
 */
interface RuntimeNetworkParametersSource {

    /** 读取当前生效值，供一次新会话/新操作使用。 */
    suspend fun current(): RuntimeNetworkParameters

    /** 观察取值变化，供需要随设置变化重新决策的长驻消费方使用。 */
    fun observe(): Flow<RuntimeNetworkParameters>
}

/**
 * 不可变取值快照。会话建立时取一份，之后不再变化，因此设置改动不会扰动进行中的会话。
 */
data class RuntimeNetworkParametersSnapshot(
    override val listenPortRange: IntRange,
    override val discoveryWindow: Duration,
    override val maxReconnectAttempts: Int
) : RuntimeNetworkParameters

/**
 * 把持久化的 [NetworkSettings] 映射为运行时取值，并在读取面守住取值区间（R7.8 的区间）。
 *
 * 读取面**不信任**存储中的越界值：界面侧「先校验后写入」由任务 15.6 负责，这里只作为存储层兜底，
 * 把越界值钳制回合法区间，避免把非法端口/窗口/次数交给运行时。
 */
object RuntimeNetworkParametersPolicy {

    const val MIN_PORT: Int = 1
    const val MAX_PORT: Int = 65535
    const val MIN_RECONNECT_ATTEMPTS: Int = 0
    const val MAX_RECONNECT_ATTEMPTS: Int = 10

    val MIN_DISCOVERY_WINDOW: Duration = 250.milliseconds
    val MAX_DISCOVERY_WINDOW: Duration = 120_000.milliseconds

    /**
     * 映射规则：
     * - `listenPortRange` = 起点钳制到 [MIN_PORT]..[MAX_PORT]；终点钳制到 `起点..`[MAX_PORT]，
     *   因此结果范围永不为空且始终满足 `end >= start`。
     * - `discoveryWindow` = `discoveryTimeoutMs` 钳制到 [MIN_DISCOVERY_WINDOW]..[MAX_DISCOVERY_WINDOW]。
     * - `maxReconnectAttempts` 钳制到 [MIN_RECONNECT_ATTEMPTS]..[MAX_RECONNECT_ATTEMPTS]。
     */
    fun from(settings: NetworkSettings): RuntimeNetworkParametersSnapshot {
        val start = settings.portRangeStart.coerceIn(MIN_PORT, MAX_PORT)
        val end = settings.portRangeEnd.coerceIn(start, MAX_PORT)
        return RuntimeNetworkParametersSnapshot(
            listenPortRange = start..end,
            discoveryWindow = settings.discoveryTimeoutMs.milliseconds
                .coerceIn(MIN_DISCOVERY_WINDOW, MAX_DISCOVERY_WINDOW),
            maxReconnectAttempts = settings.maxReconnectAttempts
                .coerceIn(MIN_RECONNECT_ATTEMPTS, MAX_RECONNECT_ATTEMPTS)
        )
    }
}

/**
 * 生产实现：取值来自 [NetworkSettingsStore]（DataStore）。
 *
 * 本类是全仓**唯一**允许读取网络三项持久化字段的地方。
 */
@Singleton
class DataStoreRuntimeNetworkParametersSource @Inject constructor(
    @param:ApplicationContext private val appContext: Context
) : RuntimeNetworkParametersSource {

    override fun observe(): Flow<RuntimeNetworkParameters> =
        NetworkSettingsStore.observe(appContext).map(RuntimeNetworkParametersPolicy::from)

    /** 每次调用都取一次最新持久化值，保证下一个会话按新值运行（R7.4）。 */
    override suspend fun current(): RuntimeNetworkParameters =
        RuntimeNetworkParametersPolicy.from(NetworkSettingsStore.observe(appContext).first())
}
