/**
 * 认证服务
 * 与 Mac 应用 SupabaseService.swift 完全对齐
 * 支持：邮箱登录/注册、手机号OTP、Apple登录、令牌刷新
 */

import { supabase } from './supabase'
import type { AuthError, User, Session } from '@supabase/supabase-js'

// ============================================================================
// 类型定义 - 与 Mac 应用 AuthSession 对齐
// ============================================================================

export interface AuthSession {
  accessToken: string
  refreshToken: string | null
  userIdentifier: string
  displayName: string
  issuedAt: Date
}

export interface AuthResult {
  session: AuthSession | null
  error: string | null
  requiresEmailVerification?: boolean
}

export interface PasswordStrength {
  level: 'weak' | 'medium' | 'strong' | 'veryStrong'
  score: number
  description: string
  color: string
}

// ============================================================================
// 辅助函数
// ============================================================================

/**
 * 将 Supabase Session 转换为统一的 AuthSession 格式
 */
function toAuthSession(session: Session, user: User): AuthSession {
  return {
    accessToken: session.access_token,
    refreshToken: session.refresh_token ?? null,
    userIdentifier: user.id,
    displayName: user.user_metadata?.display_name || user.email?.split('@')[0] || '用户',
    issuedAt: new Date(),
  }
}

/**
 * 生成 NebulaID（与 Mac 应用 NebulaIDGenerator 对齐）
 * 格式: NB-{timestamp}-{random}
 */
function generateNebulaId(): string {
  const timestamp = Date.now().toString(36).toUpperCase()
  const random = Math.random().toString(36).substring(2, 8).toUpperCase()
  return `NB-${timestamp}-${random}`
}

/**
 * 评估密码强度（与 Mac 应用逻辑对齐）
 */
export function evaluatePasswordStrength(password: string): PasswordStrength {
  let score = 0

  // 长度评分
  if (password.length >= 8) score += 1
  if (password.length >= 12) score += 1
  if (password.length >= 16) score += 1

  // 复杂度评分
  if (/[a-z]/.test(password)) score += 1
  if (/[A-Z]/.test(password)) score += 1
  if (/[0-9]/.test(password)) score += 1
  if (/[!@#$%^&*()_+\-=\[\]{}|;':",./<>?]/.test(password)) score += 1

  // 映射到强度级别
  if (score <= 2) {
    return { level: 'weak', score, description: '弱', color: 'red' }
  } else if (score <= 4) {
    return { level: 'medium', score, description: '中等', color: 'orange' }
  } else if (score <= 6) {
    return { level: 'strong', score, description: '强', color: 'green' }
  } else {
    return { level: 'veryStrong', score, description: '非常强', color: 'blue' }
  }
}

/**
 * 验证邮箱格式
 */
export function isValidEmail(email: string): boolean {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  return emailRegex.test(email.trim().toLowerCase())
}

/**
 * 验证手机号格式（支持国际号码和中国大陆号码）
 */
export function isValidPhoneNumber(phone: string): boolean {
  const sanitized = phone.replace(/[\s\-()]/g, '')
  // E.164 格式
  const internationalRegex = /^\+[1-9]\d{1,14}$/
  // 中国大陆手机号
  const chinaRegex = /^1[3-9]\d{9}$/
  return internationalRegex.test(sanitized) || chinaRegex.test(sanitized)
}

/**
 * 检查是否为一次性邮箱
 */
export function isDisposableEmail(email: string): boolean {
  const disposableDomains = [
    'tempmail.com', 'throwaway.com', 'guerrillamail.com',
    'mailinator.com', '10minutemail.com', 'temp-mail.org'
  ]
  const domain = email.split('@')[1]?.toLowerCase()
  return disposableDomains.includes(domain)
}

// ============================================================================
// 认证方法 - 与 Mac 应用 SupabaseService 对齐
// ============================================================================

/**
 * 邮箱密码登录
 * 对应 Mac: SupabaseService.signInWithEmail()
 */
export async function signInWithEmail(email: string, password: string): Promise<AuthResult> {
  try {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: email.trim().toLowerCase(),
      password,
    })

    if (error) {
      return { session: null, error: translateAuthError(error) }
    }

    if (data.session && data.user) {
      return { session: toAuthSession(data.session, data.user), error: null }
    }

    return { session: null, error: '登录失败，请重试' }
  } catch {
    return { session: null, error: '网络错误，请检查连接' }
  }
}

