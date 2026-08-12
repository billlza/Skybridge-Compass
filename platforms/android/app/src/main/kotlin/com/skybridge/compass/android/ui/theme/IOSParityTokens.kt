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

        /**
         * Primary accent for the Android app, matching the iOS SwiftUI tab tint (`.cyan`).
         * Use this for tab tints, "View All" links, active highlights, and the primary
         * quick-action / stat accents so every surface reads from one source of truth.
         */
        val CyanAccent = Color(0xFF00BCD4)
        /** Slightly brighter cyan used for selected bottom-nav glyphs on dark glass. */
        val CyanAccentBright = Color(0xFF2AB8FF)
        /** Secondary accent (purple) used opposite cyan in the iOS gradient pairings. */
        val PurpleAccent = Color(0xFFAF52DE)

        /** Neutral fill for inset glass rows / chips on the dark scheme. */
        val GlassRowFill = Color(0xFF1E2537)
        val GlassCardFill = Color(0xFF1E2537)

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
        val GlassSectionCornerRadius = 22.dp
        val PillCornerRadius = 999.dp
        val CompactCornerRadius = 12.dp
    }

    object SpacingTokens {
        val ScreenHorizontal = 16.dp
        val ScreenTop = 8.dp
        val SectionVertical = 12.dp
        val SectionGap = 14.dp
        val ItemPadding = 16.dp
        val CompactPadding = 10.dp
        val SettingsBottomClearance = 112.dp
    }

    object GlassTokens {
        val BorderAlpha = 0.18f
        val HighlightAlpha = 0.12f
        val EdgeGlowAlpha = 0.08f
        val SectionTintAlpha = 0.20f
        val SectionBorderAlpha = 0.22f
        val SectionHighlightAlpha = 0.11f
        val SectionEdgeGlowAlpha = 0.08f
        val IconTintAlpha = 0.16f
    }

    /**
     * Security-evidence badge mapping, mirroring the iOS DashboardView
     * `securityBadgePresentation` / `securityBadgeColor` contract:
     *  - PQC      → green  / lock.shield.fill
     *  - Classic  → blue   / lock.fill
     *  - 待确认    → orange / lock
     *  - 离线      → gray   / lock.slash
     * Shared so the dashboard welcome card and any future security surface stay in lockstep.
     */
    enum class SecurityBadgeTone {
        VerifiedPqc,
        Classic,
        Pending,
        Offline
    }

    object SecurityBadge {
        fun color(tone: SecurityBadgeTone): Color = when (tone) {
            SecurityBadgeTone.VerifiedPqc -> ColorTokens.SuccessGreen
            SecurityBadgeTone.Classic -> ColorTokens.PrimaryBlue
            SecurityBadgeTone.Pending -> ColorTokens.WarningOrange
            SecurityBadgeTone.Offline -> Color(0xFF8E8E93)
        }
    }
}
