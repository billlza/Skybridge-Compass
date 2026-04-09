package com.skybridge.compass.android.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * iOS/macOS parity design tokens for Android Compose rendering.
 *
 * These values are intentionally fixed to avoid Material dynamic color drift
 * when targeting 1:1 visual parity with iOS baseline screens.
 */
object IOSParityTokens {
    object ColorTokens {
        val PrimaryBlue = Color(0xFF0A84FF)
        val SecondaryIndigo = Color(0xFF5E5CE6)
        val SuccessGreen = Color(0xFF34C759)
        val WarningOrange = Color(0xFFFF9F0A)
        val ErrorRed = Color(0xFFFF453A)

        val LightBackground = Color(0xFFF4F7FB)
        val LightSurface = Color(0xFFFFFFFF)
        val LightOnBackground = Color(0xFF0F1728)
        val LightOnSurface = Color(0xFF0F1728)
        val LightOnSurfaceVariant = Color(0xFF5F687A)

        val DarkBackground = Color(0xFF070B16)
        val DarkSurface = Color(0xFF11182A)
        val DarkOnBackground = Color(0xFFF2F5FC)
        val DarkOnSurface = Color(0xFFF2F5FC)
        val DarkOnSurfaceVariant = Color(0xFFB4BED0)
    }

    object ShapeTokens {
        val CardCornerRadius = 24.dp
        val PillCornerRadius = 999.dp
        val CompactCornerRadius = 12.dp
    }

    object SpacingTokens {
        val ScreenHorizontal = 16.dp
        val SectionVertical = 12.dp
        val ItemPadding = 16.dp
        val CompactPadding = 10.dp
    }

    object GlassTokens {
        val BorderAlpha = 0.18f
        val HighlightAlpha = 0.12f
        val EdgeGlowAlpha = 0.08f
    }
}
