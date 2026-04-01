import { create } from 'zustand'
import { persist } from 'zustand/middleware'

interface AppState {
  // Theme
  theme: 'dark' | 'light'
  setTheme: (theme: 'dark' | 'light') => void
  
  // UI State
  isSidebarOpen: boolean
  toggleSidebar: () => void
  setSidebarOpen: (open: boolean) => void
  
  // Notification preferences
  notificationsEnabled: boolean
  setNotificationsEnabled: (enabled: boolean) => void
  
  // Performance settings
  reducedMotion: boolean
  setReducedMotion: (reduced: boolean) => void
  
  // Last visited page for navigation
  lastVisitedPage: string
  setLastVisitedPage: (page: string) => void
}

export const useAppStore = create<AppState>()(
  persist(
    (set) => ({
      // Theme - default to dark
      theme: 'dark',
      setTheme: (theme) => set({ theme }),
      
      // Sidebar
      isSidebarOpen: false,
      toggleSidebar: () => set((state) => ({ isSidebarOpen: !state.isSidebarOpen })),
      setSidebarOpen: (open) => set({ isSidebarOpen: open }),
      
      // Notifications
      notificationsEnabled: true,
      setNotificationsEnabled: (enabled) => set({ notificationsEnabled: enabled }),
      
      // Performance
      reducedMotion: false,
      setReducedMotion: (reduced) => set({ reducedMotion: reduced }),
      
      // Navigation
      lastVisitedPage: '/',
      setLastVisitedPage: (page) => set({ lastVisitedPage: page }),
    }),
    {
      name: 'skybridge-app-storage',
      partialize: (state) => ({
        theme: state.theme,
        notificationsEnabled: state.notificationsEnabled,
        reducedMotion: state.reducedMotion,
        lastVisitedPage: state.lastVisitedPage,
      }),
    }
  )
)

// Selector hooks for better performance
export const useTheme = () => useAppStore((state) => state.theme)
export const useSetTheme = () => useAppStore((state) => state.setTheme)
export const useSidebar = () => useAppStore((state) => ({
  isOpen: state.isSidebarOpen,
  toggle: state.toggleSidebar,
  setOpen: state.setSidebarOpen,
}))
export const useReducedMotion = () => useAppStore((state) => state.reducedMotion)

