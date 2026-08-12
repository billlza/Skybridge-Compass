package com.skybridge.compass.android

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.i18n.AppLanguageRuntime
import com.skybridge.compass.android.ui.navigation.NavigationSemantics
import com.skybridge.compass.android.ui.navigation.Screen
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
class IntegrationTest {

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
            AppNavigationTestHarness()
        }
        composeTestRule.waitForIdle()
    }

    @After
    fun tearDown() {
        AppLanguageRuntime.applySetting(APP_LANGUAGE_SYSTEM)
    }

    @Test
    fun authenticatedShell_startsAtCurrentDashboardWithFiveTopLevelTabs() {
        assertDestination(Screen.Dashboard.route)
        assertSelectedTab(Screen.Dashboard.route)

        topLevelRoutes.forEach { route ->
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(route))
                .assertIsDisplayed()
                .assertHasClickAction()
        }
    }

    @Test
    fun authenticatedShell_dashboardScanNetworkOpensDevices() {
        selectDashboardAction(
            actionId = NavigationSemantics.ACTION_SCAN_NETWORK,
            route = Screen.DeviceDiscovery.route
        )
    }

    @Test
    fun authenticatedShell_dashboardCrossNetworkOpensDevices() {
        selectDashboardAction(
            actionId = NavigationSemantics.ACTION_CROSS_NETWORK,
            route = Screen.DeviceDiscovery.route
        )
    }

    @Test
    fun authenticatedShell_dashboardSendFileOpensFiles() {
        selectDashboardAction(
            actionId = NavigationSemantics.ACTION_SEND_FILE,
            route = Screen.FileTransfer.route
        )
    }

    @Test
    fun authenticatedShell_dashboardRemoteDesktopOpensRemote() {
        selectDashboardAction(
            actionId = NavigationSemantics.ACTION_REMOTE_DESKTOP,
            route = Screen.RemoteControl.route
        )
    }

    @Test
    fun authenticatedShell_topLevelTabsNavigateToExactCurrentDestinations() {
        listOf(
            Screen.DeviceDiscovery.route,
            Screen.FileTransfer.route,
            Screen.RemoteControl.route,
            Screen.Settings.route,
            Screen.Dashboard.route
        ).forEach(::selectTopLevelTab)

        assertDestination(Screen.Dashboard.route)
        assertSelectedTab(Screen.Dashboard.route)
    }

    @Test
    fun authenticatedShell_currentTabsExposeAccessibleLabels() {
        topLevelRoutes.zip(topLevelLabels).forEach { (route, label) ->
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(route))
                .assertHasClickAction()
            composeTestRule
                .onNodeWithContentDescription(label)
                .assertIsDisplayed()
        }

        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(Screen.ScreenMirroring.route))
            .assertDoesNotExist()
    }

    private fun selectDashboardAction(actionId: String, route: String) {
        val actionTag = NavigationSemantics.dashboardAction(actionId, route)
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_SCROLL)
            .performScrollToNode(hasTestTag(actionTag))
        composeTestRule
            .onNodeWithTag(actionTag)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()

        assertDestination(route)
        assertSelectedTab(route)
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Dashboard.route))
            .assertIsNotSelected()
    }

    private fun selectTopLevelTab(route: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(route))
            .performClick()

        assertDestination(route)
        assertSelectedTab(route)
    }

    private fun assertDestination(route: String) {
        val destinationTag = NavigationSemantics.destination(route)
        composeTestRule.waitUntil(timeoutMillis = 10_000) {
            composeTestRule
                .onAllNodesWithTag(destinationTag)
                .fetchSemanticsNodes()
                .size == 1
        }
        composeTestRule.onNodeWithTag(destinationTag).assertIsDisplayed()
    }

    private fun assertSelectedTab(route: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(route))
            .assertIsSelected()
    }

    private companion object {
        val topLevelRoutes = listOf(
            Screen.Dashboard.route,
            Screen.DeviceDiscovery.route,
            Screen.FileTransfer.route,
            Screen.RemoteControl.route,
            Screen.Settings.route
        )

        val topLevelLabels = listOf("Home", "Devices", "Files", "Remote", "Settings")
    }
}
