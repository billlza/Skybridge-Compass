package com.skybridge.compass.android.debug

import java.net.URI
import java.security.MessageDigest

internal object DebugSmokeRedaction {
    private val urlPattern = Regex("""\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+""")

    fun statusLine(line: String): String {
        val singleLine = buildString(minOf(line.length, MAX_STATUS_LINE_CHARS)) {
            for (character in line) {
                if (length == MAX_STATUS_LINE_CHARS) break
                append(
                    if (character.isUnsafeForSingleLineStatus()) {
                        REPLACEMENT_CHARACTER
                    } else {
                        character
                    }
                )
            }
        }
        return urlPattern
            .replace(singleLine) { match -> urlForArtifact(match.value) }
            .take(MAX_STATUS_LINE_CHARS)
    }

    fun urlForArtifact(raw: String?): String {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return "missing"
        return runCatching {
            val uri = URI(value)
            val scheme = uri.scheme?.takeIf { it.isNotBlank() } ?: return@runCatching sensitiveValue(value)
            val host = uri.host?.takeIf { it.isNotBlank() } ?: "host:${shortSha256(uri.rawAuthority ?: value)}"
            val port = uri.port.takeIf { it in 1..65535 }?.let { ":$it" }.orEmpty()
            val path = uri.rawPath?.takeIf { it.isNotBlank() }.orEmpty()
            val query = if (uri.rawQuery != null) "?<redacted>" else ""
            val fragment = if (uri.rawFragment != null) "#<redacted>" else ""
            "$scheme://$host$port$path$query$fragment"
        }.getOrElse {
            sensitiveValue(value)
        }
    }

    fun sensitiveValue(raw: String?): String {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return "missing"
        return "present:length=${value.length}:sha256=${shortSha256(value)}"
    }

    fun presence(raw: String?): String {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return "missing"
        return "present:length=${value.length}"
    }

    private fun shortSha256(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.take(6).joinToString(separator = "") { byte -> "%02x".format(byte) }
    }

    private fun Char.isUnsafeForSingleLineStatus(): Boolean {
        val type = Character.getType(this)
        return isISOControl() ||
            type == Character.FORMAT.toInt() ||
            type == Character.LINE_SEPARATOR.toInt() ||
            type == Character.PARAGRAPH_SEPARATOR.toInt()
    }

    private const val MAX_STATUS_LINE_CHARS = 2_048
    private const val REPLACEMENT_CHARACTER = '\uFFFD'
}
