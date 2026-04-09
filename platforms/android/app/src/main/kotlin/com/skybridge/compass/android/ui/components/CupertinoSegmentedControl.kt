package com.skybridge.compass.android.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * iOS-like segmented control.
 * - Glass container + animated capsule indicator
 * - Subtle opacity changes (Apple-like)
 */
@Composable
fun CupertinoSegmentedControl(
    items: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 40.dp
) {
    if (items.isEmpty()) return
    val clampedIndex = selectedIndex.coerceIn(0, items.lastIndex)

    BoxWithConstraints(modifier = modifier) {
        val segmentWidth = maxWidth / items.size
        val indicatorOffset = animateDpAsState(
            targetValue = segmentWidth * clampedIndex,
            animationSpec = spring(stiffness = Spring.StiffnessMediumLow, dampingRatio = 0.92f),
            label = "segmentedIndicatorOffset"
        )

        LiquidGlassSurface(
            modifier = Modifier
                .fillMaxWidth()
                .height(height),
            shape = RoundedCornerShape(999.dp),
            blurRadius = 0.dp,
            tintColor = Color(0xFFE5E5EA).copy(alpha = 0.95f), // iOS segmented control background
            tintAlpha = 0.95f,
            borderAlpha = 0.08f,
            highlightAlpha = 0f,
            edgeGlowAlpha = 0f,
            shadowElevation = 0.dp,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                // Selected capsule
                Box(
                    modifier = Modifier
                        .padding(3.dp)
                        .width(segmentWidth - 6.dp)
                        .height(height - 6.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .align(Alignment.CenterStart)
                        .padding(start = indicatorOffset.value)
                ) {
                    LiquidGlassSurface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(999.dp),
                        blurRadius = 0.dp,
                        tintColor = Color.White.copy(alpha = 0.98f), // iOS selected segment
                        tintAlpha = 0.98f,
                        borderAlpha = 0.05f,
                        highlightAlpha = 0f,
                        edgeGlowAlpha = 0f,
                        shadowElevation = 0.dp,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)
                    ) {}
                }

                Row(modifier = Modifier.fillMaxWidth()) {
                    items.forEachIndexed { index, label ->
                        val selected = index == clampedIndex
                        val alpha = animateFloatAsState(
                            targetValue = if (selected) 1f else 0.7f,
                            animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 1.0f),
                            label = "segmentedTextAlpha"
                        )
                        Box(
                            modifier = Modifier
                                .width(segmentWidth)
                                .height(height)
                                .clip(RoundedCornerShape(999.dp))
                                .clickable { onSelect(index) },
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = label,
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                                color = if (selected) Color(0xFF1C1C1E) else Color(0xFF8E8E93), // iOS text colors
                                modifier = Modifier.alpha(alpha.value)
                            )
                        }
                    }
                }
            }
        }
    }
}


