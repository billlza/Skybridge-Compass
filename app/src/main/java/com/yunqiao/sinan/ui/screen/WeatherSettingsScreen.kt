package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.shared.WeatherMode
import com.yunqiao.sinan.ui.theme.GlassColors
import com.yunqiao.sinan.weather.UnifiedWeatherManager
import com.yunqiao.sinan.weather.WeatherConfig
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeatherSettingsScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val weatherManager = remember { UnifiedWeatherManager.getInstance(context) }
    val weatherConfig by weatherManager.weatherConfig.collectAsState()
    val scope = rememberCoroutineScope()
    
    var showApiKeyDialog by remember { mutableStateOf(false) }
    var tempApiKey by remember { mutableStateOf("") }
    var showApiKey by remember { mutableStateOf(false) }
    
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        // 标题
        WeatherSettingsHeader()
        
        // 基础设置
        BasicSettingsSection(
            weatherConfig = weatherConfig,
            onWeatherEnabledChange = { weatherManager.setWeatherEnabled(it) },
            onShowInMainChange = { /* 更新显示设置 */ },
            onNotificationsChange = { /* 更新通知设置 */ }
        )
        
        // API设置
        ApiSettingsSection(
            weatherConfig = weatherConfig,
            onApiKeyClick = { 
                tempApiKey = weatherConfig.apiKey
                showApiKeyDialog = true 
            }
        )
        
        // 更新设置
        UpdateSettingsSection(
            weatherConfig = weatherConfig,
            onUpdateIntervalChange = { weatherManager.setUpdateInterval(it) },
            onWeatherModeChange = { weatherManager.setWeatherMode(it) }
        )
        
        // 功能设置
        FeatureSettingsSection(
            weatherConfig = weatherConfig,
            onWallpaperEnabledChange = { weatherManager.setWallpaperEnabled(it) }
        )
        
        // 操作按钮
        ActionButtonsSection(
            onRefreshWeather = {
                scope.launch {
                    weatherManager.refreshWeather()
                }
            },
            onResetSettings = {
                // 重置设置的逻辑
            }
        )
    }
    
    // API密钥输入对话框
    if (showApiKeyDialog) {
        ApiKeyDialog(
            currentApiKey = tempApiKey,
            onApiKeyChange = { tempApiKey = it },
            onConfirm = {
                weatherManager.setApiKey(tempApiKey)
                showApiKeyDialog = false
            },
            onDismiss = { showApiKeyDialog = false },
            showApiKey = showApiKey,
            onToggleVisibility = { showApiKey = !showApiKey }
        )
    }
}

