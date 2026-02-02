/**
 * Supabase 客户端配置
 * SkyBridge Compass Pro 跨平台统一配置
 * 与 Mac/iOS/Android 应用共享同一 Supabase 项目
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js'

// Supabase 配置 - 与 Mac 应用保持一致
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://hloqytmhjludmuhwyyzb.supabase.co'
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'sb_publishable_SonH4HoPQBQxHG_1KQZH-A_Om5mY6RR'

// 创建 Supabase 客户端单例
export const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
  },
})

// 导出配置供其他模块使用
export const supabaseConfig = {
  url: SUPABASE_URL,
  anonKey: SUPABASE_ANON_KEY,
}

