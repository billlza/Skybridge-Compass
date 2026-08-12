plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt.android)
    alias(libs.plugins.kotlin.serialization)
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    alias(libs.plugins.kotlin.compose)
}

import com.android.build.api.variant.HasUnitTest
import com.android.build.api.artifact.SingleArtifact
import org.gradle.api.DefaultTask
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.TaskAction
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Properties
import java.util.Arrays
import java.util.jar.JarInputStream
import java.util.zip.ZipFile
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory

abstract class ValidateGoogleWebRtcArtifactTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val aarFile: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val patchedAarFile: RegularFileProperty

    @get:Input
    abstract val obsoleteShimPath: Property<String>

    @TaskAction
    fun validateArtifact() {
        val artifact = aarFile.get().asFile
        var originalManifestPackage: String? = null
        val requiredAbis = setOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
        ZipFile(artifact).use { aar ->
            val entryNames = aar.entries().asSequence().map { it.name }.toSet()
            val classesEntry = requireNotNull(aar.getEntry("classes.jar")) {
                "WebRTC AAR is missing classes.jar"
            }
            val classBytes = linkedMapOf<String, ByteArray>()
            JarInputStream(ByteArrayInputStream(aar.getInputStream(classesEntry).readBytes())).use { jar ->
                generateSequence { jar.nextJarEntry }
                    .filter { !it.isDirectory && it.name.endsWith(".class") }
                    .forEach { entry -> classBytes[entry.name] = jar.readBytes() }
            }
            val requiredClasses = setOf(
                "org/webrtc/Environment.class",
                "org/webrtc/PeerConnection.class",
                "org/webrtc/PeerConnectionFactory.class",
                "org/webrtc/DataChannel.class"
            )
            check(classBytes.keys.containsAll(requiredClasses)) {
                "WebRTC AAR is missing required Java runtime classes: ${requiredClasses - classBytes.keys}"
            }
            val generatedJniReference = Regex("org/webrtc/[A-Za-z0-9_\\$]+Jni")
            val unresolvedGeneratedJni = classBytes.values
                .flatMap { bytes ->
                    generatedJniReference.findAll(String(bytes, StandardCharsets.ISO_8859_1))
                        .map { "${it.value}.class" }
                        .toList()
                }
                .toSet()
                .filterNot(classBytes::containsKey)
            check(unresolvedGeneratedJni.isEmpty()) {
                "WebRTC AAR references missing generated JNI bridge classes: $unresolvedGeneratedJni"
            }
            val nativeSymbols = setOf(
                "Java_org_webrtc_Environment_nativeCreate",
                "Java_org_webrtc_Environment_nativeFree",
                "Java_org_webrtc_PeerConnectionFactory_nativeInitializeAndroidGlobals"
            )
            requiredAbis.forEach { abi ->
                val nativeEntry = requireNotNull(
                    aar.getEntry("jni/$abi/libjingle_peerconnection_so.so")
                ) { "WebRTC AAR is missing the $abi native library" }
                val nativeText = String(
                    aar.getInputStream(nativeEntry).readBytes(),
                    StandardCharsets.ISO_8859_1
                )
                check(nativeSymbols.all(nativeText::contains)) {
                    "WebRTC $abi native library is missing the required direct JNI surface"
                }
            }
            check(requiredAbis.all { abi ->
                "jni/$abi/libjingle_peerconnection_so.so" in entryNames
            }) { "WebRTC AAR ABI set is incomplete" }
            val originalManifest = requireNotNull(aar.getEntry("AndroidManifest.xml")) {
                "WebRTC AAR is missing AndroidManifest.xml"
            }
            originalManifestPackage = validateManifest(
                bytes = aar.getInputStream(originalManifest).readBytes(),
                expectedMinSdk = "21",
                expectedTargetSdk = "23",
                description = "original WebRTC AAR"
            )
        }
        ZipFile(patchedAarFile.get().asFile).use { aar ->
            val patchedManifest = requireNotNull(aar.getEntry("AndroidManifest.xml")) {
                "Patched WebRTC AAR is missing AndroidManifest.xml"
            }
            val patchedPackage = validateManifest(
                bytes = aar.getInputStream(patchedManifest).readBytes(),
                expectedMinSdk = "36",
                expectedTargetSdk = "37",
                description = "patched WebRTC AAR"
            )
            check(patchedPackage == originalManifestPackage) {
                "Patched WebRTC AAR must preserve the upstream manifest package: " +
                    "expected=$originalManifestPackage actual=$patchedPackage"
            }
        }
        verifyPatchedPayloadIsUnchanged(artifact, patchedAarFile.get().asFile)
        check(!File(obsoleteShimPath.get()).exists()) {
            "The replacement AAR owns org.webrtc.Environment; remove the obsolete local shim"
        }
    }

    private fun validateManifest(
        bytes: ByteArray,
        expectedMinSdk: String,
        expectedTargetSdk: String,
        description: String
    ): String {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            isXIncludeAware = false
            setExpandEntityReferences(false)
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
            setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "")
            setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "")
        }
        val document = factory.newDocumentBuilder().parse(ByteArrayInputStream(bytes))
        val root = document.documentElement
        check(root.tagName == "manifest") { "$description root element must be manifest" }
        val packageName = root.getAttribute("package")
        check(packageName == "org.webrtc") {
            "$description package must be org.webrtc, found $packageName"
        }
        val childElements = (0 until root.childNodes.length)
            .map(root.childNodes::item)
            .filter { it.nodeType == org.w3c.dom.Node.ELEMENT_NODE }
        check(childElements.size == 1 && childElements.single().nodeName == "uses-sdk") {
            "$description may contain only one uses-sdk element"
        }
        val usesSdk = childElements.single() as org.w3c.dom.Element
        val androidNamespace = "http://schemas.android.com/apk/res/android"
        check(usesSdk.getAttributeNS(androidNamespace, "minSdkVersion") == expectedMinSdk) {
            "$description minSdkVersion must be $expectedMinSdk"
        }
        check(usesSdk.getAttributeNS(androidNamespace, "targetSdkVersion") == expectedTargetSdk) {
            "$description targetSdkVersion must be $expectedTargetSdk"
        }
        check(usesSdk.attributes.length == 2) {
            "$description uses-sdk may contain only minSdkVersion and targetSdkVersion"
        }
        return packageName
    }

    private fun verifyPatchedPayloadIsUnchanged(originalFile: File, patchedFile: File) {
        ZipFile(originalFile).use { original ->
            ZipFile(patchedFile).use { patched ->
                val originalNames = original.entries().asSequence()
                    .filterNot { it.isDirectory || it.name == "AndroidManifest.xml" }
                    .map { it.name }
                    .toSet()
                val patchedNames = patched.entries().asSequence()
                    .filterNot { it.isDirectory || it.name == "AndroidManifest.xml" }
                    .map { it.name }
                    .toSet()
                check(patchedNames == originalNames) {
                    "Patched WebRTC AAR may differ only in AndroidManifest.xml"
                }
                originalNames.forEach { name ->
                    val originalEntry = requireNotNull(original.getEntry(name))
                    val patchedEntry = requireNotNull(patched.getEntry(name))
                    original.getInputStream(originalEntry).buffered().use { left ->
                        patched.getInputStream(patchedEntry).buffered().use { right ->
                            val leftBuffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            val rightBuffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val leftCount = left.read(leftBuffer)
                                val rightCount = right.read(rightBuffer)
                                check(leftCount == rightCount) {
                                    "Patched WebRTC AAR changed payload entry $name"
                                }
                                if (leftCount == -1) break
                                check(
                                    Arrays.equals(
                                        leftBuffer,
                                        0,
                                        leftCount,
                                        rightBuffer,
                                        0,
                                        rightCount
                                    )
                                ) { "Patched WebRTC AAR changed payload entry $name" }
                            }
                        }
                    }
                }
            }
        }
    }
}

