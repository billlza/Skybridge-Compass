'use client'

/**
 * 密码重置页面
 * 处理密码重置链接的回调
 */

import { useState, useCallback, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { motion } from 'framer-motion'
import { supabase } from '@/lib/supabase'
import { Lock, Eye, EyeOff, Loader2, CheckCircle, ArrowRight } from 'lucide-react'
import { evaluatePasswordStrength } from '@/lib/auth'

export default function ResetPasswordPage() {
  const router = useRouter()
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  const passwordStrength = password ? evaluatePasswordStrength(password) : null

  // 确保从重置链接回调后已建立会话（兼容 PKCE code flow）
  useEffect(() => {
    const ensureSession = async () => {
      try {
        const params = new URLSearchParams(window.location.search)
        const code = params.get('code')
        if (code) {
          const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code)
          if (exchangeError) {
            console.error('Reset password exchangeCodeForSession error:', exchangeError)
            setError('链接无效或已过期，请重新发起重置密码')
            return
          }
        }

        const { data, error: sessionError } = await supabase.auth.getSession()
        if (sessionError) {
          console.error('Reset password getSession error:', sessionError)
          setError('无法获取会话，请重新发起重置密码')
          return
        }

        if (!data.session) {
          setError('未检测到有效会话，请确认使用的是最新的重置密码链接')
        }
      } catch {
        setError('处理重置链接时发生错误，请重新发起重置密码')
      }
    }

    ensureSession()
  }, [])

  const handleSubmit = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)

    if (password.length < 8) {
      setError('密码至少需要8个字符')
      return
    }

    if (passwordStrength?.level === 'weak') {
      setError('密码强度不足，请使用更复杂的密码')
      return
    }

    if (password !== confirmPassword) {
      setError('两次输入的密码不一致')
      return
    }

    setIsLoading(true)

    try {
      const { error } = await supabase.auth.updateUser({
        password,
      })

      if (error) {
        setError(error.message)
      } else {
        setSuccess(true)
        setTimeout(() => {
          router.push('/')
        }, 2000)
      }
    } catch {
      setError('重置密码时发生错误')
    } finally {
      setIsLoading(false)
    }
  }, [password, confirmPassword, passwordStrength, router])

  if (success) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center">
        <motion.div
          initial={{ opacity: 0, scale: 0.95 }}
          animate={{ opacity: 1, scale: 1 }}
          className="text-center"
        >
          <div className="w-20 h-20 bg-green-500/20 rounded-full flex items-center justify-center mx-auto mb-6">
            <CheckCircle className="w-10 h-10 text-green-400" />
          </div>
          <h1 className="text-2xl font-bold text-white mb-2">密码已重置</h1>
          <p className="text-white/60">正在跳转到主页...</p>
        </motion.div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center p-4">
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="w-full max-w-md"
      >
        <div className="bg-slate-800/50 backdrop-blur-xl border border-white/10 rounded-3xl p-8">
          {/* Logo */}
          <div className="flex items-center justify-center mb-8">
            <div className="w-16 h-16 bg-gradient-to-br from-accent to-blue-500 rounded-2xl flex items-center justify-center shadow-lg shadow-accent/25">
              <span className="text-2xl font-bold text-white">SC</span>
            </div>
          </div>

          <h1 className="text-2xl font-bold text-white text-center mb-2">重置密码</h1>
          <p className="text-white/60 text-center mb-8">请输入您的新密码</p>

          {error && (
            <motion.div
              initial={{ opacity: 0, y: -10 }}
              animate={{ opacity: 1, y: 0 }}
              className="mb-6 p-4 bg-red-500/10 border border-red-500/20 rounded-xl text-red-400 text-sm"
            >
              {error}
            </motion.div>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            {/* 新密码 */}
            <div>
              <div className="relative">
                <Lock className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
                <input
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="新密码（至少8个字符）"
                  className="w-full pl-12 pr-12 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                  autoComplete="new-password"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-4 top-1/2 -translate-y-1/2 text-white/40 hover:text-white/60 transition-colors"
                >
                  {showPassword ? <EyeOff size={20} /> : <Eye size={20} />}
                </button>
              </div>

              {/* 密码强度指示器 */}
              {password && passwordStrength && (
                <motion.div
                  initial={{ opacity: 0, height: 0 }}
                  animate={{ opacity: 1, height: 'auto' }}
                  className="mt-3"
                >
                  <div className="flex items-center gap-2 mb-2">
                    <div className="flex-1 flex gap-1">
                      {[1, 2, 3, 4].map((level) => (
                        <div
                          key={level}
                          className={`h-1 flex-1 rounded-full transition-colors ${
                            passwordStrength.score >= level * 2 - 1
                              ? passwordStrength.level === 'weak'
                                ? 'bg-red-500'
                                : passwordStrength.level === 'medium'
                                ? 'bg-orange-500'
                                : passwordStrength.level === 'strong'
                                ? 'bg-green-500'
                                : 'bg-blue-500'
                              : 'bg-white/10'
                          }`}
                        />
                      ))}
                    </div>
                    <span
                      className={`text-xs ${
                        passwordStrength.level === 'weak'
                          ? 'text-red-400'
                          : passwordStrength.level === 'medium'
                          ? 'text-orange-400'
                          : passwordStrength.level === 'strong'
                          ? 'text-green-400'
                          : 'text-blue-400'
                      }`}
                    >
                      {passwordStrength.description}
                    </span>
                  </div>
                </motion.div>
              )}
            </div>

            {/* 确认密码 */}
            <div className="relative">
              <Lock className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
              <input
                type={showPassword ? 'text' : 'password'}
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                placeholder="确认新密码"
                className="w-full pl-12 pr-4 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                autoComplete="new-password"
              />
            </div>

            {/* 提交按钮 */}
            <button
              type="submit"
              disabled={isLoading}
              className="w-full py-4 bg-gradient-to-r from-accent to-blue-500 text-white font-semibold rounded-xl flex items-center justify-center gap-2 hover:opacity-90 disabled:opacity-50 transition-opacity shadow-lg shadow-accent/25"
            >
              {isLoading ? (
                <Loader2 className="animate-spin" size={20} />
              ) : (
                <>
                  重置密码
                  <ArrowRight size={20} />
                </>
              )}
            </button>
          </form>

          <div className="mt-6 text-center">
            <button
              onClick={() => router.push('/')}
              className="text-white/60 hover:text-white text-sm transition-colors"
            >
              返回首页
            </button>
          </div>
        </div>
      </motion.div>
    </div>
  )
}

