package com.skybridge.compass.discovery.data.services

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration

/**
 * 发现窗口（R7.4、design §7）：把一次发现流限制在 `RuntimeNetworkParameters.discoveryWindow` 时长内。
 *
 * 窗口时长在**发现启动时**取一次，因此这次发现按启动时的设置运行；设置改动只影响下一次启动的发现，
 * 不会打断正在进行的发现。
 */
object DiscoveryWindow {

    /**
     * 在 [window] 时长后正常结束上游发现流。
     *
     * - 窗口内上游发出的每个结果都照原样向下游传递；
     * - 窗口到点即取消上游采集并**正常完成**（不是抛错）——发现窗口结束是预期终态，不是失败；
     * - 上游先于窗口自行结束时，本流随之结束，不再等待窗口耗尽。
     */
    fun <T> Flow<T>.withDiscoveryWindow(window: Duration): Flow<T> = channelFlow {
        val upstream = this@withDiscoveryWindow
        withTimeoutOrNull(window) {
            upstream.collect { value -> send(value) }
        }
    }
}