abstract class VerifyReleaseArtifactConfigurationTask : DefaultTask() {
    @get:Input
    abstract val repositoryRootPath: Property<String>

    @TaskAction
    fun verifyArtifactConfiguration() {
        val localProperties = Properties().apply {
            val propertiesFile = File(repositoryRootPath.get(), "local.properties")
            if (propertiesFile.isFile) {
                propertiesFile.inputStream().use(::load)
            }
        }
        val supabaseUrl = localProperties.getProperty("SUPABASE_URL")
            ?: System.getenv("SUPABASE_URL")
        val supabaseAnonKey = localProperties.getProperty("SUPABASE_ANON_KEY")
            ?: System.getenv("SUPABASE_ANON_KEY")
        if (supabaseUrl.isNullOrBlank() || supabaseAnonKey.isNullOrBlank()) {
            throw GradleException(
                "Release artifact production requires SUPABASE_URL and SUPABASE_ANON_KEY " +
                    "in local.properties or environment",
            )
        }

        val values = linkedMapOf(
            "KEYSTORE_PATH" to System.getenv("KEYSTORE_PATH")?.trim().orEmpty(),
            "KEYSTORE_PASSWORD" to System.getenv("KEYSTORE_PASSWORD").orEmpty(),
            "KEY_ALIAS" to System.getenv("KEY_ALIAS")?.trim().orEmpty(),
            "KEY_PASSWORD" to System.getenv("KEY_PASSWORD").orEmpty(),
        )
        val missing = values.filterValues(String::isEmpty).keys
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Release packaging requires the complete signing credential set; missing: " +
                    missing.joinToString(", "),
            )
        }

        val configuredPath = File(values.getValue("KEYSTORE_PATH"))
        val keystoreFile = if (configuredPath.isAbsolute) {
            configuredPath
        } else {
            File(repositoryRootPath.get(), configuredPath.path)
        }
        if (!Files.isRegularFile(keystoreFile.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            throw GradleException(
                "KEYSTORE_PATH must name an existing non-symbolic-link regular file",
            )
        }

        val storePassword = values.getValue("KEYSTORE_PASSWORD").toCharArray()
        val keyPassword = values.getValue("KEY_PASSWORD").toCharArray()
        try {
            val keyStore = KeyStore.getInstance(keystoreFile, storePassword)
            val alias = values.getValue("KEY_ALIAS")
            if (!keyStore.isKeyEntry(alias)) {
                throw GradleException("KEY_ALIAS must identify a private-key entry in KEYSTORE_PATH")
            }
            val key = keyStore.getKey(alias, keyPassword)
            if (key !is PrivateKey) {
                throw GradleException("KEY_ALIAS must identify an unlockable private-key entry")
            }
            val certificateChain = keyStore.getCertificateChain(alias)
                ?.map { certificate -> certificate as? X509Certificate }
            if (certificateChain.isNullOrEmpty() || certificateChain.any { it == null }) {
                throw GradleException("KEY_ALIAS must include an X.509 signing certificate chain")
            }
            try {
                requireNotNull(certificateChain.first()).checkValidity()
            } catch (error: CertificateException) {
                throw GradleException("KEY_ALIAS signing certificate is not currently valid", error)
            }
        } catch (error: GradleException) {
            throw error
        } catch (error: Exception) {
            throw GradleException(
                "Release signing credentials could not unlock KEYSTORE_PATH and KEY_ALIAS",
                error,
            )
        } finally {
            Arrays.fill(storePassword, '\u0000')
            Arrays.fill(keyPassword, '\u0000')
        }
    }
}

