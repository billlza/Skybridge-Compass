package com.yunqiao.sinan.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

// Material Design 3 动态配色方案 - 深色主题
private val MD3DarkColorScheme = darkColorScheme(
    primary = Color(0xFF90CAF9),
    onPrimary = Color(0xFF003258),
    primaryContainer = Color(0xFF00497D),
    onPrimaryContainer = Color(0xFFCAE6FF),
    secondary = Color(0xFF7DD3C0),
    onSecondary = Color(0xFF003831),
    secondaryContainer = Color(0xFF005048),
    onSecondaryContainer = Color(0xFF9AF0DD),
    tertiary = Color(0xFFFFB3BA),
    onTertiary = Color(0xFF5F1123),
    tertiaryContainer = Color(0xFF7D2939),
    onTertiaryContainer = Color(0xFFFFD9DC),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF0F1419),
    onBackground = Color(0xFFE1E2E8),
    surface = Color(0xFF0F1419),
    onSurface = Color(0xFFE1E2E8),
    surfaceVariant = Color(0xFF42474E),
    onSurfaceVariant = Color(0xFFC2C7CF),
    outline = Color(0xFF8C9199),
    outlineVariant = Color(0xFF42474E),
    scrim = Color(0xFF000000),
    inverseSurface = Color(0xFFE1E2E8),
    inverseOnSurface = Color(0xFF2E3036),
    inversePrimary = Color(0xFF0061A4),
    surfaceDim = Color(0xFF0F1419),
    surfaceBright = Color(0xFF35393F),
    surfaceContainerLowest = Color(0xFF0A0E13),
    surfaceContainerLow = Color(0xFF171C21),
    surfaceContainer = Color(0xFF1B2025),
    surfaceContainerHigh = Color(0xFF252A30),
    surfaceContainerHighest = Color(0xFF30353B)
)

// Material Design 3 动态配色方案 - 浅色主题
private val MD3LightColorScheme = lightColorScheme(
    primary = Color(0xFF0061A4),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD1E4FF),
    onPrimaryContainer = Color(0xFF001D36),
    secondary = Color(0xFF006B5D),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFF9AF0DD),
    onSecondaryContainer = Color(0xFF00201B),
    tertiary = Color(0xFF9C4052),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFD9DC),
    onTertiaryContainer = Color(0xFF3E0713),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFF8F9FF),
    onBackground = Color(0xFF191C20),
    surface = Color(0xFFF8F9FF),
    onSurface = Color(0xFF191C20),
    surfaceVariant = Color(0xFFDFE2EB),
    onSurfaceVariant = Color(0xFF42474E),
    outline = Color(0xFF73777F),
    outlineVariant = Color(0xFFC2C7CF),
    scrim = Color(0xFF000000),
    inverseSurface = Color(0xFF2E3036),
    inverseOnSurface = Color(0xFFF0F0F7),
    inversePrimary = Color(0xFF9FCAFF),
    surfaceDim = Color(0xFFD8D9E0),
    surfaceBright = Color(0xFFF8F9FF),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF2F3FA),
    surfaceContainer = Color(0xFFECEDF4),
    surfaceContainerHigh = Color(0xFFE6E7EE),
    surfaceContainerHighest = Color(0xFFE1E2E8)
)

// 现代化液态玻璃效果增强色彩系统
object ModernGlassColors {
    // 基础玻璃效果
    val background = Color(0x99000000) // 60% 透明度，更现代
    val surface = Color(0x1AFFFFFF) // 10% 透明白色，更精致
    val border = Color(0x33FFFFFF) // 20% 透明白色边框
    val highlight = Color(0x0DFFFFFF) // 5% 微妙高光
    
    // 动态渐变色彩
    val gradientStart = Color(0xFF1976D2)
    val gradientEnd = Color(0xFF42A5F5)
    val gradientAccent = Color(0xFF7C4DFF)
    
    // 选中状态渐变
    val gradientSelectedStart = Color(0xFF6200EA)
    val gradientSelectedEnd = Color(0xFF3F51B5)
    
    // 状态指示色彩
    val successGradientStart = Color(0xFF00C853)
    val successGradientEnd = Color(0xFF4CAF50)
    val warningGradientStart = Color(0xFFFF6F00)
    val warningGradientEnd = Color(0xFFFF9800)
    val errorGradientStart = Color(0xFFD50000)
    val errorGradientEnd = Color(0xFFF44336)
    
    // 现代毛玻璃效果
    val frostedGlass = Color(0x40FFFFFF)
    val deepFrostedGlass = Color(0x60000000)
    
    // 材质层次阴影
    val elevationTint = Color(0x0A000000)
    val softShadow = Color(0x1A000000)
    val mediumShadow = Color(0x33000000)
    val hardShadow = Color(0x4D000000)
}

// 兼容性别名 - 为了支持旧代码中的GlassColors引用
val GlassColors = ModernGlassColors

// 动画颜色扩展
object AnimatedColors {
    val shimmerHighlight = Color(0x33FFFFFF)
    val shimmerBase = Color(0x1AFFFFFF)
    val pulseColor = Color(0xFF6200EA)
    val rippleColor = Color(0x1A6200EA)
}

// 现代化形状系统
val ModernShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

// 主题状态管理
val LocalThemeIsDark = staticCompositionLocalOf { true }
val LocalUseDynamicColor = staticCompositionLocalOf { true }

@Composable
fun YunQiaoSiNanTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            // 动态配色仅在 Android S (API 31) 及以上版本可用
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> MD3DarkColorScheme
        else -> MD3LightColorScheme
    }

    CompositionLocalProvider(
        LocalThemeIsDark provides darkTheme,
        LocalUseDynamicColor provides dynamicColor
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = ModernTypography,
            shapes = ModernShapes,
            content = content
        )
    }
}