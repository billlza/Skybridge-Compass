package com.skybridge.compass.core.p2p

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Shared strict boundary for unauthenticated externally-tagged JSON protocol frames. */
internal object StrictJsonWire {
    data class EnvelopeCase(
        val name: String,
        val payload: JsonElement
    )

    fun validatedUtf8(bytes: ByteArray): String {
        val text = bytes.decodeToString(throwOnInvalidSequence = true)
        val scanner = Scanner(text)
        scanner.parseValue(depth = 0)
        scanner.skipWhitespace()
        require(scanner.isAtEnd()) { "unexpected trailing JSON content" }
        return text
    }

    fun requireSingleEnvelopeCase(
        element: JsonElement,
        allowedCases: Set<String>
    ): EnvelopeCase {
        val envelope = element as? JsonObject
            ?: throw IllegalArgumentException("JSON message envelope must be an object")
        require(envelope.size == 1) { "JSON message envelope must contain exactly one case" }
        val (name, payload) = envelope.entries.single()
        require(name in allowedCases) { "JSON message envelope case is unsupported" }
        return EnvelopeCase(name, payload)
    }

    private class Scanner(private val text: String) {
        private var index = 0

        fun isAtEnd(): Boolean = index == text.length

        fun skipWhitespace() {
            while (index < text.length && text[index].isWhitespace()) index++
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
            val keys = mutableSetOf<String>()
            while (true) {
                skipWhitespace()
                require(index < text.length && text[index] == '"') {
                    "JSON object key must be a string"
                }
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
                    '\\' -> appendEscapedCharacter(result)
                    else -> {
                        require(character.code >= 0x20) { "unescaped JSON control character" }
                        result.append(character)
                    }
                }
            }
            throw IllegalArgumentException("unterminated JSON string")
        }

        private fun appendEscapedCharacter(result: StringBuilder) {
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
                first.isLowSurrogate() ->
                    throw IllegalArgumentException("unexpected low surrogate")
                else -> result.append(first)
            }
        }

        private fun readUnicodeCodeUnit(): Char {
            require(index + 4 <= text.length) { "truncated JSON unicode escape" }
            val codeUnit = text.substring(index, index + 4).toIntOrNull(16)
                ?: throw IllegalArgumentException("invalid JSON unicode escape")
            index += 4
            return codeUnit.toChar()
        }

        private fun parsePrimitive() {
            val start = index
            while (index < text.length && text[index] !in PRIMITIVE_DELIMITERS) index++
            require(index > start) { "invalid JSON primitive" }
        }

        private fun expect(expected: Char) {
            require(index < text.length && text[index] == expected) { "expected JSON token" }
            index++
        }

        private fun consume(expected: Char): Boolean {
            if (index >= text.length || text[index] != expected) return false
            index++
            return true
        }

        private companion object {
            const val MAX_NESTING_DEPTH = 64
            val PRIMITIVE_DELIMITERS = setOf(' ', '\t', '\n', '\r', ',', ']', '}')
        }
    }
}