abstract class GenerateReleaseSourceBindingTask : DefaultTask() {
    @get:Input
    abstract val repositoryRootPath: Property<String>

    @get:org.gradle.api.tasks.OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generateSourceBinding() {
        val root = File(repositoryRootPath.get()).canonicalFile
        val gitDirectory = File(root, ".git")
        if (!gitDirectory.exists()) {
            throw GradleException("Release source binding requires the canonical Git worktree root")
        }
        val head = project.providers.exec {
            commandLine("git", "-C", root.absolutePath, "rev-parse", "--verify", "HEAD")
        }.standardOutput.asText.get().trim()
        val status = project.providers.exec {
            commandLine(
                "git", "-C", root.absolutePath, "status", "--porcelain", "--untracked-files=all",
            )
        }.standardOutput.asText.get()
        if (status.isNotBlank()) {
            throw GradleException("Release artifact production requires a clean canonical Git worktree")
        }
        val binding = outputDirectory.file("skybridge-release/source.properties").get().asFile
        binding.parentFile.mkdirs()
        binding.writeText(
            "repository=skybridge-compass\ncommit=$head\n",
            StandardCharsets.UTF_8,
        )
    }
}

abstract class GenerateReleaseApkAuditMetadataTask : DefaultTask() {
    @get:Input
    abstract val repositoryRootPath: Property<String>

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val apkDirectory: DirectoryProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val mappingFile: RegularFileProperty

    @get:OutputFile
    abstract val metadataFile: RegularFileProperty

