package com.skybridge.compass.core.p2p

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import java.io.IOException

class TcpControlClientCleanupRegistryTest : FunSpec({
    test("primary failure retains cleanup failure as suppressed and the next connect retries") {
        val owner = RetryableClientOwner()
        val registry = TcpControlClientCleanupRegistry<RetryableClientOwner>(
            maxOwners = 1,
            closeOwner = RetryableClientOwner::close
        )

        owner.failNextClose = true
        val cleanupFailure = registry.closeAfterFailure(owner)
        val primaryFailure = IOException("handshake failed")
        cleanupFailure?.let(primaryFailure::addSuppressed)

        primaryFailure.suppressed.toList() shouldBe listOf(cleanupFailure)
        registry.pendingCount() shouldBe 1

        registry.retryBeforeNextConnect()
        owner.closeAttempts shouldBe 2
        registry.pendingCount() shouldBe 0
    }

    test("new connect remains refused while the exact pending owner still fails cleanup") {
        val owner = RetryableClientOwner(alwaysFail = true)
        val registry = TcpControlClientCleanupRegistry<RetryableClientOwner>(
            maxOwners = 1,
            closeOwner = RetryableClientOwner::close
        )

        registry.closeAfterFailure(owner)
        val failure = shouldThrow<IllegalStateException> {
            registry.retryBeforeNextConnect()
        }

        failure.suppressed.single().message shouldBe "injected client cleanup failure"
        owner.closeAttempts shouldBe 2
        registry.pendingCount() shouldBe 1
    }
})

private class RetryableClientOwner(
    private val alwaysFail: Boolean = false
) {
    var failNextClose = false
    var closeAttempts = 0
        private set

    fun close() {
        closeAttempts += 1
        if (alwaysFail || failNextClose) {
            failNextClose = false
            throw IOException("injected client cleanup failure")
        }
    }
}
