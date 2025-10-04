package com.yunqiao.sinan.ui.component

import android.os.Build
import androidx.compose.animation.core.*
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.ripple.rememberRipple
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.data.NavigationItem
import com.yunqiao.sinan.ui.theme.AnimatedColors
import com.yunqiao.sinan.ui.theme.LocalThemeIsDark
import com.yunqiao.sinan.ui.theme.LocalUseDynamicColor
import com.yunqiao.sinan.ui.theme.ModernGlassColors
import com.yunqiao.sinan.ui.theme.ModernShapes

/**
 * 现代化液态玻璃效果侧边栏
 * 实现Material Design 3规范，支持流畅动画和现代美学设计
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SideNavigation(
    navigationItems: List<NavigationItem>,
    selectedRoute: String,
    onItemClick: (String) -> Unit,
    onThemeChange: ((Boolean, Boolean) -> Unit)? = null,
    modifier: Modifier = Modifier,
    drawerProgress: Float = 1f
) {
    val isDarkTheme = LocalThemeIsDark.current
    val colorScheme = MaterialTheme.colorScheme

    // 动态背景动画
    val infiniteTransition = rememberInfiniteTransition(label = "background")
    val backgroundShimmer by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(3000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "shimmer"
    )
    
    val progress = drawerProgress.coerceIn(0f, 1f)
    val glassBlur = lerp(0.5.dp, 18.dp, progress)
    val elevation = lerp(0.dp, 12.dp, progress)
    val overlayAlpha = 0.72f + 0.2f * progress

    Surface(
        modifier = modifier
            .fillMaxHeight()
            .width(280.dp),
        shape = RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp),
        color = Color.Transparent,
        tonalElevation = elevation
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            colorScheme.surface.copy(alpha = overlayAlpha),
                            colorScheme.surface.copy(alpha = overlayAlpha + 0.08f),
                            colorScheme.surface.copy(alpha = overlayAlpha)
                        ),
                        startY = 0f,
                        endY = Float.POSITIVE_INFINITY
                    ),
                    shape = RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp)
                )
                // 毛玻璃效果
                .blur(radius = glassBlur)
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            colorScheme.outline.copy(alpha = 0.2f),
                            colorScheme.outline.copy(alpha = 0.1f),
                            colorScheme.outline.copy(alpha = 0.2f)
                        )
                    ),
                    shape = RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp)
                )
                .clip(RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp))
                .graphicsLayer {
                    val offset = (1f - progress) * -24f
                    translationX = offset
                    alpha = 0.85f + 0.15f * progress
                }
                .padding(vertical = 32.dp, horizontal = 20.dp)
        ) {
            Column {
                // 应用标题区域
                ModernAppHeader(
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 16.dp)
                )
                
                Spacer(modifier = Modifier.height(40.dp))
                
                // 导航菜单列表
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    items(navigationItems) { item ->
                        ModernNavigationItemView(
                            item = item,
                            isSelected = item.route == selectedRoute,
                            onClick = { onItemClick(item.route) }
                        )
                    }
                }
                
                Spacer(modifier = Modifier.height(32.dp))
                
                // 主题切换区域
                if (onThemeChange != null) {
                    ModernThemeControls(
                        onThemeChange = onThemeChange,
                        modifier = Modifier.padding(horizontal = 8.dp)
                    )
                }
            }
        }
    }
}

/**
 * 现代化应用标题区域
 */
@Composable
fun ModernAppHeader(
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 应用图标（现代化设计）
        Surface(
            modifier = Modifier.size(48.dp),
            shape = CircleShape,
            color = Color.Transparent
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                colorScheme.primary,
                                colorScheme.secondary,
                                colorScheme.tertiary
                            )
                        ),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "云",
                    style = MaterialTheme.typography.titleLarge,
                    color = colorScheme.onPrimary,
                    fontWeight = FontWeight.Bold
                )
            }
        }
        
        Spacer(modifier = Modifier.width(16.dp))
        
        Column {
            Text(
                text = "云桥司南",
                style = MaterialTheme.typography.titleLarge,
                color = colorScheme.onSurface,
                fontWeight = FontWeight.Bold
            )
            
            Text(
                text = "SkyBridge Compass",
                style = MaterialTheme.typography.bodySmall,
                color = colorScheme.onSurface.copy(alpha = 0.7f)
            )
        }
    }
}

