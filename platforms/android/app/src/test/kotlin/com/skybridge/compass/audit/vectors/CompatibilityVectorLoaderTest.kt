package com.skybridge.compass.audit.vectors

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir

class CompatibilityVectorLoaderTest {
    private val json = Json

    @Test
    fun realCorpusIsManifestFirstPinnedAndComplete() {
        val loader = CompatibilityVectorLoader.fromWorkspace()

        assertEquals(AppleVectorContract.SOURCE_COMMIT, loader.manifest.sourceCommit)
        assertEquals(AppleVectorContract.SOURCE_SET_SHA256, loader.manifest.sourceSetSha256)
        assertEquals(AppleVectorContract.SEMANTIC_INPUT_SHA256, loader.manifest.semanticInputSha256)
        assertEquals(23, loader.manifest.captures.size)
        assertEquals(23, loader.loadAll().size)
        assertEquals(
            mapOf("F1" to 8, "F2" to 5, "F3" to 5, "F4" to 5),
            loader.loadAll().groupingBy { it.surface.id }.eachCount(),
        )
        assertTrue(CodecSurface.entries.all(loader::satisfiesR91))
    }

    @Test
    fun realCorpusMatchesExactTypedDescriptorAndProvenanceRegistry() {
        val loader = CompatibilityVectorLoader.fromWorkspace()

        loader.loadAll().zip(AppleVectorContract.descriptors).forEach { (vector, descriptor) ->
            assertEquals(descriptor.surface, vector.surface)
            assertEquals(descriptor.messageType, vector.messageType)
            assertEquals(descriptor.relativePath, vector.relativePath)
            assertEquals(descriptor.sourcePath, vector.provenance.sourcePath)
            assertEquals(AppleVectorContract.ORIGIN, vector.provenance.origin)
            assertEquals(loader.manifest.sourceCommit, vector.provenance.sourceCommit)
            assertEquals(loader.manifest.sourceSetSha256, vector.provenance.sourceSetSha256)
        }
    }

    @Test
    fun snapshotsCannotBeMutatedThroughRawBytesOrExpectedFields() {
        val loader = CompatibilityVectorLoader.fromWorkspace()
        val scalar = loader.loadRequired(CodecSurface.F1_FILE_TRANSFER, "metadata").single()
        val originalFirstByte = scalar.rawBytes.first()
        scalar.rawBytes[0] = (originalFirstByte.toInt() xor 0xff).toByte()
        assertEquals(originalFirstByte, scalar.rawBytes.first())

        val scalarFields = (scalar.expectedFields as VectorExpectedFields.Scalars).values.toMutableMap()
        scalarFields["op"] = "corrupted"
        assertEquals("metadata", scalar.expectedFields.values["op"])

        val raw = loader.loadRequired(CodecSurface.F4_BONJOUR_TXT, "main-service-record").single()
        val firstRead = (raw.expectedFields as VectorExpectedFields.RawBytes).values
        val originalDeviceId = firstRead.getValue("deviceId").copyOf()
        firstRead.getValue("deviceId")[0] = 0
        val secondRead = raw.expectedFields.values
        assertArrayEquals(originalDeviceId, secondRead.getValue("deviceId"))
    }

    @Test
    fun rawExpectedFieldsEqualityAndHashAreIndependentOfInsertionOrder() {
        val first = VectorExpectedFields.RawBytes(
            linkedMapOf("a" to byteArrayOf(1), "b" to byteArrayOf(2)),
        )
        val second = VectorExpectedFields.RawBytes(
            linkedMapOf("b" to byteArrayOf(2), "a" to byteArrayOf(1)),
        )

        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
    }

    @Test
    fun manifestAndReadmeHashesArePinned() {
        val root = CompatibilityVectorLoader.locateCorpus()
        assertEquals(
            AppleVectorContract.MANIFEST_SHA256,
            sha256(File(root, "manifest.json").readBytes()),
        )
        assertEquals(
            AppleVectorContract.README_SHA256,
            sha256(File(root, "README.md").readBytes()),
        )
    }

    @Test
    fun extraFileFailsClosed(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        File(corpus, "unexpected.txt").writeText("unexpected")

        assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
    }

    @Test
    fun extraDirectoryFailsClosed(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        File(corpus, "extra-directory").mkdir()

        assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
    }

    @Test
    fun missingDocumentFailsClosed(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        assertTrue(File(corpus, "f2-p2p-handshake/messageA-1.json").delete())

        assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
    }

    @Test
    fun symbolicLinkFailsClosed(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        val expectedPath = File(corpus, "f1-file-transfer/metadata-1.json")
        val externalTarget = File(temporary, "metadata-target.json")
        assertTrue(expectedPath.renameTo(externalTarget))
        Files.createSymbolicLink(expectedPath.toPath(), externalTarget.toPath())

        assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
    }

    @Test
    fun changedManifestFailsPinnedDigestBeforeAnyVectorIsExposed(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        File(corpus, "manifest.json").appendText(" ")

        val error = assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
        assertTrue(error.message.orEmpty().contains("manifest.json SHA-256 mismatch"))
    }

