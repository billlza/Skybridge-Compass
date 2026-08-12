package com.skybridge.compass.android.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.TrendingDown
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import kotlin.math.cos
import kotlin.math.sin

/**
 * 通用UI组件库
 * 
 * 包含应用中常用的可复用组件
 */

/**
 * 动画状态指示器
 */
@Composable
fun AnimatedStatusIndicator(
    isActive: Boolean,
    modifier: Modifier = Modifier,
    activeColor: Color = MaterialTheme.colorScheme.primary,
    inactiveColor: Color = MaterialTheme.colorScheme.outline
) {
    val infiniteTransition = rememberInfiniteTransition(label = "status_indicator")
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        ),
        label = "alpha_animation"
    )
    
    Box(
        modifier = modifier
            .size(12.dp)
            .clip(CircleShape)
            .background(
                if (isActive) activeColor.copy(alpha = alpha) else inactiveColor
            )
    )
}

/**
 * 渐变卡片
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GradientCard(
    modifier: Modifier = Modifier,
    gradient: Brush = Brush.linearGradient(
        colors = listOf(
            MaterialTheme.colorScheme.primaryContainer,
            MaterialTheme.colorScheme.secondaryContainer
        )
    ),
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier,
        onClick = onClick ?: {},
        enabled = onClick != null,
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(gradient)
                .padding(16.dp),
            content = content
        )
    }
}

/**
 * 圆形进度指示器
 */
@Composable
fun CircularProgressIndicatorWithLabel(
    progress: Float,
    label: String,
    modifier: Modifier = Modifier,
    size: androidx.compose.ui.unit.Dp = 80.dp,
    strokeWidth: androidx.compose.ui.unit.Dp = 8.dp,
    color: Color = MaterialTheme.colorScheme.primary
) {
    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val canvasSize = size.toPx()
            val strokeWidthPx = strokeWidth.toPx()
            val radius = (canvasSize - strokeWidthPx) / 2
            val center = canvasSize / 2
            
            // 背景圆环
            drawCircle(
                color = color.copy(alpha = 0.2f),
                radius = radius,
                center = androidx.compose.ui.geometry.Offset(center, center),
                style = Stroke(width = strokeWidthPx, cap = StrokeCap.Round)
            )
            
            // 进度圆弧
            drawArc(
                color = color,
                startAngle = -90f,
                sweepAngle = 360f * progress,
                useCenter = false,
                style = Stroke(width = strokeWidthPx, cap = StrokeCap.Round),
                topLeft = androidx.compose.ui.geometry.Offset(
                    strokeWidthPx / 2,
                    strokeWidthPx / 2
                ),
                size = androidx.compose.ui.geometry.Size(
                    canvasSize - strokeWidthPx,
                    canvasSize - strokeWidthPx
                )
            )
        }
        
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "${(progress * 100).toInt()}%",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = color
            )
            Text(
                text = label,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * 统计数据卡片
 */
@Composable
fun StatCard(
    title: String,
    value: String,
    modifier: Modifier = Modifier,
    change: String? = null,
    changePositive: Boolean = true,
    icon: ImageVector
) {
    Card(
        modifier = modifier,
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = value,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold
                    )
                    
                    change?.let {
                        Spacer(modifier = Modifier.height(4.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                imageVector = if (changePositive) Icons.AutoMirrored.Filled.TrendingUp else Icons.AutoMirrored.Filled.TrendingDown,
                                contentDescription = null,
                                tint = if (changePositive) Color.Green else Color.Red,
                                modifier = Modifier.size(16.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                text = it,
                                style = MaterialTheme.typography.bodySmall,
                                color = if (changePositive) Color.Green else Color.Red
                            )
                        }
                    }
                }
                
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(32.dp)
                )
            }
        }
    }
}

/**
 * 连接状态指示器
 */
@Composable
fun ConnectionStatusIndicator(
    isConnected: Boolean,
    deviceName: String,
    modifier: Modifier = Modifier
) {
    val connectedText = localizedText("已连接", "Connected", "接続済み")
    val disconnectedText = localizedText("未连接", "Disconnected", "未接続")
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        AnimatedStatusIndicator(
            isActive = isConnected,
            activeColor = Color.Green,
            inactiveColor = Color.Red
        )
        
        Spacer(modifier = Modifier.width(8.dp))
        
        Column {
            Text(
                text = deviceName,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = if (isConnected) connectedText else disconnectedText,
                style = MaterialTheme.typography.bodySmall,
                color = if (isConnected) Color.Green else Color.Red
            )
        }
    }
}

/**
 * 网络质量指示器
 * 使用 Material Icons 的 SignalCellular 系列图标（Android 最佳实践）
 */
@Composable
fun NetworkQualityIndicator(
    quality: String,
    signalStrength: Int, // 0-100
    modifier: Modifier = Modifier
) {
    val signalDescription = localizedText("网络信号：", "Network signal: ", "ネットワーク信号: ")
    val signalIcon = when {
        signalStrength > 75 -> Icons.Default.SignalCellular4Bar
        signalStrength > 50 -> Icons.Default.NetworkCell
        signalStrength > 25 -> Icons.Default.SignalCellularAlt
        signalStrength > 0 -> Icons.Default.SignalCellularAlt1Bar
        else -> Icons.Default.SignalCellularOff
    }
    
    val signalColor = when {
        signalStrength > 75 -> Color(0xFF4CAF50) // Material Green
        signalStrength > 50 -> Color(0xFF8BC34A) // Light Green
        signalStrength > 25 -> Color(0xFFFFC107) // Amber
        else -> Color(0xFFF44336) // Red
    }

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = signalIcon,
            contentDescription = "$signalDescription$quality",
            tint = signalColor,
            modifier = Modifier.size(28.dp)
        )
        
        Spacer(modifier = Modifier.width(8.dp))
        
        Text(
            text = quality,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            color = signalColor
        )
    }
}

@Preview(showBackground = true)
@Composable
fun CommonComponentsPreview() {
    SkyBridgeCompassTheme {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            StatCard(
                title = localizedText("连接设备", "Connected Devices", "接続デバイス"),
                value = "3",
                change = "+1",
                changePositive = true,
                icon = Icons.Default.Devices
            )
            
            ConnectionStatusIndicator(
                isConnected = true,
                deviceName = "MacBook Pro"
            )
            
            NetworkQualityIndicator(
                quality = localizedText("优秀", "Excellent", "優秀"),
                signalStrength = 85
            )
            
            CircularProgressIndicatorWithLabel(
                progress = 0.75f,
                label = "CPU"
            )
        }
    }
}
