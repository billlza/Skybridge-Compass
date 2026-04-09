package com.skybridge.compass.shared.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import java.util.Locale

// Color Palette
object AppColors {
    // Primary Colors
    val Primary = Color(0xFF2196F3)
    val PrimaryVariant = Color(0xFF1976D2)
    val Secondary = Color(0xFF03DAC6)
    val SecondaryVariant = Color(0xFF018786)
    
    // Surface Colors
    val Surface = Color(0xFFFFFFFF)
    val SurfaceVariant = Color(0xFFF5F5F5)
    val Background = Color(0xFFFAFAFA)
    val Error = Color(0xFFB00020)
    val Warning = Color(0xFFFF9800)
    val Success = Color(0xFF4CAF50)
    val Info = Color(0xFF2196F3)
    
    // Text Colors
    val OnPrimary = Color(0xFFFFFFFF)
    val OnSecondary = Color(0xFF000000)
    val OnSurface = Color(0xFF000000)
    val OnBackground = Color(0xFF000000)
    val OnError = Color(0xFFFFFFFF)
    
    // Dark Theme Colors
    val DarkPrimary = Color(0xFF90CAF9)
    val DarkPrimaryVariant = Color(0xFF42A5F5)
    val DarkSecondary = Color(0xFF03DAC6)
    val DarkSecondaryVariant = Color(0xFF03DAC6)
    
    val DarkSurface = Color(0xFF121212)
    val DarkSurfaceVariant = Color(0xFF1E1E1E)
    val DarkBackground = Color(0xFF121212)
    val DarkError = Color(0xFFCF6679)
    
    val DarkOnPrimary = Color(0xFF000000)
    val DarkOnSecondary = Color(0xFF000000)
    val DarkOnSurface = Color(0xFFFFFFFF)
    val DarkOnBackground = Color(0xFFFFFFFF)
    val DarkOnError = Color(0xFF000000)
    
    // Status Colors
    val Connected = Color(0xFF4CAF50)
    val Disconnected = Color(0xFFF44336)
    val Connecting = Color(0xFFFF9800)
    val Transferring = Color(0xFF2196F3)
    val Paused = Color(0xFFFF9800)
    val Completed = Color(0xFF4CAF50)
    val Failed = Color(0xFFF44336)
    
    // Gradient Colors
    val GradientStart = Color(0xFF2196F3)
    val GradientEnd = Color(0xFF21CBF3)
    val DarkGradientStart = Color(0xFF1976D2)
    val DarkGradientEnd = Color(0xFF1565C0)
}

// Typography
object AppTypography {
    val displayLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 57.sp,
        lineHeight = 64.sp,
        letterSpacing = (-0.25).sp
    )
    
    val displayMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 45.sp,
        lineHeight = 52.sp,
        letterSpacing = 0.sp
    )
    
    val displaySmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 36.sp,
        lineHeight = 44.sp,
        letterSpacing = 0.sp
    )
    
    val headlineLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 32.sp,
        lineHeight = 40.sp,
        letterSpacing = 0.sp
    )
    
    val headlineMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 28.sp,
        lineHeight = 36.sp,
        letterSpacing = 0.sp
    )
    
    val headlineSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 24.sp,
        lineHeight = 32.sp,
        letterSpacing = 0.sp
    )
    
    val titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = 0.sp
    )
    
    val titleMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.15.sp
    )
    
    val titleSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp
    )
    
    val bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.5.sp
    )
    
    val bodyMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.25.sp
    )
    
    val bodySmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.4.sp
    )
    
    val labelLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp
    )
    
    val labelMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.5.sp
    )
    
    val labelSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.5.sp
    )
}

// Light Color Scheme
private val LightColorScheme = lightColorScheme(
    primary = AppColors.Primary,
    onPrimary = AppColors.OnPrimary,
    primaryContainer = AppColors.PrimaryVariant,
    onPrimaryContainer = AppColors.OnPrimary,
    secondary = AppColors.Secondary,
    onSecondary = AppColors.OnSecondary,
    secondaryContainer = AppColors.SecondaryVariant,
    onSecondaryContainer = AppColors.OnSecondary,
    tertiary = AppColors.Info,
    onTertiary = AppColors.OnPrimary,
    error = AppColors.Error,
    onError = AppColors.OnError,
    errorContainer = AppColors.Error,
    onErrorContainer = AppColors.OnError,
    background = AppColors.Background,
    onBackground = AppColors.OnBackground,
    surface = AppColors.Surface,
    onSurface = AppColors.OnSurface,
    surfaceVariant = AppColors.SurfaceVariant,
    onSurfaceVariant = AppColors.OnSurface,
    outline = Color(0xFF79747E),
    outlineVariant = Color(0xFFCAC4D0),
    scrim = Color(0xFF000000),
    inverseSurface = AppColors.DarkSurface,
    inverseOnSurface = AppColors.DarkOnSurface,
    inversePrimary = AppColors.DarkPrimary,
    surfaceDim = Color(0xFFDDD7E0),
    surfaceBright = Color(0xFFFEF7FF),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF7F2FA),
    surfaceContainer = Color(0xFFF1ECF4),
    surfaceContainerHigh = Color(0xFFECE6F0),
    surfaceContainerHighest = Color(0xFFE6E0E9)
)

