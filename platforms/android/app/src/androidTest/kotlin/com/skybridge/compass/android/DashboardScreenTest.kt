package com.skybridge.compass.android

import android.os.Build
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToNode
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.i18n.AppLanguageRuntime
import com.skybridge.compass.android.ui.navigation.NavigationSemantics
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.screens.dashboard.DashboardScreen
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.core.data.database.AppDatabase
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import javax.inject.Inject

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class DashboardScreenTest {

    @Inject lateinit var database: AppDatabase

    @get:Rule(order = -1)
    val databaseCleanupRule = TestDatabaseCleanupRule {
        if (::database.isInitialized) database else null
    }

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeTestRule = createAndroidComposeRule<HiltTestActivity>()

    @Before
    fun setUp() {
        hiltRule.inject()
        AppLanguageRuntime.applySetting(APP_LANGUAGE_EN)
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                DashboardScreen(navController = rememberNavController())
            }
        }
    }

    @After
    fun tearDown() {
        AppLanguageRuntime.applySetting(APP_LANGUAGE_SYSTEM)
    }

    @Test
    fun dashboardScreen_displaysCurrentTitleAndDeviceSummary() {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_TITLE, useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithText(Build.MODEL, substring = false)
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithText("Android ${Build.VERSION.RELEASE}")
            .assertIsDisplayed()
    }

    @Test
    fun dashboardScreen_displaysCurrentSummaryCards() {
        scrollDashboardTo(NavigationSemantics.DASHBOARD_DISCOVERY_STAT)

        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_DISCOVERY_STAT)
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithText("Discovery & Connections")
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_TRANSFER_STAT)
            .assertIsDisplayed()
        composeTestRule
            .onNodeWithText("Transfers & Performance")
            .assertIsDisplayed()
    }

    @Test
    fun dashboardScreen_displaysCurrentQuickActions() {
        val actions = listOf(
            Triple(NavigationSemantics.ACTION_SCAN_NETWORK, Screen.DeviceDiscovery.route, "Scan Network"),
            Triple(NavigationSemantics.ACTION_SEND_FILE, Screen.FileTransfer.route, "Send File"),
            Triple(NavigationSemantics.ACTION_REMOTE_DESKTOP, Screen.RemoteControl.route, "Remote Desktop"),
            Triple(NavigationSemantics.ACTION_CROSS_NETWORK, Screen.DeviceDiscovery.route, "Cross-Network")
        )

        actions.forEach { (actionId, route, label) ->
            val tag = NavigationSemantics.dashboardAction(actionId, route)
            scrollDashboardTo(tag)
            composeTestRule.onNodeWithTag(tag).assertIsDisplayed()
            composeTestRule.onNodeWithText(label).assertIsDisplayed()
        }
    }

    @Test
    fun dashboardScreen_currentQuickActionsAreClickable() {
        listOf(
            NavigationSemantics.ACTION_SCAN_NETWORK to Screen.DeviceDiscovery.route,
            NavigationSemantics.ACTION_SEND_FILE to Screen.FileTransfer.route,
            NavigationSemantics.ACTION_REMOTE_DESKTOP to Screen.RemoteControl.route,
            NavigationSemantics.ACTION_CROSS_NETWORK to Screen.DeviceDiscovery.route
        ).forEach { (actionId, route) ->
            val tag = NavigationSemantics.dashboardAction(actionId, route)
            scrollDashboardTo(tag)
            composeTestRule
                .onNodeWithTag(tag)
                .assertIsDisplayed()
                .assertHasClickAction()
        }
    }

    @Test
    fun dashboardScreen_displaysCurrentTopBarActions() {
        composeTestRule.onNodeWithContentDescription("Refresh").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("Notifications").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("Scan to Connect").assertIsDisplayed()
    }

    @Test
    fun dashboardScreen_scrollsToNearbyDevicesSection() {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_SCROLL)
            .performScrollToNode(androidx.compose.ui.test.hasText("Nearby Devices"))

        composeTestRule.onNodeWithText("Nearby Devices").assertIsDisplayed()
        composeTestRule.onNodeWithText("View All").assertIsDisplayed()
    }

    private fun scrollDashboardTo(tag: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_SCROLL)
            .performScrollToNode(hasTestTag(tag))
    }
}
