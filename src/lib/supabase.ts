import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || 'https://hloqytmhjludmuhwyyzb.supabase.co'
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0'
const localNebulaIssuer = 'http://127.0.0.1:3000'
const defaultNebulaScope = 'openid profile email offline_access'
const nebulaOAuthStorageKey = 'skybridge.nebula.oauth'
const postAuthRedirectStorageKey = 'skybridge.post_auth_redirect'

export const supabase = createClient(supabaseUrl, supabaseAnonKey)

type NebulaOAuthFlow = 'login' | 'register'

interface NebulaOAuthSession {
  baseUrl: string
  clientId: string
  redirectUri: string
  codeVerifier: string
  state: string
  flow: NebulaOAuthFlow
}

function isBrowser() {
  return typeof window !== 'undefined'
}

function isLocalHostname(hostname: string) {
  return hostname === 'localhost' || hostname === '127.0.0.1'
}

function normalizeBaseUrl(rawValue?: string | null) {
  return rawValue?.trim().replace(/\/+$/, '') || ''
}

function getNebulaBaseUrl() {
  const envBaseUrl =
    import.meta.env.VITE_NEBULA_BASE_URL ||
    import.meta.env.VITE_SKYBRIDGE_AUTH_BASEURL

  if (envBaseUrl?.trim()) {
    return normalizeBaseUrl(envBaseUrl)
  }

  if (isBrowser() && isLocalHostname(window.location.hostname)) {
    return localNebulaIssuer
  }

  return ''
}

function getNebulaClientId() {
  const envClientId = import.meta.env.VITE_NEBULA_CLIENT_ID?.trim()

  if (envClientId) {
    return envClientId
  }

  if (isBrowser() && isLocalHostname(window.location.hostname)) {
    return 'skybridge_compass_web'
  }

  return ''
}

function getNebulaScope() {
  return import.meta.env.VITE_NEBULA_SCOPE?.trim() || defaultNebulaScope
}

function getNebulaRedirectUri() {
  if (!isBrowser()) {
    return ''
  }

  return `${window.location.origin}/auth/callback`
}

function getNebulaOAuthConfig() {
  const baseUrl = getNebulaBaseUrl()
  const clientId = getNebulaClientId()
  const redirectUri = getNebulaRedirectUri()
  const scope = getNebulaScope()

  return {
    baseUrl,
    clientId,
    redirectUri,
    scope,
    enabled: Boolean(baseUrl && clientId && redirectUri)
  }
}

export function isNebulaOAuthConfigured() {
  return getNebulaOAuthConfig().enabled
}

