package com.skybridge.compass.android.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val DarkColorScheme = darkColorScheme(
    primary = IOSParityTokens.ColorTokens.PrimaryBlue,
    secondary = IOSParityTokens.ColorTokens.SecondaryIndigo,
    tertiary = IOSParityTokens.ColorTokens.SuccessGreen,
    background = IOSParityTokens.ColorTokens.DarkBackground,
    surface = IOSParityTokens.ColorTokens.DarkSurface,
    onBackground = IOSParityTokens.ColorTokens.DarkOnBackground,
    onSurface = IOSParityTokens.ColorTokens.DarkOnSurface,
    onSurfaceVariant = IOSParityTokens.ColorTokens.DarkOnSurfaceVariant,
    error = IOSParityTokens.ColorTokens.ErrorRed
)

private val LightColorScheme = lightColorScheme(
    primary = IOSParityTokens.ColorTokens.PrimaryBlue,
    secondary = IOSParityTokens.ColorTokens.SecondaryIndigo,
    tertiary = IOSParityTokens.ColorTokens.SuccessGreen,
    background = IOSParityTokens.ColorTokens.LightBackground,
    surface = IOSParityTokens.ColorTokens.LightSurface,
    onBackground = IOSParityTokens.ColorTokens.LightOnBackground,
    onSurface = IOSParityTokens.ColorTokens.LightOnSurface,
    onSurfaceVariant = IOSParityTokens.ColorTokens.LightOnSurfaceVariant,
    error = IOSParityTokens.ColorTokens.ErrorRed
)

@Composable
fun SkyBridgeCompassTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Fixed iOS parity palette by default.
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            WindowCompat.setDecorFitsSystemWindows(window, false)
            // Use WindowInsetsController for modern status bar/navigation bar styling
            val insetsController = WindowCompat.getInsetsController(window, view)
            insetsController.isAppearanceLightStatusBars = !darkTheme
            insetsController.isAppearanceLightNavigationBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
