package com.skybridge.compass.android.logging

import java.security.MessageDigest

internal object SensitiveLogRedaction {
    fun identifier(raw: String?): String {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return "missing"
        return "present:length=${value.length}:sha256=${shortSha256(value)}"
    }

    private fun shortSha256(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.take(6).joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
