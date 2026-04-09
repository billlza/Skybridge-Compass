package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.AesGcmCombined
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PHandshakeInteropTest {

    @Test
    fun clientServerHandshakeAndAppCryptoRoundtrip() {
        val client = P2PHandshakeClient(platformVersion = "test")
        val (state, msgA) = client.start()

        val server = P2PHandshakeServer()
        val response = server.respond(msgA)

        val clientResult = client.finish(state, response.messageBToSend)

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
