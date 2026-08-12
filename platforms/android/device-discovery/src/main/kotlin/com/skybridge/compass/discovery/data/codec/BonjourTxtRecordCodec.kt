package com.skybridge.compass.discovery.data.codec

/**
 * Pure-Kotlin, Android-free RFC 6763 DNS-SD TXT record codec.
 *
 * DNS-SD (RFC 6763 §6) encodes a TXT record as a sequence of length-prefixed strings. Each string
 * is a single unsigned length byte (0..255) followed by that many raw bytes; the byte payload is a
 * `key=value` pair where the key is printable ASCII and the value is an arbitrary byte string. This
 * codec models the record as a `Map<String, ByteArray>` so it can be handed to `NsdServiceInfo`
 * unchanged — the on-wire bytes are exactly what this codec produces.
 *
 * Design notes:
 * - [encode] emits pairs in a canonical, order-independent order (sorted by raw key bytes) so that
 *   the same field set always yields identical bytes regardless of the input map's iteration order.
 * - [decode] parses length-prefixed pairs and splits each at the first `=` byte. A pair with no `=`
 *   is treated as a key with an empty value; a pair whose `=` is the last byte is an empty value.
 * - [validate] classifies the two discriminable length violations required by the wire protocol:
 *   a single encoded pair exceeding [MAX_PAIR_BYTES] (255 B) versus the whole record exceeding
 *   [MAX_RECORD_BYTES] (1300 B).
 *
 * The codec is deliberately free of any Android imports so it is unit-testable on the JVM.
 */
object BonjourTxtRecordCodec {

    /** Maximum encoded length of a single `key=value` pair, per RFC 6763 §6.1 (one length byte). */
    const val MAX_PAIR_BYTES: Int = 255

    /** Maximum encoded length of the entire TXT record (sum of every length byte + pair payload). */
    const val MAX_RECORD_BYTES: Int = 1300

    private const val EQUALS_BYTE: Byte = '='.code.toByte()

    /**
     * Classification of a field set against the RFC 6763 length limits.
     *
     * The three states are mutually exclusive and discriminable so callers can distinguish a single
     * oversized pair from an oversized whole record without inspecting exception messages.
     */
    sealed interface TxtValidation {
        /** Every pair is within [MAX_PAIR_BYTES] and the whole record is within [MAX_RECORD_BYTES]. */
        data object Valid : TxtValidation

        /** A single `key=value` pair's encoded payload exceeds [MAX_PAIR_BYTES]. */
        data class PairTooLarge(val key: String, val encodedPairBytes: Int) : TxtValidation

        /** The whole record's encoded length exceeds [MAX_RECORD_BYTES]. */
        data class RecordTooLarge(val encodedRecordBytes: Int) : TxtValidation
    }

    /**
     * Encodes [fields] into an RFC 6763 TXT byte sequence with canonical, order-independent ordering.
     *
     * @throws IllegalArgumentException if a key is empty or contains an `=` byte (structurally
     *   impossible to encode), or if [validate] reports a length violation.
     */
    fun encode(fields: Map<String, ByteArray>): ByteArray {
        fields.keys.forEach { key ->
            require(key.isNotEmpty()) { "TXT key must not be empty" }
            require(!key.contains('=')) { "TXT key must not contain '=' (key='$key')" }
        }
        when (val validation = validate(fields)) {
            is TxtValidation.Valid -> Unit
            is TxtValidation.PairTooLarge -> throw IllegalArgumentException(
                "TXT pair '${validation.key}' encodes to ${validation.encodedPairBytes} bytes, " +
                    "exceeding the $MAX_PAIR_BYTES byte limit"
            )
            is TxtValidation.RecordTooLarge -> throw IllegalArgumentException(
                "TXT record encodes to ${validation.encodedRecordBytes} bytes, " +
                    "exceeding the $MAX_RECORD_BYTES byte limit"
            )
        }

        val pairs = fields.entries
            .map { (key, value) -> EncodableField(key.toKeyBytes(), value) }
            .sortedWith { left, right ->
                UnsignedByteArrayComparator.compare(left.keyBytes, right.keyBytes)
            }
            .map { field -> encodePair(field.keyBytes, field.value) }

        val totalSize = pairs.sumOf { 1 + it.size }
        val out = ByteArray(totalSize)
        var offset = 0
        for (pair in pairs) {
            out[offset] = pair.size.toByte()
            offset += 1
            pair.copyInto(out, offset)
            offset += pair.size
        }
        return out
    }

