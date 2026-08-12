package com.skybridge.compass.audit.vectors

import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import com.skybridge.compass.shared.p2p.P2PCryptoCapabilities
import com.skybridge.compass.shared.p2p.P2PHPKESealedBox
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec

/** Result of decoding and re-encoding through one exact Android shipping codec. */
internal data class AppleVectorEvaluation(
    val projectedFields: VectorExpectedFields,
    val reEncodedBytes: ByteArray,
)

/**
 * Exact typed registry for the 23 captured message types.
 *
 * This registry never probes multiple decoders, reflects over model fields, or constructs a
 * parallel encoder. Every evaluator calls one named shipping decoder and its matching shipping
 * encoder. F1 evaluation establishes canonical wire compatibility only, not strict admission
 * parity with Apple's stateful per-operation admission layer.
 */
internal object AppleVectorCodecRegistry {
    private data class Key(val surface: CodecSurface, val messageType: String)

    private val F1_TYPES = setOf(
        "metadata",
        "metadataAck",
        "chunk",
        "chunkAck",
        "complete",
        "completeAck",
        "cancel",
        "error",
    )
    private val BASE_BONJOUR_KEYS = setOf("deviceId", "platform", "pubKeyFP", "version")
    private val HPKE_MODES = linkedMapOf(
        "handshake-v1" to true,
        "handshake-v2" to true,
        "application-v1" to false,
        "application-v2" to false,
        "v2-empty-nonce-tag" to false,
    )
    private val BONJOUR_ROLES = listOf(
        BonjourVectorRole("capabilities-record", BASE_BONJOUR_KEYS + "hs_soa"),
        BonjourVectorRole("identity-keys-record", BASE_BONJOUR_KEYS),
        BonjourVectorRole("main-service-record", BASE_BONJOUR_KEYS + "hs_soa"),
        BonjourVectorRole("remote-service-record", BASE_BONJOUR_KEYS),
        BonjourVectorRole("transfer-service-record", BASE_BONJOUR_KEYS),
    ).associateBy { it.messageType }

    private val evaluators: Map<Key, (ByteArray) -> AppleVectorEvaluation> = buildMap {
        F1_TYPES.forEach { messageType ->
            put(Key(CodecSurface.F1_FILE_TRANSFER, messageType)) { bytes ->
                evaluateF1(messageType, bytes)
            }
        }
        put(Key(CodecSurface.F2_P2P_HANDSHAKE, "cryptoCapabilities"), ::evaluateCapabilities)
        put(Key(CodecSurface.F2_P2P_HANDSHAKE, "handshakePolicy"), ::evaluatePolicy)
        put(Key(CodecSurface.F2_P2P_HANDSHAKE, "messageA"), ::evaluateMessageA)
        put(Key(CodecSurface.F2_P2P_HANDSHAKE, "messageB"), ::evaluateMessageB)
        put(Key(CodecSurface.F2_P2P_HANDSHAKE, "finished"), ::evaluateFinished)
        HPKE_MODES.forEach { (messageType, isHandshake) ->
            put(Key(CodecSurface.F3_HPKE_SEALED_BOX, messageType)) { bytes ->
                evaluateHpke(bytes, isHandshake = isHandshake)
            }
        }
        BONJOUR_ROLES.forEach { (messageType, role) ->
            put(Key(CodecSurface.F4_BONJOUR_TXT, messageType)) { bytes ->
                evaluateBonjour(role, bytes)
            }
        }
    }

    init {
        val descriptorKeys = AppleVectorContract.descriptors
            .mapToSet { Key(it.surface, it.messageType) }
        require(evaluators.keys == descriptorKeys) {
            "Apple vector codec registry must exactly cover the typed capture registry"
        }
    }

    fun evaluate(vector: VectorEntry.Loaded): AppleVectorEvaluation =
        evaluators.getValue(Key(vector.surface, vector.messageType)).invoke(vector.rawBytes)

    internal fun hpkeHandshakeMode(messageType: String): Boolean =
        HPKE_MODES[messageType]
            ?: throw IllegalArgumentException("Unknown typed F3 vector message: $messageType")

