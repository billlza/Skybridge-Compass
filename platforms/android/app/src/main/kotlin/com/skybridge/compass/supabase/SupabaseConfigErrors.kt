package com.skybridge.compass.supabase

sealed class SupabaseConfigException(message: String) : IllegalStateException(message)

class SupabaseConfigMissingException :
    SupabaseConfigException("未配置 Supabase，请在设置中配置后再试。")

class SupabaseConfigLockedException :
    SupabaseConfigException("Supabase 配置已锁定，请在设置中解锁后再试。")

class SupabaseConfigInvalidException(reason: String) :
    SupabaseConfigException("Supabase 配置无效：$reason")

data class SupabaseConfigValidationResult(
    val isValid: Boolean,
    val message: String? = null
)

