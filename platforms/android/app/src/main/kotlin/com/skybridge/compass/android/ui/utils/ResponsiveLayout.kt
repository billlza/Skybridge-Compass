package com.skybridge.compass.android.ui.utils

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 响应式布局工具类
 * 根据屏幕尺寸提供不同的布局参数
 */
object ResponsiveLayout {
    
    /**
     * 屏幕尺寸类型
     */
    enum class ScreenSize {
        COMPACT,    // 小屏幕 (< 600dp)
        MEDIUM,     // 中等屏幕 (600dp - 840dp)
        EXPANDED    // 大屏幕 (> 840dp)
    }
    
    /**
     * 获取当前屏幕尺寸类型
     */
    @Composable
    fun getScreenSize(): ScreenSize {
        val windowSize = LocalWindowInfo.current.containerSize
        val screenWidth = with(LocalDensity.current) { windowSize.width.toDp() }
        
        return when {
            screenWidth < 600.dp -> ScreenSize.COMPACT
            screenWidth < 840.dp -> ScreenSize.MEDIUM
            else -> ScreenSize.EXPANDED
        }
    }
    
    /**
     * 获取响应式的列数
     */
    @Composable
    fun getColumnCount(): Int {
        return when (getScreenSize()) {
            ScreenSize.COMPACT -> 1
            ScreenSize.MEDIUM -> 2
            ScreenSize.EXPANDED -> 3
        }
    }
    
    /**
     * 获取响应式的内边距
     */
    @Composable
    fun getPadding(): Dp {
        return when (getScreenSize()) {
            ScreenSize.COMPACT -> 16.dp
            ScreenSize.MEDIUM -> 24.dp
            ScreenSize.EXPANDED -> 32.dp
        }
    }
    
    /**
     * 获取响应式的间距
     */
    @Composable
    fun getSpacing(): Dp {
        return when (getScreenSize()) {
            ScreenSize.COMPACT -> 12.dp
            ScreenSize.MEDIUM -> 16.dp
            ScreenSize.EXPANDED -> 20.dp
        }
    }
    
    /**
     * 获取响应式的卡片宽度
     */
    @Composable
    fun getCardWidth(): Dp {
        return when (getScreenSize()) {
            ScreenSize.COMPACT -> 280.dp
            ScreenSize.MEDIUM -> 320.dp
            ScreenSize.EXPANDED -> 360.dp
        }
    }
    
    /**
     * 判断是否为横屏模式
     */
    @Composable
    fun isLandscape(): Boolean {
        val windowSize = LocalWindowInfo.current.containerSize
        return windowSize.width > windowSize.height
    }
    
    /**
     * 获取响应式的网格布局参数
     */
    @Composable
    fun getGridLayoutParams(): GridLayoutParams {
        val screenSize = getScreenSize()
        val isLandscape = isLandscape()
        
        return when (screenSize) {
            ScreenSize.COMPACT -> GridLayoutParams(
                columns = if (isLandscape) 2 else 1,
                padding = 16.dp,
                spacing = 12.dp
            )
            ScreenSize.MEDIUM -> GridLayoutParams(
                columns = if (isLandscape) 3 else 2,
                padding = 24.dp,
                spacing = 16.dp
            )
            ScreenSize.EXPANDED -> GridLayoutParams(
                columns = if (isLandscape) 4 else 3,
                padding = 32.dp,
                spacing = 20.dp
            )
        }
    }
}

/**
 * 网格布局参数数据类
 */
data class GridLayoutParams(
    val columns: Int,
    val padding: Dp,
    val spacing: Dp
)

/**
 * 响应式布局扩展函数
 */
@Composable
fun <T> T.responsive(
    compact: T,
    medium: T = compact,
    expanded: T = medium
): T {
    return when (ResponsiveLayout.getScreenSize()) {
        ResponsiveLayout.ScreenSize.COMPACT -> compact
        ResponsiveLayout.ScreenSize.MEDIUM -> medium
        ResponsiveLayout.ScreenSize.EXPANDED -> expanded
    }
}
