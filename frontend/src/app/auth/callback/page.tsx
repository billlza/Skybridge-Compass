'use client'

/**
 * OAuth 回调页面
 * 处理 Apple Sign In 等 OAuth 登录的回调
 */

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { Loader2, CheckCircle, XCircle } from 'lucide-react'

export default function AuthCallbackPage() {
  const router = useRouter()
  const [status, setStatus] = useState<'loading' | 'success' | 'error'>('loading')
  const [message, setMessage] = useState('正在处理登录...')

  useEffect(() => {
    const handleCallback = async () => {
      try {
        // Supabase OAuth 可能是 PKCE code flow（URL 带 ?code=...）
        // 也可能是 implicit flow（URL 带 access_token 等）
        const params = new URLSearchParams(window.location.search)
        const code = params.get('code')

        if (code) {
          const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code)
          if (exchangeError) {
            console.error('Auth callback exchangeCodeForSession error:', exchangeError)
            setStatus('error')
            setMessage('登录失败，请重试')
            return
          }
        }

        const { data, error } = await supabase.auth.getSession()

        if (error) {
          console.error('Auth callback error:', error)
          setStatus('error')
          setMessage('登录失败，请重试')
          return
        }

        if (data.session) {
          setStatus('success')
          setMessage('登录成功！正在跳转...')
          
          // 延迟跳转以显示成功状态
          setTimeout(() => {
            router.push('/')
          }, 1500)
        } else {
          setStatus('error')
          setMessage('未能获取登录信息')
        }
      } catch (err) {
        console.error('Auth callback exception:', err)
        setStatus('error')
        setMessage('处理登录时发生错误')
      }
    }

    handleCallback()
  }, [router])

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center">
      <div className="text-center">
        {status === 'loading' && (
          <>
            <Loader2 className="w-16 h-16 text-accent animate-spin mx-auto mb-6" />
            <h1 className="text-2xl font-bold text-white mb-2">{message}</h1>
            <p className="text-white/60">请稍候...</p>
          </>
        )}

        {status === 'success' && (
          <>
            <div className="w-16 h-16 bg-green-500/20 rounded-full flex items-center justify-center mx-auto mb-6">
              <CheckCircle className="w-10 h-10 text-green-400" />
            </div>
            <h1 className="text-2xl font-bold text-white mb-2">{message}</h1>
            <p className="text-white/60">即将返回主页</p>
          </>
        )}

        {status === 'error' && (
          <>
            <div className="w-16 h-16 bg-red-500/20 rounded-full flex items-center justify-center mx-auto mb-6">
              <XCircle className="w-10 h-10 text-red-400" />
            </div>
            <h1 className="text-2xl font-bold text-white mb-2">{message}</h1>
            <button
              onClick={() => router.push('/')}
              className="mt-6 px-6 py-3 bg-accent text-white rounded-xl hover:bg-accent/90 transition-colors"
            >
              返回首页
            </button>
          </>
        )}
      </div>
    </div>
  )
}

