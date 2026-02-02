'use client'

/**
 * 全局 Provider 包装器
 * 整合所有需要的 Context Providers
 */

import React from 'react'
import { AuthProvider } from '@/contexts/AuthContext'

interface ProvidersProps {
  children: React.ReactNode
}

export default function Providers({ children }: ProvidersProps) {
  return (
    <AuthProvider>
      {children}
    </AuthProvider>
  )
}

