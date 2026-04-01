import { supabase } from './supabase'

export interface CliLoginSession {
  session_id: string
  status: 'pending' | 'approved' | 'cancelled' | 'expired'
  platform: string | null
  device_name: string | null
  cli_version: string | null
  expires_at: string
}

interface CliApproveResponse {
  redirect_to: string
}

function isBrowser() {
  return typeof window !== 'undefined'
}

function isLocalHostname(hostname: string) {
  return hostname === 'localhost' || hostname === '127.0.0.1'
}

export function getAuthApiBaseUrl() {
  const configured = import.meta.env.VITE_AUTH_API_BASE_URL?.trim()

  if (configured) {
    return configured.replace(/\/+$/, '')
  }

  if (isBrowser() && isLocalHostname(window.location.hostname)) {
    return 'http://127.0.0.1:3000'
  }

  return 'https://api.skybridge.com'
}

async function parseApiError(response: Response, fallbackMessage: string) {
  const result = await response.json().catch(() => null)
  return result?.error?.message || fallbackMessage
}

export async function fetchCliLoginSession(sessionId: string): Promise<CliLoginSession> {
  const response = await fetch(`${getAuthApiBaseUrl()}/api/cli-login/sessions/${encodeURIComponent(sessionId)}`, {
    method: 'GET',
    headers: {
      'Accept': 'application/json'
    }
  })

  if (!response.ok) {
    throw new Error(await parseApiError(response, '获取 CLI 登录会话失败'))
  }

  return response.json()
}

export async function approveCliLoginSession(sessionId: string): Promise<CliApproveResponse> {
  const { data: { session }, error } = await supabase.auth.getSession()

  if (error || !session?.access_token || !session.refresh_token) {
    throw new Error('当前网站会话无效，请重新登录')
  }

  const response = await fetch(`${getAuthApiBaseUrl()}/api/cli-login/sessions/${encodeURIComponent(sessionId)}/approve`, {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Authorization': `Bearer ${session.access_token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      access_token: session.access_token,
      refresh_token: session.refresh_token
    })
  })

  if (!response.ok) {
    throw new Error(await parseApiError(response, '授权 CLI 登录失败'))
  }

  return response.json()
}
