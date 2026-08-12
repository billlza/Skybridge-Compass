package com.skybridge.compass

import android.content.Context
import android.content.Intent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.skybridge.compass.android.MainActivity
import com.skybridge.compass.android.TestDatabaseCleanupRule
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.i18n.AppLanguageRuntime
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import com.skybridge.compass.android.ui.navigation.NavigationSemantics
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.core.data.database.AppDatabase
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import javax.inject.Inject

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class MainActivityTest {

    @Inject lateinit var database: AppDatabase

    @get:Rule(order = -1)
    val databaseCleanupRule = TestDatabaseCleanupRule {
        if (::database.isInitialized) database else null
    }

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeTestRule = createEmptyComposeRule()

    private lateinit var context: Context
    private lateinit var previousLanguage: String

    @Before
    fun setUp() {
        hiltRule.inject()
        composeTestRule.mainClock.autoAdvance = false
        context = ApplicationProvider.getApplicationContext()
        runBlocking {
            previousLanguage = AppSettingsStore.observeAppLanguage(context).first()
            AppSettingsStore.setAppLanguage(context, APP_LANGUAGE_EN)
        }
        AppLanguageRuntime.applySetting(APP_LANGUAGE_EN)
    }

    @After
    fun tearDown() {
        runBlocking {
            AppSettingsStore.setAppLanguage(context, previousLanguage)
        }
        AppLanguageRuntime.applySetting(previousLanguage)
    }

    @Test
    fun mainActivity_forcedLoginModeShowsAuthGateAndHidesAppNavigation() {
        withMainActivity(forceLoginScreen = true) {
            composeTestRule.onNodeWithText("SkyBridge Compass").assertIsDisplayed()
            composeTestRule.onNodeWithText("Sign-in Method").assertIsDisplayed()
            topLevelRoutes.forEach { route ->
                composeTestRule
                    .onNodeWithTag(NavigationSemantics.bottomTab(route))
                    .assertDoesNotExist()
            }
        }
    }

    @Test
    fun mainActivity_debugVisualModeStartsAtCurrentDashboard() {
        withMainActivity(forceVisualTestMode = true) {
            assertDestination(Screen.Dashboard.route)
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Dashboard.route))
                .assertIsSelected()
            composeTestRule.onNodeWithText("Sign-in Method").assertDoesNotExist()
            topLevelRoutes.forEach { route ->
                composeTestRule
                    .onNodeWithTag(NavigationSemantics.bottomTab(route))
                    .assertIsDisplayed()
                    .assertHasClickAction()
            }
        }
    }

    @Test
    fun mainActivity_filesTabOpensCurrentFileTransferDestination() {
        withMainActivity(forceVisualTestMode = true) {
            selectTopLevelDestination(Screen.FileTransfer.route)
        }
    }

    @Test
    fun mainActivity_remoteTabOpensCurrentRemoteControlDestination() {
        withMainActivity(forceVisualTestMode = true) {
            selectTopLevelDestination(Screen.RemoteControl.route)
        }
    }

    @Test
    fun mainActivity_debugNavigationIntentOpensRequestedCurrentDestination() {
        withMainActivity(
            forceVisualTestMode = true,
            navRoute = Screen.Settings.route
        ) {
            assertDestination(Screen.Settings.route)
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Settings.route))
                .assertIsSelected()
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Dashboard.route))
                .assertIsNotSelected()
        }
    }

    @Test
    fun mainActivity_rejectsSecurityReviewIntentWithoutAnExactCurrentPrompt() {
        withMainActivity(
            forceVisualTestMode = true,
            securityReviewKind = SecurityPromptNotifier.REVIEW_KIND_INBOUND_FILE,
            securityReviewId = "00000000-0000-0000-0000-000000000099"
        ) {
            assertDestination(Screen.Dashboard.route)
            composeTestRule.onNodeWithText("Incoming file transfer").assertDoesNotExist()
        }
    }

    @Test
    fun mainActivity_opensOnlyTheExactCurrentSecurityPrompt() {
        val transferId = "00000000-0000-0000-0000-000000000098"
        SecurityPromptStore.requestInboundDecision(
            SecurityPromptStore.InboundFileTransferPrompt(
                transferId = transferId,
                fileName = "bounded-review.txt",
                fileSizeBytes = 4,
                senderDeviceId = "authenticated-peer"
            )
        )
        try {
            withMainActivity(
                forceVisualTestMode = true,
                securityReviewKind = SecurityPromptNotifier.REVIEW_KIND_INBOUND_FILE,
                securityReviewId = transferId
            ) {
                waitForText("Incoming file transfer")
                composeTestRule.onNodeWithText("Incoming file transfer").assertIsDisplayed()
                composeTestRule
                    .onNodeWithText("From: authenticated-peer\nFile: bounded-review.txt\nSize: 4 B\nSave to: Downloads")
                    .assertIsDisplayed()
            }
        } finally {
            SecurityPromptStore.resolveInbound(
                transferId,
                SecurityPromptStore.InboundFileTransferDecision.Decline
            )
        }
    }

    @Test
    fun mainActivity_recreationRestoresSelectedTopLevelDestination() {
        withMainActivity(forceVisualTestMode = true) { scenario ->
            selectTopLevelDestination(Screen.FileTransfer.route)

            scenario.recreate()

            assertDestination(Screen.FileTransfer.route)
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.FileTransfer.route))
                .assertIsSelected()
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Dashboard.route))
                .assertIsNotSelected()
        }
    }

    @Test
    fun mainActivity_currentTopLevelNavigationExposesTabAccessibilitySemantics() {
        withMainActivity(forceVisualTestMode = true) {
            topLevelRoutes.zip(topLevelLabels).forEach { (route, label) ->
                composeTestRule
                    .onNodeWithTag(NavigationSemantics.bottomTab(route))
                    .assertHasClickAction()
                    .assert(
                        SemanticsMatcher.expectValue(
                            SemanticsProperties.Role,
                            Role.Tab
                        )
                    )
                composeTestRule
                    .onNodeWithContentDescription(label)
                    .assertIsDisplayed()
            }
        }
    }

    @Test
    fun mainActivity_repeatedTopLevelSwitchingEndsOnExactRequestedDestination() {
        withMainActivity(forceVisualTestMode = true) {
            listOf(
                Screen.DeviceDiscovery.route,
                Screen.Settings.route,
                Screen.RemoteControl.route,
                Screen.FileTransfer.route,
                Screen.Dashboard.route
            ).forEach(::selectTopLevelDestination)

            assertDestination(Screen.Dashboard.route)
            composeTestRule
                .onNodeWithTag(NavigationSemantics.bottomTab(Screen.Dashboard.route))
                .assertIsSelected()
        }
    }

    private fun withMainActivity(
        forceVisualTestMode: Boolean = false,
        forceLoginScreen: Boolean = false,
        navRoute: String? = null,
        securityReviewKind: String? = null,
        securityReviewId: String? = null,
        assertions: (ActivityScenario<MainActivity>) -> Unit
    ) {
        val intent = Intent(context, MainActivity::class.java).apply {
            if (forceVisualTestMode) {
                putExtra(MainActivity.EXTRA_FORCE_VISUAL_TEST_MODE, true)
            }
            if (forceLoginScreen) {
                putExtra(MainActivity.EXTRA_FORCE_LOGIN_SCREEN, true)
            }
            if (navRoute != null) {
                putExtra(MainActivity.EXTRA_NAV_ROUTE, navRoute)
            }
            if (securityReviewKind != null) {
                putExtra(SecurityPromptNotifier.EXTRA_REVIEW_KIND, securityReviewKind)
            }
            if (securityReviewId != null) {
                putExtra(SecurityPromptNotifier.EXTRA_REVIEW_ID, securityReviewId)
            }
        }

        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            composeTestRule.mainClock.advanceTimeByFrame()
            composeTestRule.waitForIdle()
            assertions(scenario)
        }
    }

    private fun selectTopLevelDestination(route: String) {
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(route))
            .performClick()
        assertDestination(route)
        composeTestRule
            .onNodeWithTag(NavigationSemantics.bottomTab(route))
            .assertIsSelected()
    }

    private fun assertDestination(route: String) {
        val destinationTag = NavigationSemantics.destination(route)
        composeTestRule.waitUntil(timeoutMillis = 10_000) {
            composeTestRule.mainClock.advanceTimeByFrame()
            composeTestRule
                .onAllNodesWithTag(destinationTag)
                .fetchSemanticsNodes()
                .size == 1
        }
        composeTestRule.onNodeWithTag(destinationTag).assertIsDisplayed()
    }

    private fun waitForText(text: String) {
        composeTestRule.waitUntil(timeoutMillis = 10_000) {
            composeTestRule.mainClock.advanceTimeByFrame()
            composeTestRule
                .onAllNodesWithText(text)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
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
