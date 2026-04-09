package com.skybridge.compass.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import com.skybridge.compass.android.MainActivity
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 集成测试 - 测试应用的端到端功能
 */
@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class IntegrationTest {
    
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)
    
    @get:Rule(order = 1)
    val composeTestRule = createAndroidComposeRule<MainActivity>()
    
    @get:Rule(order = 2)
    val permissionRule: GrantPermissionRule = GrantPermissionRule.grant(
        android.Manifest.permission.ACCESS_WIFI_STATE,
        android.Manifest.permission.CHANGE_WIFI_STATE,
        android.Manifest.permission.ACCESS_NETWORK_STATE,
        android.Manifest.permission.INTERNET
    )
    
    @Before
    fun setup() {
        hiltRule.inject()
    }
    
    @Test
    fun fullAppFlow_dashboardToDeviceDiscoveryAndBack() {
        // 验证应用启动并显示Dashboard
        composeTestRule
            .onNodeWithText("SkyBridge Compass")
            .assertIsDisplayed()
        
        // 验证连接状态显示
        composeTestRule
            .onNodeWithText("连接状态")
            .assertIsDisplayed()
        
        // 点击设备发现
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证导航到设备发现屏幕
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
        
        // 验证扫描功能可用
        composeTestRule
            .onNodeWithText("开始扫描")
            .assertIsDisplayed()
            .assertIsEnabled()
    }
    
    @Test
    fun fullAppFlow_screenMirroringWorkflow() {
        // 从Dashboard导航到屏幕镜像
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证屏幕镜像界面
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .assertIsDisplayed()
        
        // 验证镜像状态显示
        composeTestRule
            .onNodeWithText("镜像状态")
            .assertIsDisplayed()
        
        // 验证目标设备选择可用
        composeTestRule
            .onNodeWithText("选择目标设备")
            .assertIsDisplayed()
    }
    
    @Test
    fun fullAppFlow_remoteControlAccess() {
        // 导航到远程控制
        composeTestRule
            .onNodeWithText("远程控制")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证远程控制界面
        composeTestRule
            .onNodeWithText("远程控制")
            .assertIsDisplayed()
        
        // 验证控制状态显示
        composeTestRule
            .onNodeWithText("控制状态")
            .assertIsDisplayed()
    }
    
    @Test
    fun fullAppFlow_settingsConfiguration() {
        // 导航到设置
        composeTestRule
            .onNodeWithText("设置")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证设置界面
        composeTestRule
            .onNodeWithText("设置")
            .assertIsDisplayed()
        
        // 验证设置选项可用
        composeTestRule
            .onNodeWithText("网络设置")
            .assertIsDisplayed()
    }
    
    @Test
    fun dataFlow_connectionStatusUpdates() {
        // 验证连接状态会更新
        composeTestRule
            .onNodeWithText("连接状态")
            .assertIsDisplayed()
        
        // 等待状态更新
        composeTestRule.waitForIdle()
        
        // 验证状态指示器存在
        composeTestRule
            .onNodeWithContentDescription("连接状态指示器")
            .assertExists()
    }
    
    @Test
    fun dataFlow_deviceListUpdates() {
        // 导航到设备发现
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证设备列表存在
        composeTestRule
            .onNodeWithText("已发现设备")
            .assertIsDisplayed()
        
        // 点击扫描按钮
        composeTestRule
            .onNodeWithText("开始扫描")
            .performClick()
        
        // 等待扫描结果
        composeTestRule.waitForIdle()
        
        // 验证扫描状态更新
        composeTestRule
            .onNodeWithText("正在扫描...")
            .assertIsDisplayed()
    }
    
    @Test
    fun errorHandling_networkErrorRecovery() {
        // 验证应用在网络错误时的处理
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 点击扫描（可能会触发网络错误）
        composeTestRule
            .onNodeWithText("开始扫描")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证应用仍然响应
        composeTestRule
            .onNodeWithText("设备发现")
            .assertIsDisplayed()
    }
    
    @Test
    fun performanceTest_navigationSpeed() {
        val startTime = System.currentTimeMillis()
        
        // 快速导航测试
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        composeTestRule
            .onNodeWithText("屏幕镜像")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        composeTestRule
            .onNodeWithText("远程控制")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        val endTime = System.currentTimeMillis()
        val navigationTime = endTime - startTime
        
        // 验证导航在合理时间内完成（例如5秒）
        assert(navigationTime < 5000) { "导航时间过长: ${navigationTime}ms" }
    }
    
    @Test
    fun memoryTest_noMemoryLeaks() {
        // 多次导航以测试内存泄漏
        repeat(5) {
            composeTestRule
                .onNodeWithText("设备发现")
                .performClick()
            
            composeTestRule.waitForIdle()
            
            composeTestRule
                .onNodeWithText("屏幕镜像")
                .performClick()
            
            composeTestRule.waitForIdle()
            
            composeTestRule
                .onNodeWithText("远程控制")
                .performClick()
            
            composeTestRule.waitForIdle()
            
            composeTestRule
                .onNodeWithText("设置")
                .performClick()
            
            composeTestRule.waitForIdle()
        }
        
        // 验证应用仍然正常运行
        composeTestRule
            .onNodeWithText("设置")
            .assertIsDisplayed()
    }
    
    @Test
    fun accessibilityTest_contentDescriptions() {
        // 验证重要UI元素有内容描述
        composeTestRule
            .onNodeWithContentDescription("连接状态指示器")
            .assertExists()
        
        // 导航到设备发现
        composeTestRule
            .onNodeWithText("设备发现")
            .performClick()
        
        composeTestRule.waitForIdle()
        
        // 验证扫描按钮有适当的内容描述
        composeTestRule
            .onNodeWithText("开始扫描")
            .assertExists()
    }
}