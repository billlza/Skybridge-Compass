package com.skybridge.compass.supabase

import io.ktor.http.URLBuilder
import io.ktor.http.path

internal object SupabasePostgrestUrls {
    private val identifier = Regex("^[A-Za-z_][A-Za-z0-9_]*$")

    fun table(baseUrl: String, table: String, query: Map<String, String> = emptyMap()): String {
        require(identifier.matches(table)) { "Invalid PostgREST table name: $table" }
        val builder = URLBuilder(baseUrl.trimEnd('/'))
        builder.path("rest", "v1", table)
        query.forEach { (key, value) ->
            require(identifier.matches(key)) { "Invalid PostgREST query parameter: $key" }
            builder.parameters.append(key, value)
        }
        return builder.buildString()
    }
}
