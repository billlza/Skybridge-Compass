package com.yunqiao.sinan.manager

import android.content.Context
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.Locale

class AIAssistantManager(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val preferences = context.getSharedPreferences("ai_settings", Context.MODE_PRIVATE)
    private val httpClient = OkHttpClient()
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
    private val defaultEndpoints = mapOf(
        AIModel.NEBULA_CORE to "https://nebula.yunqiao/api/v1/chat/completions",
        AIModel.GPT4_TURBO to "https://api.openai.com/v1/chat/completions",
        AIModel.GPT5_ORBITAL to "https://api.openai.com/v1/chat/completions"
    )
    private val defaultModelNames = mapOf(
        AIModel.NEBULA_CORE to "nebula-core-2",
        AIModel.GPT4_TURBO to "gpt-4.1-turbo",
        AIModel.GPT5_ORBITAL to "gpt-5-orbital"
    )
    private val defaultSystemPrompt = "你是云桥司南的智能助理，负责设备协同、网络诊断与远程控制建议。"
    private val _availableModels = MutableStateFlow(
        listOf(
            AIModelProfile(
                model = AIModel.NEBULA_CORE,
                displayName = "Nubula Core",
                description = "系统级调度与策略规划",
                strengths = listOf("设备联动", "本地快速响应", "权限与安全治理"),
                maxContextTokens = 16000,
                multimodal = false
            ),
            AIModelProfile(
                model = AIModel.GPT4_TURBO,
                displayName = "GPT-4 Turbo",
                description = "复杂问题与多轮分析",
                strengths = listOf("知识检索", "长文档理解", "跨域问答"),
                maxContextTokens = 128000,
                multimodal = true
            ),
            AIModelProfile(
                model = AIModel.GPT5_ORBITAL,
                displayName = "GPT-5 Orbital",
                description = "超大规模推理与多模态协同",
                strengths = listOf("实时翻译", "图像与遥测解析", "策略决策"),
                maxContextTokens = 256000,
                multimodal = true
            )
        )
    )
    private val _activeModel = MutableStateFlow(_availableModels.value.last())
    private val _capabilityHighlights = MutableStateFlow(buildHighlights(_activeModel.value))
    val availableModels: StateFlow<List<AIModelProfile>> = _availableModels.asStateFlow()
    val activeModel: StateFlow<AIModelProfile> = _activeModel.asStateFlow()
    val capabilityHighlights: StateFlow<List<String>> = _capabilityHighlights.asStateFlow()

    init {
        scope.launch {
            _availableModels.collect { models ->
                val active = models.firstOrNull { it.model == _activeModel.value.model } ?: models.last()
                if (active != _activeModel.value) {
                    _activeModel.value = active
                    _capabilityHighlights.value = buildHighlights(active)
                }
            }
        }
    }

    fun selectModel(model: AIModel) {
        val target = _availableModels.value.firstOrNull { it.model == model } ?: return
        if (target != _activeModel.value) {
            _activeModel.value = target
            _capabilityHighlights.value = buildHighlights(target)
        }
    }

    suspend fun generateResponse(
        userMessage: String,
        history: List<AssistantConversationFrame>
    ): AIResponse {
        val profile = _activeModel.value
        return executeChatCompletion(profile, userMessage, history)
    }

    private fun buildHighlights(profile: AIModelProfile): List<String> {
        val coverage = if (profile.multimodal) "多模态协作" else "文本决策"
        val reach = when (profile.model) {
            AIModel.NEBULA_CORE -> "本地优先"
            AIModel.GPT4_TURBO -> "云端增强"
            AIModel.GPT5_ORBITAL -> "全域智能"
        }
        val context = "上下文 ${profile.maxContextTokens / 1000}K"
        return listOf(coverage, reach) + profile.strengths + context
    }

    private suspend fun executeChatCompletion(
        profile: AIModelProfile,
        userMessage: String,
        history: List<AssistantConversationFrame>
    ): AIResponse = withContext(Dispatchers.IO) {
        val endpoint = resolveEndpoint(profile.model)
        val modelName = resolveModelName(profile.model)
        val payload = JSONObject().apply {
            put("model", modelName)
            put("temperature", 0.2)
            put("messages", buildMessageArray(userMessage, history))
        }
        val requestBuilder = Request.Builder()
            .url(endpoint)
            .header("Content-Type", "application/json")
            .post(payload.toString().toRequestBody(jsonMediaType))
        resolveAuthHeader(profile.model)?.let { header ->
            requestBuilder.header("Authorization", header)
        }

        val request = requestBuilder.build()
        val start = SystemClock.elapsedRealtime()
        httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("AI服务调用失败: ${response.code} ${response.message}")
            }
            val body = response.body?.string() ?: throw IOException("AI服务返回空响应")
            val parsed = JSONObject(body)
            val choices = parsed.optJSONArray("choices") ?: JSONArray()
            if (choices.length() == 0) {
                throw IOException("AI服务未返回有效内容")
            }
            val message = choices.getJSONObject(0).optJSONObject("message")
            val content = message?.optString("content").orEmpty()
            val diagnostics = mutableListOf<String>()
            parsed.optJSONObject("usage")?.let { usage ->
                diagnostics += "prompt tokens: ${usage.optInt("prompt_tokens")}".trim()
                diagnostics += "completion tokens: ${usage.optInt("completion_tokens")}".trim()
            }
            diagnostics += "endpoint: $endpoint"
            val latency = SystemClock.elapsedRealtime() - start
            AIResponse(
                content = content.ifBlank { "(AI服务未返回文本内容)" },
                diagnostics = diagnostics.filter { it.isNotBlank() },
                latencyMs = latency,
                model = profile.model
            )
        }
    }

    private fun buildMessageArray(
        userMessage: String,
        history: List<AssistantConversationFrame>
    ): JSONArray {
        val messages = JSONArray()
        messages.put(
            JSONObject()
                .put("role", "system")
                .put("content", preferences.getString("ai_system_prompt", defaultSystemPrompt))
        )
        history.sortedBy { it.timestamp }
            .takeLast(8)
            .forEach { frame ->
                messages.put(
                    JSONObject()
                        .put("role", frame.role.toApiRole())
                        .put("content", frame.content)
                )
            }
        messages.put(
            JSONObject()
                .put("role", "user")
                .put("content", userMessage)
        )
        return messages
    }

    private fun resolveEndpoint(model: AIModel): String {
        val key = "endpoint_${model.name.lowercase(Locale.getDefault())}"
        return preferences.getString(key, defaultEndpoints[model]) ?: defaultEndpoints.getValue(model)
    }

    private fun resolveModelName(model: AIModel): String {
        val key = "model_${model.name.lowercase(Locale.getDefault())}"
        return preferences.getString(key, defaultModelNames[model]) ?: defaultModelNames.getValue(model)
    }

    private fun resolveAuthHeader(model: AIModel): String? {
        val keyName = when (model) {
            AIModel.NEBULA_CORE -> "nebula_api_key"
            AIModel.GPT4_TURBO, AIModel.GPT5_ORBITAL -> "openai_api_key"
        }
        val apiKey = preferences.getString(keyName, null)
        return apiKey?.takeIf { it.isNotBlank() }?.let { "Bearer $it" }
    }
}

data class AIModelProfile(
    val model: AIModel,
    val displayName: String,
    val description: String,
    val strengths: List<String>,
    val maxContextTokens: Int,
    val multimodal: Boolean
)

data class AIResponse(
    val content: String,
    val diagnostics: List<String>,
    val latencyMs: Long,
    val model: AIModel
)

data class AssistantConversationFrame(
    val role: ConversationRole,
    val content: String,
    val timestamp: Long
)

enum class ConversationRole {
    SYSTEM,
    USER,
    ASSISTANT;

    fun prefix(): String {
        return when (this) {
            SYSTEM -> "SYS:"
            USER -> "USR:"
            ASSISTANT -> "AI:"
        }
    }
}

private fun ConversationRole.toApiRole(): String {
    return when (this) {
        ConversationRole.SYSTEM -> "system"
        ConversationRole.USER -> "user"
        ConversationRole.ASSISTANT -> "assistant"
    }
}

enum class AIModel {
    NEBULA_CORE,
    GPT4_TURBO,
    GPT5_ORBITAL
}
