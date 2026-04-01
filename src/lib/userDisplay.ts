import { User } from '@supabase/supabase-js'

type DisplayableUserProfile = {
  full_name?: string | null
  custom_user_id?: string | null
  nebula_id?: string | null
  email?: string | null
  phone?: string | null
}

function normalizeDisplayValue(value?: string | null) {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function getMetadataDisplayName(user?: User | null) {
  const metadata = user?.user_metadata

  return (
    normalizeDisplayValue(metadata?.display_name) ||
    normalizeDisplayValue(metadata?.full_name) ||
    normalizeDisplayValue(metadata?.name)
  )
}

function getMetadataNebulaId(user?: User | null) {
  const metadata = user?.user_metadata

  return (
    normalizeDisplayValue(metadata?.nebula_id) ||
    normalizeDisplayValue(metadata?.nebulaId)
  )
}

export function getPreferredDisplayName(
  user?: User | null,
  userProfile?: DisplayableUserProfile | null
) {
  return (
    normalizeDisplayValue(userProfile?.full_name) ||
    getMetadataDisplayName(user) ||
    normalizeDisplayValue(userProfile?.custom_user_id) ||
    normalizeDisplayValue(userProfile?.nebula_id) ||
    normalizeDisplayValue(userProfile?.email) ||
    normalizeDisplayValue(user?.email) ||
    normalizeDisplayValue(userProfile?.phone) ||
    normalizeDisplayValue(user?.phone) ||
    '星云用户'
  )
}

export function getPreferredNebulaId(
  user?: User | null,
  userProfile?: DisplayableUserProfile | null,
  fallbackNebulaId?: string | null
) {
  return (
    getMetadataNebulaId(user) ||
    normalizeDisplayValue(userProfile?.nebula_id) ||
    normalizeDisplayValue(fallbackNebulaId) ||
    null
  )
}