@Composable
private fun WeatherSettingsHeader() {
    Row(
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Settings,
            contentDescription = "设置",
            tint = Color.White,
            modifier = Modifier.size(32.dp)
        )
        
        Spacer(modifier = Modifier.width(16.dp))
        
        Column {
            Text(
                text = "天气设置",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Text(
                text = "配置天气功能和API设置",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

@Composable
private fun BasicSettingsSection(
    weatherConfig: WeatherConfig,
    onWeatherEnabledChange: (Boolean) -> Unit,
    onShowInMainChange: (Boolean) -> Unit,
    onNotificationsChange: (Boolean) -> Unit
) {
    SettingsCard(
        title = "基础设置",
        icon = Icons.Default.Settings
    ) {
        SettingsSwitch(
            title = "启用天气功能",
            subtitle = "开启后会自动获取和显示天气信息",
            checked = weatherConfig.enabled,
            onCheckedChange = onWeatherEnabledChange
        )
        
        SettingsSwitch(
            title = "主界面显示",
            subtitle = "在主界面显示天气信息",
            checked = weatherConfig.showInMainScreen,
            onCheckedChange = onShowInMainChange
        )
        
        SettingsSwitch(
            title = "天气通知",
            subtitle = "接收天气变化和预警通知",
            checked = weatherConfig.notificationsEnabled,
            onCheckedChange = onNotificationsChange
        )
    }
}

@Composable
private fun ApiSettingsSection(
    weatherConfig: WeatherConfig,
    onApiKeyClick: () -> Unit
) {
    SettingsCard(
        title = "API设置",
        icon = Icons.Default.Api
    ) {
        SettingsItem(
            title = "Weather API密钥",
            subtitle = if (weatherConfig.apiKey.isNotEmpty()) {
                "已配置 (${weatherConfig.apiKey.take(8)}...)"
            } else {
                "点击设置API密钥以获取真实天气数据"
            },
            onClick = onApiKeyClick,
            trailingIcon = Icons.Default.KeyboardArrowRight
        )
        
        SettingsInfoCard(
            title = "获取免费API密钥",
            content = """
                1. 访问 https://www.weatherapi.com
                2. 注册免费账户
                3. 获取API密钥
                4. 每月免费100万次请求
            """.trimIndent(),
            icon = Icons.Default.Info
        )
    }
}

@Composable
private fun UpdateSettingsSection(
    weatherConfig: WeatherConfig,
    onUpdateIntervalChange: (Long) -> Unit,
    onWeatherModeChange: (WeatherMode) -> Unit
) {
    var showIntervalDialog by remember { mutableStateOf(false) }
    var showModeDialog by remember { mutableStateOf(false) }
    
    SettingsCard(
        title = "更新设置",
        icon = Icons.Default.Update
    ) {
        SettingsItem(
            title = "更新间隔",
            subtitle = "${weatherConfig.updateIntervalMinutes}分钟",
            onClick = { showIntervalDialog = true },
            trailingIcon = Icons.Default.Schedule
        )
        
        SettingsItem(
            title = "天气模式",
            subtitle = when (weatherConfig.weatherMode) {
                WeatherMode.AUTO -> "自动模式"
                WeatherMode.MANUAL -> "手动模式"
                WeatherMode.SIMULATION -> "模拟模式"
                WeatherMode.DISABLED -> "已禁用"
            },
            onClick = { showModeDialog = true },
            trailingIcon = Icons.Default.Tune
        )
    }
    
    // 更新间隔选择对话框
    if (showIntervalDialog) {
        UpdateIntervalDialog(
            currentInterval = weatherConfig.updateIntervalMinutes,
            onIntervalSelected = { interval ->
                onUpdateIntervalChange(interval)
                showIntervalDialog = false
            },
            onDismiss = { showIntervalDialog = false }
        )
    }
    
    // 天气模式选择对话框
    if (showModeDialog) {
        WeatherModeDialog(
            currentMode = weatherConfig.weatherMode,
            onModeSelected = { mode ->
                onWeatherModeChange(mode)
                showModeDialog = false
            },
            onDismiss = { showModeDialog = false }
        )
    }
}

@Composable
private fun FeatureSettingsSection(
    weatherConfig: WeatherConfig,
    onWallpaperEnabledChange: (Boolean) -> Unit
) {
    SettingsCard(
        title = "功能设置",
        icon = Icons.Default.Extension
    ) {
        SettingsSwitch(
            title = "智能壁纸",
            subtitle = "根据天气条件自动切换壁纸",
            checked = weatherConfig.wallpaperEnabled,
            onCheckedChange = onWallpaperEnabledChange
        )
    }
}

@Composable
private fun ActionButtonsSection(
    onRefreshWeather: () -> Unit,
    onResetSettings: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Button(
            onClick = onRefreshWeather,
            modifier = Modifier.weight(1f),
            colors = ButtonDefaults.buttonColors(
                containerColor = GlassColors.highlight
            )
        ) {
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            
            Spacer(modifier = Modifier.width(8.dp))
            
            Text("刷新天气")
        }
        
        OutlinedButton(
            onClick = onResetSettings,
            modifier = Modifier.weight(1f),
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = Color.White
            )
        ) {
            Icon(
                imageVector = Icons.Default.RestartAlt,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            
            Spacer(modifier = Modifier.width(8.dp))
            
            Text("重置设置")
        }
    }
}

@Composable
private fun SettingsCard(
    title: String,
    icon: ImageVector,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = title,
                    tint = GlassColors.highlight,
                    modifier = Modifier.size(24.dp)
                )
                
                Spacer(modifier = Modifier.width(12.dp))
                
                Text(
                    text = title,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White
                )
            }
            
            content()
        }
    }
}

@Composable
private fun SettingsSwitch(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f)
        ) {
            Text(
                text = title,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White
            )
            
            Text(
                text = subtitle,
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
        
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = GlassColors.highlight,
                checkedTrackColor = GlassColors.highlight.copy(alpha = 0.5f)
            )
        )
    }
}

