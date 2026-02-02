'use client'

/**
 * 登录表单组件
 * 支持邮箱、手机号、Apple 登录
 * 与 Mac 应用 AuthenticationView.swift 对齐
 */

import React, { useState, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { Mail, Phone, Apple, Lock, ArrowRight, Loader2, Eye, EyeOff } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { isValidEmail, isValidPhoneNumber } from '@/lib/auth'

// ============================================================================
// 类型定义
// ============================================================================

type LoginMethod = 'email' | 'phone' | 'apple'

interface LoginFormProps {
  onSuccess?: () => void
  onSwitchToRegister?: () => void
}

// ============================================================================
// 组件
// ============================================================================

export default function LoginForm({ onSuccess, onSwitchToRegister }: LoginFormProps) {
  const { signInWithEmail, sendPhoneOTP, verifyPhoneOTP, signInWithApple, isLoading, error, clearError } = useAuth()

  // 状态
  const [method, setMethod] = useState<LoginMethod>('email')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [phone, setPhone] = useState('')
  const [otpCode, setOtpCode] = useState('')
  const [otpSent, setOtpSent] = useState(false)
  const [countdown, setCountdown] = useState(0)
  const [showPassword, setShowPassword] = useState(false)
  const [localError, setLocalError] = useState<string | null>(null)

  // 切换登录方式
  const switchMethod = useCallback((newMethod: LoginMethod) => {
    setMethod(newMethod)
    setLocalError(null)
    clearError()
    setOtpSent(false)
    setOtpCode('')
  }, [clearError])

  // 邮箱登录
  const handleEmailLogin = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    setLocalError(null)

    if (!isValidEmail(email)) {
      setLocalError('请输入有效的邮箱地址')
      return
    }

    if (password.length < 6) {
      setLocalError('密码至少需要6个字符')
      return
    }

    const success = await signInWithEmail(email, password)
    if (success) {
      onSuccess?.()
    }
  }, [email, password, signInWithEmail, onSuccess])

  // 发送验证码
  const handleSendOTP = useCallback(async () => {
    setLocalError(null)

    if (!isValidPhoneNumber(phone)) {
      setLocalError('请输入有效的手机号码')
      return
    }

    const success = await sendPhoneOTP(phone)
    if (success) {
      setOtpSent(true)
      setCountdown(60)
      
      // 倒计时
      const timer = setInterval(() => {
        setCountdown(prev => {
          if (prev <= 1) {
            clearInterval(timer)
            return 0
          }
          return prev - 1
        })
      }, 1000)
    }
  }, [phone, sendPhoneOTP])

  // 手机登录
  const handlePhoneLogin = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    setLocalError(null)

    if (!otpCode || otpCode.length < 4) {
      setLocalError('请输入验证码')
      return
    }

    const success = await verifyPhoneOTP(phone, otpCode)
    if (success) {
      onSuccess?.()
    }
  }, [phone, otpCode, verifyPhoneOTP, onSuccess])

  // Apple 登录
  const handleAppleLogin = useCallback(async () => {
    await signInWithApple()
    // Apple 登录会重定向，不需要在这里处理 success
  }, [signInWithApple])

  // 显示的错误
  const displayError = localError || error

  return (
    <div className="w-full max-w-md mx-auto">
      {/* 登录方式选择 */}
      <div className="flex gap-2 mb-8 p-1 bg-white/5 rounded-2xl">
        {[
          { id: 'email' as LoginMethod, icon: Mail, label: '邮箱' },
          { id: 'phone' as LoginMethod, icon: Phone, label: '手机' },
          { id: 'apple' as LoginMethod, icon: Apple, label: 'Apple' },
        ].map(({ id, icon: Icon, label }) => (
          <button
            key={id}
            onClick={() => switchMethod(id)}
            className={`flex-1 flex items-center justify-center gap-2 py-3 px-4 rounded-xl transition-all duration-300 ${
              method === id
                ? 'bg-accent text-white shadow-lg shadow-accent/25'
                : 'text-white/60 hover:text-white hover:bg-white/10'
            }`}
          >
            <Icon size={18} />
            <span className="text-sm font-medium">{label}</span>
          </button>
        ))}
      </div>

      {/* 错误提示 */}
      <AnimatePresence>
        {displayError && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            className="mb-6 p-4 bg-red-500/10 border border-red-500/20 rounded-xl text-red-400 text-sm"
          >
            {displayError}
          </motion.div>
        )}
      </AnimatePresence>

      {/* 登录表单 */}
      <AnimatePresence mode="wait">
        {method === 'email' && (
          <motion.form
            key="email"
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            onSubmit={handleEmailLogin}
            className="space-y-4"
          >
            {/* 邮箱输入 */}
            <div className="relative">
              <Mail className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="邮箱地址"
                className="w-full pl-12 pr-4 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                autoComplete="email"
              />
            </div>

            {/* 密码输入 */}
            <div className="relative">
              <Lock className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
              <input
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="密码"
                className="w-full pl-12 pr-12 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                autoComplete="current-password"
              />
              <button
                type="button"
                onClick={() => setShowPassword(!showPassword)}
                className="absolute right-4 top-1/2 -translate-y-1/2 text-white/40 hover:text-white/60 transition-colors"
              >
                {showPassword ? <EyeOff size={20} /> : <Eye size={20} />}
              </button>
            </div>

            {/* 登录按钮 */}
            <button
              type="submit"
              disabled={isLoading}
              className="w-full py-4 bg-gradient-to-r from-accent to-blue-500 text-white font-semibold rounded-xl flex items-center justify-center gap-2 hover:opacity-90 disabled:opacity-50 transition-opacity shadow-lg shadow-accent/25"
            >
              {isLoading ? (
                <Loader2 className="animate-spin" size={20} />
              ) : (
                <>
                  登录
                  <ArrowRight size={20} />
                </>
              )}
            </button>
          </motion.form>
        )}

        {method === 'phone' && (
          <motion.form
            key="phone"
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            onSubmit={handlePhoneLogin}
            className="space-y-4"
          >
            {/* 手机号输入 */}
            <div className="relative">
              <Phone className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
              <input
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="手机号码"
                className="w-full pl-12 pr-4 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                autoComplete="tel"
              />
            </div>

            {/* 验证码输入 */}
            {otpSent && (
              <motion.div
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: 'auto' }}
                className="relative"
              >
                <input
                  type="text"
                  value={otpCode}
                  onChange={(e) => setOtpCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
                  placeholder="验证码"
                  className="w-full px-4 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all text-center text-2xl tracking-widest"
                  maxLength={6}
                />
              </motion.div>
            )}

            {/* 发送验证码 / 登录按钮 */}
            {!otpSent ? (
              <button
                type="button"
                onClick={handleSendOTP}
                disabled={isLoading}
                className="w-full py-4 bg-gradient-to-r from-green-500 to-emerald-500 text-white font-semibold rounded-xl flex items-center justify-center gap-2 hover:opacity-90 disabled:opacity-50 transition-opacity shadow-lg shadow-green-500/25"
              >
                {isLoading ? (
                  <Loader2 className="animate-spin" size={20} />
                ) : (
                  '发送验证码'
                )}
              </button>
            ) : (
              <div className="space-y-3">
                <button
                  type="submit"
                  disabled={isLoading || otpCode.length < 4}
                  className="w-full py-4 bg-gradient-to-r from-green-500 to-emerald-500 text-white font-semibold rounded-xl flex items-center justify-center gap-2 hover:opacity-90 disabled:opacity-50 transition-opacity shadow-lg shadow-green-500/25"
                >
                  {isLoading ? (
                    <Loader2 className="animate-spin" size={20} />
                  ) : (
                    <>
                      登录
                      <ArrowRight size={20} />
                    </>
                  )}
                </button>
                <button
                  type="button"
                  onClick={handleSendOTP}
                  disabled={countdown > 0}
                  className="w-full py-2 text-white/60 text-sm hover:text-white disabled:text-white/30 transition-colors"
                >
                  {countdown > 0 ? `${countdown}秒后可重新发送` : '重新发送验证码'}
                </button>
              </div>
            )}
          </motion.form>
        )}

        {method === 'apple' && (
          <motion.div
            key="apple"
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            className="space-y-4"
          >
            <button
              onClick={handleAppleLogin}
              disabled={isLoading}
              className="w-full py-4 bg-white text-black font-semibold rounded-xl flex items-center justify-center gap-3 hover:bg-white/90 disabled:opacity-50 transition-all shadow-lg"
            >
              {isLoading ? (
                <Loader2 className="animate-spin text-black" size={20} />
              ) : (
                <>
                  <Apple size={22} />
                  使用 Apple ID 登录
                </>
              )}
            </button>
            <p className="text-center text-white/40 text-sm">
              使用 Face ID 或 Touch ID 快速登录
            </p>
          </motion.div>
        )}
      </AnimatePresence>

      {/* 切换到注册 */}
      <div className="mt-8 text-center">
        <button
          onClick={onSwitchToRegister}
          className="text-white/60 hover:text-white text-sm transition-colors"
        >
          还没有账号？<span className="text-accent ml-1">立即注册</span>
        </button>
      </div>
    </div>
  )
}

