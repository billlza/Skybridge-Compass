package com.skybridge.compass.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.ui.theme.IOSParityTokens

/**
 * Apple-like grouped list section:
 * - Section title (optional)
 * - One glass container with internal dividers
 */
@Composable
fun GroupedGlassSection(
    modifier: Modifier = Modifier,
    title: String? = null,
    containerPadding: PaddingValues = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
    content: @Composable ColumnScope.() -> Unit
) {
    Column(modifier = modifier.fillMaxWidth()) {
        if (!title.isNullOrBlank()) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp)
            )
        }
        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(IOSParityTokens.ShapeTokens.GlassSectionCornerRadius),
            opticalDepth = 22.dp,
            tintColor = MaterialTheme.colorScheme.surface.copy(
                alpha = IOSParityTokens.GlassTokens.SectionTintAlpha
            ),
            tintAlpha = IOSParityTokens.GlassTokens.SectionTintAlpha,
            borderAlpha = IOSParityTokens.GlassTokens.SectionBorderAlpha,
            highlightAlpha = IOSParityTokens.GlassTokens.SectionHighlightAlpha,
            edgeGlowAlpha = IOSParityTokens.GlassTokens.SectionEdgeGlowAlpha,
            contentPadding = containerPadding
        ) {
            Column { content() }
        }
    }
}

@Composable
fun GroupedGlassDivider(
    modifier: Modifier = Modifier,
    insetStart: Dp = 52.dp,
    alpha: Float = 0.14f
) {
    // Subtle iOS-like divider: inset to align after icon tile
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = insetStart, end = 12.dp)
            .height(1.dp)
            .alpha(alpha)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f))
    ) {
        // divider line
    }
}

@Composable
fun GroupedGlassRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (icon != null) {
            LiquidGlassSurface(
                shape = RoundedCornerShape(12.dp),
                blurRadius = 0.dp,
                tintColor = com.skybridge.compass.android.ui.theme.IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = 0.16f),
                tintAlpha = 0.16f,
                borderAlpha = 0.12f,
                highlightAlpha = 0.06f,
                edgeGlowAlpha = 0.04f,
                shadowElevation = 0.dp,
                contentPadding = PaddingValues(10.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = com.skybridge.compass.android.ui.theme.IOSParityTokens.ColorTokens.CyanAccent,
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            Spacer(modifier = Modifier.width(12.dp))
        }

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            if (!subtitle.isNullOrBlank()) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        if (trailing != null) {
            Spacer(modifier = Modifier.width(10.dp))
            trailing()
        }
    }
}

