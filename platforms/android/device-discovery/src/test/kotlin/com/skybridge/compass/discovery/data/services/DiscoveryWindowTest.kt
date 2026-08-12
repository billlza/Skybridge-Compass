@file:OptIn(ExperimentalCoroutinesApi::class)

package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.core.data.RuntimeNetworkParametersSnapshot
import com.skybridge.compass.discovery.data.services.DiscoveryWindow.withDiscoveryWindow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlin.time.Duration.Companion.milliseconds

/**
 * `discoveryWindow` 接线（任务 15.2 / R7.4）：一次发现在启动时读到的窗口时长后正常结束，
 * 设置改动只影响下一次启动，不打断进行中的发现。
 */
class DiscoveryWindowTest : FunSpec({

    test("emissions inside the window pass through and the flow completes at the window edge") {
        runTest {
            val upstream = flow {
                emit(1)
                delay(100)
                emit(2)
                delay(100)
                emit(3)
                // 窗口(250ms)之后的发出不应被下游看到。
                delay(100)
                emit(4)
                delay(10_000)
                emit(5)
            }

            val received = upstream.withDiscoveryWindow(250.milliseconds).toList()

            received shouldBe listOf(1, 2, 3)
        }
    }

    test("window end completes normally rather than failing") {
        runTest {
            val neverEnding = flow<Int> {
                emit(7)
                delay(Long.MAX_VALUE)
            }

            // 没有异常抛出即为正常终态；窗口结束是预期结果而非失败。
            neverEnding.withDiscoveryWindow(500.milliseconds).toList() shouldBe listOf(7)
        }
    }

    test("upstream finishing before the window ends the flow without waiting out the window") {
        runTest {
            val short = flow {
                emit("a")
                emit("b")
            }

            val startedAt = testScheduler.currentTime
            short.withDiscoveryWindow(120_000.milliseconds).toList() shouldBe listOf("a", "b")
            // 上游自行结束，无需等满窗口。
            (testScheduler.currentTime - startedAt) shouldBe 0L
        }
    }

    test("a longer configured window keeps a discovery run alive longer") {
        runTest {
            val ticking = flow {
                repeat(10) { index ->
                    emit(index)
                    delay(100)
                }
            }

            ticking.withDiscoveryWindow(250.milliseconds).toList() shouldBe listOf(0, 1, 2)
            ticking.withDiscoveryWindow(550.milliseconds).toList() shouldBe listOf(0, 1, 2, 3, 4, 5)
        }
    }

    test("a settings change is observed by the next discovery run, not by the in-flight one") {
        runTest {
            val source = FakeRuntimeNetworkParametersSource(discoveryWindow = 250.milliseconds)

            val ticking = flow {
                repeat(10) { index ->
                    emit(index)
                    delay(100)
                }
            }

            // 发现启动时取一次窗口，本次运行按该值执行。
            val firstRunWindow = source.current().discoveryWindow
            val firstRun = ticking.withDiscoveryWindow(firstRunWindow)

            // 运行开始后用户改了设置。
            source.value = RuntimeNetworkParametersSnapshot(
                listenPortRange = source.value.listenPortRange,
                discoveryWindow = 550.milliseconds,
                maxReconnectAttempts = source.value.maxReconnectAttempts
            )

            // 进行中的这次发现仍按启动时的 250ms 结束。
            firstRun.toList() shouldBe listOf(0, 1, 2)

            // 下一次启动重新读取，按新的 550ms 运行。
            val secondRun = ticking.withDiscoveryWindow(source.current().discoveryWindow)
            secondRun.toList() shouldBe listOf(0, 1, 2, 3, 4, 5)
        }
    }
})
