package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.Signature
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SignedLanKemRefreshClientIntegrationTest {
    @Test
    fun strictExchangeVerifiesSignatureCommitsOnceAndRereadsDurableKeys() = runTest {
        val macSigningKeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val macPublicKey = macSigningKeyPair.public.encoded.takeLast(32).toByteArray()
        val macFingerprint = ProtocolIdentityBinding.computeFingerprint(
            ProtocolSigningAlgorithm.ED25519,
            macPublicKey
        )
        val trustedPreferences = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPreferences)
        trustedStore.upsertVerifiedCurrentPathAuthority(
            deviceId = DEVICE_ID,
            protocolPublicKeyFingerprint = macFingerprint,
            protocolSigningAlgorithm = "Ed25519"
        )
        val kemPreferences = ScriptedSharedPreferences()
        val peerKemStore = PeerKemKeyStore(
            prefsProvider = { kemPreferences },
            trustedPeerStoreProvider = { trustedStore },
            currentTimeMillis = { NOW_MILLIS }
        )
        val localIdentity = object : SignedLanKemRefreshIdentity {
            override fun trustedPeerStore(): TrustedPeerStore = trustedStore

            override fun requesterMlDsa65PublicKey(): ByteArray =
                ByteArray(AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE) { 0x22 }

            override fun deviceId(): String = "id:android-1"
        }
        val exchangeCount = AtomicInteger(0)
        val transport = BootstrapControlExchange { host, port, body, timeoutMs ->
            exchangeCount.incrementAndGet()
            assertEquals("192.168.1.19", host)
            assertEquals(44_000, port)
            assertEquals(2_000, timeoutMs)
            val request = decodeRequest(body)
            assertEquals(DEVICE_ID, request.targetDeviceId)
            assertEquals(macFingerprint, request.targetProtocolIdentityFingerprint)
            assertEquals(listOf(0x0001, 0x0101), request.requestedSuiteWireIds)

            val unsigned = SkrBootstrapWire.SignedKemRefreshPayload(
                deviceId = DEVICE_ID,
                protocolSigningAlgorithm = "Ed25519",
                protocolIdentityPublicKey = macPublicKey,
                protocolIdentityFingerprint = macFingerprint,
                kemPublicKeys = listOf(
                    SkrBootstrapWire.KemPublicKeyInfo(
                        P2PCryptoSuite.X_WING.wireId.toInt(),
                        X_WING_PUBLIC_KEY
                    )
                ),
                keyId = "skr-key-1",
                generation = 7,
                sentAt = PibBootstrapWire.unixMillisToReferenceSeconds(NOW_MILLIS),
                expiresAt = PibBootstrapWire.unixMillisToReferenceSeconds(
                    NOW_MILLIS + 300_000
                ),
                requestNonce = request.nonce,
                requestHashHex = SkrCanonical.requestHashHex(request),
                bonjourEndpointDigest = ENDPOINT_DIGEST,
                signature = ByteArray(64)
            )
            val signature = Signature.getInstance("Ed25519").run {
                initSign(macSigningKeyPair.private)
                update(SkrCanonical.responseSignaturePreimage(unsigned))
                sign()
            }
            encodeSignedResponse(unsigned.copy(signature = signature))
        }
        val client = SignedLanKemRefreshClient(
            identity = localIdentity,
            peerKemKeyStore = peerKemStore,
            transport = transport,
            verifier = SignedLanKemRefreshVerifier(),
            secureRandom = SecureRandom(),
            currentTimeMillis = { NOW_MILLIS },
            localXWingAvailable = { true }
        )

        val result = client.refresh(
            target = SignedLanKemRefreshClient.Target(
                endpoint = ResolvedBootstrapControlEndpoint.fromResolvedBonjour(
                    "192.168.1.19",
                    44_000
                ),
                deviceId = DEVICE_ID,
                pinnedProtocolFingerprint = macFingerprint,
                bonjourEndpointDigest = ENDPOINT_DIGEST
            ),
            timeoutMs = 2_000
        )

        assertEquals(1, exchangeCount.get())
        assertEquals(1, kemPreferences.commitCount)
        assertEquals(listOf(P2PCryptoSuite.X_WING.wireId.toInt()), result.signedSuiteWireIds)
        val durable = peerKemStore.loadVerifiedReadOnly(DEVICE_ID)
        assertArrayEquals(X_WING_PUBLIC_KEY, durable.xWingPublicKey)
        assertNull(durable.mlKem768PublicKey)
        assertEquals(7L, peerKemStore.maximumSignedRefreshGeneration(listOf(DEVICE_ID)))
    }

    private fun decodeRequest(bytes: ByteArray): SkrBootstrapWire.KemRefreshRequestPayload {
        val element = json.parseToJsonElement(StrictJsonWire.validatedUtf8(bytes))
        val envelope = StrictJsonWire.requireSingleEnvelopeCase(
            element,
            setOf("kemRefreshRequest")
        )
        return json.decodeFromJsonElement(
            SkrBootstrapWire.KemRefreshRequestPayload.serializer(),
            envelope.payload
        )
    }

    private fun encodeSignedResponse(payload: SkrBootstrapWire.SignedKemRefreshPayload): ByteArray {
        val envelope = JsonObject(
            mapOf(
                "signedKEMRefresh" to json.encodeToJsonElement(
                    SkrBootstrapWire.SignedKemRefreshPayload.serializer(),
                    payload
                )
            )
        )
        return json.encodeToString(JsonObject.serializer(), envelope).encodeToByteArray()
    }

    private companion object {
        const val DEVICE_ID = "id:mac-1"
        const val NOW_MILLIS = 1_700_000_000_000L
        const val ENDPOINT_DIGEST =
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        val X_WING_PUBLIC_KEY = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE) { 0x55 }
        val json = Json {
            ignoreUnknownKeys = false
            explicitNulls = false
            encodeDefaults = true
        }
    }
}
