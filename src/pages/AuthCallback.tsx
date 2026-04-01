import React, { useEffect, useRef } from 'react'
import { handleAuthCallback } from '../lib/supabase'

const AuthCallback: React.FC = () => {
  const isMountedRef = useRef(true)
  const callbackProcessedRef = useRef(false)

  useEffect(() => {
    isMountedRef.current = true
    
    // 防止重复执行
    if (callbackProcessedRef.current) return
    
    callbackProcessedRef.current = true
    
    const processCallback = async () => {
      try {
        if (isMountedRef.current) {
          await handleAuthCallback()
        }
      } catch (error) {
        console.error('Auth callback processing error:', error)
        if (isMountedRef.current) {
          // 在错误情况下重定向到登录页面
          window.location.href = '/auth?error=' + encodeURIComponent('Authentication failed')
        }
      }
    }
    
    processCallback()
    
    return () => {
      isMountedRef.current = false
    }
  }, [])

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
      <div className="text-center">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500 mx-auto mb-4"></div>
        <h2 className="text-xl font-semibold text-white mb-2">正在验证您的账号...</h2>
        <p className="text-gray-400">请稍候，我们正在为您完成登录</p>
      </div>
    </div>
  )
}

export default AuthCallback