    @Test
    fun oversizedReadmeFailsAtTheBoundedFileRead(@TempDir temporary: File) {
        val corpus = copyCorpus(temporary)
        File(corpus, "README.md").writeBytes(ByteArray(64 * 1_024 + 1) { 'x'.code.toByte() })

        val error = assertThrows(VectorSchemaException::class.java) {
            CompatibilityVectorLoader(corpus)
        }
        assertTrue(error.message.orEmpty().contains("file size"))
        assertTrue(error.message.orEmpty().contains("1..65536"))
    }

    @Test
    fun globalDescriptorContractCannotBeMutatedThroughJvmCollectionCasts() {
        val descriptorMutationView = AppleVectorContract.descriptors as MutableList<*>
        assertThrows(UnsupportedOperationException::class.java) {
            descriptorMutationView.clear()
        }
        val pathMutationView = AppleVectorContract.byRelativePath as MutableMap<*, *>
        assertThrows(UnsupportedOperationException::class.java) {
            pathMutationView.clear()
        }
        assertEquals(23, AppleVectorContract.descriptors.size)
        assertEquals(23, AppleVectorContract.byRelativePath.size)
    }

    @Test
    fun documentSchemaRejectsTypedIdentityCountFieldsAndProvenanceMutations() {
        val loader = CompatibilityVectorLoader.fromWorkspace()
        val corpus = CompatibilityVectorLoader.locateCorpus()
        val relativePath = "f1-file-transfer/metadata-1.json"
        val base = json.parseToJsonElement(File(corpus, relativePath).readText()).jsonObject
        loader.parseDocumentSchemaForTest(base.toBytes(), relativePath)

        val expected = base.getValue("expectedFields").jsonObject
        val provenance = base.getValue("provenance").jsonObject
        val rawHex = (base.getValue("rawBytesHex") as JsonPrimitive).content
        val invalid = listOf(
            JsonObject(base + ("unexpected" to JsonPrimitive("value"))),
            JsonObject(base - "expectedFields"),
            JsonObject(base + ("surface" to JsonPrimitive("F2"))),
            JsonObject(base + ("messageType" to JsonPrimitive("chunk"))),
            JsonObject(base + ("rawBytesHex" to JsonPrimitive(rawHex + "00"))),
            JsonObject(
                base + ("expectedFields" to JsonObject(expected + ("version" to JsonPrimitive(1)))),
            ),
            JsonObject(
                base + ("provenance" to JsonObject(
                    provenance + ("origin" to JsonPrimitive("PENDING_APPLE_CAPTURE")),
                )),
            ),
            JsonObject(
                base + ("provenance" to JsonObject(
                    provenance + ("sourcePath" to JsonPrimitive("../HandshakeMessages.swift")),
                )),
            ),
            JsonObject(
                base + ("provenance" to JsonObject(
                    provenance + ("sourceCommit" to JsonPrimitive("0".repeat(40))),
                )),
            ),
        )
        invalid.forEach { document ->
            assertThrows(VectorSchemaException::class.java) {
                loader.parseDocumentSchemaForTest(document.toBytes(), relativePath)
            }
        }
    }

    @Test
    fun f4ExpectedFieldsRejectNonLowerHexAndRemainTypedRawBytes() {
        val loader = CompatibilityVectorLoader.fromWorkspace()
        val corpus = CompatibilityVectorLoader.locateCorpus()
        val relativePath = "f4-bonjour-txt/main-service-record-1.json"
        val base = json.parseToJsonElement(File(corpus, relativePath).readText()).jsonObject
        val fields = base.getValue("expectedFields").jsonObject
        val deviceId = (fields.getValue("deviceId") as JsonPrimitive).content
        val uppercase = JsonObject(
            base + ("expectedFields" to JsonObject(
                fields + ("deviceId" to JsonPrimitive(deviceId.uppercase())),
            )),
        )

        assertThrows(VectorSchemaException::class.java) {
            loader.parseDocumentSchemaForTest(uppercase.toBytes(), relativePath)
        }
        assertTrue(
            loader.parseDocumentSchemaForTest(base.toBytes(), relativePath).expectedFields
                is VectorExpectedFields.RawBytes,
        )
    }

