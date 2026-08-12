package com.skybridge.compass.android

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.navigation.testing.TestNavHostController
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import javax.inject.Inject

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class NavigationTest {

    @Inject lateinit var database: AppDatabase

    @get:Rule(order = -1)
    val databaseCleanupRule = TestDatabaseCleanupRule {
        if (::database.isInitialized) database else null
    }

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeTestRule = createAndroidComposeRule<HiltTestActivity>()

    private lateinit var navController: TestNavHostController

    @Before
    fun setUp() {
        hiltRule.inject()
        AppLanguageRuntime.applySetting(APP_LANGUAGE_EN)
        composeTestRule.setContent {
            AppNavigationTestHarness { navController = it }
        }
        composeTestRule.waitForIdle()
    }

    @After
    fun tearDown() {
        AppLanguageRuntime.applySetting(APP_LANGUAGE_SYSTEM)
    }

    @Test
    fun navigation_startsAtDashboardWithHomeSelected() {
        assertCurrentDestination(Screen.Dashboard.route)
        assertSelectedTab(Screen.Dashboard.route)

        listOf(
            Screen.DeviceDiscovery.route,
            Screen.FileTransfer.route,
            Screen.RemoteControl.route,
            Screen.Settings.route
        ).forEach { route ->
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(route))
                .assertIsNotSelected()
        }
    }

    @Test
    fun navigation_exposesFiveCurrentTopLevelTabs() {
        listOf(
            Screen.Dashboard.route,
            Screen.DeviceDiscovery.route,
            Screen.FileTransfer.route,
            Screen.RemoteControl.route,
            Screen.Settings.route
        ).forEach { route ->
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(route))
                .assertIsDisplayed()
                .assertHasClickAction()
        }
    }

    @Test
    fun navigation_devicesTabUpdatesDestinationAndSelection() {
        selectTab(Screen.DeviceDiscovery.route, Screen.DeviceDiscovery.route)
    }

    @Test
    fun navigation_filesTabUpdatesPatternDestinationAndSelection() {
        selectTab(Screen.FileTransfer.route, Screen.FileTransfer.routePattern)
    }

    @Test
    fun navigation_remoteTabUpdatesPatternDestinationAndSelection() {
        selectTab(Screen.RemoteControl.route, Screen.RemoteControl.routePattern)
    }

    @Test
    fun navigation_settingsTabUpdatesDestinationAndSelection() {
        selectTab(Screen.Settings.route, Screen.Settings.route)
    }

    @Test
    fun navigation_dashboardSendFileActionSelectsFilesRoute() {
        selectDashboardAction(
            NavigationSemantics.ACTION_SEND_FILE,
            Screen.FileTransfer.route,
            Screen.FileTransfer.routePattern
        )
        assertSelectedTab(Screen.FileTransfer.route)
    }

    @Test
    fun navigation_dashboardRemoteDesktopActionSelectsRemoteRoute() {
        selectDashboardAction(
            NavigationSemantics.ACTION_REMOTE_DESKTOP,
            Screen.RemoteControl.route,
            Screen.RemoteControl.routePattern
        )
        assertSelectedTab(Screen.RemoteControl.route)
    }

    @Test
    fun navigation_backReturnsToDashboardAndRestoresHomeSelection() {
        selectTab(Screen.DeviceDiscovery.route, Screen.DeviceDiscovery.route)

        composeTestRule.runOnIdle {
            assertTrue(navController.popBackStack())
        }
        composeTestRule.waitForIdle()

        assertCurrentDestination(Screen.Dashboard.route)
        assertSelectedTab(Screen.Dashboard.route)
    }

    @Test
    fun navigation_invalidRouteFailsWithoutChangingDestination() {
        composeTestRule.runOnIdle {
            assertThrows(IllegalArgumentException::class.java) {
                navController.navigate("route-that-is-not-in-the-graph")
            }
            assertEquals(Screen.Dashboard.route, navController.currentDestination?.route)
        }
        assertSelectedTab(Screen.Dashboard.route)
    }

    private fun selectTab(tabRoute: String, destinationRoute: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(tabRoute))
            .performClick()
        composeTestRule.waitForIdle()

        assertCurrentDestination(destinationRoute)
        assertSelectedTab(tabRoute)
    }

    private fun selectDashboardAction(
        actionId: String,
        actionRoute: String,
        destinationRoute: String
    ) {
        val tag = NavigationSemantics.dashboardAction(actionId, actionRoute)
        composeTestRule
            .onNodeWithTag(NavigationSemantics.DASHBOARD_SCROLL)
            .performScrollToNode(hasTestTag(tag))
        composeTestRule
            .onNodeWithTag(tag)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        composeTestRule.waitForIdle()

        assertCurrentDestination(destinationRoute)
    }

    private fun assertCurrentDestination(expectedRoute: String) {
        composeTestRule.runOnIdle {
            assertEquals(expectedRoute, navController.currentDestination?.route)
        }
    }

    private fun assertSelectedTab(route: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(route))
            .assertIsSelected()
    }
}
