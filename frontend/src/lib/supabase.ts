/**
 * Supabase 客户端配置
 * SkyBridge Compass Pro 跨平台统一配置
 * 与 SkyBridge 其他端保持账户与后端环境一致
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js'

// Supabase 配置 - 与 Mac 应用保持一致
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  throw new Error('Missing Supabase env: NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY')
}

const isBrowser = typeof window !== 'undefined'

// 创建 Supabase 客户端单例
export const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
    flowType: 'pkce',
    // Reduce long-lived token exposure compared to localStorage.
    // NOTE: Still accessible to XSS; CSP + safe rendering are required.
    storage: isBrowser ? window.sessionStorage : undefined,
  },
})