// Dark Color Scheme
private val DarkColorScheme = darkColorScheme(
    primary = AppColors.DarkPrimary,
    onPrimary = AppColors.DarkOnPrimary,
    primaryContainer = AppColors.DarkPrimaryVariant,
    onPrimaryContainer = AppColors.DarkOnPrimary,
    secondary = AppColors.DarkSecondary,
    onSecondary = AppColors.DarkOnSecondary,
    secondaryContainer = AppColors.DarkSecondaryVariant,
    onSecondaryContainer = AppColors.DarkOnSecondary,
    tertiary = AppColors.DarkPrimary,
    onTertiary = AppColors.DarkOnPrimary,
    error = AppColors.DarkError,
    onError = AppColors.DarkOnError,
    errorContainer = AppColors.DarkError,
    onErrorContainer = AppColors.DarkOnError,
    background = AppColors.DarkBackground,
    onBackground = AppColors.DarkOnBackground,
    surface = AppColors.DarkSurface,
    onSurface = AppColors.DarkOnSurface,
    surfaceVariant = AppColors.DarkSurfaceVariant,
    onSurfaceVariant = AppColors.DarkOnSurface,
    outline = Color(0xFF938F99),
    outlineVariant = Color(0xFF49454F),
    scrim = Color(0xFF000000),
    inverseSurface = AppColors.Surface,
    inverseOnSurface = AppColors.OnSurface,
    inversePrimary = AppColors.Primary,
    surfaceDim = Color(0xFF141218),
    surfaceBright = Color(0xFF3B383E),
    surfaceContainerLowest = Color(0xFF0F0D13),
    surfaceContainerLow = Color(0xFF1D1B20),
    surfaceContainer = Color(0xFF211F26),
    surfaceContainerHigh = Color(0xFF2B2930),
    surfaceContainerHighest = Color(0xFF36343B)
)

// Typography Configuration
private val Typography = Typography(
    displayLarge = AppTypography.displayLarge,
    displayMedium = AppTypography.displayMedium,
    displaySmall = AppTypography.displaySmall,
    headlineLarge = AppTypography.headlineLarge,
    headlineMedium = AppTypography.headlineMedium,
    headlineSmall = AppTypography.headlineSmall,
    titleLarge = AppTypography.titleLarge,
    titleMedium = AppTypography.titleMedium,
    titleSmall = AppTypography.titleSmall,
    bodyLarge = AppTypography.bodyLarge,
    bodyMedium = AppTypography.bodyMedium,
    bodySmall = AppTypography.bodySmall,
    labelLarge = AppTypography.labelLarge,
    labelMedium = AppTypography.labelMedium,
    labelSmall = AppTypography.labelSmall
)

// Theme Configuration
@Composable
fun SkyBridgeCompassTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false, // Disable dynamic color for consistent branding
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}

// Theme Extensions
@Composable
fun getStatusColor(status: String): Color {
    return when (status.lowercase(Locale.ROOT)) {
        "connected" -> AppColors.Connected
        "disconnected" -> AppColors.Disconnected
        "connecting" -> AppColors.Connecting
        "transferring" -> AppColors.Transferring
        "paused" -> AppColors.Paused
        "completed" -> AppColors.Completed
        "failed" -> AppColors.Failed
        else -> MaterialTheme.colorScheme.onSurface
    }
}

@Composable
fun getConnectionQualityColor(quality: String): Color {
    return when (quality.lowercase(Locale.ROOT)) {
        "excellent" -> AppColors.Success
        "good" -> AppColors.Info
        "fair" -> AppColors.Warning
        "poor" -> AppColors.Error
        else -> MaterialTheme.colorScheme.onSurface
    }
}

// Custom Theme Properties
data class CustomColors(
    val success: Color,
    val warning: Color,
    val info: Color,
    val connected: Color,
    val disconnected: Color,
    val connecting: Color,
    val transferring: Color,
    val paused: Color,
    val completed: Color,
    val failed: Color,
    val gradientStart: Color,
    val gradientEnd: Color
)

val LocalCustomColors = staticCompositionLocalOf {
    CustomColors(
        success = AppColors.Success,
        warning = AppColors.Warning,
        info = AppColors.Info,
        connected = AppColors.Connected,
        disconnected = AppColors.Disconnected,
        connecting = AppColors.Connecting,
        transferring = AppColors.Transferring,
        paused = AppColors.Paused,
        completed = AppColors.Completed,
        failed = AppColors.Failed,
        gradientStart = AppColors.GradientStart,
        gradientEnd = AppColors.GradientEnd
    )
}

@Composable
fun ProvideSkyBridgeTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val customColors = if (darkTheme) {
        CustomColors(
            success = AppColors.Success,
            warning = AppColors.Warning,
            info = AppColors.Info,
            connected = AppColors.Connected,
            disconnected = AppColors.Disconnected,
            connecting = AppColors.Connecting,
            transferring = AppColors.Transferring,
            paused = AppColors.Paused,
            completed = AppColors.Completed,
            failed = AppColors.Failed,
            gradientStart = AppColors.DarkGradientStart,
            gradientEnd = AppColors.DarkGradientEnd
        )
    } else {
        CustomColors(
            success = AppColors.Success,
            warning = AppColors.Warning,
            info = AppColors.Info,
            connected = AppColors.Connected,
            disconnected = AppColors.Disconnected,
            connecting = AppColors.Connecting,
            transferring = AppColors.Transferring,
            paused = AppColors.Paused,
            completed = AppColors.Completed,
            failed = AppColors.Failed,
            gradientStart = AppColors.GradientStart,
            gradientEnd = AppColors.GradientEnd
        )
    }

    CompositionLocalProvider(
        LocalCustomColors provides customColors
    ) {
        SkyBridgeCompassTheme(
            darkTheme = darkTheme,
            content = content
        )
    }
}

// Theme Access Extensions
object SkyBridgeTheme {
    val colors: CustomColors
        @Composable
        get() = LocalCustomColors.current
}