    @TaskAction
    fun generateAuditMetadata() {
        val apks = apkDirectory.get().asFile
            .walkTopDown()
            .filter { file -> file.isFile && file.extension == "apk" }
            .toList()
        check(apks.size == 1) {
            "Expected exactly one release APK for audit metadata, found ${apks.map(File::getName)}"
        }
        val mapping = mappingFile.get().asFile
        check(mapping.isFile) { "Release R8 mapping is missing" }
        val repositoryRoot = File(repositoryRootPath.get()).canonicalFile
        val head = project.providers.exec {
            commandLine("git", "-C", repositoryRoot.absolutePath, "rev-parse", "--verify", "HEAD")
        }.standardOutput.asText.get().trim()
        val status = project.providers.exec {
            commandLine(
                "git", "-C", repositoryRoot.absolutePath,
                "status", "--porcelain", "--untracked-files=all",
            )
        }.standardOutput.asText.get()
        check(status.isBlank()) {
            "Release source changed while the APK was being built"
        }
        val packagedBinding = ZipFile(apks.single()).use { apk ->
            val entry = requireNotNull(apk.getEntry("assets/skybridge-release/source.properties")) {
                "Release APK is missing its source binding"
            }
            apk.getInputStream(entry).bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
        }
        val packagedCommit = packagedBinding
            .lineSequence()
            .singleOrNull { line -> line.startsWith("commit=") }
            ?.substringAfter("commit=")
        check(packagedCommit == head) {
            "Release APK source binding changed during artifact production"
        }
        val output = metadataFile.get().asFile
        output.parentFile.mkdirs()
        output.writeText(
            buildString {
                append("format=skybridge-release-apk-audit-v1\n")
                append("apk.sha256=")
                append(sha256(apks.single()))
                append('\n')
                append("mapping.sha256=")
                append(sha256(mapping))
                append('\n')
                append("source.commit=")
                append(head)
                append('\n')
            },
            StandardCharsets.UTF_8,
        )
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}

abstract class GenerateReleaseAabAuditMetadataTask : DefaultTask() {
    @get:Input
    abstract val repositoryRootPath: Property<String>

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val aabFile: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val mappingFile: RegularFileProperty

    @get:OutputFile
    abstract val metadataFile: RegularFileProperty

    @TaskAction
    fun generateAuditMetadata() {
        val aab = aabFile.get().asFile
        check(aab.isFile && aab.extension == "aab") { "Release AAB is missing" }
        val mapping = mappingFile.get().asFile
        check(mapping.isFile && mapping.length() > 0L) { "Release R8 mapping is missing or empty" }
        val repositoryRoot = File(repositoryRootPath.get()).canonicalFile
        val head = project.providers.exec {
            commandLine("git", "-C", repositoryRoot.absolutePath, "rev-parse", "--verify", "HEAD")
        }.standardOutput.asText.get().trim()
        val status = project.providers.exec {
            commandLine(
                "git", "-C", repositoryRoot.absolutePath,
                "status", "--porcelain", "--untracked-files=all",
            )
        }.standardOutput.asText.get()
        check(status.isBlank()) {
            "Release source changed while the AAB was being built"
        }
        val packagedBinding = ZipFile(aab).use { bundle ->
            val bindingEntries = bundle.entries().asSequence()
                .filter { entry ->
                    !entry.isDirectory &&
                        entry.name == "base/assets/skybridge-release/source.properties"
                }
                .toList()
            check(bindingEntries.size == 1) {
                "Release AAB must contain exactly one base source binding"
            }
            bundle.getInputStream(bindingEntries.single())
                .bufferedReader(StandardCharsets.UTF_8)
                .use { it.readText() }
        }
        val bindingFields = linkedMapOf<String, String>()
        packagedBinding
            .lineSequence()
            .filter(String::isNotBlank)
            .forEach { line ->
                val separator = line.indexOf('=')
                check(separator > 0) { "Release AAB source binding is malformed" }
                val key = line.substring(0, separator)
                check(key !in bindingFields) {
                    "Release AAB source binding contains a duplicate field"
                }
                bindingFields[key] = line.substring(separator + 1)
            }
        check(bindingFields.keys == setOf("repository", "commit")) {
            "Release AAB source binding has unexpected or duplicate fields"
        }
        check(bindingFields.getValue("repository") == "skybridge-compass") {
            "Release AAB source binding repository is invalid"
        }
        check(bindingFields.getValue("commit") == head) {
            "Release AAB source binding changed during artifact production"
        }
        val output = metadataFile.get().asFile
        output.parentFile.mkdirs()
        output.writeText(
            buildString {
                append("format=skybridge-release-aab-audit-v1\n")
                append("aab.sha256=")
                append(sha256(aab))
                append('\n')
                append("mapping.sha256=")
                append(sha256(mapping))
                append('\n')
                append("source.commit=")
                append(head)
                append('\n')
            },
            StandardCharsets.UTF_8,
        )
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}

// 加载 Supabase 配置（优先 local.properties，其次环境变量）。
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) {
        f.inputStream().use { input -> load(input) }
    }
}
val SUPABASE_URL_PROP: String? = localProps.getProperty("SUPABASE_URL") ?: System.getenv("SUPABASE_URL")
val SUPABASE_ANON_KEY_PROP: String? = localProps.getProperty("SUPABASE_ANON_KEY") ?: System.getenv("SUPABASE_ANON_KEY")
val GOOGLE_WEB_CLIENT_ID_PROP: String? = localProps.getProperty("GOOGLE_WEB_CLIENT_ID") ?: System.getenv("GOOGLE_WEB_CLIENT_ID")
// Nebula OAuth 2.1 public-client (PKCE) config — mirrors iOS NEBULA_BASE_URL / NEBULA_CLIENT_ID.
// NEBULA_CLIENT_SECRET is optional for native public clients (kept for parity; not required by PKCE).
val NEBULA_BASE_URL_PROP: String? = localProps.getProperty("NEBULA_BASE_URL") ?: System.getenv("NEBULA_BASE_URL")
val NEBULA_CLIENT_ID_PROP: String? = localProps.getProperty("NEBULA_CLIENT_ID") ?: System.getenv("NEBULA_CLIENT_ID")