    private fun evaluateF1(messageType: String, bytes: ByteArray): AppleVectorEvaluation {
        val message = CrossNetworkFileTransferWireCodec.decode(bytes)
        require(message.op.name == messageType) {
            "F1 decoded op '${message.op.name}' does not match registry type '$messageType'"
        }
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(projectFileTransfer(message)),
            reEncodedBytes = CrossNetworkFileTransferWireCodec.encode(message),
        )
    }

    private fun projectFileTransfer(message: CrossNetworkFileTransferMessage): Map<String, String> =
        buildMap {
            put("version", message.version.toString())
            put("op", message.op.name)
            put("transferId", message.transferId)
            message.senderDeviceId?.let { put("senderDeviceId", it) }
            message.senderDeviceName?.let { put("senderDeviceName", it) }
            message.fileName?.let { put("fileName", it) }
            message.fileSize?.let { put("fileSize", it.toString()) }
            message.chunkSize?.let { put("chunkSize", it.toString()) }
            message.totalChunks?.let { put("totalChunks", it.toString()) }
            message.mimeType?.let { put("mimeType", it) }
            message.encryption?.let { put("encryption", it) }
            message.chunkIndex?.let { put("chunkIndex", it.toString()) }
            message.chunkData?.let { put("chunkData", it.toHexLower()) }
            message.nonce?.let { put("nonce", it.toHexLower()) }
            message.chunkSha256?.let { put("chunkSha256", it.toHexLower()) }
            message.rawSize?.let { put("rawSize", it.toString()) }
            message.receivedBytes?.let { put("receivedBytes", it.toString()) }
            message.fileSha256?.let { put("fileSha256", it.toHexLower()) }
            message.merkleRoot?.let { put("merkleRoot", it.toHexLower()) }
            message.merkleRootSignature?.let { put("merkleRootSignature", it.toHexLower()) }
            message.merkleRootSignatureAlg?.let { put("merkleRootSignatureAlg", it) }
            message.missingChunks?.let { put("missingChunks", it.toList().toString()) }
            message.batchId?.let { put("batchId", it) }
            message.batchIndex?.let { put("batchIndex", it.toString()) }
            message.batchTotal?.let { put("batchTotal", it.toString()) }
            message.relativePath?.let { put("relativePath", it) }
            message.message?.let { put("message", it) }
        }

    private fun evaluateCapabilities(bytes: ByteArray): AppleVectorEvaluation {
        val value = P2PCryptoCapabilities.deterministicDecode(bytes)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "supportedKEM" to value.supportedKEM.toString(),
                    "supportedSignature" to value.supportedSignature.toString(),
                    "supportedAuthProfiles" to value.supportedAuthProfiles.toString(),
                    "supportedAEAD" to value.supportedAEAD.toString(),
                    "pqcAvailable" to value.pqcAvailable.toString(),
                    "platformVersion" to value.platformVersion,
                    "providerTypeRaw" to value.providerTypeRaw,
                ),
            ),
            reEncodedBytes = value.deterministicEncode(),
        )
    }

    private fun evaluatePolicy(bytes: ByteArray): AppleVectorEvaluation {
        val value = P2PHandshakePolicy.deterministicDecode(bytes)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "requirePqc" to value.requirePqc.toString(),
                    "allowClassicFallback" to value.allowClassicFallback.toString(),
                    "minimumTierRaw" to value.minimumTierRaw,
                    "requireSecureEnclavePoP" to value.requireSecureEnclavePoP.toString(),
                ),
            ),
            reEncodedBytes = value.deterministicEncode(),
        )
    }

    private fun evaluateMessageA(bytes: ByteArray): AppleVectorEvaluation {
        val value = P2PHandshakeWire.decodeMessageA(bytes)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "clientNonce" to value.clientNonce.toHexLower(),
                    "signature" to value.signature.toHexLower(),
                ),
            ),
            reEncodedBytes = P2PHandshakeWire.encodeMessageA(value),
        )
    }

    private fun evaluateMessageB(bytes: ByteArray): AppleVectorEvaluation {
        val value = P2PHandshakeWire.decodeMessageB(bytes)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "responderShare" to value.responderShare.toHexLower(),
                    "serverNonce" to value.serverNonce.toHexLower(),
                    "signature" to value.signature.toHexLower(),
                ),
            ),
            reEncodedBytes = P2PHandshakeWire.encodeMessageB(value),
        )
    }

    private fun evaluateFinished(bytes: ByteArray): AppleVectorEvaluation {
        val value = P2PHandshakeWire.decodeFinished(bytes)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "version" to (value.version.toInt() and 0xff).toString(),
                    "direction" to value.direction.name,
                    "mac" to value.mac.toHexLower(),
                ),
            ),
            reEncodedBytes = P2PHandshakeWire.encodeFinished(value.direction, value.mac),
        )
    }

    private fun evaluateHpke(bytes: ByteArray, isHandshake: Boolean): AppleVectorEvaluation {
        val value = P2PHPKESealedBox.parse(bytes, isHandshake = isHandshake)
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.Scalars(
                mapOf(
                    "version" to value.version.toString(),
                    "suiteWireId" to value.suiteWireId.toInt().toString(),
                    "encapsulatedKey" to value.encapsulatedKey.toHexLower(),
                    "nonce" to value.nonce.toHexLower(),
                    "ciphertext" to value.ciphertext.toHexLower(),
                    "tag" to value.tag.toHexLower(),
                ),
            ),
            reEncodedBytes = value.combinedWithHeader(),
        )
    }

    private fun evaluateBonjour(role: BonjourVectorRole, bytes: ByteArray): AppleVectorEvaluation {
        val fields = BonjourTxtRecordCodec.decode(bytes)
        require(fields.keys == role.expectedKeys) {
            "F4 ${role.messageType} keys do not match its typed advertisement role"
        }
        return AppleVectorEvaluation(
            projectedFields = VectorExpectedFields.RawBytes(fields),
            reEncodedBytes = BonjourTxtRecordCodec.encode(fields),
        )
    }

    private data class BonjourVectorRole(
        val messageType: String,
        val expectedKeys: Set<String>,
    )

}

private inline fun <T, R> Iterable<T>.mapToSet(transform: (T) -> R): Set<R> =
    mapTo(LinkedHashSet(), transform)
