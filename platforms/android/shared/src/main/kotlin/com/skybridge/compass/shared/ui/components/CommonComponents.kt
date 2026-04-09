package com.skybridge.compass.shared.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.TrendingDown
import androidx.compose.material.icons.automirrored.filled.TrendingFlat
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.skybridge.compass.shared.ui.theme.SkyBridgeTheme
import java.util.Locale

/**
 * Status indicator with animated color changes
 */
@Composable
fun StatusIndicator(
    status: String,
    modifier: Modifier = Modifier,
    size: Dp = 12.dp,
    showLabel: Boolean = true
) {
    val statusColor = when (status.lowercase(Locale.ROOT)) {
        "connected" -> SkyBridgeTheme.colors.connected
        "disconnected" -> SkyBridgeTheme.colors.disconnected
        "connecting" -> SkyBridgeTheme.colors.connecting
        "transferring" -> SkyBridgeTheme.colors.transferring
        "paused" -> SkyBridgeTheme.colors.paused
        "completed" -> SkyBridgeTheme.colors.completed
        "failed" -> SkyBridgeTheme.colors.failed
        else -> MaterialTheme.colorScheme.onSurface
    }

    val animatedColor by animateColorAsState(
        targetValue = statusColor,
        animationSpec = tween(300),
        label = "status_color"
    )

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(animatedColor)
        )
        
        if (showLabel) {
            Text(
                text = status.replaceFirstChar { it.titlecase(Locale.ROOT) },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

/**
 * Progress indicator with percentage and status
 */
@Composable
fun ProgressIndicatorWithStatus(
    progress: Float,
    status: String,
    modifier: Modifier = Modifier,
    showPercentage: Boolean = true,
    height: Dp = 8.dp
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            StatusIndicator(
                status = status,
                size = 8.dp,
                showLabel = true
            )
            
            if (showPercentage) {
                Text(
                    text = "${(progress * 100).toInt()}%",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }

        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(height)
                .clip(RoundedCornerShape(height / 2)),
            color = when (status.lowercase(Locale.ROOT)) {
                "transferring" -> SkyBridgeTheme.colors.transferring
                "completed" -> SkyBridgeTheme.colors.completed
                "failed" -> SkyBridgeTheme.colors.failed
                "paused" -> SkyBridgeTheme.colors.paused
                else -> MaterialTheme.colorScheme.primary
            },
            trackColor = MaterialTheme.colorScheme.surfaceVariant
        )
    }
}

/**
 * Gradient card with custom content
 */
@Composable
fun GradientCard(
    modifier: Modifier = Modifier,
    gradient: Brush = Brush.horizontalGradient(
        colors = listOf(
            SkyBridgeTheme.colors.gradientStart,
            SkyBridgeTheme.colors.gradientEnd
        )
    ),
    contentColor: Color = Color.White,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(gradient)
                .padding(16.dp)
        ) {
            CompositionLocalProvider(
                LocalContentColor provides contentColor
            ) {
                Column(content = content)
            }
        }
    }
}

/**
 * Info card with icon and content
 */
@Composable
fun InfoCard(
    title: String,
    subtitle: String? = null,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    iconTint: Color = MaterialTheme.colorScheme.primary,
    onClick: (() -> Unit)? = null
) {
    Card(
        modifier = modifier.then(
            if (onClick != null) {
                Modifier.clickable { onClick() }
            } else {
                Modifier
            }
        ),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(24.dp)
            )
            
            Column(
                modifier = Modifier.weight(1f)
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                
                if (subtitle != null) {
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            
            if (onClick != null) {
                Icon(
                    imageVector = Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

/**
 * Statistics card with value and label
 */
@Composable
fun StatisticsCard(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    valueColor: Color = MaterialTheme.colorScheme.primary,
    trend: StatisticsTrend? = null
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (icon != null) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = valueColor,
                        modifier = Modifier.size(20.dp)
                    )
                }
                
                Text(
                    text = value,
                    style = MaterialTheme.typography.headlineMedium.copy(
                        fontWeight = FontWeight.Bold
                    ),
                    color = valueColor,
                    textAlign = TextAlign.Center
                )
                
                if (trend != null) {
                    TrendIndicator(trend = trend)
                }
            }
            
            Text(
                text = label,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/**
 * Trend indicator for statistics
 */
@Composable
fun TrendIndicator(
    trend: StatisticsTrend,
    modifier: Modifier = Modifier
) {
    val (icon, color) = when (trend.direction) {
        TrendDirection.UP -> Icons.AutoMirrored.Filled.TrendingUp to SkyBridgeTheme.colors.success
        TrendDirection.DOWN -> Icons.AutoMirrored.Filled.TrendingDown to SkyBridgeTheme.colors.failed
        TrendDirection.STABLE -> Icons.AutoMirrored.Filled.TrendingFlat to MaterialTheme.colorScheme.onSurfaceVariant
    }
    
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(16.dp)
        )
        
        if (trend.percentage != null) {
            Text(
                text = "${trend.percentage}%",
                style = MaterialTheme.typography.labelSmall,
                color = color
            )
        }
    }
}

/**
 * Loading indicator with message
 */
@Composable
fun LoadingIndicator(
    message: String = "Loading...",
    modifier: Modifier = Modifier,
    showMessage: Boolean = true
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        CircularProgressIndicator(
            color = MaterialTheme.colorScheme.primary,
            strokeWidth = 3.dp
        )
        
        if (showMessage) {
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}

/**
 * Empty state indicator
 */
@Composable
fun EmptyStateIndicator(
    title: String,
    subtitle: String? = null,
    icon: ImageVector = Icons.Default.Inbox,
    modifier: Modifier = Modifier,
    actionButton: @Composable (() -> Unit)? = null
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(64.dp)
        )
        
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center
        )
        
        if (subtitle != null) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
        
        actionButton?.invoke()
    }
}

