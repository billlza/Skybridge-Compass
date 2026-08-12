package com.skybridge.compass.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.ui.theme.IOSParityTokens

/**
 * Shared iOS-parity surface + accent helpers.
 *
 * These are the canonical building blocks for the Android UI parity pass. Every screen
 * (Dashboard, Devices, and the step 5b screens — Files / Remote / Settings) should reach
 * for [IOSGlassCard] and [iosPlatformAccent] rather than re-deriving glass tints and
 * platform colors inline, so the whole app stays on one cyan-accented dark glass language.
 *
 * The look mirrors the iOS `.ultraThinMaterial` cards with a top-left white → transparent →
 * accent gradient stroke.
 */
@Composable
fun IOSGlassCard(
    modifier: Modifier = Modifier,
    accentColor: Color = IOSParityTokens.ColorTokens.CyanAccent,
    cornerRadius: Int = 24,
    fillAlpha: Float = 0.62f,
    content: @Composable () -> Unit
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cornerRadius.dp))
            .background(IOSParityTokens.ColorTokens.GlassCardFill.copy(alpha = fillAlpha))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.30f),
                        Color.Transparent,
                        accentColor.copy(alpha = 0.12f)
                    ),
                    start = Offset.Zero,
                    end = Offset(600f, 600f)
                ),
                shape = RoundedCornerShape(cornerRadius.dp)
            )
    ) {
        content()
    }
}

/**
 * Inset glass row used for device / connection rows and list items. Accepts a per-row accent
 * (e.g. the platform color) that tints the gradient stroke, matching the iOS row treatment.
 */
@Composable
fun IOSGlassRow(
    modifier: Modifier = Modifier,
    accentColor: Color = IOSParityTokens.ColorTokens.CyanAccent,
    cornerRadius: Int = 16,
    fillAlpha: Float = 0.60f,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    var base = modifier
        .fillMaxWidth()
        .clip(RoundedCornerShape(cornerRadius.dp))
        .background(IOSParityTokens.ColorTokens.GlassRowFill.copy(alpha = fillAlpha))
        .border(
            width = 1.dp,
            brush = Brush.linearGradient(
                colors = listOf(
                    Color.White.copy(alpha = 0.24f),
                    Color.Transparent,
                    accentColor.copy(alpha = 0.10f)
                ),
                start = Offset.Zero,
                end = Offset(500f, 500f)
            ),
            shape = RoundedCornerShape(cornerRadius.dp)
        )
    if (onClick != null) {
        base = base.clickable(onClick = onClick)
    }
    Box(modifier = base) { content() }
}

/**
 * Canonical per-platform accent color, matching the iOS dashboard device-row palette.
 * Keyed off a platform label substring so it works for both discovery `DeviceType` display
 * names and connection presentation labels.
 */
fun iosPlatformAccent(platformLabel: String): Color = when {
    platformLabel.contains("iOS", ignoreCase = true) -> IOSParityTokens.ColorTokens.CyanAccent
    platformLabel.contains("macOS", ignoreCase = true) -> IOSParityTokens.ColorTokens.PrimaryBlue
    platformLabel.contains("Android", ignoreCase = true) -> IOSParityTokens.ColorTokens.SuccessGreen
    platformLabel.contains("Windows", ignoreCase = true) -> IOSParityTokens.ColorTokens.PrimaryBlue
    platformLabel.contains("Linux", ignoreCase = true) -> IOSParityTokens.ColorTokens.WarningOrange
    else -> Color(0xFF8E8E93)
}
