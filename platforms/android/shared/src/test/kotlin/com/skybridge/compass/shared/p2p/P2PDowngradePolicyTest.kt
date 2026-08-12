package com.skybridge.compass.shared.p2p

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of the canonical Rust policy tests
 * (`rust/crates/skybridge-core/src/policy.rs#tests`) plus the SBP2 TX-padding
 * round-trip, ensuring the Android downgrade taxonomy matches canon.
 */
class P2PDowngradePolicyTest {

    private val pqcSuite = P2PCryptoSuite.MLKEM_768
    private val classicSuite = P2PCryptoSuite.X25519

    // ---- Taxonomy: BLOCKED reasons are never eligible ----

    @Test
    fun blockedReasonsAreNotFallbackEligible() {
        val blocked = listOf(
            FallbackReason.TIMEOUT,
            FallbackReason.SIGNATURE_VERIFICATION_FAILED,
            FallbackReason.REPLAY_DETECTED,
            FallbackReason.KEY_CONFIRMATION_FAILED,
            FallbackReason.IDENTITY_MISMATCH,
            FallbackReason.SUITE_SIGNATURE_MISMATCH
        )
        for (reason in blocked) {
            assertFalse("$reason must be structurally fallback-ineligible", reason.isFallbackEligible())
        }
    }

    @Test
    fun allowedReasonsAreFallbackEligible() {
        assertTrue(FallbackReason.PQC_PROVIDER_UNAVAILABLE.isFallbackEligible())
        assertTrue(FallbackReason.SUITE_NEGOTIATION_FAILED.isFallbackEligible())
    }

    // ---- Gate: BLOCKED reasons are denied even under PREFER_PQC ----