@Composable
private fun SettingsItem(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    trailingIcon: ImageVector
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                color = Color.White.copy(alpha = 0.05f),
                shape = RoundedCornerShape(8.dp)
            )
            .padding(16.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f)
        ) {
            Text(
                text = title,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White
            )
            
            Text(
                text = subtitle,
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
        
        IconButton(onClick = onClick) {
            Icon(
                imageVector = trailingIcon,
                contentDescription = null,
                tint = GlassColors.highlight,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

@Composable
private fun SettingsInfoCard(
    title: String,
    content: String,
    icon: ImageVector
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = Color.White.copy(alpha = 0.05f)
        ),
        shape = RoundedCornerShape(8.dp)
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = GlassColors.highlight,
                modifier = Modifier.size(20.dp)
            )
            
            Column {
                Text(
                    text = title,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White
                )
                
                Spacer(modifier = Modifier.height(4.dp))
                
                Text(
                    text = content,
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f),
                    lineHeight = 16.sp
                )
            }
        }
    }
}

@Composable
private fun ApiKeyDialog(
    currentApiKey: String,
    onApiKeyChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    showApiKey: Boolean,
    onToggleVisibility: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = "设置API密钥",
                color = Color.White
            )
        },
        text = {
            Column {
                Text(
                    text = "请输入您的WeatherAPI密钥",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 14.sp
                )
                
                Spacer(modifier = Modifier.height(16.dp))
                
                OutlinedTextField(
                    value = currentApiKey,
                    onValueChange = onApiKeyChange,
                    label = { Text("API密钥") },
                    visualTransformation = if (showApiKey) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = onToggleVisibility) {
                            Icon(
                                imageVector = if (showApiKey) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showApiKey) "隐藏" else "显示"
                            )
                        }
                    },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = GlassColors.highlight,
                        unfocusedBorderColor = Color.White.copy(alpha = 0.3f),
                        focusedLabelColor = GlassColors.highlight,
                        unfocusedLabelColor = Color.White.copy(alpha = 0.7f)
                    ),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = GlassColors.highlight
                )
            ) {
                Text("确认")
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = Color.White.copy(alpha = 0.7f)
                )
            ) {
                Text("取消")
            }
        },
        containerColor = GlassColors.background
    )
}

@Composable
private fun UpdateIntervalDialog(
    currentInterval: Long,
    onIntervalSelected: (Long) -> Unit,
    onDismiss: () -> Unit
) {
    val intervals = listOf(
        15L to "15分钟",
        30L to "30分钟",
        60L to "1小时", 
        120L to "2小时",
        360L to "6小时"
    )
    
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = "选择更新间隔",
                color = Color.White
            )
        },
        text = {
            Column {
                intervals.forEach { (interval, label) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = currentInterval == interval,
                            onClick = { onIntervalSelected(interval) },
                            colors = RadioButtonDefaults.colors(
                                selectedColor = GlassColors.highlight,
                                unselectedColor = Color.White.copy(alpha = 0.7f)
                            )
                        )
                        
                        Spacer(modifier = Modifier.width(8.dp))
                        
                        Text(
                            text = label,
                            color = Color.White,
                            fontSize = 16.sp
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = GlassColors.highlight
                )
            ) {
                Text("确认")
            }
        },
        containerColor = GlassColors.background
    )
}

@Composable
private fun WeatherModeDialog(
    currentMode: WeatherMode,
    onModeSelected: (WeatherMode) -> Unit,
    onDismiss: () -> Unit
) {
    val modes = listOf(
        WeatherMode.AUTO to "自动模式",
        WeatherMode.MANUAL to "手动模式",
        WeatherMode.SIMULATION to "模拟模式",
        WeatherMode.DISABLED to "已禁用"
    )
    
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = "选择天气模式",
                color = Color.White
            )
        },
        text = {
            Column {
                modes.forEach { (mode, label) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = currentMode == mode,
                            onClick = { onModeSelected(mode) },
                            colors = RadioButtonDefaults.colors(
                                selectedColor = GlassColors.highlight,
                                unselectedColor = Color.White.copy(alpha = 0.7f)
                            )
                        )
                        
                        Spacer(modifier = Modifier.width(8.dp))
                        
                        Text(
                            text = label,
                            color = Color.White,
                            fontSize = 16.sp
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = GlassColors.highlight
                )
            ) {
                Text("确认")
            }
        },
        containerColor = GlassColors.background
    )
}