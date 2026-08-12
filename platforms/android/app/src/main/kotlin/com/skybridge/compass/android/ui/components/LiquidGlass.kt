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
 * Rendering strategy for SkyBridge glass surfaces.
 *
 * Compose does not expose Apple Liquid Glass or a stable backdrop-sampling primitive. [Layered]
 * therefore renders a deterministic tint/specular/rim stack behind content. [Reduced] keeps the
 * same geometry while lowering decorative contrast for dense or accessibility-sensitive surfaces.
 */
enum class GlassRenderingQuality {
    Layered,
    Reduced
}

/**
 * Layout-safe glass surface tuned to the shared Apple visual language.
 *
 * [opticalDepth] controls the strength of the simulated material; it is not a blur radius.
 * [blurRadius] is retained only as a source-compatible alias for older callers and also does not
 * request backdrop blur. This avoids pretending that Android RenderEffect can sample pixels behind
 * a Compose subtree—it only blurs the subtree itself and would soften text and controls.
 */
@Composable
fun LiquidGlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(IOSParityTokens.ShapeTokens.CardCornerRadius),
    opticalDepth: Dp = 24.dp,
    blurRadius: Dp? = null,
    renderingQuality: GlassRenderingQuality = GlassRenderingQuality.Layered,
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
    val qualityScale = if (renderingQuality == GlassRenderingQuality.Layered) 1f else 0.62f
    val depth = blurRadius ?: opticalDepth
    val depthFactor = (depth.value / 24f).coerceIn(0.45f, 1.55f) * qualityScale

    val borderBrush = Brush.linearGradient(
        colors = listOf(
            Color.White.copy(alpha = (borderAlpha * 1.18f).coerceAtMost(0.30f)),
            Color.White.copy(alpha = (borderAlpha * 0.56f).coerceAtMost(0.15f)),
            Color.Transparent
        ),
        start = Offset.Zero,
        end = Offset(960f, 960f)
    )
    val topSpecularBrush = Brush.verticalGradient(
        colors = listOf(
            Color.White.copy(alpha = (highlightAlpha * 1.25f * depthFactor).coerceAtMost(0.21f)),
            Color.White.copy(alpha = (highlightAlpha * 0.46f * depthFactor).coerceAtMost(0.08f)),
            Color.Transparent
        )
    )
    val centerBloomBrush = Brush.radialGradient(
        colors = listOf(
            Color.White.copy(alpha = (highlightAlpha * 0.50f * depthFactor).coerceAtMost(0.065f)),
            Color.Transparent
        ),
        radius = 960f
    )
    val refractiveRimBrush = Brush.horizontalGradient(
        colors = listOf(
            IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = (edgeGlowAlpha * 0.30f * depthFactor).coerceAtMost(0.035f)),
            Color.Transparent,
            IOSParityTokens.ColorTokens.PurpleAccent.copy(alpha = (edgeGlowAlpha * 0.26f * depthFactor).coerceAtMost(0.03f))
        )
    )
    val edgeSheenBrush = Brush.horizontalGradient(
        colors = listOf(
            Color.White.copy(alpha = (edgeGlowAlpha * 0.78f * qualityScale).coerceAtMost(0.085f)),
            Color.Transparent,
            Color.Transparent,
            Color.White.copy(alpha = (edgeGlowAlpha * 0.68f * qualityScale).coerceAtMost(0.075f))
        )
    )
    val bottomDepthBrush = Brush.verticalGradient(
        colors = listOf(
            Color.Transparent,
            Color.Black.copy(alpha = (0.018f + highlightAlpha * 0.18f * qualityScale).coerceAtMost(0.06f))
        )
    )

    var baseModifier = modifier
        .shadow(shadowElevation, shape, clip = false)
        .clip(shape)
        .background(effectiveTint)
        .drawWithCache {
            onDrawWithContent {
                // Material layers stay behind descendants so typography and controls remain crisp.
                drawRect(topSpecularBrush)
                drawRect(centerBloomBrush)
                if (edgeGlowEnabled) {
                    drawRect(refractiveRimBrush)
                    drawRect(edgeSheenBrush)
                }
                drawRect(bottomDepthBrush)
                drawContent()
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