/**
 * 现代化导航项组件
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModernNavigationItemView(
    item: NavigationItem,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val interactionSource = remember { MutableInteractionSource() }
    
    // 选中动画
    val animatedProgress by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "selection"
    )
    
    // 颜色动画
    val animatedBackgroundColor by animateColorAsState(
        targetValue = if (isSelected) {
            colorScheme.primaryContainer.copy(alpha = 0.9f)
        } else {
            Color.Transparent
        },
        animationSpec = tween(300),
        label = "background"
    )
    
    val animatedIconColor by animateColorAsState(
        targetValue = if (isSelected) {
            colorScheme.onPrimaryContainer
        } else {
            colorScheme.onSurface.copy(alpha = 0.7f)
        },
        animationSpec = tween(300),
        label = "icon"
    )
    
    val animatedTextColor by animateColorAsState(
        targetValue = if (isSelected) {
            colorScheme.onPrimaryContainer
        } else {
            colorScheme.onSurface.copy(alpha = 0.8f)
        },
        animationSpec = tween(300),
        label = "text"
    )
    
    // 缩放动画
    val scale by animateFloatAsState(
        targetValue = if (isSelected) 1.02f else 1f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "scale"
    )
    
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .scale(scale)
            .graphicsLayer {
                shadowElevation = if (isSelected) 8.dp.toPx() else 0.dp.toPx()
            },
        shape = ModernShapes.large,
        color = animatedBackgroundColor,
        interactionSource = interactionSource
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 图标容器
            Surface(
                shape = CircleShape,
                color = if (isSelected) {
                    colorScheme.primary.copy(alpha = 0.2f)
                } else {
                    Color.Transparent
                },
                modifier = Modifier.size(32.dp)
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize()
                ) {
                    Icon(
                        imageVector = item.icon,
                        contentDescription = item.title,
                        tint = animatedIconColor,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
            
            Spacer(modifier = Modifier.width(16.dp))
            
            Text(
                text = item.title,
                style = MaterialTheme.typography.bodyLarge,
                color = animatedTextColor,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal
            )
            
            Spacer(modifier = Modifier.weight(1f))
            
            // 选中指示器
            if (isSelected) {
                Surface(
                    shape = CircleShape,
                    color = colorScheme.primary,
                    modifier = Modifier
                        .size(6.dp)
                        .scale(animatedProgress)
                ) {}
            }
        }
    }
}

/**
 * 现代化主题控制组件
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModernThemeControls(
    onThemeChange: (Boolean, Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val isDarkTheme = LocalThemeIsDark.current
    val useDynamicColor = LocalUseDynamicColor.current
    
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ModernShapes.large,
        color = colorScheme.surfaceContainer.copy(alpha = 0.7f),
        tonalElevation = 2.dp
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                text = "主题设置",
                style = MaterialTheme.typography.titleMedium,
                color = colorScheme.onSurfaceVariant,
                fontWeight = FontWeight.SemiBold
            )
            
            // 深色/浅色主题切换
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "深色主题",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "当前: ${if (isDarkTheme) "深色" else "浅色"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }
                
                Switch(
                    checked = isDarkTheme,
                    onCheckedChange = { darkMode ->
                        onThemeChange(darkMode, useDynamicColor)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.primary,
                        checkedTrackColor = colorScheme.primaryContainer,
                        uncheckedThumbColor = colorScheme.outline,
                        uncheckedTrackColor = colorScheme.surfaceVariant
                    )
                )
            }
            
            // 动态配色切换
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "动态配色",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "Material You 个性化颜色",
                        style = MaterialTheme.typography.bodySmall,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }
                
                Switch(
                    checked = useDynamicColor,
                    onCheckedChange = { dynamic ->
                        onThemeChange(isDarkTheme, dynamic)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.primary,
                        checkedTrackColor = colorScheme.primaryContainer,
                        uncheckedThumbColor = colorScheme.outline,
                        uncheckedTrackColor = colorScheme.surfaceVariant
                    )
                )
            }
            
            // 主题预览
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item {
                    ThemePreviewCard(
                        name = "主色",
                        color = colorScheme.primary,
                        isSelected = true
                    )
                }
                item {
                    ThemePreviewCard(
                        name = "次色",
                        color = colorScheme.secondary
                    )
                }
                item {
                    ThemePreviewCard(
                        name = "第三色",
                        color = colorScheme.tertiary
                    )
                }
            }
        }
    }
}

/**
 * 主题预览卡片
 */
@Composable
fun ThemePreviewCard(
    name: String,
    color: Color,
    isSelected: Boolean = false,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    
    Surface(
        modifier = modifier.size(width = 60.dp, height = 40.dp),
        shape = ModernShapes.small,
        color = color,
        border = if (isSelected) {
            BorderStroke(2.dp, colorScheme.outline)
        } else null
    ) {
        Box(
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = name,
                style = MaterialTheme.typography.labelSmall,
                color = if (color.luminance() > 0.5f) Color.Black else Color.White
            )
        }
    }
}