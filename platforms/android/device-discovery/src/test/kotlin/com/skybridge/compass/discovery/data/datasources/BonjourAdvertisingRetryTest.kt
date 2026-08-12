package com.skybridge.compass.discovery.data.datasources

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.collections.shouldContainExactly
import io.kotest.matchers.shouldBe
import io.kotest.matchers.string.shouldContain
import io.kotest.matchers.types.shouldBeInstanceOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.test.runTest

/**
 * Task 7.8 — Bonjour advertising registration retry & terminal-failure state (R3.13).
 *
 * Covers:
 *  - retry sequence is exactly 1s / 2s / 4s and at most 3 retries (4 attempts total),
 *  - a terminal failure marks the advertising status as Failed with a reason,
 *  - early success stops retrying,
 *  - a failed advertise does not stop an independently-running browse flow.
 *
 * The backoff clock is injected so the test never actually waits 7+ seconds.
 */
class BonjourAdvertisingRetryTest : FunSpec({

    test("retry backoff schedule is exactly 1s, 2s, 4s with at most 3 retries") {
        // A pure check of the declared schedule so the constants can't silently drift.
        BonjourAdvertisingRetryPolicy.MAX_RETRIES shouldBe 3
        BonjourAdvertisingRetryPolicy.BACKOFF_DELAYS_MS shouldContainExactly listOf(1_000L, 2_000L, 4_000L)
    }

    test("all attempts fail: exactly 3 retries run with 1s/2s/4s backoff then last error rethrown") {
        val recordedBackoffs = mutableListOf<Long>()
        var attempts = 0

        val error = runCatchingThrowable {
            BonjourAdvertisingRetryPolicy.execute<String>(
                attempt = {
                    attempts += 1
                    throw IllegalStateException("registration failed #$attempts")
                },
                delayMs = { recordedBackoffs += it },
                onRetryScheduled = { _, _ -> }
            )
        }

        // 1 initial attempt + 3 retries.
        attempts shouldBe 4
        // The injected backoff clock saw exactly the 1s/2s/4s schedule, in order.
        recordedBackoffs shouldContainExactly listOf(1_000L, 2_000L, 4_000L)
        error.shouldBeInstanceOf<IllegalStateException>()
        error.message shouldContain "registration failed #4"
    }

    test("retry indices reported to the status hook are 1, 2, 3 with matching backoffs") {
        val retries = mutableListOf<Pair<Int, Long>>()

        runCatchingThrowable {
            BonjourAdvertisingRetryPolicy.execute<String>(
                attempt = { throw RuntimeException("boom") },
                delayMs = { },
                onRetryScheduled = { retryIndex, backoffMs -> retries += retryIndex to backoffMs }
            )
        }

        retries shouldContainExactly listOf(1 to 1_000L, 2 to 2_000L, 3 to 4_000L)
    }

    test("success on the 3rd attempt stops retrying and returns the result") {
        var attempts = 0
        val backoffs = mutableListOf<Long>()

        val result = BonjourAdvertisingRetryPolicy.execute(
            attempt = { index ->
                attempts += 1
                if (index < 2) throw IllegalStateException("not yet") else "service-name"
            },
            delayMs = { backoffs += it }
        )

        result shouldBe "service-name"
        attempts shouldBe 3
        // Only two backoffs were consumed (before retry 1 and retry 2); the 4s backoff never ran.
        backoffs shouldContainExactly listOf(1_000L, 2_000L)
    }

    test("first-attempt success performs no retries and no backoff") {
        val backoffs = mutableListOf<Long>()
        var attempts = 0

        val result = BonjourAdvertisingRetryPolicy.execute(
            attempt = { attempts += 1; "ok" },
            delayMs = { backoffs += it }
        )

        result shouldBe "ok"
        attempts shouldBe 1
        backoffs.isEmpty() shouldBe true
    }

    test("registrar publishes Registering -> Retrying(1,2,3) -> Failed(reason) on terminal failure") {
        val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
        val transitions = mutableListOf<BonjourAdvertisingStatus>()
        val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })

        runCatchingThrowable {
            registrar.register(serviceType = "_skybridge._tcp") {
                transitions += status.value
                throw IllegalStateException("NSD registration failed (errorCode=3)")
            }
        }

        // The status observed at the start of each of the 4 attempts.
        transitions[0] shouldBe BonjourAdvertisingStatus.Registering("_skybridge._tcp")
        transitions[1] shouldBe BonjourAdvertisingStatus.Retrying("_skybridge._tcp", attempt = 1, backoffMs = 1_000L)
        transitions[2] shouldBe BonjourAdvertisingStatus.Retrying("_skybridge._tcp", attempt = 2, backoffMs = 2_000L)
        transitions[3] shouldBe BonjourAdvertisingStatus.Retrying("_skybridge._tcp", attempt = 3, backoffMs = 4_000L)

        val terminal = status.value
        terminal.shouldBeInstanceOf<BonjourAdvertisingStatus.Failed>()
        terminal.serviceType shouldBe "_skybridge._tcp"
        terminal.reason shouldContain "failed after 3 retries"
        terminal.reason shouldContain "errorCode=3"
    }

    test("registrar publishes Active on success and returns the service name") {
        val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
        val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })

        val name = registrar.register(serviceType = "_skybridge._tcp") { "resolved-instance" }

        name shouldBe "resolved-instance"
        status.value shouldBe BonjourAdvertisingStatus.Active("_skybridge._tcp", "resolved-instance")
    }

    test("structured cancellation is propagated and does not mark the status Failed") {
        val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
        val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })

        val thrown = runCatchingThrowable {
            registrar.register(serviceType = "_skybridge._tcp") {
                throw CancellationException("scope cancelled")
            }
        }

        thrown.shouldBeInstanceOf<CancellationException>()
        // Status stays Registering — cancellation is not a terminal advertising failure.
        status.value shouldBe BonjourAdvertisingStatus.Registering("_skybridge._tcp")
    }

    test("a terminal advertise failure does not stop an independently-running browse flow") {
        runTest {
            val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
            val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })
            val browseResult = CompletableDeferred<String>()

            supervisorScope {
                // Advertise side: always fails terminally.
                val advertiseJob = async {
                    runCatchingThrowable {
                        registrar.register(serviceType = "_skybridge._tcp") {
                            throw IllegalStateException("registration failed")
                        }
                    }
                }
                // Browse side: independent job that keeps running to completion.
                launch {
                    browseResult.complete("browsing")
                }

                advertiseJob.await()
            }

            // Advertise reached terminal Failed state...
            status.value.shouldBeInstanceOf<BonjourAdvertisingStatus.Failed>()
            // ...yet the browse side completed normally, unaffected.
            browseResult.isCompleted shouldBe true
            browseResult.await() shouldBe "browsing"
        }
    }
})

/** Runs [block] and returns the thrown [Throwable]; fails loudly if nothing was thrown. */
private inline fun runCatchingThrowable(block: () -> Unit): Throwable {
    return try {
        block()
        throw AssertionError("Expected an exception to be thrown, but none was")
    } catch (assertion: AssertionError) {
        throw assertion
    } catch (t: Throwable) {
        t
    }
}
