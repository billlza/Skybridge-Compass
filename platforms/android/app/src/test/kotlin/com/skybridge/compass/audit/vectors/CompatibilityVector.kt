package com.skybridge.compass.audit.vectors

import java.util.Collections

/** The four production wire surfaces covered by the Apple compatibility corpus. */
enum class CodecSurface(
    val id: String,
    val dirName: String,
    val displayName: String,
    /** Audit-level coarse bound. Shipping codecs may impose a narrower message-specific bound. */
    val maxEncodedBytes: Int,
) {
    F1_FILE_TRANSFER("F1", "f1-file-transfer", "file-transfer message", 1 * 1024 * 1024),
    F2_P2P_HANDSHAKE("F2", "f2-p2p-handshake", "P2P handshake message", 65_535),
    F3_HPKE_SEALED_BOX("F3", "f3-hpke-sealed-box", "HPKE sealed box", 128 * 1024),
    F4_BONJOUR_TXT("F4", "f4-bonjour-txt", "Bonjour TXT record", 1_300),
    ;

    companion object {
        fun fromId(id: String): CodecSurface? = entries.firstOrNull { it.id == id }
    }
}

data class VectorProvenance(
    val origin: String,
    val source: String,
    val collectedAtUtc: String,
    val note: String,
    val repoIdentity: String,
    val repositoryRemoteUrl: String,
    val captureToolPath: String,
    val semanticInputPath: String,
    val semanticInputSha256: String,
    val sourcePath: String,
    val sourceCommit: String,
    val sourceSetSha256: String,
)

sealed interface VectorEntry {
    val surface: CodecSurface
    val messageType: String
    val provenance: VectorProvenance
    val relativePath: String

    /** Immutable snapshot of one Apple production-codec capture document. */
    class Loaded(
        override val surface: CodecSurface,
        override val messageType: String,
        override val provenance: VectorProvenance,
        override val relativePath: String,
        rawBytes: ByteArray,
        val expectedFields: VectorExpectedFields,
    ) : VectorEntry {
        private val rawBytesSnapshot = rawBytes.copyOf()

        val rawBytes: ByteArray
            get() = rawBytesSnapshot.copyOf()

        fun rawBytesHex(): String = rawBytesSnapshot.toHexLower()

        override fun equals(other: Any?): Boolean =
            other is Loaded &&
                surface == other.surface &&
                messageType == other.messageType &&
                provenance == other.provenance &&
                relativePath == other.relativePath &&
                rawBytesSnapshot.contentEquals(other.rawBytesSnapshot) &&
                expectedFields == other.expectedFields

        override fun hashCode(): Int {
            var result = surface.hashCode()
            result = 31 * result + messageType.hashCode()
            result = 31 * result + provenance.hashCode()
            result = 31 * result + relativePath.hashCode()
            result = 31 * result + rawBytesSnapshot.contentHashCode()
            result = 31 * result + expectedFields.hashCode()
            return result
        }
    }
}

/** Expected semantic fields are typed by surface; F4 never passes through a string/hex map. */
sealed interface VectorExpectedFields {
    class Scalars(values: Map<String, String>) : VectorExpectedFields {
        private val snapshot: Map<String, String> =
            Collections.unmodifiableMap(LinkedHashMap(values))

        val values: Map<String, String>
            get() = snapshot.toMap()

        override fun equals(other: Any?): Boolean = other is Scalars && snapshot == other.snapshot

        override fun hashCode(): Int = snapshot.hashCode()
    }

    class RawBytes(values: Map<String, ByteArray>) : VectorExpectedFields {
        private val snapshot: Map<String, ByteArray> = Collections.unmodifiableMap(
            values.mapValuesTo(LinkedHashMap()) { (_, value) -> value.copyOf() },
        )

        val values: Map<String, ByteArray>
            get() = Collections.unmodifiableMap(
                snapshot.mapValuesTo(LinkedHashMap()) { (_, value) -> value.copyOf() },
            )

        override fun equals(other: Any?): Boolean =
            other is RawBytes &&
                snapshot.keys == other.snapshot.keys &&
                snapshot.all { (key, value) -> value.contentEquals(other.snapshot.getValue(key)) }

        override fun hashCode(): Int = snapshot.keys.sorted().fold(1) { hash, key ->
            31 * hash + key.hashCode() + 31 * snapshot.getValue(key).contentHashCode()
        }
    }
}

data class AppleVectorToolchain(
    val swiftVersion: String,
    val xcodeVersion: String,
    val testExecutableSha256: String,
)

data class AppleVectorCapture(
    val surface: CodecSurface,
    val messageType: String,
    val relativePath: String,
    val sourcePath: String,
    val rawByteCount: Int,
    val documentSha256: String,
)

data class AppleVectorManifest(
    val schemaVersion: Int,
    val fixtureSetId: String,
    val repoIdentity: String,
    val repositoryRemoteUrl: String,
    val sourceCommit: String,
    val sourceSetSha256: String,
    val semanticInputPath: String,
    val semanticInputSha256: String,
    val captureToolPath: String,
    val collectedAtUtc: String,
    val integrityPurpose: String,
    val toolchain: AppleVectorToolchain,
    val captures: List<AppleVectorCapture>,
)

data class AppleVectorDescriptor(
    val surface: CodecSurface,
    val messageType: String,
    val relativePath: String,
    val sourcePath: String,
)

