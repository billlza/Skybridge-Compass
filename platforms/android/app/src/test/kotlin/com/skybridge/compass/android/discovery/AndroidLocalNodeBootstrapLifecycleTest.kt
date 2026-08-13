package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.core.p2p.TcpControlSession
import com.skybridge.compass.core.p2p.TcpControlServerFailure
import com.skybridge.compass.discovery.data.services.P2PLocalNodeService
import io.kotest.matchers.shouldBe
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.verify
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidLocalNodeBootstrapLifecycleTest {
    @Test
    fun stopThenStartRunsTheSuccessorOnlyAfterPriorCleanupCompletes() = runTest {
        val settings = MutableSharedFlow<SecuritySettings>(replay = 1)
        settings.emit(SecuritySettings())
        val localNodeService = mockk<P2PLocalNodeService>()
        val tcpControlServer = mockk<TcpControlServer>()
        every { tcpControlServer.incomingSessions } returns MutableSharedFlow()
        every { tcpControlServer.terminalFailure } returns MutableStateFlow(null)
        val stopEntered = CompletableDeferred<Unit>()
        val releaseStop = CompletableDeferred<Unit>()
        val priorRuntimeStopped = CompletableDeferred<Unit>()
        val startPorts = ArrayDeque(listOf(55_101, 55_102))
        var startCalls = 0
        coEvery { localNodeService.start(any(), any()) } coAnswers {
            startCalls += 1
            if (startCalls == 2) {
                check(priorRuntimeStopped.isCompleted) {
                    "successor started before the prior runtime completed cleanup"
                }
            }
            startPorts.removeFirst()
        }
        coEvery { localNodeService.stop() } coAnswers {
            stopEntered.complete(Unit)
            releaseStop.await()
        }

        val bootstrap = AndroidLocalNodeBootstrap(
            localNodeService = localNodeService,
            tcpControlServer = tcpControlServer,
            dispatcher = StandardTestDispatcher(testScheduler),
            observeSecuritySettings = { settings },
            permissionGranted = { true },
            lifecycleHooks = AndroidLocalNodeLifecycleHooks(
                afterRuntimeStopped = { priorRuntimeStopped.complete(Unit) }
            )
        )

        bootstrap.start()
        runCurrent()
        coVerify(exactly = 1) { localNodeService.start(any(), any()) }
        val stopping = async { bootstrap.stop() }
        stopEntered.await()
        bootstrap.start()

        assertFalse(stopping.isCompleted)
        releaseStop.complete(Unit)
        runCurrent()
        stopping.await()
        coVerify(exactly = 2) { localNodeService.start(any(), any()) }

        bootstrap.close()
        coVerify(exactly = 2) { localNodeService.stop() }
    }

    @Test
    fun stopInvalidatesAStartCommandThatHasNotReachedTheCoordinator() = runTest {
        val settings = MutableSharedFlow<SecuritySettings>(replay = 1)
        settings.emit(SecuritySettings())
        val localNodeService = mockk<P2PLocalNodeService>()
        val tcpControlServer = mockk<TcpControlServer>()
        every { tcpControlServer.incomingSessions } returns MutableSharedFlow()
        every { tcpControlServer.terminalFailure } returns MutableStateFlow(null)
        val firstStopClaimed = CompletableDeferred<Unit>()
        val releaseFirstStop = CompletableDeferred<Unit>()
        coEvery { localNodeService.stop() } returns Unit
        var stopCommands = 0
        val hooks = AndroidLocalNodeLifecycleHooks(
            afterStopCommandClaimed = {
                stopCommands += 1
                if (stopCommands == 1) {
                    firstStopClaimed.complete(Unit)
                    releaseFirstStop.await()
                }
            }
        )
        coEvery { localNodeService.start(any(), any()) } returns 55_103

        val bootstrap = AndroidLocalNodeBootstrap(
            localNodeService = localNodeService,
            tcpControlServer = tcpControlServer,
            dispatcher = StandardTestDispatcher(testScheduler),
            observeSecuritySettings = { settings },
            permissionGranted = { true },
            lifecycleHooks = hooks
        )

        val firstStop = async { bootstrap.stop() }
        runCurrent()
        firstStopClaimed.await()
        bootstrap.start()
        val secondStop = async { bootstrap.stop() }
        releaseFirstStop.complete(Unit)
        runCurrent()
        firstStop.await()
        secondStop.await()

        coVerify(exactly = 0) { localNodeService.start(any(), any()) }
        coVerify(exactly = 0) { localNodeService.stop() }
        bootstrap.close()
        coVerify(exactly = 0) { localNodeService.stop() }
    }

    @Test
    fun stopCancelsAndClosesAnObservedInboundSessionBeforeReturning() = runTest {
        val settings = MutableSharedFlow<SecuritySettings>(replay = 1)
        settings.emit(SecuritySettings())
        val incoming = MutableSharedFlow<TcpControlSession>()
        val events = MutableSharedFlow<com.skybridge.compass.core.p2p.TcpControlEvent>()
        val session = mockk<TcpControlSession>()
        every { session.events } returns events
        every { session.close() } just Runs
        val localNodeService = mockk<P2PLocalNodeService>()
        coEvery { localNodeService.start(any(), any()) } returns 55_104
        coEvery { localNodeService.stop() } returns Unit
        val tcpControlServer = mockk<TcpControlServer>()
        every { tcpControlServer.incomingSessions } returns incoming
        every { tcpControlServer.terminalFailure } returns MutableStateFlow<TcpControlServerFailure?>(null)

        val bootstrap = AndroidLocalNodeBootstrap(
            localNodeService = localNodeService,
            tcpControlServer = tcpControlServer,
            dispatcher = StandardTestDispatcher(testScheduler),
            observeSecuritySettings = { settings },
            permissionGranted = { true }
        )

        bootstrap.start()
        runCurrent()
        incoming.subscriptionCount.first { it == 1 }
        incoming.emit(session)
        runCurrent()
        events.subscriptionCount.first { it == 1 }

        bootstrap.stop()
        runCurrent()

        verify(exactly = 1) { session.close() }
        incoming.subscriptionCount.value shouldBe 0
        events.subscriptionCount.value shouldBe 0
        coVerify(exactly = 1) { localNodeService.stop() }
        bootstrap.close()
    }

    @Test
    fun listenerFailureCleansTheOldRuntimeBeforeStartingAnExplicitSuccessor() = runTest {
        val settings = MutableSharedFlow<SecuritySettings>(replay = 1).apply {
            emit(SecuritySettings())
        }
        val terminalFailure = MutableStateFlow<TcpControlServerFailure?>(null)
        val localNodeService = mockk<P2PLocalNodeService>()
        val tcpControlServer = mockk<TcpControlServer>()
        every { tcpControlServer.incomingSessions } returns MutableSharedFlow()
        every { tcpControlServer.terminalFailure } returns terminalFailure
        coEvery { localNodeService.start(any(), any()) } returnsMany listOf(55_105, 55_106)
        coEvery { localNodeService.stop() } coAnswers {
            terminalFailure.value = null
        }
        val bootstrap = AndroidLocalNodeBootstrap(
            localNodeService = localNodeService,
            tcpControlServer = tcpControlServer,
            dispatcher = StandardTestDispatcher(testScheduler),
            observeSecuritySettings = { settings },
            permissionGranted = { true }
        )

        bootstrap.start()
        runCurrent()
        coVerify(exactly = 1) { localNodeService.start(any(), any()) }

        terminalFailure.value = TcpControlServerFailure(
            generation = 1,
            cause = IOException("listener failed")
        )
        bootstrap.start()
        runCurrent()

        coVerify(exactly = 1) { localNodeService.stop() }
        coVerify(exactly = 2) { localNodeService.start(any(), any()) }
        terminalFailure.value shouldBe null

        bootstrap.close()
        coVerify(exactly = 2) { localNodeService.stop() }
    }
}
