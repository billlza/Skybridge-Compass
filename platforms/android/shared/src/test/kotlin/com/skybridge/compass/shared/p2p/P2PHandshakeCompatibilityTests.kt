package com.skybridge.compass.shared.p2p

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PHandshakeCompatibilityTests {

    @Test
    fun messageASignatureVerifiesForStaticEd25519PublicKeyWithLow7BitsSet() {
        val privateKey = P2PHandshakeWire.decodeEd25519PrivateKey(
            Base64.getDecoder().decode("MC4CAQAwBQYDK2VwBCIEIOdc14db9199/Tj4MwDdozvyzqSvrvWIaG6Kn5U1URwU")
        )
        val publicKey = Base64.getDecoder().decode("JnurU6zrCNr6Dm+XMUiwEcJ0PDs9af0Av1YHyulQNg4=")
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = publicKey,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x44 })),
            clientNonce32 = ByteArray(32) { (it + 3).toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = privateKey
        )

        val decoded = P2PHandshakeWire.decodeMessageA(messageA)
        assertTrue(P2PHandshakeWire.verifyMessageASignature(decoded, messageA))
    }

    @Test
    fun suiteCatalogIncludes0102CompatEntry() {
        assertEquals(
            P2PCryptoSuite.MLKEM_768_FS_COMPAT,
            P2PCryptoSuite.fromWireId(0x0102u)
        )
        assertFalse(P2PCryptoSuite.isNegotiable(P2PCryptoSuite.MLKEM_768_FS_COMPAT))
    }

    @Test
    fun decodeMessageAToleratesUnknownSupportedSuiteIds() {
        val (idPriv, idPubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519, P2PCryptoSuite.P256),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x11 })),
            clientNonce32 = ByteArray(32) { it.toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = "test"
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = idPriv
        )

        val raw = HandshakePaddingP1.unwrapIfNeeded(messageA).copyOf()
        // Layout: version(1) + count(2) + firstSuite(2) + secondSuite(2)
        raw[5] = 0x42
        raw[6] = 0x42

        val decoded = P2PHandshakeWire.decodeMessageA(raw)
        assertTrue(decoded.supportedSuites.any { it.knownOrNull() == P2PCryptoSuite.X25519 })
        assertTrue(decoded.unknownSupportedSuiteWireIds.contains(0x4242u.toUShort()))
    }

    @Test
    fun decodeMessageAToleratesUnknownKeyShareSuiteIds() {
        val (idPriv, idPubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x22 })),
            clientNonce32 = ByteArray(32) { (it + 1).toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = "test"
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = idPriv
        )

        val raw = HandshakePaddingP1.unwrapIfNeeded(messageA).copyOf()
        // Layout with one supported suite:
        // version(1) + supportedCount(2) + suiteWireId(2) + keyShareCount(2) + keyShareSuiteId(2)
        raw[7] = 0x7E
        raw[8] = 0x7E

        val decoded = P2PHandshakeWire.decodeMessageA(raw)
        assertEquals(1, decoded.keyShares.size)
        assertTrue(decoded.keyShares[0].suiteId is P2PCryptoSuiteId.Unknown)
        assertTrue(decoded.unknownKeyShareSuiteWireIds.contains(0x7E7Eu.toUShort()))
    }

    @Test
    fun responderRejectsUnknownOfferedSuiteIdsEvenIfKnownPresent() {
        val (idPriv, idPubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519, P2PCryptoSuite.P256),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x11 })),
            clientNonce32 = ByteArray(32) { it.toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = "test"
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = idPriv
        )

        val raw = messageA.copyOf()
        // Layout: version(1) + count(2) + firstSuite(2) + secondSuite(2)
        raw[5] = 0x42
        raw[6] = 0x42

        val sigPreimage = P2PHandshakeWire.buildMessageASignaturePreimagePublic(raw)
        val sig = P2PHandshakeWire.signEd25519Public(sigPreimage, idPriv)
        val withoutSig = P2PHandshakeWire.messageAWithoutSignatureFromWire(raw)
        val sigOffset = withoutSig.size
        raw[sigOffset] = (sig.size and 0xFF).toByte()
        raw[sigOffset + 1] = ((sig.size ushr 8) and 0xFF).toByte()
        System.arraycopy(sig, 0, raw, sigOffset + 2, sig.size)

        val server = P2PHandshakeServer()
        assertThrows(IllegalArgumentException::class.java) {
            server.respond(raw)
        }
    }

    @Test
    fun clientRejectsUnknownSelectedSuiteAfterSignatureVerification() {
        val client = P2PHandshakeClient(platformVersion = "test")
        val (state, msgA) = client.start()

        val server = P2PHandshakeServer()
        val response = server.respond(msgA)

        val raw = response.messageBToSend.copyOf()
        // MessageB layout: version(1) + selectedSuite(2)
        raw[1] = 0x42
        raw[2] = 0x42

        val transcriptA32 = P2PHandshakeWire.transcriptHashAFromWire(state.messageAWithoutPadding)
        val parsedB = P2PHandshakeWire.decodeMessageB(raw)
        val sigPreimage = P2PHandshakeWire.buildMessageBSignaturePreimagePublic(
            transcriptHashA32 = transcriptA32,
            selectedSuiteWireId = 0x4242u.toUShort(),
            responderShare = parsedB.responderShare,
            serverNonce = parsedB.serverNonce,
            payloadCombinedWithHeader = parsedB.encryptedPayload.combinedWithHeader(),
            identityPublicKeyBytes = parsedB.identityPublicKeys.encode()
        )
        val serverPriv = requireNotNull(response.state.identityPrivateKey) { "test requires classic Ed25519 identity key" }
        val sig = P2PHandshakeWire.signEd25519Public(sigPreimage, serverPriv)
        val withoutSig = P2PHandshakeWire.messageBWithoutSignatureFromWire(raw)
        val sigOffset = withoutSig.size
        raw[sigOffset] = (sig.size and 0xFF).toByte()
        raw[sigOffset + 1] = ((sig.size ushr 8) and 0xFF).toByte()
        System.arraycopy(sig, 0, raw, sigOffset + 2, sig.size)

        assertThrows(IllegalArgumentException::class.java) {
            client.finish(state, raw)
        }
    }

    @Test
    fun messageAExtensionsRoundtripAndAreCoveredBySignature() {
        val (idPriv, idPubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val ext = P2PSoa.SoaExtension(
            version = P2PSoa.VERSION,
            initiatorPeerId = P2PSoa.canonicalPeerIdBytes("peer-A"),
            targetPeerId = P2PSoa.canonicalPeerIdBytes("peer-B"),
            attemptId = ByteArray(P2PSoa.ATTEMPT_ID_LEN) { it.toByte() }
        ).encodeTlv()
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x33 })),
            clientNonce32 = ByteArray(32) { (it + 2).toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = "test"
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = idPriv,
            extensionsRaw = ext
        )

        val decoded = P2PHandshakeWire.decodeMessageA(messageA)
        assertTrue(decoded.extensionsRaw.contentEquals(ext))
        assertTrue(P2PHandshakeWire.verifyMessageASignature(decoded, messageA))

        val tampered = messageA.copyOf()
        val idx = indexOf(tampered, P2PSoa.CONTAINER_MAGIC)
        assertTrue(idx >= 0)
        // flip one byte inside extensions payload
        tampered[idx + P2PSoa.CONTAINER_MAGIC.size + 2] = (tampered[idx + P2PSoa.CONTAINER_MAGIC.size + 2].toInt() xor 0x01).toByte()
        val tamperedDecoded = P2PHandshakeWire.decodeMessageA(tampered)
        assertFalse(P2PHandshakeWire.verifyMessageASignature(tamperedDecoded, tampered))
    }

    @Test
    fun trustStorePersistsAndRejectsMismatch() {
        val store = P2PHandshakeWire.InMemoryTrustStore()
        val (_, firstPub) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val firstKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = firstPub,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )

        val firstDecision = P2PHandshakeWire.verifyOrPersistPeerTrust(
            peerId = "peer-A",
            identityPublicKeys = firstKeys,
            trustStore = store
        )
        assertEquals(P2PHandshakeWire.TrustDecision.TRUSTED_NEW, firstDecision)

        val secondDecision = P2PHandshakeWire.verifyOrPersistPeerTrust(
            peerId = "peer-A",
            identityPublicKeys = firstKeys,
            trustStore = store
        )
        assertEquals(P2PHandshakeWire.TrustDecision.TRUSTED_EXISTING, secondDecision)

        val (_, changedPub) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val changedKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = changedPub,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )

        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.verifyOrPersistPeerTrust(
                peerId = "peer-A",
                identityPublicKeys = changedKeys,
                trustStore = store
            )
        }
    }

    @Test
    fun trustStoreCanRequirePrePinnedPeer() {
        val store = P2PHandshakeWire.InMemoryTrustStore()
        val (_, pub) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val keys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = pub,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )

        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.verifyOrPersistPeerTrust(
                peerId = "peer-strict",
                identityPublicKeys = keys,
                trustStore = store,
                allowTrustOnFirstUse = false
            )
        }
    }

    @Test
    fun messageASignatureFallsBackToCanonicalPreimageWhenPolicyUsesLegacyEncoding() {
        val (idPriv, idPubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val messageA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = listOf(P2PCryptoSuite.X25519),
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32) { 0x55 })),
            clientNonce32 = ByteArray(32) { (it + 5).toByte() },
            capabilities = P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM"),
                pqcAvailable = false,
                platformVersion = "legacy-test",
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityKeys = identity,
            identitySigningPrivateKey = idPriv
        )

        val raw = HandshakePaddingP1.unwrapIfNeeded(messageA)
        var offset = 1
        val supportedCount = readU16LE(raw, offset)
        offset += 2 + supportedCount * 2
        val keyShareCount = readU16LE(raw, offset)
        offset += 2
        repeat(keyShareCount) {
            val shareLen = readU16LE(raw, offset + 2)
            offset += 4 + shareLen
        }
        offset += 32
        val capLen = readU16LE(raw, offset)
        offset += 2 + capLen

        val policyLenOffset = offset
        val policyLen = readU16LE(raw, policyLenOffset)
        val policyDataOffset = policyLenOffset + 2
        assertTrue(policyLen > 0)
        assertEquals(0, raw[policyDataOffset + policyLen - 1].toInt())

        val mutated = ByteArray(raw.size - 1)
        System.arraycopy(raw, 0, mutated, 0, policyDataOffset + policyLen - 1)
        System.arraycopy(
            raw,
            policyDataOffset + policyLen,
            mutated,
            policyDataOffset + policyLen - 1,
            raw.size - (policyDataOffset + policyLen)
        )
        val trimmedPolicyLen = policyLen - 1
        mutated[policyLenOffset] = (trimmedPolicyLen and 0xFF).toByte()
        mutated[policyLenOffset + 1] = ((trimmedPolicyLen ushr 8) and 0xFF).toByte()

        val decoded = P2PHandshakeWire.decodeMessageA(mutated)
        assertTrue(P2PHandshakeWire.verifyMessageASignature(decoded, mutated))
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || haystack.size < needle.size) return -1
        for (i in 0..(haystack.size - needle.size)) {
            var ok = true
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) {
                    ok = false
                    break
                }
            }
            if (ok) return i
        }
        return -1
    }

    private fun readU16LE(data: ByteArray, offset: Int): Int =
        (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)

    @Test
    fun suitePlanAndroid17UsesPqcWhenXWingUnavailable() {
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "17",
            liboqsAvailable = true,
            xWingAvailable = false,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                mlKem768PublicKey = ByteArray(1) { 0x01 }
            )
        )
        assertEquals(P2PCryptoSuite.MLKEM_768, plan.selectedSuite)
        assertFalse(plan.usedClassicFallback)
        assertEquals("liboqsPQC", plan.minimumTierRaw)
    }

    @Test
    fun suitePlanAndroid14UsesPqcTier() {
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "14",
            liboqsAvailable = true,
            xWingAvailable = true,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                mlKem768PublicKey = ByteArray(1) { 0x02 },
                xWingPublicKey = ByteArray(1) { 0x03 }
            )
        )
        assertEquals(P2PCryptoSuite.MLKEM_768, plan.selectedSuite)
        assertFalse(plan.usedClassicFallback)
    }

    @Test
    fun suitePlanAndroid13UsesPqcTier() {
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "13",
            liboqsAvailable = true,
            xWingAvailable = true,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                mlKem768PublicKey = ByteArray(1) { 0x04 },
                xWingPublicKey = ByteArray(1) { 0x05 }
            )
        )
        assertEquals(P2PCryptoSuite.MLKEM_768, plan.selectedSuite)
        assertFalse(plan.usedClassicFallback)
    }

    @Test
    fun suitePlanMarksClassicFallbackWhenPqcUnavailable() {
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "17",
            liboqsAvailable = true,
            xWingAvailable = false,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys()
        )
        assertEquals(P2PCryptoSuite.X25519, plan.selectedSuite)
        assertTrue(plan.usedClassicFallback)
    }

    @Test
    fun strictPolicyRejectsClassicDowngradeWhenPeerKemMissing() {
        assertThrows(IllegalStateException::class.java) {
            P2PHandshakeClient.resolveSuitePlanForTesting(
                platformVersion = "17",
                liboqsAvailable = true,
                xWingAvailable = true,
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
                policy = P2PHandshakePolicy(
                    requirePqc = true,
                    allowClassicFallback = false,
                    minimumTierRaw = "nativePQC",
                    requireSecureEnclavePoP = false
                )
            )
        }
    }

    @Test
    fun strictPolicyAllowsTrustedClassicBootstrapWhenPeerKemMissing() {
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "17",
            liboqsAvailable = true,
            xWingAvailable = true,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
            policy = P2PHandshakePolicy(
                requirePqc = true,
                allowClassicFallback = false,
                minimumTierRaw = "nativePQC",
                requireSecureEnclavePoP = false
            ),
            allowClassicBootstrapForTrustedPeer = true
        )

        assertEquals(P2PCryptoSuite.X25519, plan.selectedSuite)
        assertTrue(plan.usedClassicFallback)
    }

    @Test
    fun classicFallbackCooldownIsEnforcedPerPeer() {
        val cooldownStore = P2PHandshakeWire.InMemoryFallbackCooldownStore()
        val peerId = "peer-cooldown"
        val t0 = 1_000L

        val beforeRecord = P2PHandshakeWire.evaluateClassicFallbackCooldown(
            peerId = peerId,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = t0
        )
        assertTrue(beforeRecord.allowed)

        P2PHandshakeWire.recordClassicFallback(
            peerId = peerId,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = t0
        )

        val immediatelyAfter = P2PHandshakeWire.evaluateClassicFallbackCooldown(
            peerId = peerId,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = t0 + 100
        )
        assertFalse(immediatelyAfter.allowed)
        assertTrue(immediatelyAfter.remainingMillis in 299_800L..300_000L)

        val afterWindow = P2PHandshakeWire.evaluateClassicFallbackCooldown(
            peerId = peerId,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = t0 + 301_000
        )
        assertTrue(afterWindow.allowed)
        assertEquals(0L, afterWindow.remainingMillis)
    }
}