    @Test
    fun gateDeniesBlockedReasonsEvenWhenPolicyAllows() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val blocked = listOf(
            FallbackReason.TIMEOUT,
            FallbackReason.SIGNATURE_VERIFICATION_FAILED,
            FallbackReason.REPLAY_DETECTED,
            FallbackReason.KEY_CONFIRMATION_FAILED,
            FallbackReason.IDENTITY_MISMATCH,
            FallbackReason.SUITE_SIGNATURE_MISMATCH
        )
        for (reason in blocked) {
            val decision = gate.authorizeDowngrade("peer-a", pqcSuite, classicSuite, reason)
            assertEquals(DowngradeDecision.DeniedReasonIneligible(reason), decision)
            assertFalse(decision.isAllowed)
        }
    }

    // ---- Gate: eligible reason under PREFER_PQC is allowed ----

    @Test
    fun gateAllowsEligibleReasonUnderPreferPqc() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val decision = gate.authorizeDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.PQC_PROVIDER_UNAVAILABLE,
            transcriptAnchor = byteArrayOf(0xab.toByte(), 0xcd.toByte())
        )
        assertTrue(decision.isAllowed)
        val event = decision.eventOrNull()
        assertNotNull(event)
        assertEquals(pqcSuite.wireId.toInt(), event!!.fromSuite)
        assertEquals(classicSuite.wireId.toInt(), event.toSuite)
        assertEquals(FallbackReason.PQC_PROVIDER_UNAVAILABLE, event.reason)
        assertEquals("abcd", event.transcriptAnchorHex)
        assertEquals(DowngradeEvent.DOWNGRADE_RESISTANCE, event.downgradeResistance)
    }

    // ---- Strict modes deny business fallback ----

    @Test
    fun strictComplianceDeniesEligibleReason() {
        val gate = PolicyGate(DowngradePolicy.STRICT_PQC_COMPLIANCE)
        val decision = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.SUITE_NEGOTIATION_FAILED
        )
        assertEquals(DowngradeDecision.DeniedByPolicy, decision)
    }

    @Test
    fun strictBootstrapDeniesBusinessFallbackButAllowsControlChannel() {
        val policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED
        assertFalse(policy.allowsClassicBusinessFallback())
        assertTrue(policy.allowsBootstrapControlChannel())

        val gate = PolicyGate(policy)
        val decision = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.PQC_PROVIDER_UNAVAILABLE
        )
        assertEquals(DowngradeDecision.DeniedByPolicy, decision)
    }

    // ---- 300 s cooldown enforced: second fallback within window denied ----

    @Test
    fun cooldownDeniesSecondFallbackWithinWindow() {
        val store = P2PHandshakeWire.InMemoryFallbackCooldownStore()
        var now = 1_000L
        val gate = PolicyGate(
            policy = DowngradePolicy.PREFER_PQC,
            cooldownStore = store,
            cooldownMillis = 300_000L,
            clock = { now }
        )
        val first = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.PQC_PROVIDER_UNAVAILABLE
        )
        assertTrue("first fallback should be authorized", first.isAllowed)

        now += 1_000L // still inside the window
        val second = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.PQC_PROVIDER_UNAVAILABLE
        )
        assertTrue(second is DowngradeDecision.DeniedRateLimited)
        val remaining = (second as DowngradeDecision.DeniedRateLimited).remainingMillis
        assertTrue(remaining in 1..300_000L)
    }

    @Test
    fun cooldownIsPerPeer() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val a = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.PQC_PROVIDER_UNAVAILABLE
        )
        val b = gate.authorizeDowngrade(
            "peer-b", pqcSuite, classicSuite, FallbackReason.PQC_PROVIDER_UNAVAILABLE
        )
        assertTrue(a.isAllowed)
        assertTrue("a different peer must not share the cooldown", b.isAllowed)
    }

    @Test
    fun cooldownExpiryAllowsAgain() {
        val store = P2PHandshakeWire.InMemoryFallbackCooldownStore()
        var now = 1_000L
        val gate = PolicyGate(
            policy = DowngradePolicy.PREFER_PQC,
            cooldownStore = store,
            cooldownMillis = 300_000L,
            clock = { now }
        )
        val first = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.SUITE_NEGOTIATION_FAILED
        )
        now += 300_001L // past the window
        val second = gate.authorizeDowngrade(
            "peer-a", pqcSuite, classicSuite, FallbackReason.SUITE_NEGOTIATION_FAILED
        )
        assertTrue(first.isAllowed)
        assertTrue("expired cooldown should re-allow fallback", second.isAllowed)
    }

    // ---- DowngradeEvent round-trips through serialization ----

    @Test
    fun downgradeEventRoundTripsThroughJson() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val decision = gate.authorizeDowngrade(
            peer = "peer-roundtrip",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.PQC_PROVIDER_UNAVAILABLE,
            transcriptAnchor = byteArrayOf(0xde.toByte(), 0xad.toByte(), 0xbe.toByte(), 0xef.toByte())
        )
        val event = decision.eventOrNull()!!

        val json = Json.encodeToString(DowngradeEvent.serializer(), event)
        val decoded = Json.decodeFromString(DowngradeEvent.serializer(), json)

        assertEquals(event, decoded)
        assertEquals("peer-roundtrip", decoded.peer)
        assertEquals(pqcSuite.wireId.toInt(), decoded.fromSuite)
        assertEquals(classicSuite.wireId.toInt(), decoded.toSuite)
        assertEquals(FallbackReason.PQC_PROVIDER_UNAVAILABLE, decoded.reason)
        assertEquals(DowngradePolicy.PREFER_PQC, decoded.policy)
        assertEquals(300L, decoded.cooldownSeconds)
        assertEquals("deadbeef", decoded.transcriptAnchorHex)
        // snake_case wire keys match the canon serde format
        assertTrue(json.contains("\"from_suite\""))
        assertTrue(json.contains("\"pqc_provider_unavailable\""))
        assertTrue(json.contains("\"prefer_pqc\""))
    }

    @Test
    fun wirePolicyByteMatchesLegacyFormat() {
        assertEquals(0x01.toByte(), DowngradePolicy.PREFER_PQC.wirePolicyByte())
        assertEquals(0x01.toByte(), DowngradePolicy.STRICT_PQC_COMPLIANCE.wirePolicyByte())
        assertEquals(0x00.toByte(), DowngradePolicy.DEFAULT.wirePolicyByte())
    }

    @Test
    fun fromHandshakePolicyMapsPostures() {
        assertEquals(
            DowngradePolicy.STRICT_PQC_COMPLIANCE,
            DowngradePolicy.fromHandshakePolicy(
                P2PHandshakePolicy(requirePqc = true, allowClassicFallback = false, minimumTierRaw = "nativePQC")
            )
        )
        assertEquals(
            DowngradePolicy.PREFER_PQC,
            DowngradePolicy.fromHandshakePolicy(
                P2PHandshakePolicy(requirePqc = true, allowClassicFallback = true, minimumTierRaw = "liboqsPQC")
            )
        )
        assertEquals(
            DowngradePolicy.STRICT_PQC_COMPLIANCE,
            DowngradePolicy.fromHandshakePolicy(P2PHandshakePolicy.DEFAULT)
        )
    }

    // ---- SBP2 TX padding round-trip behind the flag ----

    @Test
    fun sbp2WrapDisabledByDefaultReturnsPayloadUnchanged() {
        val payload = ByteArray(40) { it.toByte() }
        assertFalse(TrafficPaddingP2.txPaddingEnabled)
        val wrapped = TrafficPaddingP2.wrapIfEnabled(payload)
        assertTrue("disabled wrap must be identity", wrapped.contentEquals(payload))
    }

    @Test
    fun sbp2WrapEnabledPadsToBucketAndUnwrapsBackToOriginal() {
        val payload = ByteArray(40) { (it + 7).toByte() }
        try {
            TrafficPaddingP2.txPaddingEnabled = true
            val wrapped = TrafficPaddingP2.wrapIfEnabled(payload)
            // Padded up to the next 256-byte bucket.
            assertEquals(TrafficPaddingP2.PADDING_BUCKET, wrapped.size)
            assertTrue("wrapped must be larger than payload", wrapped.size > payload.size)
            val unwrapped = TrafficPaddingP2.unwrapIfNeeded(wrapped)
            assertTrue("unwrap must recover the exact payload", unwrapped.contentEquals(payload))
        } finally {
            TrafficPaddingP2.txPaddingEnabled = false
        }
        assertFalse(TrafficPaddingP2.txPaddingEnabled)
    }

    @Test
    fun unwrapIgnoresUnframedTraffic() {
        val plain = ByteArray(20) { (it * 3).toByte() }
        assertTrue(TrafficPaddingP2.unwrapIfNeeded(plain).contentEquals(plain))
    }

    @Test
    fun handshakeClientEmitsStructuredDowngradeEventOnClassicFallback() {
        // API 17 + liboqs available but no peer KEM key -> classic fallback.
        var sunk: DowngradeEvent? = null
        val store = P2PHandshakeWire.InMemoryFallbackCooldownStore()
        val client = P2PHandshakeClient(platformVersion = "Android 17 (API 37)")
        val (state, _) = client.start(
            P2PHandshakeClient.StartOptions(
                peerIdForFallbackCooldown = "peer-fallback",
                fallbackCooldownStore = store,
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
                handshakePolicy = P2PHandshakePolicy(
                    requirePqc = false,
                    allowClassicFallback = true,
                    minimumTierRaw = "classic"
                ),
                downgradeAuditSink = { sunk = it }
            )
        )
        val emitted = state.downgradeEvent
        assertNotNull("a structured downgrade event must be emitted", emitted)
        assertEquals(P2PCryptoSuite.X25519.wireId.toInt(), emitted!!.toSuite)
        assertEquals(FallbackReason.SUITE_NEGOTIATION_FAILED, emitted.reason)
        assertNotNull("audit sink must receive the event", sunk)
        assertEquals(emitted, sunk)
    }

    @Test
    fun handshakeWithoutPeerIdDoesNotEmitEvent() {
        val client = P2PHandshakeClient(platformVersion = "Android 17 (API 37)")
        val (state, _) = client.start(
            P2PHandshakeClient.StartOptions(
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
                handshakePolicy = P2PHandshakePolicy(
                    requirePqc = false,
                    allowClassicFallback = true,
                    minimumTierRaw = "classic"
                )
            )
        )
        assertNull(state.downgradeEvent)
    }

    // ---- R4.5: user-authorization gate (policy-eligibility AND explicit consent) ----

    /**
     * R4.5: every BLOCKED reason is denied by the user-approved gate even when the
     * user *has* granted authorization — the structural reason gate still wins, so a
     * BLOCKED reason never authorizes a downgrade and never mints an audit event.
     */
    @Test
    fun userApprovedGateDeniesBlockedReasonsEvenWithUserConsent() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val grant = UserDowngradeAuthorization.Granted(
            peer = "peer-a",
            fromSuiteWireId = pqcSuite.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val blocked = listOf(
            FallbackReason.TIMEOUT,
            FallbackReason.SIGNATURE_VERIFICATION_FAILED,
            FallbackReason.REPLAY_DETECTED,
            FallbackReason.KEY_CONFIRMATION_FAILED,
            FallbackReason.IDENTITY_MISMATCH,
            FallbackReason.SUITE_SIGNATURE_MISMATCH
        )
        for (reason in blocked) {
            val decision = gate.authorizeUserApprovedDowngrade(
                peer = "peer-a",
                fromSuite = pqcSuite,
                toSuite = classicSuite,
                reason = reason,
                userAuthorization = grant
            )
            assertEquals(
                "$reason must stay ineligible even with user consent",
                DowngradeDecision.DeniedReasonIneligible(reason),
                decision
            )
            assertNull("no audit event for a BLOCKED reason", decision.eventOrNull())
        }
    }

    /**
     * R4.5: a policy-eligible, fallback-eligible reason is STILL denied when the user
     * has not authorized the downgrade — and no cooldown is consumed / no event minted.
     */
    @Test
    fun userApprovedGateDeniesEligibleReasonWithoutUserAuthorization() {
        val store = P2PHandshakeWire.InMemoryFallbackCooldownStore()
        val gate = PolicyGate(policy = DowngradePolicy.PREFER_PQC, cooldownStore = store)

        val decision = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
            userAuthorization = UserDowngradeAuthorization.NotAuthorized
        )
        assertEquals(DowngradeDecision.DeniedUserNotAuthorized, decision)
        assertNull(decision.eventOrNull())

        // Cooldown must NOT have been consumed by the denied attempt: a subsequent
        // properly-authorized request for the same peer is allowed immediately.
        val grant = UserDowngradeAuthorization.Granted(
            peer = "peer-a",
            fromSuiteWireId = pqcSuite.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val authorized = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
            userAuthorization = grant
        )
        assertTrue("denied attempt must not have armed the cooldown", authorized.isAllowed)
    }

    /**
     * R4.5: only when BOTH the policy permits it AND the user explicitly authorized
     * the exact peer/suite transition is a downgrade allowed and an audit event emitted.
     */
    @Test
    fun userApprovedGateAllowsWhenPolicyEligibleAndUserAuthorized() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        val grant = UserDowngradeAuthorization.Granted(
            peer = "peer-a",
            fromSuiteWireId = pqcSuite.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val decision = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.PQC_PROVIDER_UNAVAILABLE,
            userAuthorization = grant,
            transcriptAnchor = byteArrayOf(0x01, 0x02)
        )
        assertTrue(decision.isAllowed)
        val event = decision.eventOrNull()
        assertNotNull("an auditable downgrade event must be emitted", event)
        assertEquals(FallbackReason.PQC_PROVIDER_UNAVAILABLE, event!!.reason)
        assertEquals(classicSuite.wireId.toInt(), event.toSuite)
    }

    /**
     * R4.5: a user grant is scoped — a consent for a *different* suite transition (or
     * peer) does not authorize this one. Even under a permissive policy + eligible
     * reason, a mismatched grant is denied.
     */
    @Test
    fun userApprovedGateRejectsMismatchedGrantScope() {
        val gate = PolicyGate(DowngradePolicy.PREFER_PQC)
        // Grant names a different from-suite than the one actually being downgraded.
        val mismatchedGrant = UserDowngradeAuthorization.Granted(
            peer = "peer-a",
            fromSuiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val decision = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite, // != X_WING named in the grant
            toSuite = classicSuite,
            reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
            userAuthorization = mismatchedGrant
        )
        assertEquals(DowngradeDecision.DeniedUserNotAuthorized, decision)

        // A grant for a different peer likewise does not authorize peer-a.
        val otherPeerGrant = UserDowngradeAuthorization.Granted(
            peer = "peer-b",
            fromSuiteWireId = pqcSuite.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val decision2 = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
            userAuthorization = otherPeerGrant
        )
        assertEquals(DowngradeDecision.DeniedUserNotAuthorized, decision2)
    }

    /**
     * R4.5: even a fully-authorized user grant cannot override a strict policy posture
     * that forbids classic business fallback.
     */
    @Test
    fun userApprovedGateStillHonorsStrictPolicy() {
        val gate = PolicyGate(DowngradePolicy.STRICT_PQC_COMPLIANCE)
        val grant = UserDowngradeAuthorization.Granted(
            peer = "peer-a",
            fromSuiteWireId = pqcSuite.wireId.toInt(),
            toSuiteWireId = classicSuite.wireId.toInt()
        )
        val decision = gate.authorizeUserApprovedDowngrade(
            peer = "peer-a",
            fromSuite = pqcSuite,
            toSuite = classicSuite,
            reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
            userAuthorization = grant
        )
        assertEquals(DowngradeDecision.DeniedByPolicy, decision)
    }
}
