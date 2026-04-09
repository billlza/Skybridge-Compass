package com.skybridge.compass.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.ui.theme.IOSParityTokens

/**
 * Layout-safe glass surface tuned for iOS parity.
 *
 * Intentionally avoids noisy texture layers that can create "mesh" artifacts on Android panels.
 */
@Composable
fun LiquidGlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(IOSParityTokens.ShapeTokens.CardCornerRadius),
    blurRadius: Dp = 24.dp,
    enableRealBlur: Boolean = true,
    tintColor: Color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
    tintAlpha: Float? = null,
    shadowElevation: Dp = 0.dp,
    borderWidth: Dp = 1.dp,
    borderAlpha: Float = IOSParityTokens.GlassTokens.BorderAlpha,
    highlightAlpha: Float = IOSParityTokens.GlassTokens.HighlightAlpha,
    edgeGlowAlpha: Float = IOSParityTokens.GlassTokens.EdgeGlowAlpha,
    contentPadding: PaddingValues = PaddingValues(IOSParityTokens.SpacingTokens.ItemPadding),
    edgeGlowEnabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    val effectiveTint = tintAlpha?.let { tintColor.copy(alpha = it) } ?: tintColor
    val blurFactor = ((blurRadius.value / 24f).coerceIn(0.55f, 1.75f)) * if (enableRealBlur) 1f else 0.86f

    val borderBrush = Brush.linearGradient(
        colors = listOf(
            Color.White.copy(alpha = (borderAlpha * 1.12f).coerceAtMost(0.28f)),
            Color.White.copy(alpha = (borderAlpha * 0.58f).coerceAtMost(0.16f)),
            Color.Transparent
        ),
        start = Offset(0f, 0f),
        end = Offset(960f, 960f)
    )

    val topSpecularBrush = Brush.verticalGradient(
        colors = listOf(
            Color.White.copy(alpha = (highlightAlpha * 1.28f * blurFactor).coerceAtMost(0.22f)),
            Color.White.copy(alpha = (highlightAlpha * 0.72f * blurFactor).coerceAtMost(0.11f)),
            Color.Transparent
        )
    )

    val centerBloomBrush = Brush.radialGradient(
        colors = listOf(
            Color.White.copy(alpha = (highlightAlpha * 0.58f * blurFactor).coerceAtMost(0.07f)),
            Color.Transparent
        ),
        radius = 960f
    )

    val edgeSheenBrush = Brush.horizontalGradient(
        colors = listOf(
            Color.White.copy(alpha = (edgeGlowAlpha * 0.82f).coerceAtMost(0.09f)),
            Color.Transparent,
            Color.Transparent,
            Color.White.copy(alpha = (edgeGlowAlpha * 0.74f).coerceAtMost(0.08f))
        )
    )

    val bottomDepthBrush = Brush.verticalGradient(
        colors = listOf(
            Color.Transparent,
            Color.Black.copy(alpha = (0.02f + highlightAlpha * 0.2f).coerceAtMost(0.07f))
        )
    )

    var baseModifier = modifier
        .shadow(shadowElevation, shape, clip = false)
        .clip(shape)
        .background(effectiveTint)
        .drawWithCache {
            onDrawWithContent {
                drawContent()
                drawRect(topSpecularBrush)
                drawRect(centerBloomBrush)
                if (edgeGlowEnabled) {
                    drawRect(edgeSheenBrush)
                }
                drawRect(bottomDepthBrush)
            }
        }
        .border(borderWidth, borderBrush, shape)

    if (onClick != null) {
        baseModifier = baseModifier.clickable(onClick = onClick)
    }

    Box(modifier = baseModifier) {
        Box(modifier = Modifier.padding(contentPadding)) {
            content()
        }
    }
}
