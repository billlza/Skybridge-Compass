'use client'

/**
 * 注册表单组件
 * 与 Mac 应用 AuthenticationView.swift 对齐
 */

import React, { useState, useCallback, useMemo } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { Mail, Lock, User, ArrowRight, Loader2, Eye, EyeOff, CheckCircle, XCircle, AlertCircle } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { isValidEmail, evaluatePasswordStrength, isDisposableEmail } from '@/lib/auth'

// ============================================================================
// 类型定义
// ============================================================================

interface RegisterFormProps {
  onSuccess?: () => void
  onSwitchToLogin?: () => void
}

// ============================================================================
// 组件
// ============================================================================

export default function RegisterForm({ onSuccess, onSwitchToLogin }: RegisterFormProps) {
  const { signUpWithEmail, isLoading, error, clearError } = useAuth()

  // 状态
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirmPassword, setShowConfirmPassword] = useState(false)
  const [localError, setLocalError] = useState<string | null>(null)
  const [verificationSent, setVerificationSent] = useState(false)

  // 密码强度
  const passwordStrength = useMemo(() => {
    if (!password) return null
    return evaluatePasswordStrength(password)
  }, [password])

  // 验证状态
  const validations = useMemo(() => ({
    email: email ? isValidEmail(email) : null,
    emailNotDisposable: email && isValidEmail(email) ? !isDisposableEmail(email) : null,
    passwordLength: password.length >= 8,
    passwordStrength: passwordStrength ? passwordStrength.level !== 'weak' : false,
    passwordMatch: password && confirmPassword ? password === confirmPassword : null,
    displayNameValid: displayName.length >= 2,
  }), [email, password, confirmPassword, displayName, passwordStrength])

  // 表单是否有效
  const isFormValid = useMemo(() => {
    return (
      validations.email &&
      validations.emailNotDisposable &&
      validations.passwordLength &&
      validations.passwordStrength &&
      validations.passwordMatch &&
      validations.displayNameValid
    )
  }, [validations])

  // 提交注册
  const handleSubmit = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    setLocalError(null)
    clearError()

    // 验证
    if (!isValidEmail(email)) {
      setLocalError('请输入有效的邮箱地址')
      return
    }

    if (isDisposableEmail(email)) {
      setLocalError('不支持使用临时邮箱注册')
      return
    }

    if (password.length < 8) {
      setLocalError('密码至少需要8个字符')
      return
    }

    if (passwordStrength?.level === 'weak') {
      setLocalError('密码强度不足，请使用更复杂的密码')
      return
    }

    if (password !== confirmPassword) {
      setLocalError('两次输入的密码不一致')
      return
    }

    if (displayName.length < 2) {
      setLocalError('显示名称至少需要2个字符')
      return
    }

    const result = await signUpWithEmail(email, password, displayName)
    
    if (result.success) {
      if (result.requiresVerification) {
        setVerificationSent(true)
      } else {
        onSuccess?.()
      }
    }
  }, [email, password, confirmPassword, displayName, passwordStrength, signUpWithEmail, clearError, onSuccess])

  // 显示的错误
  const displayError = localError || error

  // 验证邮件已发送状态
  if (verificationSent) {
    return (
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        className="w-full max-w-md mx-auto text-center"
      >
        <div className="w-20 h-20 mx-auto mb-6 bg-green-500/20 rounded-full flex items-center justify-center">
          <CheckCircle className="text-green-400" size={40} />
        </div>
        <h2 className="text-2xl font-bold text-white mb-4">验证邮件已发送</h2>
        <p className="text-white/60 mb-8">
          我们已向 <span className="text-accent">{email}</span> 发送了一封验证邮件。
          <br />
          请查收并点击邮件中的链接完成注册。
        </p>
        <button
          onClick={onSwitchToLogin}
          className="text-accent hover:text-accent/80 transition-colors"
        >
          返回登录
        </button>
      </motion.div>
    )
  }

  return (
    <div className="w-full max-w-md mx-auto">
      <h2 className="text-2xl font-bold text-white mb-2">创建账号</h2>
      <p className="text-white/60 mb-8">加入 SkyBridge Compass，开始您的跨平台之旅</p>

      {/* 错误提示 */}
      <AnimatePresence>
        {displayError && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            className="mb-6 p-4 bg-red-500/10 border border-red-500/20 rounded-xl text-red-400 text-sm flex items-center gap-3"
          >
            <AlertCircle size={20} />
            {displayError}
          </motion.div>
        )}
      </AnimatePresence>

      <form onSubmit={handleSubmit} className="space-y-4">
        {/* 显示名称 */}
        <div className="relative">
          <User className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
          <input
            type="text"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            placeholder="显示名称"
            className="w-full pl-12 pr-12 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
            autoComplete="name"
          />
          {displayName && (
            <div className="absolute right-4 top-1/2 -translate-y-1/2">
              {validations.displayNameValid ? (
                <CheckCircle className="text-green-400" size={20} />
              ) : (
                <XCircle className="text-red-400" size={20} />
              )}
            </div>
          )}
        </div>

        {/* 邮箱 */}
        <div className="relative">
          <Mail className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="邮箱地址"
            className="w-full pl-12 pr-12 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
            autoComplete="email"
          />
          {email && (
            <div className="absolute right-4 top-1/2 -translate-y-1/2">
              {validations.email && validations.emailNotDisposable ? (
                <CheckCircle className="text-green-400" size={20} />
              ) : (
                <XCircle className="text-red-400" size={20} />
              )}
            </div>
          )}
        </div>

        {/* 密码 */}
        <div>
          <div className="relative">
            <Lock className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
            <input
              type={showPassword ? 'text' : 'password'}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="密码（至少8个字符）"
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
              <p className="text-white/40 text-xs">
                建议包含大小写字母、数字和特殊字符
              </p>
            </motion.div>
          )}
        </div>

        {/* 确认密码 */}
        <div className="relative">
          <Lock className="absolute left-4 top-1/2 -translate-y-1/2 text-white/40" size={20} />
          <input
            type={showConfirmPassword ? 'text' : 'password'}
            value={confirmPassword}
            onChange={(e) => setConfirmPassword(e.target.value)}
            placeholder="确认密码"
            className="w-full pl-12 pr-12 py-4 bg-white/5 border border-white/10 rounded-xl text-white placeholder-white/40 focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
            autoComplete="new-password"
          />
          <button
            type="button"
            onClick={() => setShowConfirmPassword(!showConfirmPassword)}
            className="absolute right-12 top-1/2 -translate-y-1/2 text-white/40 hover:text-white/60 transition-colors"
          >
            {showConfirmPassword ? <EyeOff size={20} /> : <Eye size={20} />}
          </button>
          {confirmPassword && (
            <div className="absolute right-4 top-1/2 -translate-y-1/2">
              {validations.passwordMatch ? (
                <CheckCircle className="text-green-400" size={20} />
              ) : (
                <XCircle className="text-red-400" size={20} />
              )}
            </div>
          )}
        </div>

        {/* 注册按钮 */}
        <button
          type="submit"
          disabled={isLoading || !isFormValid}
          className="w-full py-4 bg-gradient-to-r from-accent to-blue-500 text-white font-semibold rounded-xl flex items-center justify-center gap-2 hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-opacity shadow-lg shadow-accent/25"
        >
          {isLoading ? (
            <Loader2 className="animate-spin" size={20} />
          ) : (
            <>
              创建账号
              <ArrowRight size={20} />
            </>
          )}
        </button>
      </form>

      {/* 切换到登录 */}
      <div className="mt-8 text-center">
        <button
          onClick={onSwitchToLogin}
          className="text-white/60 hover:text-white text-sm transition-colors"
        >
          已有账号？<span className="text-accent ml-1">立即登录</span>
        </button>
      </div>

      {/* 服务条款 */}
      <p className="mt-6 text-center text-white/40 text-xs">
        注册即表示您同意我们的
        <a href="/terms" className="text-accent hover:underline mx-1">服务条款</a>
        和
        <a href="/privacy" className="text-accent hover:underline mx-1">隐私政策</a>
      </p>
    </div>
  )
}

