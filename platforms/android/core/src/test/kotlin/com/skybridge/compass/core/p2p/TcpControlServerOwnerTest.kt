package com.skybridge.compass.core.p2p

import io.kotest.core.spec.style.FunSpec
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.matchers.shouldBe
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class TcpControlServerOwnerTest : FunSpec({
    test("an accepted client from a retired generation cannot be installed into its successor") {
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>()
        val firstListener = owners.installListener(TestListener("listener-a"))
        val accepted = acceptClient(owners, firstListener, TestClient("client-a"))

        val retired = owners.beginStopCleanup()
        owners.isCurrentTransition(retired) shouldBe true
        owners.completeCleanup(retired) shouldBe true
        val successor = owners.installListener(TestListener("listener-b"))
        owners.isCurrentTransition(retired) shouldBe false
        val successorClient = acceptClient(owners, successor, TestClient("client-b"))
        val successorSession = requireNotNull(
            owners.promoteAcceptedToSession(successor, successorClient, TestSession("session-b"))
        )

        retired.listeners shouldBe listOf(firstListener)
        retired.accepted shouldBe listOf(accepted)
        owners.isCurrent(firstListener) shouldBe false
        owners.beginAcceptWhenAvailable(firstListener) shouldBe null
        owners.beginAcceptedCleanup(accepted) shouldBe null
        owners.isCurrent(successor) shouldBe true
        owners.acceptedCount shouldBe 0
        owners.sessionCount shouldBe 1
        owners.retireSession(successorSession) shouldBe true
    }

    test("an old cleanup transition cannot clear a successor terminal state") {
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>()
        val first = owners.installListener(TestListener("listener-a"))
        val retired = owners.beginStopCleanup()

        owners.isCurrentTransition(retired) shouldBe true
        owners.completeCleanup(retired) shouldBe true
        val successor = owners.installListener(TestListener("listener-b"))
        owners.isCurrentTransition(retired) shouldBe false
        owners.isCurrent(successor) shouldBe true
    }

    test("failed stop preserves the exact session owner until a later stop succeeds") {
        val owners = TcpControlServerOwner<TestListener, TestClient, RetryableTestSession>()
        val listener = owners.installListener(TestListener("listener-a"))
        val client = acceptClient(owners, listener, TestClient("client-a"))
        lateinit var sessionOwner: TcpControlServerOwner.SessionOwner<RetryableTestSession>
        val session = RetryableTestSession(
            onClosed = { owners.retireSession(sessionOwner) }
        )
        sessionOwner = requireNotNull(owners.promoteAcceptedToSession(listener, client, session))

        val firstStop = owners.beginStopCleanup()
        owners.hasPendingCleanup shouldBe true
        session.failNextClose = true
        shouldThrow<IOException> { firstStop.sessions.single().resource.close() }
        session.closeAttempts shouldBe 1
        session.closeNotifications shouldBe 0
        shouldThrow<IllegalStateException> {
            owners.installListener(TestListener("premature-successor"))
        }

        val retryStop = owners.beginStopCleanup()
        retryStop.sessions shouldBe listOf(sessionOwner)
        retryStop.sessions.single().resource.close()
        session.closeAttempts shouldBe 2
        session.closeNotifications shouldBe 1
        owners.completeCleanup(retryStop) shouldBe true
        owners.hasPendingCleanup shouldBe false

        val successor = owners.installListener(TestListener("listener-b"))
        owners.retireSession(sessionOwner) shouldBe false
        owners.isCurrent(successor) shouldBe true
        session.close()
        session.closeAttempts shouldBe 2
        session.closeNotifications shouldBe 1
    }

    test("accepted close failure moves exact ownership into pending stop cleanup") {
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>()
        val listener = owners.installListener(TestListener("listener"))
        val client = acceptClient(owners, listener, TestClient("client"))

        val acceptedCleanup = requireNotNull(owners.beginAcceptedCleanup(client))
        acceptedCleanup.accepted shouldBe listOf(client)
        owners.acceptedCount shouldBe 0
        owners.hasPendingCleanup shouldBe true
        shouldThrow<IllegalStateException> {
            owners.installListener(TestListener("successor-before-stop"))
        }

        val stopCleanup = owners.beginStopCleanup()
        stopCleanup.accepted shouldBe listOf(client)
        stopCleanup.listeners shouldBe listOf(listener)
        owners.completeCleanup(stopCleanup) shouldBe true
        owners.hasPendingCleanup shouldBe false
    }

    test("accept returning after stop transfers its socket into pending cleanup before drain") {
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>()
        val old = owners.installListener(TestListener("listener-a"))
        val inFlight = requireNotNull(owners.beginAcceptWhenAvailable(old))
        owners.beginStopCleanup()

        owners.completeAcceptSuccess(
            owner = inFlight,
            resource = TestClient("late-client-a")
        )
        owners.awaitAcceptsDrained(timeoutMillis = 100) shouldBe true
        owners.hasPendingCleanup shouldBe true

        val stop = owners.beginStopCleanup()
        stop.accepted.map { it.resource.id } shouldBe listOf("late-client-a")
        stop.listeners shouldBe listOf(old)
    }

    test("capacity waiter receives a token after an exact session owner retires") {
        val capacityWaitStarted = CountDownLatch(1)
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>(
            maxClientOwners = 1,
            onCapacityWait = capacityWaitStarted::countDown
        )
        val listener = owners.installListener(TestListener("listener"))
        val accepted = acceptClient(owners, listener, TestClient("client"))
        val session = requireNotNull(
            owners.promoteAcceptedToSession(listener, accepted, TestSession("session"))
        )
        val result = AtomicReference<TcpControlServerOwner.AcceptOwner?>()
        val completed = CountDownLatch(1)
        val waiter = thread(name = "tcp-capacity-waiter") {
            result.set(owners.beginAcceptWhenAvailable(listener))
            completed.countDown()
        }

        check(capacityWaitStarted.await(HANG_GUARD_SECONDS, TimeUnit.SECONDS))
        owners.retireSession(session) shouldBe true
        check(completed.await(HANG_GUARD_SECONDS, TimeUnit.SECONDS))
        waiter.join()

        val token = requireNotNull(result.get())
        token.generation shouldBe listener.generation
        owners.completeAcceptFailure(token) shouldBe true
    }

    test("retiring listener releases capacity waiter with no token") {
        val capacityWaitStarted = CountDownLatch(1)
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>(
            maxClientOwners = 1,
            onCapacityWait = capacityWaitStarted::countDown
        )
        val listener = owners.installListener(TestListener("listener"))
        val accepted = acceptClient(owners, listener, TestClient("client"))
        requireNotNull(owners.promoteAcceptedToSession(listener, accepted, TestSession("session")))
        val result = AtomicReference<TcpControlServerOwner.AcceptOwner?>()
        val completed = CountDownLatch(1)
        val waiter = thread(name = "tcp-stop-capacity-waiter") {
            result.set(owners.beginAcceptWhenAvailable(listener))
            completed.countDown()
        }

        check(capacityWaitStarted.await(HANG_GUARD_SECONDS, TimeUnit.SECONDS))
        owners.beginStopCleanup()
        check(completed.await(HANG_GUARD_SECONDS, TimeUnit.SECONDS))
        waiter.join()

        result.get() shouldBe null
    }

    test("session close retries notification without closing the socket twice") {
        val closeState = TcpControlSessionCloseState()
        var socketCloseAttempts = 0
        var notificationAttempts = 0

        shouldThrow<IOException> {
            closeState.close(
                prepare = {},
                closeSocket = { socketCloseAttempts += 1 },
                notifyClosed = {
                    notificationAttempts += 1
                    throw IOException("notification failed")
                }
            )
        }
        closeState.canStart shouldBe false

        closeState.close(
            prepare = {},
            closeSocket = { socketCloseAttempts += 1 },
            notifyClosed = { notificationAttempts += 1 }
        )
        socketCloseAttempts shouldBe 1
        notificationAttempts shouldBe 2
    }

    test("session close retries preparation before touching the socket") {
        val closeState = TcpControlSessionCloseState()
        var preparationAttempts = 0
        var socketCloseAttempts = 0
        var notifications = 0

        shouldThrow<IOException> {
            closeState.close(
                prepare = {
                    preparationAttempts += 1
                    throw IOException("preparation failed")
                },
                closeSocket = { socketCloseAttempts += 1 },
                notifyClosed = { notifications += 1 }
            )
        }
        closeState.canStart shouldBe false
        socketCloseAttempts shouldBe 0
        notifications shouldBe 0

        closeState.close(
            prepare = { preparationAttempts += 1 },
            closeSocket = { socketCloseAttempts += 1 },
            notifyClosed = { notifications += 1 }
        )
        preparationAttempts shouldBe 2
        socketCloseAttempts shouldBe 1
        notifications shouldBe 1
    }

    test("owner callback registered after close is delivered exactly once") {
        val callback = TcpControlSessionOwnerCloseCallback("session")
        var notifications = 0

        callback.notifyClosed()
        callback.register { owner ->
            owner shouldBe "session"
            notifications += 1
        }
        callback.notifyClosed()

        notifications shouldBe 1
    }

    test("close and handshake commit are linearized by one close-state lock") {
        val closeState = TcpControlSessionCloseState()
        var established = false
        var cleared = false

        closeState.commitIfOpen {
            established = true
        } shouldBe Unit
        closeState.close(
            prepare = {
                established = false
                cleared = true
            },
            closeSocket = {},
            notifyClosed = {}
        )
        closeState.commitIfOpen { established = true } shouldBe null

        established shouldBe false
        cleared shouldBe true
    }

    test("failed owner callback remains retryable") {
        val callback = TcpControlSessionOwnerCloseCallback("session")
        var attempts = 0
        callback.register {
            attempts += 1
            if (attempts == 1) throw IOException("injected callback failure")
        }

        shouldThrow<IOException> { callback.notifyClosed() }
        callback.notifyClosed()

        attempts shouldBe 2
    }

    test("retiring an old active session cannot remove its successor generation") {
        val owners = TcpControlServerOwner<TestListener, TestClient, TestSession>()
        val firstListener = owners.installListener(TestListener("listener-a"))
        val firstClient = acceptClient(owners, firstListener, TestClient("client-a"))
        val firstSession = requireNotNull(
            owners.promoteAcceptedToSession(firstListener, firstClient, TestSession("session-a"))
        )
        val retired = owners.beginStopCleanup()
        owners.completeCleanup(retired) shouldBe true
        val successor = owners.installListener(TestListener("listener-b"))
        val successorClient = acceptClient(owners, successor, TestClient("client-b"))
        val successorSession = requireNotNull(
            owners.promoteAcceptedToSession(successor, successorClient, TestSession("session-b"))
        )

        retired.sessions shouldBe listOf(firstSession)
        owners.retireSession(firstSession) shouldBe false
        owners.sessionCount shouldBe 1
        owners.retireSession(successorSession) shouldBe true
    }
})

private data class TestListener(val id: String)
private data class TestClient(val id: String)
private data class TestSession(val id: String)

private const val HANG_GUARD_SECONDS = 5L

private fun <S : Any> acceptClient(
    owners: TcpControlServerOwner<TestListener, TestClient, S>,
    listener: TcpControlServerOwner.ListenerOwner<TestListener>,
    client: TestClient
): TcpControlServerOwner.ClientOwner<TestClient> {
    val reservation = requireNotNull(owners.beginAcceptWhenAvailable(listener))
    return requireNotNull(owners.completeAcceptSuccess(reservation, client))
}

private class RetryableTestSession(
    private val onClosed: () -> Unit
) {
    private val closeState = TcpControlSessionCloseState()
    var failNextClose = false
    var closeAttempts = 0
        private set
    var closeNotifications = 0
        private set

    fun close() = closeState.close(
        prepare = {},
        closeSocket = {
            closeAttempts += 1
            if (failNextClose) {
                failNextClose = false
                throw IOException("injected socket close failure")
            }
        },
        notifyClosed = {
            closeNotifications += 1
            onClosed()
        }
    )
}
