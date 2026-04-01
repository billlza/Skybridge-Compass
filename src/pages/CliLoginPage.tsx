import React, { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router-dom';

import { useAuth } from '../contexts/AuthContext';
import { approveCliLoginSession, fetchCliLoginSession, type CliLoginSession } from '../lib/cliLogin';

function formatExpiry(isoValue: string) {
  const date = new Date(isoValue)
  if (Number.isNaN(date.getTime())) {
    return '未知'
  }

  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    month: 'short',
    day: 'numeric'
  }).format(date)
}

function buildWebsiteLoginRedirect(path: string) {
  return `/auth?mode=login&redirect=${encodeURIComponent(path)}`
}

function cliRedirectStorageKey(sessionId: string) {
  return `skybridge.cli.redirect.${sessionId}`
}

const CliLoginPage: React.FC = () => {
  const { user, loading } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const sessionId = searchParams.get('session')?.trim() || ''
  const [session, setSession] = useState<CliLoginSession | null>(null)
  const [fetching, setFetching] = useState(true)
  const [approving, setApproving] = useState(false)
  const [error, setError] = useState('')
  const [redirectTo, setRedirectTo] = useState<string | null>(null)
  const currentPath = useMemo(() => `${location.pathname}${location.search}`, [location.pathname, location.search])

  useEffect(() => {
    let cancelled = false

    async function loadSession() {
      if (!sessionId) {
        setError('缺少 CLI 登录会话参数')
        setFetching(false)
        return
      }

      setFetching(true)
      setError('')

      try {
        const result = await fetchCliLoginSession(sessionId)
        if (!cancelled) {
          setSession(result)
          const storedRedirect = window.sessionStorage.getItem(cliRedirectStorageKey(sessionId))
          if (storedRedirect) {
            setRedirectTo(storedRedirect)
          }
        }
      } catch (err: any) {
        if (!cancelled) {
          setError(err?.message || '加载 CLI 登录会话失败')
          setSession(null)
        }
      } finally {
        if (!cancelled) {
          setFetching(false)
        }
      }
    }

    void loadSession()

    return () => {
      cancelled = true
    }
  }, [sessionId])

  useEffect(() => {
    if (!redirectTo) {
      return
    }

    const timer = window.setTimeout(() => {
      window.location.assign(redirectTo)
    }, 800)

    return () => window.clearTimeout(timer)
  }, [redirectTo])

  const handleApprove = async () => {
    if (!sessionId) {
      return
    }

    setApproving(true)
    setError('')

    try {
      const result = await approveCliLoginSession(sessionId)
      window.sessionStorage.setItem(cliRedirectStorageKey(sessionId), result.redirect_to)
      setRedirectTo(result.redirect_to)
      setSession(previous => previous ? { ...previous, status: 'approved' } : previous)
    } catch (err: any) {
      setError(err?.message || '授权 CLI 登录失败')
    } finally {
      setApproving(false)
    }
  }

  return (
    <div className="min-h-screen pt-24 pb-16 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
      <div className="max-w-xl w-full apple-glass-panel apple-glass-sheen p-8">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold text-white">
            授权
            <span className="bg-gradient-to-r from-cyan-300 to-blue-400 bg-clip-text text-transparent ml-2">
              SkyBridge CLI
            </span>
          </h1>
          <p className="mt-3 text-sm text-slate-300">
            在当前浏览器完成确认后，登录会自动返回到本机命令行。
          </p>
        </div>

        {(fetching || loading) && (
          <div className="text-center text-slate-300 py-10">
            <div className="mx-auto mb-4 h-12 w-12 animate-spin rounded-full border-4 border-slate-700 border-t-cyan-400" />
            正在加载 CLI 登录会话…
          </div>
        )}

        {!fetching && !loading && error && (
          <div className="rounded-2xl border border-red-400/30 bg-red-500/10 p-4 text-sm text-red-200">
            {error}
          </div>
        )}

        {!fetching && !loading && session && !redirectTo && (
          <div className="space-y-6">
            <div className="rounded-2xl border border-white/10 bg-white/5 p-5 text-sm text-slate-200">
              <div className="flex justify-between gap-6 py-2">
                <span className="text-slate-400">平台</span>
                <span>{session.platform || '未知'}</span>
              </div>
              <div className="flex justify-between gap-6 py-2">
                <span className="text-slate-400">设备名</span>
                <span>{session.device_name || '未提供'}</span>
              </div>
              <div className="flex justify-between gap-6 py-2">
                <span className="text-slate-400">CLI 版本</span>
                <span>{session.cli_version || '未知'}</span>
              </div>
              <div className="flex justify-between gap-6 py-2">
                <span className="text-slate-400">状态</span>
                <span>{session.status}</span>
              </div>
              <div className="flex justify-between gap-6 py-2">
                <span className="text-slate-400">有效期至</span>
                <span>{formatExpiry(session.expires_at)}</span>
              </div>
            </div>

            {!user && session.status === 'pending' && (
              <div className="space-y-4">
                <p className="text-sm text-slate-300">
                  需要先登录网站账号，才能继续授权当前 CLI 设备。
                </p>
                <button
                  type="button"
                  onClick={() => navigate(buildWebsiteLoginRedirect(currentPath))}
                  className="w-full rounded-xl bg-cyan-400/20 px-4 py-3 text-sm font-medium text-cyan-100 transition hover:bg-cyan-400/30"
                >
                  先登录网站账号
                </button>
              </div>
            )}

            {user && session.status === 'pending' && (
              <div className="space-y-4">
                <div className="rounded-2xl border border-cyan-400/20 bg-cyan-400/10 p-4 text-sm text-cyan-50">
                  将使用当前网站账号授权 SkyBridge CLI 登录这台设备。
                </div>
                <button
                  type="button"
                  disabled={approving}
                  onClick={() => void handleApprove()}
                  className="w-full rounded-xl bg-gradient-to-r from-cyan-500 to-blue-500 px-4 py-3 text-sm font-semibold text-white transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {approving ? '正在授权…' : '继续登录 CLI'}
                </button>
                <button
                  type="button"
                  onClick={() => navigate('/', { replace: true })}
                  className="w-full rounded-xl border border-white/10 px-4 py-3 text-sm text-slate-300 transition hover:bg-white/5"
                >
                  取消
                </button>
              </div>
            )}

            {session.status !== 'pending' && (
              <div className="rounded-2xl border border-amber-400/20 bg-amber-400/10 p-4 text-sm text-amber-50">
                当前会话状态为 {session.status}，请回到命令行重新发起一次登录。
              </div>
            )}
          </div>
        )}

        {redirectTo && (
          <div className="space-y-4 text-center">
            <div className="rounded-2xl border border-emerald-400/20 bg-emerald-400/10 p-5 text-sm text-emerald-50">
              已授权完成，正在尝试返回 SkyBridge CLI。
            </div>
            <a
              href={redirectTo}
              className="block w-full rounded-xl bg-gradient-to-r from-emerald-500 to-cyan-500 px-4 py-3 text-sm font-semibold text-white transition hover:opacity-90"
            >
              继续返回 CLI
            </a>
            <button
              type="button"
              onClick={() => {
                if (sessionId) {
                  window.sessionStorage.removeItem(cliRedirectStorageKey(sessionId))
                }
                navigate('/', { replace: true })
              }}
              className="w-full rounded-xl border border-white/10 px-4 py-3 text-sm text-slate-300 transition hover:bg-white/5"
            >
              取消并返回首页
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

export default CliLoginPage