/** Pinned Level-1 provenance contract for the fresh Apple production-codec capture. */
internal object AppleVectorContract {
    const val MANIFEST_SHA256 = "8baaf1e824a65d74a35e25d27ba57771e488cf6bdd63611b0c45273d47c09869"
    const val README_SHA256 = "c7745dc36da5e7d818ab2b8758813dc7005a499aa562a7182f2c7fdda378c0e2"
    const val SOURCE_COMMIT = "6d6f601ea0ac23ba5c62d46b98c3efd03acc4898"
    const val SOURCE_SET_SHA256 = "7ea5e3760a2f27818700bdad3f047f26d9670365eb79ea73e70a72ea69364cfb"
    const val SEMANTIC_INPUT_SHA256 = "d3ff9759f75fb6dd4651b0b41e156005809ce3db6cc80524ca56533e17058cb0"
    const val REPO_IDENTITY = "github.com/billlza/Skybridge-Compass"
    const val REPOSITORY_REMOTE_URL = "https://github.com/billlza/Skybridge-Compass"
    const val CAPTURE_TOOL_PATH = "Tests/SkyBridgeCoreTests/AppleCompatibilityVectorCaptureTests.swift"
    const val SEMANTIC_INPUT_PATH = "Tests/SkyBridgeCoreTests/Fixtures/AppleCompatibilityVectors/inputs.json"
    const val FIXTURE_SET_ID = "apple-production-codec-v1"
    const val CAPTURED_AT_UTC = "2026-08-10T22:59:36.000Z"
    const val ORIGIN = "APPLE_REFERENCE_CAPTURE"
    const val SOURCE = "SkyBridge Apple production codec XCTest capture"

    private const val F1_SOURCE =
        "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferWireEncoder.swift"
    private const val HANDSHAKE_SOURCE = "Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift"
    private const val HPKE_SOURCE = "Sources/SkyBridgeProtocolCore/P2P/HPKESealedBox.swift"
    private const val BONJOUR_SOURCE =
        "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift"

    val descriptors: List<AppleVectorDescriptor> = Collections.unmodifiableList(listOf(
        descriptor(CodecSurface.F1_FILE_TRANSFER, "cancel", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "chunk", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "chunkAck", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "complete", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "completeAck", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "error", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "metadata", F1_SOURCE),
        descriptor(CodecSurface.F1_FILE_TRANSFER, "metadataAck", F1_SOURCE),
        descriptor(
            CodecSurface.F2_P2P_HANDSHAKE,
            "cryptoCapabilities",
            "Sources/SkyBridgeProtocolCore/P2P/CryptoCapabilities.swift",
        ),
        descriptor(CodecSurface.F2_P2P_HANDSHAKE, "finished", HANDSHAKE_SOURCE),
        descriptor(
            CodecSurface.F2_P2P_HANDSHAKE,
            "handshakePolicy",
            "Sources/SkyBridgeProtocolCore/P2P/TranscriptBuilder.swift",
        ),
        descriptor(CodecSurface.F2_P2P_HANDSHAKE, "messageA", HANDSHAKE_SOURCE),
        descriptor(CodecSurface.F2_P2P_HANDSHAKE, "messageB", HANDSHAKE_SOURCE),
        descriptor(CodecSurface.F3_HPKE_SEALED_BOX, "application-v1", HPKE_SOURCE),
        descriptor(CodecSurface.F3_HPKE_SEALED_BOX, "application-v2", HPKE_SOURCE),
        descriptor(CodecSurface.F3_HPKE_SEALED_BOX, "handshake-v1", HPKE_SOURCE),
        descriptor(CodecSurface.F3_HPKE_SEALED_BOX, "handshake-v2", HPKE_SOURCE),
        descriptor(CodecSurface.F3_HPKE_SEALED_BOX, "v2-empty-nonce-tag", HPKE_SOURCE),
        descriptor(CodecSurface.F4_BONJOUR_TXT, "capabilities-record", BONJOUR_SOURCE),
        descriptor(CodecSurface.F4_BONJOUR_TXT, "identity-keys-record", BONJOUR_SOURCE),
        descriptor(CodecSurface.F4_BONJOUR_TXT, "main-service-record", BONJOUR_SOURCE),
        descriptor(CodecSurface.F4_BONJOUR_TXT, "remote-service-record", BONJOUR_SOURCE),
        descriptor(CodecSurface.F4_BONJOUR_TXT, "transfer-service-record", BONJOUR_SOURCE),
    ))

    val byRelativePath: Map<String, AppleVectorDescriptor> = Collections.unmodifiableMap(
        descriptors.associateByTo(LinkedHashMap()) { it.relativePath },
    )

    private fun descriptor(
        surface: CodecSurface,
        messageType: String,
        sourcePath: String,
    ): AppleVectorDescriptor = AppleVectorDescriptor(
        surface = surface,
        messageType = messageType,
        relativePath = "${surface.dirName}/$messageType-1.json",
        sourcePath = sourcePath,
    )
}

internal fun ByteArray.toHexLower(): String = buildString(size * 2) {
    this@toHexLower.forEach { byte ->
        val value = byte.toInt() and 0xff
        append(HEX_DIGITS[value ushr 4])
        append(HEX_DIGITS[value and 0x0f])
    }
}

private const val HEX_DIGITS = "0123456789abcdef"
