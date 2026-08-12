package com.skybridge.compass.android.securityprompts

import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class SecurityPromptStoreTest {
    @Test
    fun `concurrent identical inbound requests share one decision owner`() = runBlocking {
        repeat(40) { iteration ->
            val transferId = "concurrent-inbound-$iteration-${System.nanoTime()}"
            val prompt = inboundPrompt(transferId)
            val start = CompletableDeferred<Unit>()

            val decisions = coroutineScope {
                List(24) {
                    async(Dispatchers.Default) {
                        start.await()
                        SecurityPromptStore.requestInboundDecision(prompt, timeoutMs = 5_000)
                    }
                }.also { start.complete(Unit) }.awaitAll()
            }

            assertTrue(decisions.all { it === decisions.first() })
            assertSame(
                decisions.first(),
                SecurityPromptStore.requestInboundDecision(
                    prompt.copy(createdAtMs = prompt.createdAtMs + 1),
                    timeoutMs = 5_000
                )
            )
            assertEquals(prompt, SecurityPromptStore.getInboundPrompt(transferId))
            SecurityPromptStore.resolveInbound(
                transferId,
                SecurityPromptStore.InboundFileTransferDecision.Decline
            )
            assertSame(
                SecurityPromptStore.InboundFileTransferDecision.Decline,
                withTimeout(1_000) { decisions.first().await() }
            )
            assertNull(SecurityPromptStore.getInboundPrompt(transferId))
        }
    }

    @Test
    fun `same inbound id with different security fields is rejected`() = runBlocking {
        val transferId = "conflicting-inbound-${System.nanoTime()}"
        val original = inboundPrompt(transferId)
        val decision = SecurityPromptStore.requestInboundDecision(original, timeoutMs = 5_000)

        try {
            val conflict = original.copy(fileName = "different.bin")
            assertThrows(SecurityPromptIdentityConflictException::class.java) {
                SecurityPromptStore.requestInboundDecision(conflict, timeoutMs = 5_000)
            }
            assertEquals(original, SecurityPromptStore.getInboundPrompt(transferId))
        } finally {
            SecurityPromptStore.resolveInbound(
                transferId,
                SecurityPromptStore.InboundFileTransferDecision.Decline
            )
        }

        assertSame(
            SecurityPromptStore.InboundFileTransferDecision.Decline,
            withTimeout(1_000) { decision.await() }
        )
    }

    @Test
    fun `resolve and timeout race completes the inbound decision exactly once`() = runBlocking {
        repeat(40) { iteration ->
            val transferId = "timeout-race-$iteration-${System.nanoTime()}"
            val decision = SecurityPromptStore.requestInboundDecision(
                inboundPrompt(transferId),
                timeoutMs = 15
            )

            val manualResolve = async(Dispatchers.Default) {
                delay(15)
                SecurityPromptStore.resolveInbound(
                    transferId,
                    SecurityPromptStore.InboundFileTransferDecision.Accept(
                        downloadsDisplayName = "accepted.bin",
                        overwriteExisting = false
                    )
                )
            }
            val resolved = withTimeout(1_000) { decision.await() }
            manualResolve.await()

            assertTrue(
                resolved is SecurityPromptStore.InboundFileTransferDecision.Accept ||
                    resolved === SecurityPromptStore.InboundFileTransferDecision.Decline
            )
            assertNull(SecurityPromptStore.getInboundPrompt(transferId))
            SecurityPromptStore.resolveInbound(
                transferId,
                SecurityPromptStore.InboundFileTransferDecision.Decline
            )
            assertEquals(resolved, decision.await())
        }
    }

    @Test
    fun `concurrent identical pairing requests share one decision and conflicts fail closed`() = runBlocking {
        val requestId = "pairing-${System.nanoTime()}"
        val prompt = PairingTrustRequest(
            requestId = requestId,
            peerId = "peer-a",
            declaredDeviceId = "device-a",
            protocolPublicKeyFingerprint = "sha256:aa"
        )
        val start = CompletableDeferred<Unit>()
        val decisions = coroutineScope {
            List(24) {
                async(Dispatchers.Default) {
                    start.await()
                    SecurityPromptStore.requestPairingDecision(prompt, timeoutMs = 5_000)
                }
            }.also { start.complete(Unit) }.awaitAll()
        }

        try {
            assertTrue(decisions.all { it === decisions.first() })
            assertThrows(SecurityPromptIdentityConflictException::class.java) {
                SecurityPromptStore.requestPairingDecision(
                    prompt.copy(peerId = "peer-b"),
                    timeoutMs = 5_000
                )
            }
        } finally {
            SecurityPromptStore.resolvePairing(requestId, PairingTrustDecision.DECLINE)
        }

        assertSame(PairingTrustDecision.DECLINE, withTimeout(1_000) { decisions.first().await() })
        assertNull(SecurityPromptStore.getPairingPrompt(requestId))
    }

    @Test
    fun `non-positive prompt timeouts are rejected before registration`() {
        val inboundId = "invalid-timeout-${System.nanoTime()}"
        assertThrows(IllegalArgumentException::class.java) {
            SecurityPromptStore.requestInboundDecision(inboundPrompt(inboundId), timeoutMs = 0)
        }
        assertNull(SecurityPromptStore.getInboundPrompt(inboundId))
    }

    @Test
    fun `inbound admission is bounded per sender and globally`() {
        val perSenderIds = List(SecurityPromptStore.MAX_PENDING_INBOUND_PROMPTS_PER_SENDER) { index ->
            "bounded-sender-$index-${System.nanoTime()}"
        }
        try {
            perSenderIds.forEach { transferId ->
                SecurityPromptStore.requestInboundDecision(
                    inboundPrompt(transferId).copy(senderDeviceId = "bounded-peer"),
                    timeoutMs = 5_000
                )
            }
            val rejectedId = "bounded-sender-rejected-${System.nanoTime()}"
            assertThrows(SecurityPromptCapacityExceededException::class.java) {
                SecurityPromptStore.requestInboundDecision(
                    inboundPrompt(rejectedId).copy(senderDeviceId = "bounded-peer"),
                    timeoutMs = 5_000
                )
            }
            assertNull(SecurityPromptStore.getInboundPrompt(rejectedId))
        } finally {
            perSenderIds.forEach { transferId ->
                SecurityPromptStore.resolveInbound(
                    transferId,
                    SecurityPromptStore.InboundFileTransferDecision.Decline
                )
            }
        }

        val globalIds = List(SecurityPromptStore.MAX_PENDING_INBOUND_PROMPTS) { index ->
            "bounded-global-$index-${System.nanoTime()}"
        }
        try {
            globalIds.forEachIndexed { index, transferId ->
                SecurityPromptStore.requestInboundDecision(
                    inboundPrompt(transferId).copy(senderDeviceId = "bounded-peer-$index"),
                    timeoutMs = 5_000
                )
            }
            val rejectedId = "bounded-global-rejected-${System.nanoTime()}"
            assertThrows(SecurityPromptCapacityExceededException::class.java) {
                SecurityPromptStore.requestInboundDecision(
                    inboundPrompt(rejectedId).copy(senderDeviceId = "new-peer"),
                    timeoutMs = 5_000
                )
            }
            assertNull(SecurityPromptStore.getInboundPrompt(rejectedId))
        } finally {
            globalIds.forEach { transferId ->
                SecurityPromptStore.resolveInbound(
                    transferId,
                    SecurityPromptStore.InboundFileTransferDecision.Decline
                )
            }
        }
    }

    @Test
    fun `pairing admission is bounded per peer`() {
        val requestIds = List(SecurityPromptStore.MAX_PENDING_PAIRING_PROMPTS_PER_PEER) { index ->
            "bounded-pairing-$index-${System.nanoTime()}"
        }
        try {
            requestIds.forEach { requestId ->
                SecurityPromptStore.requestPairingDecision(
                    pairingPrompt(requestId, peerId = "bounded-peer"),
                    timeoutMs = 5_000
                )
            }
            val rejectedId = "bounded-pairing-rejected-${System.nanoTime()}"
            assertThrows(SecurityPromptCapacityExceededException::class.java) {
                SecurityPromptStore.requestPairingDecision(
                    pairingPrompt(rejectedId, peerId = "bounded-peer"),
                    timeoutMs = 5_000
                )
            }
            assertNull(SecurityPromptStore.getPairingPrompt(rejectedId))
        } finally {
            requestIds.forEach { requestId ->
                SecurityPromptStore.resolvePairing(requestId, PairingTrustDecision.DECLINE)
            }
        }
    }

    private fun inboundPrompt(transferId: String) =
        SecurityPromptStore.InboundFileTransferPrompt(
            transferId = transferId,
            fileName = "payload.bin",
            mimeType = "application/octet-stream",
            fileSizeBytes = 128,
            senderDeviceId = "device-a",
            senderDeviceName = "Peer A"
        )

    private fun pairingPrompt(requestId: String, peerId: String) =
        PairingTrustRequest(
            requestId = requestId,
            peerId = peerId,
            declaredDeviceId = "device-a",
            protocolPublicKeyFingerprint = "sha256:aa"
        )
}