function encodeBase64Url(bytes: Uint8Array) {
  let binary = ''

  bytes.forEach(byte => {
    binary += String.fromCharCode(byte)
  })

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function randomPkceString(length: number) {
  if (!isBrowser() || !window.crypto?.getRandomValues) {
    throw new Error('当前环境不支持 Nebula PKCE 流程')
  }

  const bytes = new Uint8Array(length)
  window.crypto.getRandomValues(bytes)
  return encodeBase64Url(bytes).slice(0, length)
}

async function sha256Base64Url(value: string) {
  if (!isBrowser() || !window.crypto?.subtle) {
    throw new Error('当前浏览器不支持 Web Crypto，无法启动 Nebula 授权')
  }

  const digest = await window.crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return encodeBase64Url(new Uint8Array(digest))
}

function saveNebulaOAuthSession(session: NebulaOAuthSession) {
  if (!isBrowser()) {
    return
  }

  window.sessionStorage.setItem(nebulaOAuthStorageKey, JSON.stringify(session))
}

function readNebulaOAuthSession(): NebulaOAuthSession | null {
  if (!isBrowser()) {
    return null
  }

  const rawValue = window.sessionStorage.getItem(nebulaOAuthStorageKey)
  if (!rawValue) {
    return null
  }

  try {
    const parsed = JSON.parse(rawValue) as Partial<NebulaOAuthSession>
    if (
      !parsed.baseUrl ||
      !parsed.clientId ||
      !parsed.redirectUri ||
      !parsed.codeVerifier ||
      !parsed.state ||
      !parsed.flow
    ) {
      return null
    }

    return parsed as NebulaOAuthSession
  } catch (error) {
    console.error('Failed to parse Nebula OAuth session:', error)
    return null
  }
}

function clearNebulaOAuthSession() {
  if (!isBrowser()) {
    return
  }

  window.sessionStorage.removeItem(nebulaOAuthStorageKey)
}

function redirectTo(url: string) {
  setTimeout(() => {
    try {
      window.location.assign(url)
    } catch (error) {
      console.error('Redirect error:', error)
      window.location.href = url
    }
  }, 100)
}

function redirectToAuthError(message: string) {
  redirectTo(`/auth?mode=login&error=${encodeURIComponent(message)}`)
}

export function sanitizePostAuthRedirect(rawValue?: string | null) {
  const trimmed = rawValue?.trim()
  if (!trimmed) {
    return null
  }

  if (!trimmed.startsWith('/') || trimmed.startsWith('//')) {
    return null
  }

  return trimmed
}

export function rememberPostAuthRedirect(path: string | null) {
  if (!isBrowser()) {
    return
  }

  const sanitized = sanitizePostAuthRedirect(path)
  if (sanitized) {
    window.sessionStorage.setItem(postAuthRedirectStorageKey, sanitized)
  } else {
    window.sessionStorage.removeItem(postAuthRedirectStorageKey)
  }
}

export function consumePostAuthRedirect() {
  if (!isBrowser()) {
    return null
  }

  const remembered = sanitizePostAuthRedirect(window.sessionStorage.getItem(postAuthRedirectStorageKey))
  window.sessionStorage.removeItem(postAuthRedirectStorageKey)
  return remembered
}

export async function beginNebulaOAuth(flow: NebulaOAuthFlow = 'login') {
  if (!isBrowser()) {
    throw new Error('Nebula 授权只能在浏览器中启动')
  }

  const config = getNebulaOAuthConfig()
  if (!config.enabled) {
    throw new Error('Nebula 授权未配置，请先设置 VITE_NEBULA_BASE_URL 和 VITE_NEBULA_CLIENT_ID')
  }

  const state = randomPkceString(32)
  const codeVerifier = randomPkceString(96)
  const codeChallenge = await sha256Base64Url(codeVerifier)

  saveNebulaOAuthSession({
    baseUrl: config.baseUrl,
    clientId: config.clientId,
    redirectUri: config.redirectUri,
    codeVerifier,
    state,
    flow
  })

  const authorizeUrl = new URL(`${config.baseUrl}/oauth/authorize`)
  authorizeUrl.searchParams.set('response_type', 'code')
  authorizeUrl.searchParams.set('client_id', config.clientId)
  authorizeUrl.searchParams.set('redirect_uri', config.redirectUri)
  authorizeUrl.searchParams.set('scope', config.scope)
  authorizeUrl.searchParams.set('state', state)
  authorizeUrl.searchParams.set('code_challenge', codeChallenge)
  authorizeUrl.searchParams.set('code_challenge_method', 'S256')

  if (flow === 'register') {
    authorizeUrl.searchParams.set('flow', 'register')
  }

  window.location.assign(authorizeUrl.toString())
}

async function exchangeNebulaCodeForSession(code: string, storedSession: NebulaOAuthSession) {
  const response = await fetch(`${storedSession.baseUrl}/oauth/token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json'
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: storedSession.clientId,
      code,
      redirect_uri: storedSession.redirectUri,
      code_verifier: storedSession.codeVerifier
    }).toString()
  })

  const result = await response.json().catch(() => null)

  if (!response.ok) {
    throw new Error(result?.error_description || result?.error || 'Nebula 授权换取会话失败')
  }

  if (!result?.access_token || !result?.refresh_token) {
    throw new Error('Nebula 授权返回的会话无效')
  }

  const { error } = await supabase.auth.setSession({
    access_token: result.access_token,
    refresh_token: result.refresh_token
  })

  if (error) {
    throw error
  }
}

// 通过边缘函数完成星云ID登录，避免在浏览器暴露邮箱映射
export async function signInWithNebulaId(nebulaId: string, password: string) {
  const response = await fetch(
    `${supabaseUrl}/functions/v1/nebula-login`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${supabaseAnonKey}`,
        'apikey': supabaseAnonKey,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        nebula_id: nebulaId.trim().toUpperCase(),
        password
      })
    }
  )

  const result = await response.json().catch(() => null)

  if (!response.ok) {
    throw new Error(result?.error?.message || '星云账号登录失败')
  }

  const session = result?.data?.session
  if (!session?.access_token || !session?.refresh_token) {
    throw new Error('星云账号登录响应无效')
  }

  const { data, error } = await supabase.auth.setSession({
    access_token: session.access_token,
    refresh_token: session.refresh_token
  })

  if (error) {
    console.error('Error setting nebula session:', error.message)
    throw error
  }

  return data
}

