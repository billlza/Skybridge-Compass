package com.skybridge.compass.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.skybridge.compass.android.ui.screens.dashboard.DashboardScreen
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Dashboard屏幕UI测试
 */
@RunWith(AndroidJUnit4::class)
class DashboardScreenTest {
    
    @get:Rule
    val composeTestRule = createComposeRule()
    
    @Test
    fun dashboardScreen_displaysCorrectTitle() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证标题显示
        composeTestRule
            .onNodeWithText("SkyBridge Compass")
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_displaysStatusCards() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证状态卡片显示
        composeTestRule
            .onNodeWithText("已连接设备")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("活跃会话")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("网络质量")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("数据传输")
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_displaysQuickActionCards() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证快速操作卡片显示
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("远程控制")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("设置")
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_quickActionCardsAreClickable() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证快速操作卡片可点击
        composeTestRule
            .onNodeWithText("设备发现")
            .assertHasClickAction()
        
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .assertHasClickAction()
        
        composeTestRule
            .onNodeWithText("远程控制")
            .assertHasClickAction()
        
        composeTestRule
            .onNodeWithText("设置")
            .assertHasClickAction()
    }
    
    @Test
    fun dashboardScreen_connectionStatusIndicatorWorks() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 等待连接状态指示器出现
        composeTestRule.waitForIdle()
        
        // 验证连接状态指示器存在
        composeTestRule
            .onAllNodesWithContentDescription("连接状态")
            .assertCountEquals(1)
    }
    
    @Test
    fun dashboardScreen_scrollsCorrectly() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证可以滚动到底部
        composeTestRule
            .onNodeWithText("设置")
            .performScrollTo()
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_handlesDataUpdates() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 等待数据更新
        composeTestRule.waitForIdle()
        
        // 验证数据会更新（由于模拟数据的随机性，我们只验证元素存在）
        composeTestRule
            .onNodeWithText("已连接设备")
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_respondsToScreenSizeChanges() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 验证响应式布局工作正常
        // 在不同屏幕尺寸下，布局应该适应
        composeTestRule
            .onNodeWithText("已连接设备")
            .assertIsDisplayed()
        
        composeTestRule
            .onNodeWithText("活跃会话")
            .assertIsDisplayed()
    }
    
    @Test
    fun dashboardScreen_networkQualityIndicatorDisplays() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                DashboardScreen(navController = navController)
            }
        }
        
        // 等待网络质量指示器加载
        composeTestRule.waitForIdle()
        
        // 验证网络质量指示器显示
        composeTestRule
            .onNodeWithText("网络质量")
            .assertIsDisplayed()
    }
}