// 规范最终值，避免在 buildTypes 内写复杂内插和转义
val SUPABASE_URL_FINAL = SUPABASE_URL_PROP?.trim().orEmpty()
val SUPABASE_ANON_KEY_FINAL = SUPABASE_ANON_KEY_PROP?.trim().orEmpty()
val GOOGLE_WEB_CLIENT_ID_FINAL = GOOGLE_WEB_CLIENT_ID_PROP ?: ""
val NEBULA_BASE_URL_FINAL = NEBULA_BASE_URL_PROP ?: ""
val NEBULA_CLIENT_ID_FINAL = NEBULA_CLIENT_ID_PROP ?: ""

val RELEASE_KEYSTORE_PATH = System.getenv("KEYSTORE_PATH")?.trim().orEmpty()
val RELEASE_KEYSTORE_PASSWORD = System.getenv("KEYSTORE_PASSWORD").orEmpty()
val RELEASE_KEY_ALIAS = System.getenv("KEY_ALIAS")?.trim().orEmpty()
val RELEASE_KEY_PASSWORD = System.getenv("KEY_PASSWORD").orEmpty()
val releaseSigningValuesPresent = listOf(
    RELEASE_KEYSTORE_PATH,
    RELEASE_KEYSTORE_PASSWORD,
    RELEASE_KEY_ALIAS,
    RELEASE_KEY_PASSWORD
).all(String::isNotEmpty)
android {
    namespace = "com.skybridge.compass"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.skybridge.compass"
        minSdk = 36
        targetSdk = 37
        versionCode = 2
        versionName = "1.0.2"

        testInstrumentationRunner = "com.skybridge.compass.android.HiltTestRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    val productionReleaseSigning = signingConfigs.create("productionRelease") {
        storeFile = if (releaseSigningValuesPresent) {
            rootProject.file(RELEASE_KEYSTORE_PATH)
        } else {
            layout.buildDirectory.file("missing-release-signing-keystore").get().asFile
        }
        storePassword = RELEASE_KEYSTORE_PASSWORD.ifEmpty { "missing" }
        keyAlias = RELEASE_KEY_ALIAS.ifEmpty { "missing" }
        keyPassword = RELEASE_KEY_PASSWORD.ifEmpty { "missing" }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            // Emulator默认连接宿主机：10.0.2.2
            buildConfigField("String", "API_BASE_URL", "\"http://10.0.2.2:8080/api/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "true")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "true")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            buildConfigField("String", "NEBULA_BASE_URL", "\"${NEBULA_BASE_URL_FINAL}\"")
            buildConfigField("String", "NEBULA_CLIENT_ID", "\"${NEBULA_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = false
            isDebuggable = true
        }
        
        release {
            signingConfig = productionReleaseSigning
            buildConfigField("String", "API_BASE_URL", "\"https://api.skybridge.com/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "false")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "false")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            buildConfigField("String", "NEBULA_BASE_URL", "\"${NEBULA_BASE_URL_FINAL}\"")
            buildConfigField("String", "NEBULA_CLIENT_ID", "\"${NEBULA_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        
        create("staging") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            buildConfigField("String", "API_BASE_URL", "\"https://staging-api.skybridge.com/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "true")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "true")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            buildConfigField("String", "NEBULA_BASE_URL", "\"${NEBULA_BASE_URL_FINAL}\"")
            buildConfigField("String", "NEBULA_CLIENT_ID", "\"${NEBULA_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = false
            isDebuggable = true
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }

    // 使用 Kotlin Compose 插件后不再需要 legacy 的 composeOptions
    // composeOptions {
    //     kotlinCompilerExtensionVersion = "1.5.13"
    // }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests.all {
            it.useJUnitPlatform()
        }
    }
}

