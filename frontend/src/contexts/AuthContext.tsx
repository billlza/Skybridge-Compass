'use client'

/**
 * 认证上下文
 * 提供全局认证状态管理，与 Mac 应用 AuthenticationService 对齐
 */

import React, { createContext, useContext, useEffect, useState, useCallback } from 'react'
import type { ReactNode } from 'react'
import {
  AuthSession,
  signInWithEmail,
  signUpWithEmail,
  sendPhoneOTP,
  verifyPhoneOTP,
  signInWithApple,
  signOut as authSignOut,
  getCurrentSession,
  onAuthStateChange,
  resetPassword,
  updateUserProfile,
} from '@/lib/auth'

// ============================================================================
// 类型定义
// ============================================================================

interface AuthContextValue {
  // 状态
  session: AuthSession | null
  isLoading: boolean
  isAuthenticated: boolean
  error: string | null

  // 邮箱认证
  signInWithEmail: (email: string, password: string) => Promise<boolean>
  signUpWithEmail: (email: string, password: string, displayName?: string) => Promise<{ success: boolean; requiresVerification: boolean }>
  
  // 手机认证
  sendPhoneOTP: (phone: string) => Promise<boolean>
  verifyPhoneOTP: (phone: string, token: string) => Promise<boolean>
  
  // Apple 认证
  signInWithApple: () => Promise<boolean>
  
  // 其他
  resetPassword: (email: string) => Promise<boolean>
  signOut: () => Promise<void>
  clearError: () => void
  updateProfile: (updates: { displayName?: string; phoneNumber?: string; avatarUrl?: string }) => Promise<boolean>
}

// ============================================================================
// Context
// ============================================================================

const AuthContext = createContext<AuthContextValue | null>(null)

// ============================================================================
// Provider
// ============================================================================

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<AuthSession | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // 初始化：获取当前会话
  useEffect(() => {
    const initAuth = async () => {
      try {
        const currentSession = await getCurrentSession()
        setSession(currentSession)
      } catch (err) {
        console.error('Failed to get current session:', err)
      } finally {
        setIsLoading(false)
      }
    }

    initAuth()

    // 监听认证状态变化
    const { data: { subscription } } = onAuthStateChange((newSession) => {
      setSession(newSession)
      setIsLoading(false)
    })

    return () => {
      subscription.unsubscribe()
    }
  }, [])

  // 清除错误
  const clearError = useCallback(() => {
    setError(null)
  }, [])

  // 邮箱登录
  const handleSignInWithEmail = useCallback(async (email: string, password: string): Promise<boolean> => {
    setIsLoading(true)
    setError(null)

    const result = await signInWithEmail(email, password)
    
    if (result.error) {
      setError(result.error)
      setIsLoading(false)
      return false
    }

    setSession(result.session)
    setIsLoading(false)
    return true
  }, [])

  // 邮箱注册
  const handleSignUpWithEmail = useCallback(async (
    email: string,
    password: string,
    displayName?: string
  ): Promise<{ success: boolean; requiresVerification: boolean }> => {
    setIsLoading(true)
    setError(null)

    const result = await signUpWithEmail(email, password, displayName)
    
    if (result.error) {
      setError(result.error)
      setIsLoading(false)
      return { success: false, requiresVerification: false }
    }

    if (result.requiresEmailVerification) {
      setIsLoading(false)
      return { success: true, requiresVerification: true }
    }

    setSession(result.session)
    setIsLoading(false)
    return { success: true, requiresVerification: false }
  }, [])

  // 发送手机验证码
  const handleSendPhoneOTP = useCallback(async (phone: string): Promise<boolean> => {
    setError(null)

    const result = await sendPhoneOTP(phone)
    
    if (result.error) {
      setError(result.error)
      return false
    }

    return true
  }, [])

  // 验证手机 OTP
  const handleVerifyPhoneOTP = useCallback(async (phone: string, token: string): Promise<boolean> => {
    setIsLoading(true)
    setError(null)

    const result = await verifyPhoneOTP(phone, token)
    
    if (result.error) {
      setError(result.error)
      setIsLoading(false)
      return false
    }

    setSession(result.session)
    setIsLoading(false)
    return true
  }, [])

  // Apple 登录
  const handleSignInWithApple = useCallback(async (): Promise<boolean> => {
    setError(null)

    const result = await signInWithApple()
    
    if (result.error) {
      setError(result.error)
      return false
    }

    // Apple OAuth 会重定向，所以这里返回 true 表示已发起
    return true
  }, [])

  // 重置密码
  const handleResetPassword = useCallback(async (email: string): Promise<boolean> => {
    setError(null)

    const result = await resetPassword(email)
    
    if (result.error) {
      setError(result.error)
      return false
    }

    return true
  }, [])

  // 登出
  const handleSignOut = useCallback(async (): Promise<void> => {
    setIsLoading(true)
    
    await authSignOut()
    
    setSession(null)
    setError(null)
    setIsLoading(false)
  }, [])

  // 更新资料
  const handleUpdateProfile = useCallback(async (updates: {
    displayName?: string
    phoneNumber?: string
    avatarUrl?: string
  }): Promise<boolean> => {
    setError(null)

    const result = await updateUserProfile(updates)
    
    if (result.error) {
      setError(result.error)
      return false
    }

    // 刷新会话以获取更新后的用户信息
    const currentSession = await getCurrentSession()
    setSession(currentSession)

    return true
  }, [])

  const value: AuthContextValue = {
    session,
    isLoading,
    isAuthenticated: !!session && session.accessToken !== 'pending_verification',
    error,
    signInWithEmail: handleSignInWithEmail,
    signUpWithEmail: handleSignUpWithEmail,
    sendPhoneOTP: handleSendPhoneOTP,
    verifyPhoneOTP: handleVerifyPhoneOTP,
    signInWithApple: handleSignInWithApple,
    resetPassword: handleResetPassword,
    signOut: handleSignOut,
    clearError,
    updateProfile: handleUpdateProfile,
  }

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

// ============================================================================
// Hook
// ============================================================================

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext)
  
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  
  return context
}

// 导出便捷的认证状态检查 hook
export function useIsAuthenticated(): boolean {
  const { isAuthenticated } = useAuth()
  return isAuthenticated
}

export function useCurrentUser(): AuthSession | null {
  const { session } = useAuth()
  return session
}