    /**
     * Decodes an RFC 6763 TXT byte sequence back into a field map.
     *
     * Decoding is order-independent: the resulting map key set and per-key value bytes are what
     * matter, not the on-wire ordering. If a key appears more than once, the last occurrence wins
     * (RFC 6763 §6.4 leaves this to the application; last-wins is the common resolver behavior).
     *
     * @throws IllegalArgumentException if [record] is truncated (a length byte claims more bytes
     *   than remain in the buffer).
     */
    fun decode(record: ByteArray): Map<String, ByteArray> {
        val result = LinkedHashMap<String, ByteArray>()
        var offset = 0
        while (offset < record.size) {
            val length = record[offset].toInt() and 0xFF
            offset += 1
            require(offset + length <= record.size) {
                "Truncated TXT record: pair length $length at offset ${offset - 1} exceeds " +
                    "remaining ${record.size - offset} bytes"
            }
            val pair = record.copyOfRange(offset, offset + length)
            offset += length

            val separatorIndex = pair.indexOf(EQUALS_BYTE)
            if (separatorIndex < 0) {
                val key = pair.toKeyString()
                if (key.isNotEmpty()) {
                    result[key] = ByteArray(0)
                }
            } else {
                val keyBytes = pair.copyOfRange(0, separatorIndex)
                val valueBytes = pair.copyOfRange(separatorIndex + 1, pair.size)
                val key = keyBytes.toKeyString()
                if (key.isNotEmpty()) {
                    result[key] = valueBytes
                }
            }
        }
        return result
    }

    /**
     * Classifies [fields] against the RFC 6763 length limits without producing output.
     *
     * Single-pair violations are reported first (a pair that cannot be length-prefixed at all is a
     * more specific fault than the aggregate record being too large).
     */
    fun validate(fields: Map<String, ByteArray>): TxtValidation {
        var totalRecordBytes = 0
        for ((key, value) in fields) {
            val pairBytes = encodedPairSize(key, value)
            if (pairBytes > MAX_PAIR_BYTES) {
                return TxtValidation.PairTooLarge(key = key, encodedPairBytes = pairBytes)
            }
            totalRecordBytes += 1 + pairBytes
        }
        if (totalRecordBytes > MAX_RECORD_BYTES) {
            return TxtValidation.RecordTooLarge(encodedRecordBytes = totalRecordBytes)
        }
        return TxtValidation.Valid
    }

    private data class EncodableField(
        val keyBytes: ByteArray,
        val value: ByteArray,
    )

    private fun encodePair(keyBytes: ByteArray, value: ByteArray): ByteArray {
        val pair = ByteArray(keyBytes.size + 1 + value.size)
        keyBytes.copyInto(pair, 0)
        pair[keyBytes.size] = EQUALS_BYTE
        value.copyInto(pair, keyBytes.size + 1)
        return pair
    }

    private fun encodedPairSize(key: String, value: ByteArray): Int =
        key.toKeyBytes().size + 1 + value.size

    /**
     * Keys are printable ASCII per RFC 6763. Latin-1 maps chars 0..255 one-to-one to bytes, which
     * guarantees a lossless [decode]/[encode] round trip for any well-formed key.
     */
    private fun String.toKeyBytes(): ByteArray = toByteArray(Charsets.ISO_8859_1)

    private fun ByteArray.toKeyString(): String = toString(Charsets.ISO_8859_1)

    private fun ByteArray.indexOf(target: Byte): Int {
        for (i in indices) {
            if (this[i] == target) return i
        }
        return -1
    }

    /** Orders raw keys by unsigned byte value so encoding is deterministic and order-independent. */
    private object UnsignedByteArrayComparator : Comparator<ByteArray> {
        override fun compare(a: ByteArray, b: ByteArray): Int {
            val min = minOf(a.size, b.size)
            for (i in 0 until min) {
                val diff = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
                if (diff != 0) return diff
            }
            return a.size - b.size
        }
    }
}
