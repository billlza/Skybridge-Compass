import React, { createContext, useContext, useEffect, useState, useCallback, useRef } from 'react'
import { User } from '@supabase/supabase-js'
import { 
  supabase, 
  getCurrentUser,
  getUserProfile as fetchCurrentUserProfile,
  signInWithNebulaId,
  signInWithPassword, 
  signInWithPhone, 
  signUp, 
  signUpWithPhone, 
  sendPhoneOTP, 
  verifyPhoneOTP, 
  signOut
} from '../lib/supabase'

interface UserProfile {
  id: string
  email: string | null
  phone: string | null
  custom_user_id: string | null
  nebula_id: string | null
  full_name: string | null
  account_type: string | null
  avatar_url: string | null
  created_at: string
  updated_at: string
}

interface AuthContextType {
  user: User | null
  userProfile: UserProfile | null
  loading: boolean
  refreshProfile: () => Promise<void>
  signIn: (email: string, password: string) => Promise<any>
  signInNebula: (nebulaId: string, password: string) => Promise<any>
  signInPhone: (phone: string, password: string) => Promise<any>
  signUp: (email: string, password: string, metadata?: any) => Promise<any>
  signUpPhone: (phone: string, password: string, metadata?: any) => Promise<any>
  sendOTP: (phone: string) => Promise<any>
  verifyOTP: (phone: string, token: string) => Promise<any>
  signOut: () => Promise<any>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null)
  const [loading, setLoading] = useState(true)
  const isMountedRef = useRef(true)
  const authSubscriptionRef = useRef<any>(null)
  const initTimeoutRef = useRef<NodeJS.Timeout | null>(null)
  const updateTimeoutsRef = useRef<Set<NodeJS.Timeout>>(new Set())

  // 获取用户资料的函数
  const fetchUserProfile = useCallback(async (userId: string): Promise<UserProfile | null> => {
    try {
      const profile = await fetchCurrentUserProfile()
      return profile
    } catch (error) {
      console.error('Error fetching user profile:', error)
      return null
    }
  }, [])

  // 刷新用户资料
  const refreshProfile = useCallback(async () => {
    if (!user?.id) return
    
    const profile = await fetchUserProfile(user.id)
    if (isMountedRef.current) {
      setUserProfile(profile)
    }
  }, [user?.id, fetchUserProfile])

  // 安全的状态更新函数
  const safeSetUser = useCallback((newUser: User | null) => {
    if (isMountedRef.current) {
      setUser(newUser)
    }
  }, [])

  const safeSetLoading = useCallback((newLoading: boolean) => {
    if (isMountedRef.current) {
      setLoading(newLoading)
    }
  }, [])

  // 用户状态初始化和监听
  useEffect(() => {
    isMountedRef.current = true

    async function initializeAuth() {
      try {
        // 添加延迟以避免竞态条件
        initTimeoutRef.current = setTimeout(async () => {
          if (!isMountedRef.current) return
          
          try {
            const { data: { user } } = await supabase.auth.getUser()
            safeSetUser(user)
          } catch (error) {
            console.error('Auth initialization error:', error)
            safeSetUser(null)
          } finally {
            safeSetLoading(false)
          }
        }, 100)
      } catch (error) {
        console.error('Auth initialization setup error:', error)
        safeSetLoading(false)
      }
    }

    // 设置认证状态监听器
    try {
      const { data: { subscription } } = supabase.auth.onAuthStateChange(
        (event, session) => {
          // 严格检查组件是否已挂载
          if (!isMountedRef.current) {
            return
          }

          try {
            // 强化：使用更长的延迟和多重安全检查
            const updateTimeout = setTimeout(() => {
              // 三重安全检查
              if (!isMountedRef.current) {
                updateTimeoutsRef.current.delete(updateTimeout)
                return
              }
              
              try {
                // 强化：分步骤处理不同事件，每步都检查组件状态
                if (event === 'SIGNED_IN' && session?.user) {
                  if (!isMountedRef.current) return
                  safeSetUser(session.user)
                  if (!isMountedRef.current) return
                  
                  // 获取用户资料
                  fetchUserProfile(session.user.id).then(profile => {
                    if (isMountedRef.current) {
                      setUserProfile(profile)
                    }
                  }).catch(err => {
                    console.error('Error fetching profile on sign in:', err)
                  })
                  
                  if (!isMountedRef.current) return
                  safeSetLoading(false)
                } else if (event === 'SIGNED_OUT') {
                  if (!isMountedRef.current) return
                  safeSetUser(null)
                  if (!isMountedRef.current) return
                  setUserProfile(null)
                  if (!isMountedRef.current) return
                  safeSetLoading(false)
                } else if (event === 'TOKEN_REFRESHED' && session?.user) {
                  if (!isMountedRef.current) return
                  safeSetUser(session.user)
                  
                  // Token刷新时也更新用户资料
                  fetchUserProfile(session.user.id).then(profile => {
                    if (isMountedRef.current) {
                      setUserProfile(profile)
                    }
                  }).catch(err => {
                    console.error('Error fetching profile on token refresh:', err)
                  })
                } else if (event === 'INITIAL_SESSION') {
                  if (!isMountedRef.current) return
                  safeSetUser(session?.user || null)
                  
                  // 如果有用户，获取用户资料
                  if (session?.user) {
                    fetchUserProfile(session.user.id).then(profile => {
                      if (isMountedRef.current) {
                        setUserProfile(profile)
                      }
                    }).catch(err => {
                      console.error('Error fetching profile on initial session:', err)
                    })
                  } else {
                    setUserProfile(null)
                  }
                  
                  if (!isMountedRef.current) return
                  safeSetLoading(false)
                }
                
              } catch (updateError) {
                console.error('Enhanced auth state update error:', updateError)
                // 在错误情况下确保加载状态被清除
                if (isMountedRef.current) {
                  try {
                    safeSetLoading(false)
                  } catch (loadingError) {
                    console.error('Error clearing loading state:', loadingError)
                  }
                }
              } finally {
                updateTimeoutsRef.current.delete(updateTimeout)
              }
            }, 100) // 强化：进一步增加延迟时间到100ms
            
            // 跟踪此定时器以便清理
            updateTimeoutsRef.current.add(updateTimeout)
          } catch (error) {
            console.error('Auth state change error:', error)
            safeSetLoading(false)
          }
        }
      )

      authSubscriptionRef.current = subscription
      initializeAuth()
    } catch (error) {
      console.error('Auth subscription setup error:', error)
      safeSetLoading(false)
    }

    return () => {
      isMountedRef.current = false
      const pendingTimeouts = updateTimeoutsRef.current
      
      // 清理初始化定时器
      if (initTimeoutRef.current) {
        clearTimeout(initTimeoutRef.current)
        initTimeoutRef.current = null
      }
      
      // 清理所有悬停的状态更新定时器
      pendingTimeouts.forEach(timeout => {
        clearTimeout(timeout)
      })
      pendingTimeouts.clear()
      
      // 安全地取消订阅
      if (authSubscriptionRef.current) {
        try {
          authSubscriptionRef.current.unsubscribe()
        } catch (error) {
          console.error('Error unsubscribing auth listener:', error)
        }
        authSubscriptionRef.current = null
      }
      
    }
  }, [fetchUserProfile, safeSetUser, safeSetLoading])

  // 认证方法 - 使用 useCallback 优化
  const handleSignIn = useCallback(async (email: string, password: string) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')
    
    safeSetLoading(true)
    try {
      const result = await signInWithPassword(email, password)
      return result
    } catch (error) {
      safeSetLoading(false)
      throw error
    }
  }, [safeSetLoading])

  const handleSignInNebula = useCallback(async (nebulaId: string, password: string) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')

    safeSetLoading(true)
    try {
      const result = await signInWithNebulaId(nebulaId, password)
      return result
    } catch (error) {
      safeSetLoading(false)
      throw error
    }
  }, [safeSetLoading])

  const handleSignInPhone = useCallback(async (phone: string, password: string) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')
    
    safeSetLoading(true)
    try {
      const result = await signInWithPhone(phone, password)
      return result
    } catch (error) {
      safeSetLoading(false)
      throw error
    }
  }, [safeSetLoading])

  const handleSignUp = useCallback(async (email: string, password: string, metadata: any = {}) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')

    return signUp(email, password, metadata)
  }, [])

  const handleSignUpPhone = useCallback(async (phone: string, password: string, metadata: any = {}) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')

    return signUpWithPhone(phone, password, metadata)
  }, [])

  const handleSendOTP = useCallback(async (phone: string) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')

    return sendPhoneOTP(phone)
  }, [])

  const handleVerifyOTP = useCallback(async (phone: string, token: string) => {
    if (!isMountedRef.current) throw new Error('组件已卸载')

    return verifyPhoneOTP(phone, token)
  }, [])

  const handleSignOut = useCallback(async () => {
    if (!isMountedRef.current) throw new Error('组件已卸载')
    
    safeSetLoading(true)
    try {
      const result = await signOut()
      return result
    } catch (error) {
      safeSetLoading(false)
      throw error
    }
  }, [safeSetLoading])

  const value = React.useMemo(() => ({
    user,
    userProfile,
    loading,
    refreshProfile,
    signIn: handleSignIn,
    signInNebula: handleSignInNebula,
    signInPhone: handleSignInPhone,
    signUp: handleSignUp,
    signUpPhone: handleSignUpPhone,
    sendOTP: handleSendOTP,
    verifyOTP: handleVerifyOTP,
    signOut: handleSignOut
  }), [
    user, 
    userProfile,
    loading, 
    refreshProfile,
    handleSignIn, 
    handleSignInNebula,
    handleSignInPhone, 
    handleSignUp, 
    handleSignUpPhone, 
    handleSendOTP, 
    handleVerifyOTP, 
    handleSignOut
  ])

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth 必须在 AuthProvider 内使用')
  }
  return context
}