// 获取当前用户
export async function getCurrentUser() {
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error) {
    console.error('Error getting user:', error)
    return null
  }
  return user
}

// 邮箱注册
export async function signUp(email: string, password: string, metadata: any = {}) {
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${window.location.protocol}//${window.location.host}/auth/callback`,
      data: metadata
    }
  })

  if (error) {
    console.error('Error signing up:', error.message)
    throw error
  }

  return data
}

// 手机号注册
export async function signUpWithPhone(phone: string, password: string, metadata: any = {}) {
  const { data, error } = await supabase.auth.signUp({
    phone,
    password,
    options: {
      data: metadata
    }
  })

  if (error) {
    console.error('Error signing up with phone:', error.message)
    throw error
  }

  return data
}

// 邮箱登录
export async function signInWithPassword(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password
  })

  if (error) {
    console.error('Error signing in:', error.message)
    throw error
  }

  return data
}

// 手机号登录
export async function signInWithPhone(phone: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({
    phone,
    password
  })

  if (error) {
    console.error('Error signing in with phone:', error.message)
    throw error
  }

  return data
}

// 发送手机验证码
export async function sendPhoneOTP(phone: string) {
  const { data, error } = await supabase.auth.signInWithOtp({
    phone
  })

  if (error) {
    console.error('Error sending phone OTP:', error.message)
    throw error
  }

  return data
}

// 验证手机验证码
export async function verifyPhoneOTP(phone: string, token: string) {
  const { data, error } = await supabase.auth.verifyOtp({
    phone,
    token,
    type: 'sms'
  })

  if (error) {
    console.error('Error verifying phone OTP:', error.message)
    throw error
  }

  return data
}

// 登出
export async function signOut() {
  const { error } = await supabase.auth.signOut()
  
  if (error) {
    console.error('Error signing out:', error.message)
    throw error
  }
}

export async function updateCurrentUserMetadata(data: Record<string, unknown>) {
  const { data: updatedUser, error } = await supabase.auth.updateUser({
    data
  })

  if (error) {
    console.error('Error updating user metadata:', error.message)
    throw error
  }

  return updatedUser
}

export async function upsertCurrentUserProfile(profile: Record<string, unknown>) {
  const { data: userResult, error: userError } = await supabase.auth.getUser()

  if (userError || !userResult.user) {
    throw new Error('用户未登录')
  }

  const user = userResult.user
  const payload = {
    id: user.id,
    email: user.email ?? null,
    phone: user.phone ?? null,
    ...profile
  }

  const { data, error } = await supabase
    .from('user_profiles')
    .upsert(payload, { onConflict: 'id' })
    .select()
    .single()

  if (error) {
    console.error('Error upserting user profile:', error.message)
    throw error
  }

  return data
}

// 重置密码
export async function resetPassword(email: string) {
  const { data, error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${window.location.protocol}//${window.location.host}/auth/reset-password`
  })

  if (error) {
    console.error('Error resetting password:', error.message)
    throw error
  }

  return data
}

// 获取用户资料
export async function getUserProfile() {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/get-user-profile`,
    {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      }
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '获取用户资料失败')
  }

  return result.data
}

// 更新用户自定义ID
export async function updateUserCustomId(customUserId: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    console.error('会话错误:', sessionError)
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/update-user-id`,
    {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ custom_user_id: customUserId })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    console.error('API错误:', result.error)
    throw new Error(result.error?.message || '更新用户ID失败')
  }

  return result.data
}

// 检查用户ID可用性
export async function checkUserIdAvailability(customUserId: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/check-user-id-availability`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ custom_user_id: customUserId })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '检查用户ID可用性失败')
  }

  return result.data
}

// 生成星云ID
export async function generateNebulaId() {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/generate-nebula-id`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      }
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '生成星云ID失败')
  }

  return result.data
}

// 发送验证码
export async function sendVerificationCode(type: 'email' | 'phone', contact: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/send-verification-code`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ type, contact })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '发送验证码失败')
  }

  return result.data
}

// 验证验证码
export async function verifyCode(type: 'email' | 'phone', contact: string, code: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/verify-code`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ type, contact, code })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '验证失败')
  }

  return result.data
}