// The JVM audit tests consume this workspace corpus directly. Declare it as an exact task input
// so corpus-only changes invalidate Gradle's up-to-date and build-cache decisions.
val appleCompatibilityVectorCorpus =
    rootProject.layout.projectDirectory.dir("app/src/test/resources/apple-compatibility-vectors")
androidComponents {
    onVariants(selector().all()) { variant ->
        val unitTest = (variant as HasUnitTest).unitTest ?: return@onVariants
        unitTest.configureTestTask { testTask ->
            testTask.inputs
                .dir(appleCompatibilityVectorCorpus)
                .withPropertyName("appleCompatibilityVectorCorpus")
                .withPathSensitivity(PathSensitivity.RELATIVE)
        }
    }
}

val verifyReleaseArtifactConfiguration = tasks.register<VerifyReleaseArtifactConfigurationTask>(
    "verifyReleaseArtifactConfiguration",
) {
    group = "verification"
    description = "Fail release artifact production unless runtime config and production signing are usable."
    repositoryRootPath.set(rootProject.layout.projectDirectory.asFile.absolutePath)
}
val generateReleaseSourceBinding = tasks.register<GenerateReleaseSourceBindingTask>(
    "generateReleaseSourceBinding",
) {
    group = "build setup"
    description = "Generate the clean Git commit binding packaged in release artifacts."
    repositoryRootPath.set(rootProject.layout.projectDirectory.dir("../..").asFile.canonicalPath)
    outputDirectory.set(layout.buildDirectory.dir("generated/releaseSourceBinding/assets"))
    dependsOn(verifyReleaseArtifactConfiguration)
    doNotTrackState("Release source binding must re-read HEAD and worktree cleanliness every build")
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            generateReleaseSourceBinding,
            { task -> task.outputDirectory },
        )
        // Public variant task names are derived from the realized release variant, not from the
        // command line. Consequently fully-qualified, aggregate and abbreviated Gradle entry
        // points all converge on the same guarded artifact-producing tasks.
        val releaseTaskSuffix = variant.name.replaceFirstChar { first -> first.uppercase() }
        val generateApkAuditMetadata = tasks.register<GenerateReleaseApkAuditMetadataTask>(
            "generate${releaseTaskSuffix}ApkAuditMetadata",
        ) {
            group = "verification"
            description = "Bind the release APK and its R8 mapping for formal inspection."
            repositoryRootPath.set(rootProject.layout.projectDirectory.dir("../..").asFile.canonicalPath)
            apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            mappingFile.set(variant.artifacts.get(SingleArtifact.OBFUSCATION_MAPPING_FILE))
            metadataFile.set(
                layout.buildDirectory.file("outputs/release-audit/${variant.name}/metadata.properties"),
            )
        }
        val generateAabAuditMetadata = tasks.register<GenerateReleaseAabAuditMetadataTask>(
            "generate${releaseTaskSuffix}AabAuditMetadata",
        ) {
            group = "verification"
            description = "Bind the signed release AAB and its R8 mapping for formal inspection."
            repositoryRootPath.set(rootProject.layout.projectDirectory.dir("../..").asFile.canonicalPath)
            aabFile.set(variant.artifacts.get(SingleArtifact.BUNDLE))
            mappingFile.set(variant.artifacts.get(SingleArtifact.OBFUSCATION_MAPPING_FILE))
            metadataFile.set(
                layout.buildDirectory.file("outputs/release-audit/${variant.name}/aab-metadata.properties"),
            )
            doNotTrackState(
                "Release AAB audit metadata must re-read HEAD and worktree cleanliness",
            )
        }
        val guardedTaskNames = setOf(
            "package$releaseTaskSuffix",
            "package${releaseTaskSuffix}Bundle",
            "package${releaseTaskSuffix}UniversalApk",
            "bundle$releaseTaskSuffix",
            "sign${releaseTaskSuffix}Bundle",
            "makeApkFromBundleFor$releaseTaskSuffix",
            "zipApksFor$releaseTaskSuffix",
            "extractApksFor$releaseTaskSuffix",
            "extractApksFromBundleFor$releaseTaskSuffix",
            "install$releaseTaskSuffix",
            "validateSigning$releaseTaskSuffix",
        )
        tasks.configureEach {
            if (name in guardedTaskNames) {
                dependsOn(verifyReleaseArtifactConfiguration)
                dependsOn(generateReleaseSourceBinding)
            }
            if (name == "assemble$releaseTaskSuffix") {
                dependsOn(generateApkAuditMetadata)
            }
            if (name == "bundle$releaseTaskSuffix") {
                finalizedBy(generateAabAuditMetadata)
            }
        }
        variant.lifecycleTasks.registerPreInstallation(verifyReleaseArtifactConfiguration)
    }
}

