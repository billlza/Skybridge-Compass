package com.yunqiao.sinan.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yunqiao.sinan.manager.AIAssistantManager
import com.yunqiao.sinan.manager.AIModel
import com.yunqiao.sinan.manager.AIModelProfile
import com.yunqiao.sinan.manager.AssistantConversationFrame
import com.yunqiao.sinan.manager.ConversationRole
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.launch

data class ChatMessage(
    val id: String,
    val content: String,
    val isUser: Boolean,
    val timestamp: Long = System.currentTimeMillis(),
    val engine: AIModel? = null,
    val diagnostics: List<String> = emptyList(),
    val latencyMs: Long? = null
)

@Composable
fun AIAssistantScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val aiManager = remember { AIAssistantManager(context) }
    val availableModels by aiManager.availableModels.collectAsStateWithLifecycle()
    val activeModel by aiManager.activeModel.collectAsStateWithLifecycle()
    val capabilityHighlights by aiManager.capabilityHighlights.collectAsStateWithLifecycle()
    var messages by remember {
        mutableStateOf(
            listOf(
                ChatMessage(
                    id = "welcome",
                    content = "您好！我是云桥司南的AI助手，有什么可以帮助您的吗？",
                    isUser = false,
                    engine = activeModel.model,
                    diagnostics = listOf("欢迎引导", "多模态待命")
                )
            )
        )
    }
    var inputText by remember { mutableStateOf(TextFieldValue("")) }
    var isProcessing by remember { mutableStateOf(false) }
    val coroutineScope = rememberCoroutineScope()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                color = Color.Transparent,
                shape = RoundedCornerShape(16.dp)
            )
            .padding(24.dp)
    ) {
        AIAssistantHeader(profile = activeModel)

        Spacer(modifier = Modifier.height(16.dp))

        ModelSelector(
            models = availableModels,
            active = activeModel,
            onSelect = { model -> aiManager.selectModel(model) }
        )

        Spacer(modifier = Modifier.height(12.dp))

        CapabilityHighlights(highlights = capabilityHighlights)

        Spacer(modifier = Modifier.height(24.dp))

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
                            messages = messages + ChatMessage(
                                id = "user_${System.currentTimeMillis()}",
                                content = message,
                                isUser = true
                            )
                            inputText = TextFieldValue("")
                            isProcessing = true

                            coroutineScope.launch {
                                runCatching {
                                    val history = messages.map { it.toFrame() } + AssistantConversationFrame(
                                        role = ConversationRole.USER,
                                        content = message,
                                        timestamp = System.currentTimeMillis()
                                    )
                                    val aiResponse = aiManager.generateResponse(message, history)
                                    messages = messages + ChatMessage(
                                        id = "ai_${System.currentTimeMillis()}",
                                        content = aiResponse.content,
                                        isUser = false,
                                        engine = aiResponse.model,
                                        diagnostics = aiResponse.diagnostics,
                                        latencyMs = aiResponse.latencyMs
                                    )
                                }.onFailure { throwable ->
                                    messages = messages + ChatMessage(
                                        id = "ai_error_${System.currentTimeMillis()}",
                                        content = throwable.message ?: "处理失败，请稍后重试",
                                        isUser = false,
                                        diagnostics = listOf("回退至 Nubula Core")
                                    )
                                }
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
fun AIAssistantHeader(profile: AIModelProfile) {
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
                text = "${profile.displayName} • ${profile.description}",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

@Composable
private fun ModelSelector(
    models: List<AIModelProfile>,
    active: AIModelProfile,
    onSelect: (AIModel) -> Unit
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(models) { profile ->
            val selected = profile.model == active.model
            OutlinedButton(
                onClick = { onSelect(profile.model) },
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = Color.White,
                    containerColor = if (selected) GlassColors.highlight.copy(alpha = 0.24f) else Color.Transparent
                ),
                border = BorderStroke(1.dp, if (selected) GlassColors.highlight else Color.White.copy(alpha = 0.4f))
            ) {
                Column(horizontalAlignment = Alignment.Start) {
                    Text(text = profile.displayName, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        text = profile.description,
                        fontSize = 11.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CapabilityHighlights(highlights: List<String>) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        highlights.forEach { item ->
            AssistChip(
                onClick = {},
                label = { Text(text = item, fontSize = 11.sp) },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = Color.White.copy(alpha = 0.12f),
                    labelColor = Color.White
                )
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
            Column(modifier = Modifier.padding(12.dp)) {
                Text(
                    text = message.content,
                    color = Color.White,
                    fontSize = 14.sp
                )
                if (!message.isUser && message.engine != null) {
                    Spacer(modifier = Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        AssistChip(
                            onClick = {},
                            label = { Text(text = when (message.engine) {
                                AIModel.NEBULA_CORE -> "Nubula Core"
                                AIModel.GPT4_TURBO -> "GPT-4 Turbo"
                                AIModel.GPT5_ORBITAL -> "GPT-5 Orbital"
                            }) },
                            colors = AssistChipDefaults.assistChipColors(
                                containerColor = GlassColors.highlight.copy(alpha = 0.16f),
                                labelColor = Color.White
                            )
                        )
                        message.latencyMs?.let {
                            AssistChip(
                                onClick = {},
                                label = { Text(text = "${it}ms") },
                                colors = AssistChipDefaults.assistChipColors(
                                    containerColor = Color.White.copy(alpha = 0.12f),
                                    labelColor = Color.White
                                )
                            )
                        }
                    }
                    if (message.diagnostics.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(6.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            message.diagnostics.forEach { hint ->
                                Text(
                                    text = "• $hint",
                                    color = Color.White.copy(alpha = 0.8f),
                                    fontSize = 11.sp
                                )
                            }
                        }
                    }
                }
            }
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

// 将聊天记录映射为会话帧
private fun ChatMessage.toFrame(): AssistantConversationFrame {
    val role = if (isUser) ConversationRole.USER else ConversationRole.ASSISTANT
    return AssistantConversationFrame(
        role = role,
        content = content,
        timestamp = timestamp
    )
}