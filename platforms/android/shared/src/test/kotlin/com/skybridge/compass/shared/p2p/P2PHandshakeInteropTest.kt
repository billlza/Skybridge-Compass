package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.AesGcmCombined
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PHandshakeInteropTest {

    @Test
    fun clientServerHandshakeAndAppCryptoRoundtrip() {
        val client = P2PHandshakeClient(platformVersion = "Android 16 (API 36)")
        val classicPolicy = P2PHandshakePolicy(
            requirePqc = false,
            allowClassicFallback = true,
            minimumTierRaw = "classic",
            requireSecureEnclavePoP = false
        )
        val (state, msgA) = client.start(P2PHandshakeClient.StartOptions(handshakePolicy = classicPolicy))

        val server = P2PHandshakeServer()
        val response = server.respond(
            msgA,
            P2PHandshakeServer.RespondOptions(
                platformVersion = "Android 16 (API 36)",
                handshakePolicy = classicPolicy
            )
        )

        val clientResult = client.finish(state, response.messageBToSend)
        assertEquals(
            P2PHandshakeWire.computePeerSigningFingerprint(
                P2PHandshakeWire.decodeMessageB(
                    HandshakePaddingP1.unwrapIfNeeded(response.messageBToSend)
                ).identityPublicKeys
            ),
            clientResult.remoteProtocolIdentityFingerprint
        )
        assertEquals(
            P2PHandshakeWire.computePeerSigningFingerprint(
                P2PHandshakeWire.decodeMessageA(HandshakePaddingP1.unwrapIfNeeded(msgA)).identityPublicKeys
            ),
            response.state.remoteProtocolIdentityFingerprint
        )

        val clientFinishedOk = server.verifyClientFinished(
            rawFinished = clientResult.clientFinishedToSend,
            sessionKeys = response.state.sessionKeys
        )
        assertTrue(clientFinishedOk)

        val responderFinished = server.buildResponderFinished(response.state.sessionKeys)
        val responderFinishedOk = client.verifyResponderFinished(
            rawFinished = responderFinished,
            sessionKeys = clientResult.sessionKeys
        )
        assertTrue(responderFinishedOk)

        val plaintext = "hello-p2p".encodeToByteArray()
        val encrypted = AesGcmCombined.seal(clientResult.sessionKeys.sendKey, plaintext)
        val decrypted = AesGcmCombined.open(response.state.sessionKeys.receiveKey, encrypted)
        assertArrayEquals(plaintext, decrypted)
    }
}