// 绑定账户
export async function bindAccount(type: 'email' | 'phone', contact: string, code?: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/bind-account`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ type, contact, code })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '绑定失败')
  }

  return result.data
}

// 解绑账户
export async function unbindAccount(type: 'email' | 'phone', code: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/unbind-account-v2`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ contact_type: type, verification_code: code })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '解绑失败')
  }

  return result.data
}

// 高级发送验证码
export async function sendVerificationCodeV2(contactType: 'email' | 'phone', contactValue: string, purpose: 'bind' | 'unbind' = 'bind') {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/send-verification-code-v2`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ 
        contact_type: contactType, 
        contact_value: contactValue,
        purpose: purpose
      })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '发送验证码失败')
  }

  return result.data
}

// 高级绑定账户
export async function bindAccountV2(contactType: 'email' | 'phone', contactValue: string, verificationCode: string) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/bind-account-v2`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ 
        contact_type: contactType, 
        contact_value: contactValue,
        verification_code: verificationCode
      })
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '绑定失败')
  }

  return result.data
}

// 获取用户绑定状态
export async function getUserBindingStatus() {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  
  if (sessionError || !session) {
    throw new Error('用户未登录')
  }

  const response = await fetch(
    `${supabaseUrl}/functions/v1/get-binding-status`,
    {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${session.access_token}`,
        'Content-Type': 'application/json'
      }
    }
  )

  const result = await response.json()
  
  if (!response.ok) {
    throw new Error(result.error?.message || '获取绑定状态失败')
  }

  return result.data
}

// 处理认证回调
export async function handleAuthCallback() {
  try {
    // 检查是否在浏览器环境中
    if (!isBrowser()) {
      console.error('handleAuthCallback called outside browser environment')
      return
    }

    const currentUrl = new URL(window.location.href)
    const storedNebulaSession = readNebulaOAuthSession()
    const nebulaCode = currentUrl.searchParams.get('code')
    const nebulaState = currentUrl.searchParams.get('state')
    const nebulaError =
      currentUrl.searchParams.get('error_description') ||
      currentUrl.searchParams.get('error')

    if (storedNebulaSession && nebulaError) {
      clearNebulaOAuthSession()
      redirectToAuthError(nebulaError)
      return
    }

    if (storedNebulaSession && nebulaCode && nebulaState) {
      if (nebulaState !== storedNebulaSession.state) {
        clearNebulaOAuthSession()
        redirectToAuthError('Nebula 授权状态校验失败，请重新登录')
        return
      }

      try {
        await exchangeNebulaCodeForSession(nebulaCode, storedNebulaSession)
        clearNebulaOAuthSession()
        redirectTo(consumePostAuthRedirect() || '/')
        return
      } catch (error: any) {
        console.error('Error exchanging Nebula OAuth code:', error)
        clearNebulaOAuthSession()
        redirectToAuthError(error?.message || 'Nebula 授权失败')
        return
      }
    }

    const authCode = currentUrl.searchParams.get('code')

    if (authCode) {
      const { data, error } = await supabase.auth.exchangeCodeForSession(authCode)

      if (error) {
        console.error('Error exchanging code for session:', error.message)
        redirectToAuthError(error.message)
        return
      }

      if (data.session) {
        redirectTo(consumePostAuthRedirect() || '/')
        return
      }
    }

    const hashFragment = currentUrl.hash.startsWith('#')
      ? currentUrl.hash.slice(1)
      : currentUrl.hash
    const hashParams = new URLSearchParams(hashFragment)
    const accessToken = hashParams.get('access_token')
    const refreshToken = hashParams.get('refresh_token')

    if (accessToken && refreshToken) {
      const { error } = await supabase.auth.setSession({
        access_token: accessToken,
        refresh_token: refreshToken
      })

      if (error) {
        redirectToAuthError(error.message)
        return
      }

      redirectTo(consumePostAuthRedirect() || '/')
      return
    }

    // 如果没有找到session，重定向到登录页面
    redirectToAuthError('No session found')
  } catch (error) {
    console.error('Unexpected error in handleAuthCallback:', error)
    clearNebulaOAuthSession()
    redirectToAuthError('Authentication failed')
  }
}