/**
 * 邮箱注册
 * 对应 Mac: SupabaseService.signUp()
 */
export async function signUpWithEmail(
  email: string,
  password: string,
  displayName?: string
): Promise<AuthResult> {
  try {
    // 验证邮箱格式
    if (!isValidEmail(email)) {
      return { session: null, error: '请输入有效的邮箱地址' }
    }

    // 检查一次性邮箱
    if (isDisposableEmail(email)) {
      return { session: null, error: '不支持使用临时邮箱注册' }
    }

    // 验证密码强度
    const strength = evaluatePasswordStrength(password)
    if (strength.level === 'weak') {
      return { session: null, error: '密码强度不足，请使用更复杂的密码' }
    }

    // 生成 NebulaID
    const nebulaId = generateNebulaId()

    const { data, error } = await supabase.auth.signUp({
      email: email.trim().toLowerCase(),
      password,
      options: {
        data: {
          display_name: displayName || email.split('@')[0],
          registration_source: 'SkyBridge Compass Web',
          nebula_id: nebulaId,
        },
      },
    })

    if (error) {
      return { session: null, error: translateAuthError(error) }
    }

    // 注册成功但需要邮箱验证
    if (data.user && !data.session) {
      return {
        session: {
          accessToken: 'pending_verification',
          refreshToken: null,
          userIdentifier: data.user.id,
          displayName: displayName || email.split('@')[0],
          issuedAt: new Date(),
        },
        error: null,
        requiresEmailVerification: true,
      }
    }

    if (data.session && data.user) {
      return { session: toAuthSession(data.session, data.user), error: null }
    }

    return { session: null, error: '注册失败，请重试' }
  } catch {
    return { session: null, error: '网络错误，请检查连接' }
  }
}

/**
 * 发送手机验证码
 * 对应 Mac: SupabaseService.sendPhoneOTP()
 */
export async function sendPhoneOTP(phone: string): Promise<{ success: boolean; error: string | null }> {
  try {
    if (!isValidPhoneNumber(phone)) {
      return { success: false, error: '请输入有效的手机号码' }
    }

    const { error } = await supabase.auth.signInWithOtp({
      phone: phone.replace(/[\s\-()]/g, ''),
    })

    if (error) {
      return { success: false, error: translateAuthError(error) }
    }

    return { success: true, error: null }
  } catch {
    return { success: false, error: '发送验证码失败，请稍后重试' }
  }
}

/**
 * 手机号OTP验证登录
 * 对应 Mac: SupabaseService.signInWithPhone()
 */
export async function verifyPhoneOTP(phone: string, token: string): Promise<AuthResult> {
  try {
    const { data, error } = await supabase.auth.verifyOtp({
      phone: phone.replace(/[\s\-()]/g, ''),
      token,
      type: 'sms',
    })

    if (error) {
      return { session: null, error: translateAuthError(error) }
    }

    if (data.session && data.user) {
      return { session: toAuthSession(data.session, data.user), error: null }
    }

    return { session: null, error: '验证失败，请重试' }
  } catch {
    return { session: null, error: '网络错误，请检查连接' }
  }
}

/**
 * Apple 登录
 * 对应 Mac: SupabaseService.signInWithApple()
 */
export async function signInWithApple(): Promise<AuthResult> {
  try {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'apple',
      options: {
        redirectTo: typeof window !== 'undefined' ? `${window.location.origin}/auth/callback` : undefined,
      },
    })

    if (error) {
      return { session: null, error: translateAuthError(error) }
    }

    // OAuth 登录会重定向，这里不会直接返回 session
    return { session: null, error: null }
  } catch {
    return { session: null, error: 'Apple 登录失败，请重试' }
  }
}

/**
 * 刷新访问令牌
 * 对应 Mac: SupabaseService.refreshAccessToken()
 */
