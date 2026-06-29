import { createContext } from 'react'
import type { User } from '@supabase/supabase-js'

export interface UserProfile {
  id: string
  email: string | null
  phone: string | null
  custom_user_id: string | null
  nebula_id: string | null
  full_name: string | null
  account_type: string | null
  avatar_url: string | null
  created_at: string
  updated_at: string
}

export interface AuthContextType {
  user: User | null
  userProfile: UserProfile | null
  loading: boolean
  refreshProfile: () => Promise<void>
  signIn: (email: string, password: string) => Promise<any>
  signInNebula: (nebulaId: string, password: string) => Promise<any>
  signInPhone: (phone: string, password: string) => Promise<any>
  signUp: (email: string, password: string, metadata?: any) => Promise<any>
  signUpPhone: (phone: string, password: string, metadata?: any) => Promise<any>
  sendOTP: (phone: string) => Promise<any>
  verifyOTP: (phone: string, token: string) => Promise<any>
  signOut: () => Promise<any>
}

export const AuthContext = createContext<AuthContextType | undefined>(undefined)
