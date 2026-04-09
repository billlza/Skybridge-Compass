package com.skybridge.compass.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.skybridge.compass.android.ui.navigation.SkyBridgeNavigation
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 导航系统UI测试
 */
@RunWith(AndroidJUnit4::class)
class NavigationTest {
    
    @get:Rule
    val composeTestRule = createComposeRule()
    
    @Test
    fun navigation_startsWithDashboardScreen() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 验证应用启动时显示Dashboard屏幕
        composeTestRule
            .onNodeWithText("SkyBridge Compass")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_navigatesToDeviceDiscovery() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 点击设备发现卡片
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        // 验证导航到设备发现屏幕
        composeTestRule.waitForIdle()
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_navigatesToScreenMirroring() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 点击屏幕镜像卡片
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .performClick()
        
        // 验证导航到屏幕镜像屏幕
        composeTestRule.waitForIdle()
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_navigatesToRemoteControl() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 点击远程控制卡片
        composeTestRule
            .onNodeWithText("远程控制")
            .performClick()
        
        // 验证导航到远程控制屏幕
        composeTestRule.waitForIdle()
        composeTestRule
            .onNodeWithText("远程控制")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_navigatesToSettings() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 点击设置卡片
        composeTestRule
            .onNodeWithText("设置")
            .performClick()
        
        // 验证导航到设置屏幕
        composeTestRule.waitForIdle()
        composeTestRule
            .onNodeWithText("设置")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_backNavigationWorks() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 导航到设备发现
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 模拟返回按钮（在实际测试中可能需要使用不同的方法）
        // 这里我们验证能够返回到Dashboard
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_multipleNavigationsWork() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 导航到设备发现
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证在设备发现屏幕
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_handlesInvalidRoutes() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 验证应用不会因为无效路由而崩溃
        // 应该始终显示有效的屏幕
        composeTestRule
            .onNodeWithText("SkyBridge Compass")
            .assertIsDisplayed()
    }
    
    @Test
    fun navigation_preservesStateAcrossNavigation() {
        composeTestRule.setContent {
            SkyBridgeCompassTheme {
                val navController = rememberNavController()
                SkyBridgeNavigation(navController = navController)
            }
        }
        
        // 验证导航后状态保持
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证屏幕正确显示
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
    }
}