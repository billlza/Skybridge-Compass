package com.skybridge.compass.core.p2p

import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class SoaPeerSessionArbiterTest {

    @Test
    fun `incoming supersedes local when remote wins`() {
        val now = longArrayOf(0L)
        val arbiter = SoaPeerSessionArbiter(nowNs = { now[0] })

        val pairKey = ByteArray(64) { 0x01 }
        val localPeerId = ByteArray(32) { 0x02 }
        val remotePeerId = ByteArray(32) { 0x01 } // lex smaller -> remote wins
        val localAttemptId = ByteArray(16) { 0x10 }
        val remoteAttemptId = ByteArray(16) { 0x20 }

        val superseded = AtomicBoolean(false)
        val decision = arbiter.registerOutgoing(
            SoaPeerSessionArbiter.OutgoingAttempt(
                pairKey = pairKey,
                initiatorPeerId = localPeerId,
                attemptId = localAttemptId,
                startedAtNs = now[0]
            ) { _, _ -> superseded.set(true) }
        )
        assertTrue(decision == SoaPeerSessionArbiter.RegisterDecision.Accepted)

        val incoming = arbiter.evaluateIncoming(
            pairKey = pairKey,
            remoteInitiatorPeerId = remotePeerId,
            remoteAttemptId = remoteAttemptId,
            targetPeerId = localPeerId,
            expectedRemotePeerId = remotePeerId,
            localPeerId = localPeerId
        )
        assertTrue(incoming is SoaPeerSessionArbiter.IncomingDecision.AcceptAndSupersedeLocal)
        assertTrue(superseded.get())
    }

    @Test
    fun `incoming is rejected when local wins`() {
        val arbiter = SoaPeerSessionArbiter()

        val pairKey = ByteArray(64) { 0x01 }
        val localPeerId = ByteArray(32) { 0x01 } // lex smaller -> local wins
        val remotePeerId = ByteArray(32) { 0x02 }
        val localAttemptId = ByteArray(16) { 0x10 }
        val remoteAttemptId = ByteArray(16) { 0x20 }

        arbiter.registerOutgoing(
            SoaPeerSessionArbiter.OutgoingAttempt(
                pairKey = pairKey,
                initiatorPeerId = localPeerId,
                attemptId = localAttemptId,
                startedAtNs = System.nanoTime()
            ) { _, _ -> }
        )

        val incoming = arbiter.evaluateIncoming(
            pairKey = pairKey,
            remoteInitiatorPeerId = remotePeerId,
            remoteAttemptId = remoteAttemptId,
            targetPeerId = localPeerId,
            expectedRemotePeerId = remotePeerId,
            localPeerId = localPeerId
        )
        assertTrue(incoming is SoaPeerSessionArbiter.IncomingDecision.RejectLocalWinner)
    }

    @Test
    fun `established pair rejects incoming`() {
        val arbiter = SoaPeerSessionArbiter()
        val pairKey = ByteArray(64) { 0x02 }

        arbiter.markEstablished(pairKey)

        val localPeerId = ByteArray(32) { 0x01 }
        val remotePeerId = ByteArray(32) { 0x02 }
        val incoming = arbiter.evaluateIncoming(
            pairKey = pairKey,
            remoteInitiatorPeerId = remotePeerId,
            remoteAttemptId = ByteArray(16) { 0x01 },
            targetPeerId = localPeerId,
            expectedRemotePeerId = remotePeerId,
            localPeerId = localPeerId
        )
        assertTrue(incoming == SoaPeerSessionArbiter.IncomingDecision.RejectAlreadyConnected)
    }

    @Test
    fun `binding mismatch rejects incoming`() {
        val arbiter = SoaPeerSessionArbiter()
        val pairKey = ByteArray(64) { 0x03 }
        val localPeerId = ByteArray(32) { 0x01 }
        val remotePeerId = ByteArray(32) { 0x02 }

        val incoming = arbiter.evaluateIncoming(
            pairKey = pairKey,
            remoteInitiatorPeerId = remotePeerId,
            remoteAttemptId = ByteArray(16) { 0x01 },
            targetPeerId = ByteArray(32) { 0x00 },
            expectedRemotePeerId = remotePeerId,
            localPeerId = localPeerId
        )
        assertTrue(incoming == SoaPeerSessionArbiter.IncomingDecision.RejectBinding)
    }
}
