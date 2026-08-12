package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.data.RuntimePairingApprovalParameters
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSnapshot
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

/**
 * `auto_trust_known_devices` 接线到运行时配对判定（R7.5）：开关在**判定时**读取，
 * 因此改动对下一个请求生效，且不会追溯批准已在等待中的请求。
 */
class PairingApprovalWiringTest {

    /** 可变开关的取值源：模拟用户在设置里切换后持久化值发生变化。 */
    private class MutableSource(@Volatile var enabled: Boolean) : RuntimePairingApprovalParametersSource {
        @Volatile var readCount: Int = 0

        override suspend fun current(): RuntimePairingApprovalParameters {
            readCount += 1
            return RuntimePairingApprovalParametersSnapshot(autoTrustKnownDevices = enabled)
        }

        override fun observe(): Flow<RuntimePairingApprovalParameters> = flow {
            emit(RuntimePairingApprovalParametersSnapshot(autoTrustKnownDevices = enabled))
        }
    }

    private var previousProvider: PairingTrustApprovalProvider? = null
    private var previousSource: RuntimePairingApprovalParametersSource? = null

    private val knownRequest = PairingTrustRequest(
        peerId = "peer-a",
        declaredDeviceId = "device-a"
    )

    @Before
    fun captureGlobals() {
        previousProvider = PairingTrustManager.approvalProvider
        previousSource = PairingTrustManager.approvalParametersSource
    }

    @After
    fun restoreGlobals() {
        PairingTrustManager.approvalProvider = previousProvider
        PairingTrustManager.approvalParametersSource = previousSource
    }

    @Test
    fun knownDeviceIsAutoApprovedWithoutPromptingWhenFlagOn() = runBlocking {
        var prompted = false
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider {
            prompted = true
            PairingTrustDecision.DECLINE
        }
        PairingTrustManager.approvalParametersSource = MutableSource(enabled = true)

        val decision = PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)

        assertEquals(PairingTrustDecision.TRUST_ALWAYS, decision)
        assertFalse("known device must not prompt when auto-trust is on", prompted)
    }

    @Test
    fun knownDeviceEntersExplicitApprovalWhenFlagOff() = runBlocking {
        var prompted = false
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider {
            prompted = true
            PairingTrustDecision.ALLOW_ONCE
        }
        PairingTrustManager.approvalParametersSource = MutableSource(enabled = false)

        val decision = PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)

        assertEquals(PairingTrustDecision.ALLOW_ONCE, decision)
        assertEquals(true, prompted)
    }

    @Test
    fun unknownDeviceEntersExplicitApprovalEvenWhenFlagOn() = runBlocking {
        var prompted = false
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider {
            prompted = true
            PairingTrustDecision.DECLINE
        }
        PairingTrustManager.approvalParametersSource = MutableSource(enabled = true)

        val decision = PairingTrustManager.requestDecision(knownRequest, isKnownDevice = false)

        assertEquals(PairingTrustDecision.DECLINE, decision)
        assertEquals(true, prompted)
    }

    /** 未注册取值源时按关闭处理（失败关闭）。 */
    @Test
    fun missingSourceFallsBackToExplicitApproval() = runBlocking {
        PairingTrustManager.approvalParametersSource = null
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider { PairingTrustDecision.ALLOW_ONCE }

        assertEquals(
            PairingTrustDecision.ALLOW_ONCE,
            PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)
        )
    }

    /**
     * 开关改动对**下一个**请求生效，但不追溯批准已在等待批准的请求：
     * 第一个请求在开关关闭时进入等待态并挂起；随后开关打开，第二个请求免交互批准；
     * 第一个请求仍停留在等待态，只能由用户操作决定结果。
     */
    @Test
    fun toggleAffectsNextRequestButNotOneAlreadyAwaitingApproval() = runBlocking {
        val source = MutableSource(enabled = false)
        PairingTrustManager.approvalParametersSource = source

        val pending = CompletableDeferred<PairingTrustDecision>()
        val promptCount = java.util.concurrent.atomic.AtomicInteger(0)
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider {
            promptCount.incrementAndGet()
            pending.await()
        }

        val first = async {
            PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)
        }
        // 让第一个请求走到等待用户批准的挂起点。
        while (promptCount.get() == 0) yield()
        assertFalse("first request must still be awaiting approval", first.isCompleted)

        // 用户切换开关为开启。
        source.enabled = true

        // 下一个请求按新值免交互批准，且不再弹出提示。
        val second = PairingTrustManager.requestDecision(
            PairingTrustRequest(peerId = "peer-b", declaredDeviceId = "device-b"),
            isKnownDevice = true
        )
        assertEquals(PairingTrustDecision.TRUST_ALWAYS, second)
        assertEquals(1, promptCount.get())

        // 第一个请求未被追溯批准，仍在等待。
        assertFalse("toggle must not retroactively approve a pending request", first.isCompleted)

        // 只能由用户操作收敛。
        pending.complete(PairingTrustDecision.DECLINE)
        assertEquals(PairingTrustDecision.DECLINE, first.await())
    }

    /** 每次判定都重新读取开关，不是构造时捕获一次。 */
    @Test
    fun flagIsReReadOnEveryDecision() = runBlocking {
        val source = MutableSource(enabled = true)
        PairingTrustManager.approvalParametersSource = source
        PairingTrustManager.approvalProvider = PairingTrustApprovalProvider { PairingTrustDecision.DECLINE }

        PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)
        PairingTrustManager.requestDecision(knownRequest, isKnownDevice = true)

        assertEquals(2, source.readCount)
    }
}