    @Test
    fun manifestSchemaRejectsUnknownMissingTraversalCountAndDescriptorMutations() {
        val loader = CompatibilityVectorLoader.fromWorkspace()
        val corpus = CompatibilityVectorLoader.locateCorpus()
        val base = json.parseToJsonElement(File(corpus, "manifest.json").readText()).jsonObject
        loader.parseManifestSchemaForTest(base.toBytes())

        val captures = base.getValue("captures").jsonArray
        val firstCapture = captures.first().jsonObject
        fun withFirstCapture(capture: JsonObject): JsonObject = JsonObject(
            base + ("captures" to JsonArray(listOf(capture) + captures.drop(1))),
        )
        val invalid = listOf(
            JsonObject(base + ("unexpected" to JsonPrimitive("value"))),
            JsonObject(base - "sourceCommit"),
            JsonObject(base + ("captures" to JsonArray(captures.dropLast(1)))),
            withFirstCapture(
                JsonObject(firstCapture + ("relativePath" to JsonPrimitive("../cancel-1.json"))),
            ),
            withFirstCapture(
                JsonObject(firstCapture + ("messageType" to JsonPrimitive("chunk"))),
            ),
            withFirstCapture(
                JsonObject(firstCapture + ("rawByteCount" to JsonPrimitive(0))),
            ),
            withFirstCapture(
                JsonObject(
                    firstCapture + ("documentSha256" to JsonPrimitive("A".repeat(64))),
                ),
            ),
            JsonObject(base + ("repoIdentity" to JsonPrimitive("example.invalid/repo"))),
        )
        invalid.forEach { manifest ->
            assertThrows(VectorSchemaException::class.java) {
                loader.parseManifestSchemaForTest(manifest.toBytes())
            }
        }
    }

    @Test
    fun strictSyntaxRejectsInvalidUtf8DuplicateKeysAndTrailingContent() {
        assertThrows(VectorSchemaException::class.java) {
            StrictVectorJson.parseObject(byteArrayOf(0xc3.toByte(), 0x28), "invalid", 32)
        }
        listOf(
            """{"a":1,"a":2}""",
            """{"a":1,"\u0061":2}""",
            """{"outer":{"a":1,"a":2}}""",
            """{"a":1} false""",
        ).forEach { json ->
            assertThrows(VectorSchemaException::class.java) {
                StrictVectorJson.parseObject(json.encodeToByteArray(), "invalid", 256)
            }
        }
    }

    @Test
    fun strictSyntaxAcceptsEscapedSlashQuoteAndValidSurrogatePair() {
        val root = StrictVectorJson.parseObject(
            """{"slash":"a\/b","quote":"\"","emoji":"\uD83D\uDE00"}"""
                .encodeToByteArray(),
            "valid",
            256,
        )
        assertEquals(setOf("slash", "quote", "emoji"), root.keys)
        assertEquals("a/b", (root.getValue("slash") as JsonPrimitive).content)
        assertEquals("\"", (root.getValue("quote") as JsonPrimitive).content)
        assertEquals("😀", (root.getValue("emoji") as JsonPrimitive).content)
    }

    @Test
    fun strictSyntaxEnforcesNestingDepthBeforeStackExhaustion() {
        val atLimit = "[".repeat(15) + "0" + "]".repeat(15)
        StrictVectorJson.parseObject(
            """{"value":$atLimit}""".encodeToByteArray(),
            "at-limit",
            256,
        )
        val overLimit = "[".repeat(16) + "0" + "]".repeat(16)
        assertThrows(VectorSchemaException::class.java) {
            StrictVectorJson.parseObject(
                """{"value":$overLimit}""".encodeToByteArray(),
                "over-limit",
                256,
            )
        }
    }

    @Test
    fun exactKeyValidationRejectsUnknownAndMissingFields() {
        val withUnknown = StrictVectorJson.parseObject(
            """{"a":"1","extra":"2"}""".encodeToByteArray(),
            "unknown",
            128,
        )
        assertThrows(VectorSchemaException::class.java) {
            withUnknown.requireExactKeys(setOf("a"), "unknown")
        }
        val missing = StrictVectorJson.parseObject("{}".encodeToByteArray(), "missing", 32)
        assertThrows(VectorSchemaException::class.java) {
            missing.requireExactKeys(setOf("a"), "missing")
        }
    }

    @Test
    fun captureHexIsStrictLowerCaseEvenAndBounded() {
        assertArrayEquals(byteArrayOf(0xde.toByte(), 0xad.toByte()), CompatibilityVectorLoader.decodeHex("dead"))
        listOf("DEAD", "de ad", "dea", "gg").forEach { invalid ->
            assertThrows(VectorSchemaException::class.java) {
                CompatibilityVectorLoader.decodeHex(invalid)
            }
        }
    }

    @Test
    fun byteComparisonReportsContentAndLengthDifferences() {
        assertEquals(null, CompatibilityVectorLoader.firstUnequalByteOffset(byteArrayOf(1), byteArrayOf(1)))
        assertEquals(1, CompatibilityVectorLoader.firstUnequalByteOffset(byteArrayOf(1, 2), byteArrayOf(1, 3)))
        assertEquals(1, CompatibilityVectorLoader.firstUnequalByteOffset(byteArrayOf(1), byteArrayOf(1, 2)))
        assertNotEquals(
            null,
            CompatibilityVectorLoader.describeByteMismatch(byteArrayOf(1), byteArrayOf(2), "vector"),
        )
    }

    private fun copyCorpus(temporary: File): File {
        val source = CompatibilityVectorLoader.locateCorpus()
        val destination = File(temporary, "vectors")
        assertTrue(source.copyRecursively(destination))
        return destination
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHexLower()

    private fun JsonObject.toBytes(): ByteArray = toString().encodeToByteArray()
}