val googleWebRtcVersion = libs.google.webrtc.get().versionConstraint.strictVersion
check(googleWebRtcVersion.isNotBlank()) {
    "WebRTC must declare an exact strict version because its Java/JNI artifacts are coupled"
}
val googleWebRtcOriginalAar = configurations.create("googleWebRtcOriginalAar") {
    isCanBeConsumed = false
    isCanBeResolved = true
    isTransitive = false
}
val googleWebRtcOriginalAarFile = googleWebRtcOriginalAar.incoming.artifactView { }.files.elements.map { elements ->
    check(elements.size == 1) { "Expected exactly one WebRTC AAR, found ${elements.size}" }
    elements.single().asFile
}

val patchGoogleWebRtcAar = tasks.register<org.gradle.api.tasks.bundling.Zip>("patchGoogleWebRtcAar") {
    group = "build setup"
    description = "Repackage the audited WebRTC AAR with explicit Android SDK metadata; binaries are unchanged."
    archiveFileName.set("webrtc-sdk-$googleWebRtcVersion-targetSdk37.aar")
    destinationDirectory.set(layout.buildDirectory.dir("patched-aar"))
    duplicatesStrategy = org.gradle.api.file.DuplicatesStrategy.FAIL
    inputs.file(googleWebRtcOriginalAarFile)
    inputs.file(layout.projectDirectory.file("src/patchedGoogleWebRtc/AndroidManifest.xml"))

    from(googleWebRtcOriginalAarFile.map { zipTree(it) }) {
        exclude("AndroidManifest.xml")
    }
    from(layout.projectDirectory.file("src/patchedGoogleWebRtc/AndroidManifest.xml")) {
        rename { "AndroidManifest.xml" }
    }
}

val patchedGoogleWebRtcAar = files(patchGoogleWebRtcAar.flatMap { it.archiveFile })
patchedGoogleWebRtcAar.builtBy(patchGoogleWebRtcAar)

val obsoleteWebRtcEnvironmentShimPath =
    rootProject.layout.projectDirectory
        .file("core/src/main/kotlin/org/webrtc/Environment.kt")
        .asFile
        .absolutePath
val validateGoogleWebRtcArtifact = tasks.register<ValidateGoogleWebRtcArtifactTask>(
    "validateGoogleWebRtcArtifact"
) {
    group = "verification"
    description = "Verify the pinned WebRTC AAR is Java/JNI complete for every packaged ABI."
    aarFile.set(layout.file(googleWebRtcOriginalAarFile))
    patchedAarFile.set(patchGoogleWebRtcAar.flatMap { it.archiveFile })
    obsoleteShimPath.set(obsoleteWebRtcEnvironmentShimPath)
}

