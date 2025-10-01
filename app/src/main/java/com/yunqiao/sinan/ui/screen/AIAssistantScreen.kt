package com.yunqiao.sinan.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

data class ChatMessage(
    val id: String,
    val content: String,
    val isUser: Boolean,
    val timestamp: Long = System.currentTimeMillis()
)

@Composable
fun AIAssistantScreen(
    modifier: Modifier = Modifier
) {
    var messages by remember { 
        mutableStateOf(
            listOf(
                ChatMessage(
                    id = "welcome",
                    content = "您好！我是云桥司南的AI助手，有什么可以帮助您的吗？",
                    isUser = false
                )
            )
        )
    }
    var inputText by remember { mutableStateOf(TextFieldValue("")) }
    var isProcessing by remember { mutableStateOf(false) }
    
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                color = Color.Transparent,
                shape = RoundedCornerShape(16.dp)
            )
            .padding(24.dp)
    ) {
        // AI助手标题
        AIAssistantHeader()
        
        Spacer(modifier = Modifier.height(24.dp))
        
        // 对话区域
        Card(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = GlassColors.background
            ),
            shape = RoundedCornerShape(16.dp)
        ) {
            Column(
                modifier = Modifier.fillMaxSize()
            ) {
                // 聊天消息列表
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(messages) { message ->
                        ChatBubble(message = message)
                    }
                    
                    if (isProcessing) {
                        item {
                            TypingIndicator()
                        }
                    }
                }
                
                // 输入框
                ChatInputField(
                    value = inputText,
                    onValueChange = { inputText = it },
                    onSend = { message ->
                        if (message.isNotBlank()) {
                            // 添加用户消息
                            messages = messages + ChatMessage(
                                id = "user_${System.currentTimeMillis()}",
                                content = message,
                                isUser = true
                            )
                            inputText = TextFieldValue("")
                            isProcessing = true
                            
                            // 模拟AI响应
                            CoroutineScope(Dispatchers.Main).launch {
                                delay(2000) // 模拟处理时间
                                val aiResponse = generateAIResponse(message)
                                messages = messages + ChatMessage(
                                    id = "ai_${System.currentTimeMillis()}",
                                    content = aiResponse,
                                    isUser = false
                                )
                                isProcessing = false
                            }
                        }
                    },
                    enabled = !isProcessing
                )
            }
        }
        
        Spacer(modifier = Modifier.height(16.dp))
        
        // 快捷功能按钮
        QuickActionButtons(
            onQuickAction = { action ->
                val quickMessage = when (action) {
                    "system_status" -> "请帮我检查系统状态"
                    "weather_info" -> "请显示当前天气信息"
                    "device_list" -> "请列出所有连接的设备"
                    "help" -> "请告诉我这个应用的主要功能"
                    else -> ""
                }
                
                if (quickMessage.isNotBlank()) {
                    inputText = TextFieldValue(quickMessage)
                }
            }
        )
    }
}

@Composable
fun AIAssistantHeader() {
    Row(
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Psychology,
            contentDescription = "AI助手",
            tint = GlassColors.highlight,
            modifier = Modifier.size(32.dp)
        )
        
        Spacer(modifier = Modifier.width(16.dp))
        
        Column {
            Text(
                text = "AI智能助手",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Text(
                text = "智能对话 • 系统控制 • 问题解答",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

@Composable
fun ChatBubble(message: ChatMessage) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (message.isUser) Arrangement.End else Arrangement.Start
    ) {
        if (!message.isUser) {
            // AI头像
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(
                        color = GlassColors.highlight,
                        shape = RoundedCornerShape(20.dp)
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.SmartToy,
                    contentDescription = "AI",
                    tint = Color.White,
                    modifier = Modifier.size(24.dp)
                )
            }
            
            Spacer(modifier = Modifier.width(8.dp))
        }
        
        // 消息气泡
        Card(
            modifier = Modifier.widthIn(max = 280.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (message.isUser) {
                    GlassColors.highlight
                } else {
                    Color.White.copy(alpha = 0.1f)
                }
            ),
            shape = RoundedCornerShape(
                topStart = 16.dp,
                topEnd = 16.dp,
                bottomStart = if (message.isUser) 16.dp else 4.dp,
                bottomEnd = if (message.isUser) 4.dp else 16.dp
            )
        ) {
            Text(
                text = message.content,
                color = Color.White,
                fontSize = 14.sp,
                modifier = Modifier.padding(12.dp)
            )
        }
        
        if (message.isUser) {
            Spacer(modifier = Modifier.width(8.dp))
            
            // 用户头像
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(
                        color = Color.Blue.copy(alpha = 0.7f),
                        shape = RoundedCornerShape(20.dp)
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Person,
                    contentDescription = "用户",
                    tint = Color.White,
                    modifier = Modifier.size(24.dp)
                )
            }
        }
    }
}

