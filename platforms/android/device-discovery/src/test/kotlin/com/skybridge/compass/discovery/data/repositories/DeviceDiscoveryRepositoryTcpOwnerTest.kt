package com.skybridge.compass.discovery.data.repositories

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import java.io.IOException

class DeviceDiscoveryRepositoryTcpOwnerTest : FunSpec({
    test("failed close retains the exact session for a later disconnect retry") {
        val owners = TcpSessionOwnerRegistry<String, RetryableRepositorySession>(
            maxOwners = 2,
            closeOwner = RetryableRepositorySession::close
        )
        val session = RetryableRepositorySession(failNextClose = true)
        owners.replace(DEVICE_ID) { onClosed -> session.attach(onClosed) }

        shouldThrow<IOException> {
            owners.disconnect(DEVICE_ID)
        }
        owners.owner(DEVICE_ID) shouldBe session

        owners.disconnect(DEVICE_ID)
        session.closeAttempts shouldBe 2
        owners.owner(DEVICE_ID) shouldBe null
    }

    test("replacement closes predecessor before publishing successor") {
        val owners = TcpSessionOwnerRegistry<String, RetryableRepositorySession>(
            maxOwners = 2,
            closeOwner = RetryableRepositorySession::close
        )
        val successor = RetryableRepositorySession()
        val old = RetryableRepositorySession()
        owners.replace(DEVICE_ID) { onClosed -> old.attach(onClosed) }

        owners.replace(DEVICE_ID) { onClosed ->
            old.closeAttempts shouldBe 1
            successor.attach(onClosed)
        }

        old.closeAttempts shouldBe 1
        owners.owner(DEVICE_ID) shouldBe successor
        owners.size() shouldBe 1
    }

    test("predecessor close failure prevents successor creation and preserves predecessor") {
        val owners = TcpSessionOwnerRegistry<String, RetryableRepositorySession>(
            maxOwners = 1,
            closeOwner = RetryableRepositorySession::close
        )
        val predecessor = RetryableRepositorySession(failNextClose = true)
        var successorCreated = false
        owners.replace(DEVICE_ID) { onClosed -> predecessor.attach(onClosed) }

        shouldThrow<IOException> {
            owners.replace(DEVICE_ID) { onClosed ->
                successorCreated = true
                RetryableRepositorySession().attach(onClosed)
            }
        }

        successorCreated shouldBe false
        owners.owner(DEVICE_ID) shouldBe predecessor
        owners.size() shouldBe 1
    }

    test("owner capacity is bounded and failed creation releases its reservation") {
        val owners = TcpSessionOwnerRegistry<String, RetryableRepositorySession>(
            maxOwners = 1,
            closeOwner = RetryableRepositorySession::close
        )
        owners.replace("peer-a") { onClosed -> RetryableRepositorySession().attach(onClosed) }

        shouldThrow<IllegalStateException> {
            owners.replace("peer-b") { onClosed -> RetryableRepositorySession().attach(onClosed) }
        }
        owners.size() shouldBe 1
    }

    test("remote close retires its exact owner and cannot remove a successor") {
        val owners = TcpSessionOwnerRegistry<String, RetryableRepositorySession>(
            maxOwners = 2,
            closeOwner = RetryableRepositorySession::close
        )
        val first = RetryableRepositorySession()
        owners.replace(DEVICE_ID) { onClosed -> first.attach(onClosed) }

        first.close()
        owners.owner(DEVICE_ID) shouldBe null
        owners.size() shouldBe 0

        val successor = RetryableRepositorySession()
        owners.replace(DEVICE_ID) { onClosed -> successor.attach(onClosed) }
        first.repeatCloseNotification()
        owners.owner(DEVICE_ID) shouldBe successor
        owners.size() shouldBe 1
    }
})

private class RetryableRepositorySession(
    private var failNextClose: Boolean = false
) {
    private var onClosed: ((RetryableRepositorySession) -> Unit)? = null
    private var closed = false
    var closeAttempts = 0
        private set

    fun attach(callback: (RetryableRepositorySession) -> Unit): RetryableRepositorySession =
        apply { onClosed = callback }

    fun close() {
        closeAttempts += 1
        if (failNextClose) {
            failNextClose = false
            throw IOException("injected repository close failure")
        }
        if (!closed) {
            closed = true
            onClosed?.invoke(this)
        }
    }

    fun repeatCloseNotification() {
        onClosed?.invoke(this)
    }
}

private const val DEVICE_ID = "peer-a"