/**
 * Error state indicator
 */
@Composable
fun ErrorStateIndicator(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Icon(
            imageVector = Icons.Default.Error,
            contentDescription = null,
            tint = SkyBridgeTheme.colors.failed,
            modifier = Modifier.size(64.dp)
        )
        
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center
        )
        
        if (subtitle != null) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
        
        if (onRetry != null) {
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary
                )
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text("Retry")
            }
        }
    }
}

/**
 * Animated counter
 */
@Composable
fun AnimatedCounter(
    count: Int,
    modifier: Modifier = Modifier,
    style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.headlineMedium,
    color: Color = MaterialTheme.colorScheme.primary
) {
    var animatedCount by remember { mutableStateOf(0) }
    
    LaunchedEffect(count) {
        val animationDuration = 1000L
        val steps = 50
        val stepDuration = animationDuration / steps
        val increment = (count - animatedCount).toFloat() / steps
        
        repeat(steps) { step ->
            animatedCount = (animatedCount + increment * (step + 1)).toInt()
            kotlinx.coroutines.delay(stepDuration)
        }
        animatedCount = count
    }
    
    Text(
        text = animatedCount.toString(),
        modifier = modifier,
        style = style,
        color = color
    )
}

/**
 * Connection quality indicator
 */
@Composable
fun ConnectionQualityIndicator(
    quality: String,
    modifier: Modifier = Modifier,
    showLabel: Boolean = true
) {
    val qualityColor = when (quality.lowercase(Locale.ROOT)) {
        "excellent" -> SkyBridgeTheme.colors.success
        "good" -> SkyBridgeTheme.colors.info
        "fair" -> SkyBridgeTheme.colors.warning
        "poor" -> SkyBridgeTheme.colors.failed
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    
    val bars = when (quality.lowercase(Locale.ROOT)) {
        "excellent" -> 4
        "good" -> 3
        "fair" -> 2
        "poor" -> 1
        else -> 0
    }
    
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.Bottom
        ) {
            repeat(4) { index ->
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .height((8 + index * 3).dp)
                        .background(
                            color = if (index < bars) qualityColor else MaterialTheme.colorScheme.surfaceVariant,
                            shape = RoundedCornerShape(1.dp)
                        )
                )
            }
        }
        
        if (showLabel) {
            Text(
                text = quality.replaceFirstChar { it.titlecase(Locale.ROOT) },
                style = MaterialTheme.typography.bodySmall,
                color = qualityColor
            )
        }
    }
}

/**
 * Speed indicator with units
 */
@Composable
fun SpeedIndicator(
    bytesPerSecond: Long,
    modifier: Modifier = Modifier,
    showIcon: Boolean = true
) {
    val (speed, unit) = formatSpeed(bytesPerSecond)
    
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        if (showIcon) {
            Icon(
                imageVector = Icons.Default.Speed,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp)
            )
        }
        
        Text(
            text = "$speed $unit",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

// Helper functions
private fun formatSpeed(bytesPerSecond: Long): Pair<String, String> {
    return when {
        bytesPerSecond >= 1_000_000_000 -> {
            String.format("%.1f", bytesPerSecond / 1_000_000_000.0) to "GB/s"
        }
        bytesPerSecond >= 1_000_000 -> {
            String.format("%.1f", bytesPerSecond / 1_000_000.0) to "MB/s"
        }
        bytesPerSecond >= 1_000 -> {
            String.format("%.1f", bytesPerSecond / 1_000.0) to "KB/s"
        }
        else -> {
            bytesPerSecond.toString() to "B/s"
        }
    }
}

// Data classes
data class StatisticsTrend(
    val direction: TrendDirection,
    val percentage: Int? = null
)

enum class TrendDirection {
    UP, DOWN, STABLE
}