export async function refreshAccessToken(): Promise<AuthResult> {
  try {
    const { data, error } = await supabase.auth.refreshSession()

    if (error) {
      return { session: null, error: translateAuthError(error) }
    }

    if (data.session && data.user) {
      return { session: toAuthSession(data.session, data.user), error: null }
    }

    return { session: null, error: '刷新令牌失败' }
  } catch {
    return { session: null, error: '网络错误，请检查连接' }
  }
}

/**
 * 重置密码
 * 对应 Mac: SupabaseService.resetPassword()
 */
export async function resetPassword(email: string): Promise<{ success: boolean; error: string | null }> {
  try {
    if (!isValidEmail(email)) {
      return { success: false, error: '请输入有效的邮箱地址' }
    }

    const { error } = await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), {
      redirectTo: typeof window !== 'undefined' ? `${window.location.origin}/auth/reset-password` : undefined,
    })

    if (error) {
      return { success: false, error: translateAuthError(error) }
    }

    return { success: true, error: null }
  } catch {
    return { success: false, error: '发送重置邮件失败，请稍后重试' }
  }
}

/**
 * 登出
 * 对应 Mac: AuthenticationService.signOut()
 */
export async function signOut(): Promise<{ success: boolean; error: string | null }> {
  try {
    const { error } = await supabase.auth.signOut()
    if (error) {
      return { success: false, error: translateAuthError(error) }
    }
    return { success: true, error: null }
  } catch {
    return { success: false, error: '登出失败' }
  }
}

/**
 * 获取当前会话
 */
export async function getCurrentSession(): Promise<AuthSession | null> {
  try {
    const { data } = await supabase.auth.getSession()
    if (data.session && data.session.user) {
      return toAuthSession(data.session, data.session.user)
    }
    return null
  } catch {
    return null
  }
}

/**
 * 获取当前用户
 */
export async function getCurrentUser(): Promise<User | null> {
  try {
    const { data } = await supabase.auth.getUser()
    return data.user
  } catch {
    return null
  }
}

// ============================================================================
// 用户资料管理 - 与 Mac 应用对齐
// ============================================================================

/**
 * 更新用户资料
 * 对应 Mac: SupabaseService.updateUserProfile()
 */
export async function updateUserProfile(updates: {
  displayName?: string
  phoneNumber?: string
  avatarUrl?: string
}): Promise<{ success: boolean; error: string | null }> {
  try {
    const { error } = await supabase.auth.updateUser({
      data: {
        display_name: updates.displayName,
        phone_number: updates.phoneNumber,
        avatar_url: updates.avatarUrl,
      },
    })

    if (error) {
      return { success: false, error: translateAuthError(error) }
    }

    return { success: true, error: null }
  } catch {
    return { success: false, error: '更新资料失败' }
  }
}

/**
 * 获取用户头像URL
 * 对应 Mac: SupabaseService.getUserAvatarUrl()
 */
export async function getUserAvatarUrl(): Promise<string | null> {
  try {
    const { data } = await supabase.auth.getUser()
    return data.user?.user_metadata?.avatar_url || null
  } catch {
    return null
  }
}

// ============================================================================
// 错误翻译
// ============================================================================

function translateAuthError(error: AuthError): string {
  const errorMessages: Record<string, string> = {
    'Invalid login credentials': '邮箱或密码错误',
    'Email not confirmed': '邮箱尚未验证，请检查收件箱',
    'User already registered': '该邮箱已被注册',
    'Password should be at least 6 characters': '密码至少需要6个字符',
    'Signup requires a valid password': '请输入有效的密码',
    'Invalid email': '邮箱格式无效',
    'Email rate limit exceeded': '请求过于频繁，请稍后重试',
    'Phone rate limit exceeded': '验证码发送过于频繁，请稍后重试',
    'Invalid OTP': '验证码错误或已过期',
  }

  return errorMessages[error.message] || error.message || '操作失败，请重试'
}

// ============================================================================
// 认证状态监听
// ============================================================================

/**
 * 监听认证状态变化
 */
export function onAuthStateChange(callback: (session: AuthSession | null) => void) {
  return supabase.auth.onAuthStateChange((event, session) => {
    if (session && session.user) {
      callback(toAuthSession(session, session.user))
    } else {
      callback(null)
    }
  })
}

