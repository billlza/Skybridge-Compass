package com.skybridge.compass.baselineprofile

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {

    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun generateBaselineProfile() = baselineProfileRule.collect(
        packageName = "com.skybridge.compass"
    ) {
        // Startup path (Startup Profile) should be captured first.
        startActivityAndWait()
        // TODO: add critical user journeys (home, discovery, transfer) as needed.
    }
}

