package com.skybridge.compass.audit.vectors

import java.io.File
import java.nio.charset.CharacterCodingException
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Collections
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * Read-only, manifest-first loader for the Apple production-codec compatibility corpus.
 *
 * The SHA-256 checks are Level-1 reliability evidence: they detect accidental corruption and
 * misattribution. They are not an authenticity or anti-tamper boundary. The loader never writes or
 * updates the corpus and validates the complete allowlisted snapshot before exposing one vector.
 */
class CompatibilityVectorLoader(
    private val vectorsRoot: File,
) {
    private val corpus: CorpusSnapshot = loadCorpus()

    val manifest: AppleVectorManifest
        get() = corpus.manifest

    fun loadAll(surface: CodecSurface): List<VectorEntry.Loaded> =
        corpus.vectorsBySurface.getValue(surface)

    fun loadAll(): List<VectorEntry.Loaded> = corpus.vectors

    fun appleVectors(surface: CodecSurface): List<VectorEntry.Loaded> = loadAll(surface)

    fun loadRequired(surface: CodecSurface, messageType: String): List<VectorEntry.Loaded> {
        val matching = loadAll(surface).filter { it.messageType == messageType }
        if (matching.isEmpty()) {
            throw MissingVectorException(
                "Apple compatibility vector missing for ${surface.id}/$messageType",
            )
        }
        return Collections.unmodifiableList(matching)
    }

    fun requireAppleVectors(
        surface: CodecSurface,
        requireMinimumCoverage: Boolean = true,
    ): List<VectorEntry.Loaded> {
        val vectors = loadAll(surface)
        if (vectors.isEmpty()) {
            throw MissingVectorException("No Apple production-codec vectors for ${surface.id}")
        }
        if (requireMinimumCoverage && vectors.size < MIN_VECTORS_PER_SURFACE) {
            throw MissingVectorException(
                "Apple vector coverage for ${surface.id} is ${vectors.size}; " +
                    "at least $MIN_VECTORS_PER_SURFACE are required",
            )
        }
        return vectors
    }

    fun satisfiesR91(surface: CodecSurface): Boolean =
        loadAll(surface).size >= MIN_VECTORS_PER_SURFACE

    fun coverage(surface: CodecSurface): SurfaceCoverage {
        val vectors = loadAll(surface)
        return SurfaceCoverage(
            surface = surface,
            totalEntries = vectors.size,
            appleCapturedCount = vectors.size,
            messageTypes = Collections.unmodifiableSet(vectors.mapTo(sortedSetOf()) { it.messageType }),
            satisfiesR91 = vectors.size >= MIN_VECTORS_PER_SURFACE,
        )
    }

    fun coverage(): List<SurfaceCoverage> = CodecSurface.entries.map(::coverage)

    /** Test-visible schema seam; production corpus loading still verifies the document digest first. */
    internal fun parseDocumentSchemaForTest(
        bytes: ByteArray,
        relativePath: String,
    ): VectorEntry.Loaded {
        val capture = manifest.captures.singleOrNull { it.relativePath == relativePath }
            ?: throw VectorSchemaException("Unknown typed vector path: $relativePath")
        val descriptor = AppleVectorContract.byRelativePath.getValue(relativePath)
        return parseVectorDocument(bytes, capture, descriptor, manifest)
    }

    /** Test-visible manifest schema seam; normal construction verifies the pinned digest first. */
    internal fun parseManifestSchemaForTest(bytes: ByteArray): AppleVectorManifest =
        parseManifest(bytes)

    private fun loadCorpus(): CorpusSnapshot {
        requireCorpusRoot()
        requireExactFileTree()

        val readmeBytes = readRegularFile(File(vectorsRoot, README_FILE), README_FILE, MAX_README_BYTES)
        requireSha256(readmeBytes, AppleVectorContract.README_SHA256, README_FILE)

        val manifestBytes = readRegularFile(
            File(vectorsRoot, MANIFEST_FILE),
            MANIFEST_FILE,
            MAX_MANIFEST_BYTES,
        )
        requireSha256(manifestBytes, AppleVectorContract.MANIFEST_SHA256, MANIFEST_FILE)
        val manifest = parseManifest(manifestBytes)

        val vectors = ArrayList<VectorEntry.Loaded>(manifest.captures.size)
        manifest.captures.forEach { capture ->
            val descriptor = AppleVectorContract.byRelativePath.getValue(capture.relativePath)
            val bytes = readRegularFile(
                File(vectorsRoot, capture.relativePath),
                capture.relativePath,
                maxDocumentBytes(descriptor.surface),
            )
            requireSha256(bytes, capture.documentSha256, capture.relativePath)
            vectors += parseVectorDocument(bytes, capture, descriptor, manifest)
        }
        // Do not publish a partial snapshot if the corpus tree changed while it was being read.
        requireExactFileTree()

        val immutableVectors = Collections.unmodifiableList(vectors.toList())
        val bySurface = CodecSurface.entries.associateWith { surface ->
            Collections.unmodifiableList(immutableVectors.filter { it.surface == surface })
        }
        return CorpusSnapshot(
            manifest = manifest,
            vectors = immutableVectors,
            vectorsBySurface = Collections.unmodifiableMap(bySurface),
        )
    }

    private fun requireCorpusRoot() {
        val path = vectorsRoot.toPath()
        if (Files.isSymbolicLink(path) || !Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            throw MissingVectorException(
                "Compatibility vector corpus is missing or is not a real directory: ${vectorsRoot.absolutePath}",
            )
        }
    }

    private fun requireExactFileTree() {
        val expectedRootNames = AppleVectorContract.descriptors
            .mapTo(sortedSetOf()) { it.surface.dirName }
            .apply {
                add(MANIFEST_FILE)
                add(README_FILE)
            }
        val rootEntries = vectorsRoot.listFiles()
            ?: throw VectorSchemaException("Unable to list vector corpus root")
        val actualRootNames = rootEntries.mapTo(sortedSetOf()) { it.name }
        if (actualRootNames != expectedRootNames) {
            throw VectorSchemaException(
                "Vector corpus root file set mismatch: expected=$expectedRootNames actual=$actualRootNames",
            )
        }

        rootEntries.forEach { entry ->
            if (Files.isSymbolicLink(entry.toPath())) {
                throw VectorSchemaException("Symbolic links are forbidden in vector corpus: ${entry.name}")
            }
        }

        CodecSurface.entries.forEach { surface ->
            val directory = File(vectorsRoot, surface.dirName)
            if (!Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                throw VectorSchemaException("Vector surface path is not a directory: ${surface.dirName}")
            }
            val expectedNames = AppleVectorContract.descriptors
                .asSequence()
                .filter { it.surface == surface }
                .mapTo(sortedSetOf()) { File(it.relativePath).name }
            val entries = directory.listFiles()
                ?: throw VectorSchemaException("Unable to list vector surface: ${surface.dirName}")
            val actualNames = entries.mapTo(sortedSetOf()) { it.name }
            if (actualNames != expectedNames) {
                throw VectorSchemaException(
                    "Vector file set mismatch for ${surface.id}: expected=$expectedNames actual=$actualNames",
                )
            }
            entries.forEach { file ->
                if (Files.isSymbolicLink(file.toPath()) ||
                    !Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
                ) {
                    throw VectorSchemaException(
                        "Vector must be a non-symbolic regular file: ${surface.dirName}/${file.name}",
                    )
                }
            }
        }
    }

    private fun parseManifest(bytes: ByteArray): AppleVectorManifest {
        val root = StrictVectorJson.parseObject(bytes, MANIFEST_FILE, MAX_MANIFEST_BYTES)
        root.requireExactKeys(MANIFEST_KEYS, MANIFEST_FILE)

        val manifest = AppleVectorManifest(
            schemaVersion = root.requireInt("schemaVersion", MANIFEST_FILE),
            fixtureSetId = root.requireString("fixtureSetId", MANIFEST_FILE),
            repoIdentity = root.requireString("repoIdentity", MANIFEST_FILE),
            repositoryRemoteUrl = root.requireString("repositoryRemoteURL", MANIFEST_FILE),
            sourceCommit = root.requireLowerHex("sourceCommit", 20, MANIFEST_FILE),
            sourceSetSha256 = root.requireLowerHex("sourceSetSha256", 32, MANIFEST_FILE),
            semanticInputPath = root.requireString("semanticInputPath", MANIFEST_FILE),
            semanticInputSha256 = root.requireLowerHex("semanticInputSha256", 32, MANIFEST_FILE),
            captureToolPath = root.requireString("captureToolPath", MANIFEST_FILE),
            collectedAtUtc = root.requireString("collectedAtUtc", MANIFEST_FILE),
            integrityPurpose = root.requireString("integrityPurpose", MANIFEST_FILE),
            toolchain = parseToolchain(root.requireObject("toolchain", MANIFEST_FILE)),
            captures = parseCaptures(root.requireArray("captures", MANIFEST_FILE)),
        )
        requirePinnedManifest(manifest)
        return manifest.copy(captures = Collections.unmodifiableList(manifest.captures.toList()))
    }

    private fun parseToolchain(root: JsonObject): AppleVectorToolchain {
        root.requireExactKeys(TOOLCHAIN_KEYS, "$MANIFEST_FILE.toolchain")
        return AppleVectorToolchain(
            swiftVersion = root.requireString("swiftVersion", "$MANIFEST_FILE.toolchain"),
            xcodeVersion = root.requireString("xcodeVersion", "$MANIFEST_FILE.toolchain"),
            testExecutableSha256 = root.requireLowerHex(
                "testExecutableSha256",
                32,
                "$MANIFEST_FILE.toolchain",
            ),
        )
    }

    private fun parseCaptures(array: JsonArray): List<AppleVectorCapture> {
        if (array.size != AppleVectorContract.descriptors.size) {
            throw VectorSchemaException(
                "$MANIFEST_FILE captures count ${array.size} != ${AppleVectorContract.descriptors.size}",
            )
        }
        val captures = array.mapIndexed { index, element ->
            val context = "$MANIFEST_FILE.captures[$index]"
            val root = element as? JsonObject
                ?: throw VectorSchemaException("$context must be an object")
            root.requireExactKeys(CAPTURE_KEYS, context)
            val surfaceId = root.requireString("surface", context)
            val surface = CodecSurface.fromId(surfaceId)
                ?: throw VectorSchemaException("$context has unsupported surface '$surfaceId'")
            AppleVectorCapture(
                surface = surface,
                messageType = root.requireString("messageType", context),
                relativePath = validateRelativePath(root.requireString("relativePath", context), context),
                sourcePath = validateRepositoryPath(root.requireString("sourcePath", context), context),
                rawByteCount = root.requireInt("rawByteCount", context),
                documentSha256 = root.requireLowerHex("documentSha256", 32, context),
            )
        }
        val identities = captures.map { Triple(it.surface, it.messageType, it.relativePath) }
        if (identities.toSet().size != identities.size) {
            throw VectorSchemaException("$MANIFEST_FILE contains duplicate capture identities")
        }
        captures.zip(AppleVectorContract.descriptors).forEachIndexed { index, (capture, expected) ->
            if (
                capture.surface != expected.surface ||
                capture.messageType != expected.messageType ||
                capture.relativePath != expected.relativePath ||
                capture.sourcePath != expected.sourcePath
            ) {
                throw VectorSchemaException(
                    "$MANIFEST_FILE capture[$index] does not match the typed capture registry",
                )
            }
            if (capture.rawByteCount !in 1..capture.surface.maxEncodedBytes) {
                throw VectorSchemaException(
                    "$MANIFEST_FILE capture[$index] rawByteCount is outside ${capture.surface.id} bounds",
                )
            }
        }
        return captures
    }

    private fun requirePinnedManifest(manifest: AppleVectorManifest) {
        val pinned = listOf(
            "schemaVersion" to (manifest.schemaVersion == 1),
            "fixtureSetId" to (manifest.fixtureSetId == AppleVectorContract.FIXTURE_SET_ID),
            "repoIdentity" to (manifest.repoIdentity == AppleVectorContract.REPO_IDENTITY),
            "repositoryRemoteURL" to
                (manifest.repositoryRemoteUrl == AppleVectorContract.REPOSITORY_REMOTE_URL),
            "sourceCommit" to (manifest.sourceCommit == AppleVectorContract.SOURCE_COMMIT),
            "sourceSetSha256" to (manifest.sourceSetSha256 == AppleVectorContract.SOURCE_SET_SHA256),
            "semanticInputPath" to
                (manifest.semanticInputPath == AppleVectorContract.SEMANTIC_INPUT_PATH),
            "semanticInputSha256" to
                (manifest.semanticInputSha256 == AppleVectorContract.SEMANTIC_INPUT_SHA256),
            "captureToolPath" to (manifest.captureToolPath == AppleVectorContract.CAPTURE_TOOL_PATH),
            "collectedAtUtc" to (manifest.collectedAtUtc == AppleVectorContract.CAPTURED_AT_UTC),
            "integrityPurpose" to (manifest.integrityPurpose == INTEGRITY_PURPOSE),
        )
        pinned.firstOrNull { !it.second }?.let { (field, _) ->
            throw VectorSchemaException("$MANIFEST_FILE pinned field mismatch: $field")
        }
        try {
            val instant = Instant.parse(manifest.collectedAtUtc)
            if (instant.toString() != "2026-08-10T22:59:36Z") {
                throw VectorSchemaException("$MANIFEST_FILE collectedAtUtc is not the pinned UTC instant")
            }
        } catch (error: DateTimeParseException) {
            throw VectorSchemaException("$MANIFEST_FILE collectedAtUtc is not valid UTC", error)
        }
    }

    private fun parseVectorDocument(
        bytes: ByteArray,
        capture: AppleVectorCapture,
        descriptor: AppleVectorDescriptor,
        manifest: AppleVectorManifest,
    ): VectorEntry.Loaded {
        val context = capture.relativePath
        val root = StrictVectorJson.parseObject(bytes, context, maxDocumentBytes(capture.surface))
        root.requireExactKeys(DOCUMENT_KEYS, context)
        if (root.requireInt("schemaVersion", context) != 1) {
            throw VectorSchemaException("$context schemaVersion must be 1")
        }
        if (root.requireString("surface", context) != descriptor.surface.id) {
            throw VectorSchemaException("$context surface does not match manifest/registry")
        }
        if (root.requireString("messageType", context) != descriptor.messageType) {
            throw VectorSchemaException("$context messageType does not match manifest/registry")
        }

        val rawBytesHex = root.requireString("rawBytesHex", context)
        val rawBytes = decodeLowerHex(
            rawBytesHex,
            maxBytes = capture.surface.maxEncodedBytes,
            context = "$context.rawBytesHex",
        )
        if (rawBytes.isEmpty() || rawBytes.size != capture.rawByteCount) {
            throw VectorSchemaException(
                "$context raw byte count ${rawBytes.size} != manifest ${capture.rawByteCount}",
            )
        }

        val expectedFieldsObject = root.requireObject("expectedFields", context)
        if (expectedFieldsObject.isEmpty()) {
            throw VectorSchemaException("$context expectedFields must not be empty")
        }
        val expectedFieldStrings = LinkedHashMap<String, String>(expectedFieldsObject.size)
        expectedFieldsObject.forEach { (key, value) ->
            if (key.isBlank()) throw VectorSchemaException("$context expectedFields has a blank key")
            val primitive = value as? JsonPrimitive
                ?: throw VectorSchemaException("$context expectedFields.$key must be a string")
            if (!primitive.isString) {
                throw VectorSchemaException("$context expectedFields.$key must be a string")
            }
            expectedFieldStrings[key] = primitive.content
        }
        val expectedFields: VectorExpectedFields =
            if (capture.surface == CodecSurface.F4_BONJOUR_TXT) {
                VectorExpectedFields.RawBytes(
                    expectedFieldStrings.mapValuesTo(LinkedHashMap()) { (key, value) ->
                        decodeLowerHex(
                            value,
                            capture.surface.maxEncodedBytes,
                            "$context.expectedFields.$key",
                        )
                    },
                )
            } else {
                VectorExpectedFields.Scalars(expectedFieldStrings)
            }

        val provenance = parseProvenance(root.requireObject("provenance", context), context)
        requireProvenanceMatches(provenance, capture, descriptor, manifest, context)

        return VectorEntry.Loaded(
            surface = descriptor.surface,
            messageType = descriptor.messageType,
            provenance = provenance,
            relativePath = descriptor.relativePath,
            rawBytes = rawBytes,
            expectedFields = expectedFields,
        )
    }

    private fun parseProvenance(root: JsonObject, documentContext: String): VectorProvenance {
        val context = "$documentContext.provenance"
        root.requireExactKeys(PROVENANCE_KEYS, context)
        return VectorProvenance(
            origin = root.requireString("origin", context),
            source = root.requireString("source", context),
            collectedAtUtc = root.requireString("collectedAtUtc", context),
            note = root.requireString("note", context),
            repoIdentity = root.requireString("repoIdentity", context),
            repositoryRemoteUrl = root.requireString("repositoryRemoteURL", context),
            captureToolPath = validateRepositoryPath(root.requireString("captureToolPath", context), context),
            semanticInputPath = validateRepositoryPath(root.requireString("semanticInputPath", context), context),
            semanticInputSha256 = root.requireLowerHex("semanticInputSha256", 32, context),
            sourcePath = validateRepositoryPath(root.requireString("sourcePath", context), context),
            sourceCommit = root.requireLowerHex("sourceCommit", 20, context),
            sourceSetSha256 = root.requireLowerHex("sourceSetSha256", 32, context),
        )
    }

    private fun requireProvenanceMatches(
        provenance: VectorProvenance,
        capture: AppleVectorCapture,
        descriptor: AppleVectorDescriptor,
        manifest: AppleVectorManifest,
        context: String,
    ) {
        val matches = provenance.origin == AppleVectorContract.ORIGIN &&
            provenance.source == AppleVectorContract.SOURCE &&
            provenance.collectedAtUtc == manifest.collectedAtUtc &&
            provenance.note.isNotBlank() &&
            provenance.repoIdentity == manifest.repoIdentity &&
            provenance.repositoryRemoteUrl == manifest.repositoryRemoteUrl &&
            provenance.captureToolPath == manifest.captureToolPath &&
            provenance.semanticInputPath == manifest.semanticInputPath &&
            provenance.semanticInputSha256 == manifest.semanticInputSha256 &&
            provenance.sourcePath == descriptor.sourcePath &&
            provenance.sourcePath == capture.sourcePath &&
            provenance.sourceCommit == manifest.sourceCommit &&
            provenance.sourceSetSha256 == manifest.sourceSetSha256
        if (!matches) {
            throw VectorSchemaException("$context provenance does not exactly match the pinned manifest")
        }
    }

    private fun readRegularFile(file: File, context: String, maxBytes: Int): ByteArray {
        val path = file.toPath()
        val before = Files.readAttributes(
            path,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        if (Files.isSymbolicLink(path) || !before.isRegularFile) {
            throw VectorSchemaException("$context is not a non-symbolic regular file")
        }
        val size = before.size()
        if (size !in 1L..maxBytes.toLong()) {
            throw VectorSchemaException("$context file size $size is outside 1..$maxBytes")
        }
        val storage = ByteArray(maxBytes + 1)
        val buffer = ByteBuffer.wrap(storage)
        Files.newByteChannel(
            path,
            setOf(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS),
        ).use { channel ->
            while (buffer.hasRemaining()) {
                val read = channel.read(buffer)
                if (read < 0) break
            }
        }
        val bytesRead = buffer.position()
        if (bytesRead !in 1..maxBytes) {
            throw VectorSchemaException("$context exceeded the bounded read limit of $maxBytes bytes")
        }
        val after = Files.readAttributes(
            path,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        val sameFile = before.fileKey()?.let { it == after.fileKey() }
            ?: (before.lastModifiedTime() == after.lastModifiedTime())
        if (!after.isRegularFile || after.size() != bytesRead.toLong() || !sameFile) {
            throw VectorSchemaException("$context changed while the corpus snapshot was being read")
        }
        return storage.copyOf(bytesRead)
    }

    private fun requireSha256(bytes: ByteArray, expected: String, context: String) {
        val actual = MessageDigest.getInstance("SHA-256").digest(bytes).toHexLower()
        if (actual != expected) {
            throw VectorSchemaException("$context SHA-256 mismatch: expected=$expected actual=$actual")
        }
    }

    private data class CorpusSnapshot(
        val manifest: AppleVectorManifest,
        val vectors: List<VectorEntry.Loaded>,
        val vectorsBySurface: Map<CodecSurface, List<VectorEntry.Loaded>>,
    )

    companion object {
        const val MIN_VECTORS_PER_SURFACE: Int = 5
        const val CORPUS_RELATIVE_PATH: String =
            "app/src/test/resources/apple-compatibility-vectors"

        private const val MANIFEST_FILE = "manifest.json"
        private const val README_FILE = "README.md"
        private const val MAX_MANIFEST_BYTES = 128 * 1024
        private const val MAX_README_BYTES = 64 * 1024
        private const val DOCUMENT_OVERHEAD_BYTES = 128 * 1024
        private const val INTEGRITY_PURPOSE =
            "SHA-256 values detect accidental capture corruption; they are not an authenticity claim"

        private val MANIFEST_KEYS = setOf(
            "schemaVersion",
            "fixtureSetId",
            "repoIdentity",
            "repositoryRemoteURL",
            "sourceCommit",
            "sourceSetSha256",
            "semanticInputPath",
            "semanticInputSha256",
            "captureToolPath",
            "collectedAtUtc",
            "integrityPurpose",
            "toolchain",
            "captures",
        )
        private val TOOLCHAIN_KEYS = setOf("swiftVersion", "xcodeVersion", "testExecutableSha256")
        private val CAPTURE_KEYS = setOf(
            "surface",
            "messageType",
            "relativePath",
            "sourcePath",
            "rawByteCount",
            "documentSha256",
        )
        private val DOCUMENT_KEYS = setOf(
            "schemaVersion",
            "surface",
            "messageType",
            "rawBytesHex",
            "expectedFields",
            "provenance",
        )
        private val PROVENANCE_KEYS = setOf(
            "origin",
            "source",
            "collectedAtUtc",
            "note",
            "repoIdentity",
            "repositoryRemoteURL",
            "captureToolPath",
            "semanticInputPath",
            "semanticInputSha256",
            "sourcePath",
            "sourceCommit",
            "sourceSetSha256",
        )

        fun locateCorpus(startDir: File = File(System.getProperty("user.dir") ?: ".")): File {
            var directory: File? = startDir.absoluteFile.normalize()
            while (directory != null) {
                val candidate = File(directory, CORPUS_RELATIVE_PATH)
                if (candidate.isDirectory) return candidate
                directory = directory.parentFile
            }
            throw MissingVectorException(
                "Unable to locate read-only Apple compatibility corpus '$CORPUS_RELATIVE_PATH' " +
                    "from ${startDir.absolutePath}",
            )
        }

        fun fromWorkspace(
            startDir: File = File(System.getProperty("user.dir") ?: "."),
        ): CompatibilityVectorLoader = CompatibilityVectorLoader(locateCorpus(startDir))

        /** Strict lower-case hex used by the capture schema. */
        fun decodeHex(hex: String, context: String = "<inline>"): ByteArray =
            decodeLowerHex(hex, Int.MAX_VALUE / 2, context)

        fun encodeHex(bytes: ByteArray): String = bytes.toHexLower()

        fun firstUnequalByteOffset(expected: ByteArray, actual: ByteArray): Int? {
            val commonLength = minOf(expected.size, actual.size)
            for (index in 0 until commonLength) {
                if (expected[index] != actual[index]) return index
            }
            return if (expected.size == actual.size) null else commonLength
        }

        fun describeByteMismatch(
            expected: ByteArray,
            actual: ByteArray,
            context: String = "",
        ): String? {
            val offset = firstUnequalByteOffset(expected, actual) ?: return null
            val prefix = if (context.isBlank()) "" else "$context: "
            val expectedAt = expected.getOrNull(offset)?.let(::byteHex) ?: "<out-of-bounds>"
            val actualAt = actual.getOrNull(offset)?.let(::byteHex) ?: "<out-of-bounds>"
            return "$prefix byte mismatch at offset $offset " +
                "(expected=$expectedAt actual=$actualAt; " +
                "expectedLength=${expected.size} actualLength=${actual.size})"
        }

        private fun byteHex(byte: Byte): String =
            ((byte.toInt() and 0xff) + 0x100).toString(16).substring(1)

        private fun maxDocumentBytes(surface: CodecSurface): Int {
            val max = surface.maxEncodedBytes.toLong() * 2L + DOCUMENT_OVERHEAD_BYTES
            return max.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }

        private fun validateRelativePath(value: String, context: String): String {
            validateRepositoryPath(value, context)
            if (value.count { it == '/' } != 1 || !value.endsWith(".json")) {
                throw VectorSchemaException("$context relativePath must be <surface>/<file>.json")
            }
            return value
        }

        private fun validateRepositoryPath(value: String, context: String): String {
            if (
                value.isBlank() ||
                value.startsWith('/') ||
                value.contains('\\') ||
                value.split('/').any { it.isBlank() || it == "." || it == ".." }
            ) {
                throw VectorSchemaException("$context contains an unsafe repository-relative path")
            }
            return value
        }

        private fun decodeLowerHex(hex: String, maxBytes: Int, context: String): ByteArray {
            val maxCharacters = maxBytes.toLong() * 2L
            if (hex.length.toLong() > maxCharacters) {
                throw VectorSchemaException("$context hex length exceeds the bounded surface limit")
            }
            if (hex.length % 2 != 0) {
                throw VectorSchemaException("$context must contain an even number of lower-case hex digits")
            }
            if (hex.any { it !in '0'..'9' && it !in 'a'..'f' }) {
                throw VectorSchemaException("$context must contain lower-case hex only")
            }
            return ByteArray(hex.length / 2) { index ->
                val high = hex[index * 2].digitToInt(16)
                val low = hex[index * 2 + 1].digitToInt(16)
                ((high shl 4) or low).toByte()
            }
        }
    }
}

data class SurfaceCoverage(
    val surface: CodecSurface,
    val totalEntries: Int,
    val appleCapturedCount: Int,
    val messageTypes: Set<String>,
    val satisfiesR91: Boolean,
)

class MissingVectorException(message: String) : AssertionError(message)

class VectorSchemaException(message: String, cause: Throwable? = null) :
    IllegalArgumentException(message, cause)

internal fun JsonObject.requireExactKeys(expected: Set<String>, context: String) {
    if (keys != expected) {
        throw VectorSchemaException("$context keys mismatch: expected=$expected actual=$keys")
    }
}

private fun JsonObject.requireString(key: String, context: String): String {
    val primitive = this[key] as? JsonPrimitive
        ?: throw VectorSchemaException("$context.$key must be a string")
    if (!primitive.isString) throw VectorSchemaException("$context.$key must be a string")
    return primitive.content
}

private fun JsonObject.requireInt(key: String, context: String): Int {
    val primitive = this[key] as? JsonPrimitive
        ?: throw VectorSchemaException("$context.$key must be an integer")
    if (primitive.isString) throw VectorSchemaException("$context.$key must be an integer")
    return primitive.intOrNull
        ?: throw VectorSchemaException("$context.$key must be an exactly representable integer")
}

private fun JsonObject.requireObject(key: String, context: String): JsonObject =
    this[key] as? JsonObject ?: throw VectorSchemaException("$context.$key must be an object")

private fun JsonObject.requireArray(key: String, context: String): JsonArray =
    this[key] as? JsonArray ?: throw VectorSchemaException("$context.$key must be an array")

private fun JsonObject.requireLowerHex(key: String, bytes: Int, context: String): String {
    val value = requireString(key, context)
    if (value.length != bytes * 2 || value.any { it !in '0'..'9' && it !in 'a'..'f' }) {
        throw VectorSchemaException("$context.$key must be exactly $bytes bytes of lower-case hex")
    }
    return value
}

/** Strict syntax pass used before kotlinx serialization can collapse duplicate object keys. */
internal object StrictVectorJson {
    private val json = Json {
        isLenient = false
        allowSpecialFloatingPointValues = false
    }

    fun parseObject(bytes: ByteArray, context: String, maxBytes: Int): JsonObject {
        if (bytes.size !in 1..maxBytes) {
            throw VectorSchemaException("$context JSON size ${bytes.size} is outside 1..$maxBytes")
        }
        val text = try {
            bytes.decodeToString(throwOnInvalidSequence = true)
        } catch (error: CharacterCodingException) {
            throw VectorSchemaException("$context is not valid UTF-8", error)
        }
        try {
            val scanner = Scanner(text)
            scanner.parseValue(depth = 0)
            scanner.skipWhitespace()
            if (!scanner.isAtEnd()) throw VectorSchemaException("$context has trailing JSON content")
        } catch (error: IllegalArgumentException) {
            if (error is VectorSchemaException) throw error
            throw VectorSchemaException("$context has invalid or duplicate-key JSON", error)
        }
        val element: JsonElement = try {
            json.parseToJsonElement(text)
        } catch (error: SerializationException) {
            throw VectorSchemaException("$context is not valid strict JSON", error)
        }
        return element as? JsonObject
            ?: throw VectorSchemaException("$context top-level JSON value must be an object")
    }

    private class Scanner(private val text: String) {
        private var index = 0

        fun isAtEnd(): Boolean = index == text.length

        fun skipWhitespace() {
            while (index < text.length && text[index] in JSON_WHITESPACE) index++
        }

        fun parseValue(depth: Int) {
            skipWhitespace()
            require(index < text.length) { "unexpected end of JSON" }
            when (text[index]) {
                '{' -> {
                    require(depth < MAX_NESTING_DEPTH) { "JSON nesting depth exceeds limit" }
                    parseObject(depth + 1)
                }
                '[' -> {
                    require(depth < MAX_NESTING_DEPTH) { "JSON nesting depth exceeds limit" }
                    parseArray(depth + 1)
                }
                '"' -> parseString()
                else -> parsePrimitive()
            }
        }

        private fun parseObject(depth: Int) {
            expect('{')
            skipWhitespace()
            if (consume('}')) return
            val keys = HashSet<String>()
            while (true) {
                skipWhitespace()
                require(index < text.length && text[index] == '"') { "object key must be a string" }
                val key = parseString()
                require(keys.add(key)) { "duplicate JSON object key" }
                skipWhitespace()
                expect(':')
                parseValue(depth)
                skipWhitespace()
                if (consume('}')) return
                expect(',')
            }
        }

        private fun parseArray(depth: Int) {
            expect('[')
            skipWhitespace()
            if (consume(']')) return
            while (true) {
                parseValue(depth)
                skipWhitespace()
                if (consume(']')) return
                expect(',')
            }
        }

        private fun parseString(): String {
            expect('"')
            val result = StringBuilder()
            while (index < text.length) {
                when (val character = text[index++]) {
                    '"' -> return result.toString()
                    '\\' -> appendEscape(result)
                    else -> {
                        require(character.code >= 0x20) { "unescaped control character" }
                        result.append(character)
                    }
                }
            }
            throw IllegalArgumentException("unterminated JSON string")
        }

        private fun appendEscape(result: StringBuilder) {
            require(index < text.length) { "unterminated JSON escape" }
            when (val escaped = text[index++]) {
                '"', '\\', '/' -> result.append(escaped)
                'b' -> result.append('\b')
                'f' -> result.append('\u000c')
                'n' -> result.append('\n')
                'r' -> result.append('\r')
                't' -> result.append('\t')
                'u' -> appendUnicodeEscape(result)
                else -> throw IllegalArgumentException("invalid JSON escape")
            }
        }

        private fun appendUnicodeEscape(result: StringBuilder) {
            val first = readUnicodeCodeUnit()
            when {
                first.isHighSurrogate() -> {
                    require(index + 2 <= text.length && text[index] == '\\' && text[index + 1] == 'u') {
                        "high surrogate is not followed by a low surrogate"
                    }
                    index += 2
                    val second = readUnicodeCodeUnit()
                    require(second.isLowSurrogate()) { "high surrogate is not followed by a low surrogate" }
                    result.append(first).append(second)
                }
                first.isLowSurrogate() -> throw IllegalArgumentException("unexpected low surrogate")
                else -> result.append(first)
            }
        }

        private fun readUnicodeCodeUnit(): Char {
            require(index + 4 <= text.length) { "truncated unicode escape" }
            val value = text.substring(index, index + 4).toIntOrNull(16)
                ?: throw IllegalArgumentException("invalid unicode escape")
            index += 4
            return value.toChar()
        }

        private fun parsePrimitive() {
            val start = index
            while (index < text.length && text[index] !in PRIMITIVE_DELIMITERS) index++
            require(index > start) { "invalid primitive" }
        }

        private fun expect(expected: Char) {
            require(index < text.length && text[index] == expected) { "expected '$expected'" }
            index++
        }

        private fun consume(expected: Char): Boolean {
            if (index >= text.length || text[index] != expected) return false
            index++
            return true
        }

        private companion object {
            const val MAX_NESTING_DEPTH = 16
            val JSON_WHITESPACE = setOf(' ', '\t', '\n', '\r')
            val PRIMITIVE_DELIMITERS = setOf(' ', '\t', '\n', '\r', ',', ']', '}')
        }
    }
}