tasks.named("preBuild").configure {
    dependsOn(validateGoogleWebRtcArtifact)
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)
    implementation(platform(libs.kotlin.bom))
    implementation(project.dependencies.project(":core"))
    implementation(project.dependencies.project(":device-discovery"))
    implementation(project.dependencies.project(":file-transfer"))
    implementation(project.dependencies.project(":shared"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.profileinstaller)
    
    // Compose BOM
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    // Add missing Compose integrations
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.fragment.ktx)
    // Avatar loading
    implementation(libs.coil.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    // ProcessLifecycleOwner: scopes the real-time weather auto-refresh to the foreground.
    implementation(libs.androidx.lifecycle.process)
    
    // Hilt
    implementation(libs.hilt.android)
    implementation(libs.androidx.hilt.navigation.compose)
    ksp(libs.hilt.compiler)
    
    // Network
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.gson)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging.interceptor)
    
    // Ktor
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.client.logging)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.serialization.kotlinx.json)
    
    // Supabase-kt BOM + modules
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.kt)
    implementation(libs.supabase.auth.kt)
    implementation(libs.supabase.postgrest.kt)
    implementation(libs.supabase.storage.kt)
    implementation(libs.supabase.realtime.kt)
    
    // Serialization
    implementation(libs.kotlinx.serialization.json)

    // Coroutines
    implementation(libs.kotlinx.coroutines.android)

    // WorkManager
    implementation(libs.androidx.work.runtime.ktx)

    // Room (needed due to AppDatabase type usage from core)
    implementation(libs.androidx.room.ktx)

    add(googleWebRtcOriginalAar.name, "io.github.webrtc-sdk:android:$googleWebRtcVersion@aar")
    implementation(patchedGoogleWebRtcAar)

    // Security (EncryptedSharedPreferences for secure account storage)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.biometric)
    implementation(libs.play.services.auth)

    // Testing
    testImplementation(libs.junit4)
    testImplementation(libs.junit.jupiter.api)
    testRuntimeOnly(libs.junit.jupiter.engine)
    testRuntimeOnly(libs.junit.vintage.engine)
    testRuntimeOnly(libs.junit.platform.launcher)
    // Kotest（property-based testing）：审计工具代码的属性测试（任务 5.5–5.8，Property 49–52）
    // 位于 `:app` 的 test 源集，与 `:shared` 既有 PBT 使用同一套 runner/assertions/property。
    testImplementation(libs.bundles.kotest)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.mockk)
    testRuntimeOnly(libs.slf4j.nop)
    testImplementation(libs.ktor.client.mock)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.navigation.testing)
    androidTestImplementation(libs.hilt.android.testing)
    kspAndroidTest(libs.hilt.compiler)
    
    // Debug Tools
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    // DataStore Preferences for persistent developer settings
    implementation(libs.androidx.datastore.preferences)
}

tasks.register("locateDebugArtifacts") {
    group = "verification"
    description = "Print expected paths of debug APK/AAB and existence"
    doLast {
        val apkDir = layout.buildDirectory.dir("outputs/apk/debug").get().asFile
        val aabDir = layout.buildDirectory.dir("outputs/bundle/debug").get().asFile
        println("APK Debug Dir: ${apkDir.absolutePath}, exists=${apkDir.exists()}")
        println("AAB Debug Dir: ${aabDir.absolutePath}, exists=${aabDir.exists()}")
    }
}

val checkLauncherIcons = tasks.register<Exec>("checkLauncherIcons") {
    group = "verification"
    description = "Verify Android launcher icons are derived from the canonical SkyBridge SVG design source."
    workingDir = rootProject.projectDir
    environment("PYTHONDONTWRITEBYTECODE", "1")
    commandLine("python3", "scripts/generate_android_launcher_icons.py", "--check")
}

tasks.named("check") {
    dependsOn(checkLauncherIcons)
}

tasks.named("preBuild") {
    dependsOn(checkLauncherIcons)
}

// Attach output logging to key packaging tasks
tasks.register("printTaskOutputs") {
    group = "verification"
    description = "Print outputs.files of key packaging tasks"
    doLast {
        listOf(
            "packageDebug",
            "packageDebugUniversalApk",
            "bundleDebug",
            "signDebugBundle",
            "makeApkFromBundleForDebug",
            "zipApksForDebug"
        ).forEach { name ->
            val t = tasks.findByName(name)
            val outputsList = t?.outputs?.files?.files?.map { it.absolutePath } ?: emptyList()
            println("[$name] outputs.files: ${outputsList}")
        }
    }
}
