package com.skybridge.compass.shared.p2p

/**
 * Mirror of Pro release handshake capability/policy models, encoded with [DeterministicCodec].
 */
data class P2PCryptoCapabilities(
    val supportedKEM: List<String>,
    val supportedSignature: List<String>,
    val supportedAuthProfiles: List<String>,
    val supportedAEAD: List<String>,
    val pqcAvailable: Boolean,
    val platformVersion: String,
    val providerTypeRaw: String
) {
    fun deterministicEncode(): ByteArray {
        val enc = DeterministicCodec.Encoder()
        enc.encodeStringArray(supportedKEM)
        enc.encodeStringArray(supportedSignature)
        enc.encodeStringArray(supportedAuthProfiles)
        enc.encodeStringArray(supportedAEAD)
        enc.encodeBool(pqcAvailable)
        enc.encodeString(platformVersion)
        enc.encodeString(providerTypeRaw)
        return enc.toByteArray()
    }

    companion object {
        fun deterministicDecode(data: ByteArray): P2PCryptoCapabilities {
            val dec = DeterministicCodec.Decoder(data)
            val supportedKEM = dec.decodeStringArray()
            val supportedSignature = dec.decodeStringArray()
            val supportedAuthProfiles = dec.decodeStringArray()
            val supportedAEAD = dec.decodeStringArray()
            val pqcAvailable = dec.decodeBool()
            val platformVersion = dec.decodeString()
            val providerTypeRaw = dec.decodeString()
            require(dec.isAtEnd) { "Trailing bytes in CryptoCapabilities" }
            return P2PCryptoCapabilities(
                supportedKEM = supportedKEM,
                supportedSignature = supportedSignature,
                supportedAuthProfiles = supportedAuthProfiles,
                supportedAEAD = supportedAEAD,
                pqcAvailable = pqcAvailable,
                platformVersion = platformVersion,
                providerTypeRaw = providerTypeRaw
            )
        }
    }
}

data class P2PHandshakePolicy(
    val requirePqc: Boolean,
    val allowClassicFallback: Boolean,
    val minimumTierRaw: String,
    val requireSecureEnclavePoP: Boolean = false
) {
    fun deterministicEncode(): ByteArray {
        val enc = DeterministicCodec.Encoder()
        enc.encodeBool(requirePqc)
        enc.encodeBool(allowClassicFallback)
        enc.encodeString(minimumTierRaw)
        // Pro release supports optional trailing bool; always emit for determinism.
        enc.encodeBool(requireSecureEnclavePoP)
        return enc.toByteArray()
    }

    companion object {
        val DEFAULT = P2PHandshakePolicy(
            requirePqc = false,
            allowClassicFallback = true,
            minimumTierRaw = "classic",
            requireSecureEnclavePoP = false
        )

        fun deterministicDecode(data: ByteArray): P2PHandshakePolicy {
            if (data.isEmpty()) return DEFAULT
            val dec = DeterministicCodec.Decoder(data)
            val requirePqc = dec.decodeBool()
            val allowClassicFallback = dec.decodeBool()
            val minimumTierRaw = dec.decodeString()
            val requireSe = if (dec.isAtEnd) false else dec.decodeBool()
            require(dec.isAtEnd) { "Trailing bytes in HandshakePolicy" }
            return P2PHandshakePolicy(
                requirePqc = requirePqc,
                allowClassicFallback = allowClassicFallback,
                minimumTierRaw = minimumTierRaw,
                requireSecureEnclavePoP = requireSe
            )
        }
    }
}


