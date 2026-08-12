package com.skybridge.compass.auth

import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

object SupabaseJwtClaims {
    fun subjectOrNull(json: Json, jwt: String): String? {
        return payloadObjectOrNull(json, jwt)?.stringOrNull("sub")
    }

    fun tenantIdentifierOrNull(json: Json, jwt: String): String? {
        val payload = payloadObjectOrNull(json, jwt) ?: return null
        val appMetadata = payload.objectOrNull("app_metadata")
        return listOf(
            appMetadata?.stringOrNull("tenant_id"),
            appMetadata?.stringOrNull("tenantId"),
            appMetadata?.stringOrNull("org_id"),
            appMetadata?.stringOrNull("workspace_id"),
            payload.stringOrNull("tenant_id"),
            payload.stringOrNull("tenantId"),
            payload.stringOrNull("sub")
        ).firstOrNull { !it.isNullOrBlank() }?.trim()
    }

    private fun payloadObjectOrNull(json: Json, jwt: String): JsonObject? {
        val payloadPart = jwt.split('.').getOrNull(1) ?: return null
        val padded = payloadPart.padEnd(((payloadPart.length + 3) / 4) * 4, '=')
        val bytes = runCatching { Base64.getUrlDecoder().decode(padded) }.getOrNull() ?: return null
        val text = String(bytes, Charsets.UTF_8)
        return runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
    }

    private fun JsonObject.stringOrNull(key: String): String? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        return primitive.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun JsonObject.objectOrNull(key: String): JsonObject? =
        runCatching { this[key]?.jsonObject }.getOrNull()
}
