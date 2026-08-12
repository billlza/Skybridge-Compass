package com.skybridge.compass.core.p2p

import org.junit.Assert.assertEquals
import org.junit.Test

class SkrCanonicalTest {
    @Test
    fun policyHashMatchesAppleGoldenVector() {
        assertEquals(
            "82dc84c640da0ab35b7711b86cfa38215c840b6f437f2d31a30a961ed17aae5e",
            SkrCanonical.policyHashHex()
        )
    }

    @Test
    fun requestHashMatchesAppleGoldenVector() {
        assertEquals(
            "ef160c364bf085b77e1d14799283550343cf8844767951d819a87d04f8660428",
            SkrCanonical.requestHashHex(goldenRequest())
        )
    }

    @Test
    fun responsePreimageHashMatchesAppleGoldenVector() {
        val response = SkrBootstrapWire.SignedKemRefreshPayload(
            deviceId = "id:mac-1",
            aliases = listOf("id:mac-1", "bonjour:mac@local."),
            protocolSigningAlgorithm = "Ed25519",
            protocolIdentityPublicKey = ByteArray(32) { 0x11 },
            protocolIdentityFingerprint =
                "6d2b9f7fa7f28ec0553190b584e04b31b946d0767464c9028284bdb721e4d884",
            kemPublicKeys = listOf(
                SkrBootstrapWire.KemPublicKeyInfo(0x0101, ByteArray(1_184) { 0x66 }),
                SkrBootstrapWire.KemPublicKeyInfo(0x0001, ByteArray(1_216) { 0x55 })
            ),
            keyId = "skr-key-1",
            generation = 1_700_000_000_125,
            sentAt = 721_692_800.25,
            expiresAt = 721_693_100.25,
            requestNonce = goldenNonce(),
            requestHashHex =
                "ef160c364bf085b77e1d14799283550343cf8844767951d819a87d04f8660428",
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = " LAN ",
            bonjourEndpointDigest = "c".repeat(64),
            signature = ByteArray(64) { 0x77 }
        )

        assertEquals(
            "e5cf02c00119fa5bc7d19335a726fed99807de83dc963fad1be144b8d310b99f",
            SkrCanonical.payloadHashHex(response)
        )
    }

    private fun goldenRequest() = SkrBootstrapWire.KemRefreshRequestPayload(
        requesterDeviceId = "id:android-1",
        targetDeviceId = "id:mac-1",
        requesterProtocolIdentityFingerprint = "a".repeat(64),
        targetProtocolIdentityFingerprint = "b".repeat(64),
        requestedSuiteWireIds = listOf(0x0101, 0x0001),
        policyRequirePQC = true,
        policyAllowClassicFallback = false,
        policyHashHex = "82dc84c640da0ab35b7711b86cfa38215c840b6f437f2d31a30a961ed17aae5e",
        routeScope = "lan",
        bonjourEndpointDigest = "c".repeat(64),
        nonce = goldenNonce(),
        sentAt = 721_692_800.125
    )

    private fun goldenNonce(): ByteArray = ByteArray(24) { it.toByte() }
}
