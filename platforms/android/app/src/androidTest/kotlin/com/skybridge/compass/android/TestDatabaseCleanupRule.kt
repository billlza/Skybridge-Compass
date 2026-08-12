package com.skybridge.compass.android

import com.skybridge.compass.core.data.database.AppDatabase
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement

/** Closes the per-test Hilt database after activity and component teardown. */
class TestDatabaseCleanupRule(
    private val database: () -> AppDatabase?
) : TestRule {
    override fun apply(base: Statement, description: Description): Statement =
        object : Statement() {
            override fun evaluate() {
                try {
                    base.evaluate()
                } finally {
                    database()?.close()
                }
            }
        }
}
