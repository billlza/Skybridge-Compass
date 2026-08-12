package com.skybridge.compass.android

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.compose.ComposeNavigator
import androidx.navigation.testing.TestNavHostController
import com.skybridge.compass.android.ui.components.BottomNavigationBar
import com.skybridge.compass.android.ui.navigation.SkyBridgeNavigation
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme

@Composable
internal fun AppNavigationTestHarness(
    onNavControllerReady: (TestNavHostController) -> Unit = {}
) {
    SkyBridgeCompassTheme {
        val context = LocalContext.current
        val navController = remember {
            TestNavHostController(context).apply {
                navigatorProvider.addNavigator(ComposeNavigator())
            }
        }
        SideEffect { onNavControllerReady(navController) }

        Scaffold(
            modifier = Modifier.fillMaxSize(),
            bottomBar = { BottomNavigationBar(navController) }
        ) { innerPadding ->
            Box(modifier = Modifier.padding(innerPadding)) {
                SkyBridgeNavigation(navController = navController)
            }
        }
    }
}