@Composable
fun TypingIndicator() {
    Row(
        verticalAlignment = Alignment.CenterVertically
    ) {
        // AI头像
        Box(
            modifier = Modifier
                .size(40.dp)
                .background(
                    color = GlassColors.highlight,
                    shape = RoundedCornerShape(20.dp)
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.SmartToy,
                contentDescription = "AI",
                tint = Color.White,
                modifier = Modifier.size(24.dp)
            )
        }
        
        Spacer(modifier = Modifier.width(8.dp))
        
        // 输入中指示器
        Card(
            colors = CardDefaults.cardColors(
                containerColor = Color.White.copy(alpha = 0.1f)
            ),
            shape = RoundedCornerShape(16.dp, 16.dp, 16.dp, 4.dp)
        ) {
            Row(
                modifier = Modifier.padding(16.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                repeat(3) { index ->
                    val alpha by animateFloatAsState(
                        targetValue = if ((System.currentTimeMillis() / 500) % 3 == index.toLong()) 1f else 0.3f,
                        animationSpec = tween(500),
                        label = "typing_dot_$index"
                    )
                    
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(
                                color = Color.White.copy(alpha = alpha),
                                shape = RoundedCornerShape(4.dp)
                            )
                    )
                }
            }
        }
    }
}

@Composable
fun ChatInputField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    onSend: (String) -> Unit,
    enabled: Boolean
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = Color.White.copy(alpha = 0.1f)
        ),
        shape = RoundedCornerShape(24.dp)
    ) {
        Row(
            modifier = Modifier.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                textStyle = androidx.compose.ui.text.TextStyle(
                    color = Color.White,
                    fontSize = 16.sp
                ),
                decorationBox = { innerTextField ->
                    if (value.text.isEmpty()) {
                        Text(
                            text = "输入您的问题...",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 16.sp
                        )
                    }
                    innerTextField()
                }
            )
            
            IconButton(
                onClick = {
                    onSend(value.text)
                },
                enabled = enabled && value.text.isNotBlank(),
                modifier = Modifier
                    .background(
                        color = if (enabled && value.text.isNotBlank()) {
                            GlassColors.highlight
                        } else {
                            Color.Gray.copy(alpha = 0.3f)
                        },
                        shape = RoundedCornerShape(20.dp)
                    )
            ) {
                Icon(
                    imageVector = Icons.Default.Send,
                    contentDescription = "发送",
                    tint = Color.White,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

@Composable
fun QuickActionButtons(
    onQuickAction: (String) -> Unit
) {
    val quickActions = listOf(
        "system_status" to "系统状态",
        "weather_info" to "天气信息",
        "device_list" to "设备列表",
        "help" to "使用帮助"
    )
    
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items(quickActions) { (action, label) ->
            OutlinedButton(
                onClick = { onQuickAction(action) },
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = Color.White
                ),
                border = androidx.compose.foundation.BorderStroke(
                    width = 1.dp,
                    color = Color.White.copy(alpha = 0.3f)
                )
            ) {
                Text(
                    text = label,
                    fontSize = 12.sp
                )
            }
        }
    }
}

// 模拟AI响应生成
fun generateAIResponse(userMessage: String): String {
    return when {
        userMessage.contains("天气", ignoreCase = true) -> {
            "根据当前天气数据显示：温度 22°C，湿度 65%，气压 1015 hPa，能见度良好。天气系统运行正常。"
        }
        userMessage.contains("系统", ignoreCase = true) || userMessage.contains("状态", ignoreCase = true) -> {
            "系统运行状态良好！\n• 所有核心服务正常运行\n• 内存使用率：78%\n• CPU负载：45%\n• 网络连接稳定"
        }
        userMessage.contains("设备", ignoreCase = true) -> {
            "当前已连接设备：\n• Node 6 控制台 - 在线\n• 远程桌面服务 - 就绪\n• 文件传输服务 - 活跃\n• 监控设备 - 正常"
        }
        userMessage.contains("功能", ignoreCase = true) || userMessage.contains("帮助", ignoreCase = true) -> {
            "云桥司南主要功能包括：\n• 系统监控与管理\n• 天气数据中心\n• 远程桌面控制\n• 文件传输服务\n• 设备发现与连接\n• Node 6 高级功能\n\n您可以通过左侧菜单访问这些功能。"
        }
        userMessage.contains("你好", ignoreCase = true) || userMessage.contains("hello", ignoreCase = true) -> {
            "您好！很高兴为您服务。我可以帮助您管理系统、查看数据、解答问题。请告诉我您需要什么帮助。"
        }
        else -> {
            "我已经收到您的消息：「${userMessage}」\n\n作为云桥司南的AI助手，我可以帮助您：\n• 系统监控和状态查询\n• 天气数据分析\n• 设备管理操作\n• 功能使用指导\n\n请告诉我您需要哪方面的帮助！"
        }
    }
}