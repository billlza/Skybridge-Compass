package com.skybridge.compass.discovery.data.datasources

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class BonjourRegistrationLeaseRegistryTest : FunSpec({
    test("a late callback for a retired lease cannot remove its replacement") {
        val registry = BonjourRegistrationLeaseRegistry<TestRegistration>()
        val first = registry.install(SERVICE_TYPE, TestRegistration("a"))
        requireNotNull(registry.retireIfCurrent(first))
        val replacement = registry.install(SERVICE_TYPE, TestRegistration("b"))

        registry.retireIfCurrent(first) shouldBe null
        registry.current(SERVICE_TYPE) shouldBe replacement
        registry.isCurrent(replacement) shouldBe true
    }

    test("retiring a current lease without a waiter is distinguishable from a stale callback") {
        val registry = BonjourRegistrationLeaseRegistry<TestRegistration>()
        val lease = registry.install(SERVICE_TYPE, TestRegistration("a"))

        val retired = requireNotNull(registry.retireIfCurrent(lease))
        retired.attempt shouldBe null
        registry.hasActiveLeases() shouldBe false
        registry.retireIfCurrent(lease) shouldBe null
    }

    test("a failed unregistration can retain the exact lease for a later retry") {
        val registry = BonjourRegistrationLeaseRegistry<TestRegistration>()
        val lease = registry.install(SERVICE_TYPE, TestRegistration("a"))
        registry.markRegistered(lease) shouldBe false
        val firstClaim = requireNotNull(registry.claimStop(lease))
        firstClaim.shouldUnregister shouldBe true
        val concurrentClaim = requireNotNull(registry.claimStop(lease))
        concurrentClaim.attempt shouldBe firstClaim.attempt
        concurrentClaim.shouldUnregister shouldBe false

        val failedAttempt = registry.failStop(lease)
        failedAttempt shouldBe firstClaim.attempt
        failedAttempt?.completeExceptionally(IllegalStateException("unregister failed"))
        firstClaim.attempt.isCompleted shouldBe true
        runCatching { firstClaim.attempt.await() }.exceptionOrNull()?.message shouldBe "unregister failed"
        val retry = requireNotNull(registry.claimStop(lease))

        registry.current(SERVICE_TYPE) shouldBe lease
        registry.hasActiveLeases() shouldBe true
        lease.stopRequested shouldBe true
        retry.shouldUnregister shouldBe true
        (retry.attempt === firstClaim.attempt) shouldBe false
    }

    test("a stop claimed while registering sends one unregister request") {
        val registry = BonjourRegistrationLeaseRegistry<TestRegistration>()
        val lease = registry.install(SERVICE_TYPE, TestRegistration("a"))

        val first = requireNotNull(registry.claimStop(lease))
        first.shouldUnregister shouldBe true
        registry.markRegistered(lease) shouldBe false
        val duplicate = requireNotNull(registry.claimStop(lease))
        duplicate.attempt shouldBe first.attempt
        duplicate.shouldUnregister shouldBe false
    }

    test("successful unregistration returns and completes the exact stop waiter") {
        val registry = BonjourRegistrationLeaseRegistry<TestRegistration>()
        val lease = registry.install(SERVICE_TYPE, TestRegistration("a"))
        registry.markRegistered(lease) shouldBe false
        val claim = requireNotNull(registry.claimStop(lease))

        val retired = requireNotNull(registry.completeStop(lease))
        retired.attempt shouldBe claim.attempt
        registry.hasActiveLeases() shouldBe false
        retired.attempt?.complete(Unit)
        claim.attempt.await()
        claim.attempt.isCompleted shouldBe true
    }
})

private data class TestRegistration(val id: String)

private const val SERVICE_TYPE = "_skybridge._tcp"
