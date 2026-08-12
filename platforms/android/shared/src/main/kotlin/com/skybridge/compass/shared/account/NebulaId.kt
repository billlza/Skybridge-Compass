package com.skybridge.compass.shared.account

@JvmInline
value class NebulaId private constructor(val value: String) {
    companion object {
        private const val PREFIX = "NEBULA"
        private const val SEPARATOR = "-"
        private const val TOKEN_LENGTH = 12

        fun parseOrNull(raw: String?): NebulaId? {
            val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val components = value.split(SEPARATOR)
            if (components.size != 3 ||
                components[0] != PREFIX ||
                components[1].length != 4 ||
                components[2].length != TOKEN_LENGTH) {
                return null
            }
            if (!components[1].all { it in '0'..'9' }) return null
            if (!components[2].all { it in '0'..'9' || it in 'A'..'Z' }) return null
            if (components[2].toULongOrNull(36) == null) return null
            return NebulaId(value)
        }

        fun isValid(raw: String): Boolean = parseOrNull(raw) != null
    }
}
