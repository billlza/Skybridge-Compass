package com.skybridge.compass.discovery.data.datasources

import kotlinx.coroutines.CompletableDeferred

internal class BonjourRegistrationLeaseRegistry<T : Any> {
    private val leases = LinkedHashMap<String, Lease<T>>()

    fun install(serviceType: String, resource: T): Lease<T> {
        check(leases[serviceType] == null) {
            "NSD service $serviceType already has an active registration"
        }
        return Lease(serviceType = serviceType, resource = resource).also {
            leases[serviceType] = it
        }
    }

    fun current(serviceType: String): Lease<T>? = leases[serviceType]

    fun snapshot(): List<Lease<T>> = leases.values.toList()

    fun isCurrent(lease: Lease<T>): Boolean = leases[lease.serviceType] === lease

    fun markRegistered(lease: Lease<T>): Boolean {
        if (!isCurrent(lease)) return false
        return if (lease.stopRequested && lease.phase != Phase.UNREGISTERING) {
            lease.phase = Phase.UNREGISTERING
            true
        } else {
            if (lease.phase == Phase.REGISTERING) lease.phase = Phase.REGISTERED
            false
        }
    }

    fun claimStop(lease: Lease<T>): StopClaim? {
        if (!isCurrent(lease)) return null
        lease.stopRequested = true
        val existing = lease.unregisterAttempt
        if (existing != null) return StopClaim(existing, shouldUnregister = false)
        val attempt = CompletableDeferred<Unit>()
        lease.unregisterAttempt = attempt
        val shouldUnregister = lease.phase != Phase.UNREGISTERING
        lease.phase = Phase.UNREGISTERING
        return StopClaim(attempt, shouldUnregister)
    }

    fun failStop(lease: Lease<T>): CompletableDeferred<Unit>? {
        if (!isCurrent(lease)) return null
        lease.phase = Phase.REGISTERED
        lease.stopRequested = true
        val attempt = lease.unregisterAttempt
        lease.unregisterAttempt = null
        return attempt
    }

    fun retireIfCurrent(lease: Lease<T>): RetiredLease? {
        if (!isCurrent(lease)) return null
        leases.remove(lease.serviceType)
        return RetiredLease(
            attempt = lease.unregisterAttempt.also { lease.unregisterAttempt = null }
        )
    }

    fun completeStop(lease: Lease<T>): RetiredLease? = retireIfCurrent(lease)

    fun hasActiveLeases(): Boolean = leases.isNotEmpty()

    data class StopClaim(
        val attempt: CompletableDeferred<Unit>,
        val shouldUnregister: Boolean
    )

    data class RetiredLease(val attempt: CompletableDeferred<Unit>?)

    class Lease<T : Any> internal constructor(
        val serviceType: String,
        val resource: T,
        phase: Phase = Phase.REGISTERING,
        stopRequested: Boolean = false,
        unregisterAttempt: CompletableDeferred<Unit>? = null
    ) {
        var phase: Phase = phase
            internal set
        var stopRequested: Boolean = stopRequested
            internal set
        var unregisterAttempt: CompletableDeferred<Unit>? = unregisterAttempt
            internal set
    }

    enum class Phase { REGISTERING, REGISTERED, UNREGISTERING }
}
