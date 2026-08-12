package com.skybridge.compass.android.webrtc

import android.content.Context
import com.skybridge.compass.core.webrtc.LocalPeerBusinessIdentity
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.SignalServerClient
import com.skybridge.compass.shared.account.NebulaId
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import org.json.JSONObject
import java.io.File

internal data class SmokeSuiteExpectation(
    val expectedSuite: P2PCryptoSuite?
) {
    val expectsExactSuite: Boolean get() = expectedSuite != null
    val expectsQPeriapt: Boolean get() = expectedSuite == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND

    fun sessionMatches(manager: SkyBridgeWebRtcConnectionManager): Boolean {
        val expected = expectedSuite
        return if (expected != null) {
            manager.negotiatedSuiteWireId() == expected.wireId.toInt()
        } else {
            manager.hasPqcSessionKeys()
        }
    }

    fun bootstrapMatches(manager: SkyBridgeWebRtcConnectionManager, pqcEnabled: Boolean): Boolean =
        when {
            !pqcEnabled -> true
            expectsQPeriapt -> manager.hasBootstrappedPeerQPeriaptForCurrentPeer()
            else -> manager.hasBootstrappedPeerKemForCurrentPeer()
        }

    fun describeExpected(): String =
        expectedSuite?.name ?: "any-pqc"

    companion object {
        fun fromArgs(
            pqcMinimumTier: String,
            expectedNegotiatedSuiteRaw: String?,
            expectQPeriaptRaw: String?
        ): SmokeSuiteExpectation {
            val expectQPeriapt = expectQPeriaptRaw
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.toBooleanStrict()
                ?: (pqcMinimumTier == P2PQPeriaptKem.MINIMUM_TIER_RAW)
            val expectedRaw = expectedNegotiatedSuiteRaw
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: if (expectQPeriapt) P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.name else null
            return SmokeSuiteExpectation(expectedRaw?.let(::parseSuite))
        }

        private fun parseSuite(raw: String): P2PCryptoSuite {
            P2PCryptoSuite.entries.firstOrNull { it.name == raw }?.let { return it }
            val wireId = parseWireId(raw)
            if (wireId != null) {
                require(wireId in 0..UShort.MAX_VALUE.toInt()) {
                    "Expected P2P suite wire id out of range: $raw"
                }
                return P2PCryptoSuite.fromWireId(wireId.toUShort())
                    ?: throw IllegalArgumentException("Unknown expected P2P suite wire id: $raw")
            }
            throw IllegalArgumentException("Unknown expected P2P suite: $raw")
        }

        private fun parseWireId(raw: String): Int? {
            val trimmed = raw.trim()
            return if (trimmed.startsWith("0x", ignoreCase = true)) {
                trimmed.drop(2).toIntOrNull(radix = 16)
            } else {
                trimmed.toIntOrNull()
            }
        }
    }
}

internal fun SkyBridgeWebRtcConnectionManager.actualSuiteDescription(): String {
    val name = negotiatedSuiteName() ?: "-"
    val wireId = negotiatedSuiteWireId()?.let { "0x" + it.toString(radix = 16).padStart(4, '0') } ?: "-"
    return "$name/$wireId"
}

internal fun String?.strictBooleanInstrumentationArg(
    argName: String,
    defaultValue: Boolean
): Boolean =
    this
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { value ->
            try {
                value.toBooleanStrict()
            } catch (error: IllegalArgumentException) {
                throw IllegalArgumentException(
                    "Invalid boolean instrumentation arg $argName: $value (expected true|false)",
                    error
                )
            }
        }
        ?: defaultValue

internal fun readSmokeAuthContext(
    context: Context,
    authContextFileName: String?
): SignalServerClient.UserAuthContext? =
    readSmokeAuthBundle(context, authContextFileName)?.userAuthContext

internal data class SmokeAuthBundle(
    val userAuthContext: SignalServerClient.UserAuthContext,
    val localBusinessIdentity: LocalPeerBusinessIdentity?
)

internal fun readSmokeAuthBundle(
    context: Context,
    authContextFileName: String?
): SmokeAuthBundle? {
    val fileName = authContextFileName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: return null
    require(!fileName.contains('/') && !fileName.contains('\\')) {
        "Auth context file name must not contain path separators"
    }
    val file = File(context.filesDir, fileName)
    require(file.isFile) { "Auth context file missing: $fileName" }
    return try {
        val payload = JSONObject(file.readText())
        val bearerToken = payload.getString("bearerToken").trim()
        val tenantId = payload.getString("tenantId").trim()
        require(bearerToken.isNotEmpty()) { "Auth context bearer token is empty" }
        require(tenantId.isNotEmpty()) { "Auth context tenant id is empty" }
        val accountDisplayName = payload.optString("accountDisplayName")
            .trim()
            .takeIf { it.isNotEmpty() }
        val nebulaId = payload.optString("nebulaId")
            .trim()
            .takeIf { it.isNotEmpty() }
        val localBusinessIdentity = nebulaId
            ?.let { NebulaId.parseOrNull(it)?.value }
            ?.let { canonicalNebulaId ->
                LocalPeerBusinessIdentity(
                    accountDisplayName = accountDisplayName,
                    nebulaId = canonicalNebulaId
                ).normalizedOrNull()
            }
        SmokeAuthBundle(
            userAuthContext = SignalServerClient.UserAuthContext(
                bearerToken = bearerToken,
                tenantId = tenantId
            ),
            localBusinessIdentity = localBusinessIdentity
        )
    } finally {
        file.delete()
    }
}

internal fun readSmokePrivateTextFile(
    context: Context,
    fileName: String?,
    label: String
): String {
    val safeFileName = fileName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: throw IllegalArgumentException("$label file name is missing")
    require(!safeFileName.contains('/') && !safeFileName.contains('\\')) {
        "$label file name must not contain path separators"
    }
    val file = File(context.filesDir, safeFileName)
    require(file.isFile) { "$label file missing: $safeFileName" }
    return try {
        file.readText().trim().also {
            require(it.isNotEmpty()) { "$label file is empty" }
        }
    } finally {
        file.delete()
    }
}

internal fun writeSmokePrivateTextFile(
    context: Context,
    fileName: String?,
    contents: String,
    label: String
) {
    val safeFileName = fileName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: throw IllegalArgumentException("$label file name is missing")
    require(!safeFileName.contains('/') && !safeFileName.contains('\\')) {
        "$label file name must not contain path separators"
    }
    require(contents.isNotBlank()) { "$label contents must not be blank" }
    File(context.filesDir, safeFileName).writeText(contents)
}
