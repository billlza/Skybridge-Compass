import { QueryClient } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // 5 minutes stale time
      staleTime: 5 * 60 * 1000,
      // 30 minutes cache time
      gcTime: 30 * 60 * 1000,
      // Retry failed requests 3 times
      retry: 3,
      // Exponential backoff
      retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000),
      // Refetch on window focus
      refetchOnWindowFocus: true,
      // Don't refetch on reconnect by default
      refetchOnReconnect: 'always',
    },
    mutations: {
      // Retry mutations once
      retry: 1,
    },
  },
})

// Query keys factory for type-safe query keys
export const queryKeys = {
  // User related
  user: {
    all: ['user'] as const,
    profile: () => [...queryKeys.user.all, 'profile'] as const,
    settings: () => [...queryKeys.user.all, 'settings'] as const,
    bindingStatus: () => [...queryKeys.user.all, 'binding-status'] as const,
  },
  
  // Auth related
  auth: {
    all: ['auth'] as const,
    session: () => [...queryKeys.auth.all, 'session'] as const,
  },
  
  // Features/Products related
  features: {
    all: ['features'] as const,
    list: () => [...queryKeys.features.all, 'list'] as const,
    detail: (id: string) => [...queryKeys.features.all, 'detail', id] as const,
  },
  
  // Downloads related
  downloads: {
    all: ['downloads'] as const,
    list: () => [...queryKeys.downloads.all, 'list'] as const,
    versions: () => [...queryKeys.downloads.all, 'versions'] as const,
  },
} as const

