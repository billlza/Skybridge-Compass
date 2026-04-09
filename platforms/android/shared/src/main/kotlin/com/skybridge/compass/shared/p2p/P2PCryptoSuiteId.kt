package com.skybridge.compass.shared.p2p

/**
 * A suite identifier that preserves unknown wire IDs without mapping them to a default.
 *
 * Wire format: UInt16 little-endian.
 */
sealed class P2PCryptoSuiteId {
    abstract val wireId: UShort

    data class Known(val suite: P2PCryptoSuite) : P2PCryptoSuiteId() {
        override val wireId: UShort
            get() = suite.wireId
    }

    data class Unknown(override val wireId: UShort) : P2PCryptoSuiteId()

    fun knownOrNull(): P2PCryptoSuite? = (this as? Known)?.suite

    companion object {
        fun parse(wireId: UShort): P2PCryptoSuiteId {
            val known = P2PCryptoSuite.fromWireId(wireId) ?: return Unknown(wireId)
            return Known(known)
        }
    }
}

