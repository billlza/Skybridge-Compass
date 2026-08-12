package com.skybridge.compass.core.network

/**
 * 配置的监听端口范围内**每一个**端口都被占用时抛出。
 *
 * 明确失败而不是静默回落到硬编码默认端口：静默回落正是 R7.4 要消除的「写入即生效」错觉
 * （用户改了范围，实际却仍在别的端口上监听）。调用方应把该失败如实呈现给用户。
 */
class ListenPortRangeExhaustedException(
    val portRange: IntRange,
    cause: Throwable? = null
) : IllegalStateException(
    "no free port in configured listen range ${portRange.first}..${portRange.last}",
    cause
)

/**
 * 在 [RuntimeNetworkParameters.listenPortRange] 内选择一个可绑定端口（R7.4）。
 *
 * 绑定动作由调用方以 [bind] 注入（返回该端口上已建立的监听资源），因此本对象不持有任何
 * Socket 语义，可在单元测试中确定化验证「只在范围内取端口」与「范围耗尽时明确失败」。
 */
object ListenPortAllocator {

    /**
     * 自 [IntRange.first] 起升序尝试绑定，返回首个绑定成功的结果。
     *
     * - 端口范围为空（`last < first`）时视为无可用端口，直接抛
     *   [ListenPortRangeExhaustedException]。
     * - 每个端口的绑定失败被视为「该端口被占用」并继续尝试下一个；范围内全部失败时抛
     *   [ListenPortRangeExhaustedException]，并把最后一次绑定失败挂为 cause。
     * - 绝不越出 [portRange]，也绝不回落到任何硬编码默认端口。
     */
    fun <T> bindWithin(portRange: IntRange, bind: (Int) -> T): T {
        var lastFailure: Throwable? = null
        for (port in portRange) {
            try {
                return bind(port)
            } catch (failure: Throwable) {
                lastFailure = failure
            }
        }
        throw ListenPortRangeExhaustedException(portRange = portRange, cause = lastFailure)
    }
}
