type AuthUserLike = {
  id?: string | null
  email?: string | null
  phone?: string | null
  user_metadata?: Record<string, unknown> | null
}

type ProfileRecord = Record<string, unknown>
type BindingStatusRecord = Record<string, unknown>

function normalizeString(value: unknown) {
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : null
  }

  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value)
  }

  return null
}

function inferAccountType(email: string | null, phone: string | null) {
  if (phone && !email) {
    return 'phone'
  }

  return 'email'
}

export function getAuthProfileSnapshot(authUser: AuthUserLike) {
  const metadata = authUser.user_metadata ?? {}
  const email = normalizeString(authUser.email)
  const phone = normalizeString(authUser.phone)

  return {
    userId: normalizeString(authUser.id),
    email,
    phone,
    metadataDisplayName:
      normalizeString(metadata.display_name) ||
      normalizeString(metadata.full_name) ||
      normalizeString(metadata.name),
    metadataNebulaId:
      normalizeString(metadata.nebula_id) ||
      normalizeString(metadata.nebulaId),
    metadataAvatarUrl: normalizeString(metadata.avatar_url),
    metadataAccountType:
      normalizeString(metadata.account_type) ||
      inferAccountType(email, phone)
  }
}

export function mergeUserProfileRecord(
  rawProfile: ProfileRecord,
  authUser: AuthUserLike,
  canonicalNebulaId?: string | null
) {
  const authSnapshot = getAuthProfileSnapshot(authUser)

  return {
    ...rawProfile,
    email: authSnapshot.email ?? normalizeString(rawProfile.email),
    phone: authSnapshot.phone ?? normalizeString(rawProfile.phone),
    nebula_id:
      normalizeString(canonicalNebulaId) ||
      authSnapshot.metadataNebulaId ||
      normalizeString(rawProfile.nebula_id),
    full_name: authSnapshot.metadataDisplayName ?? normalizeString(rawProfile.full_name),
    avatar_url: authSnapshot.metadataAvatarUrl ?? normalizeString(rawProfile.avatar_url),
    account_type: authSnapshot.metadataAccountType ?? normalizeString(rawProfile.account_type)
  }
}

export function buildUserProfileSyncPatch(
  rawProfile: ProfileRecord,
  authUser: AuthUserLike,
  canonicalNebulaId?: string | null
) {
  const authSnapshot = getAuthProfileSnapshot(authUser)
  const patch: Record<string, unknown> = {}

  if (authSnapshot.email && authSnapshot.email !== normalizeString(rawProfile.email)) {
    patch.email = authSnapshot.email
  }

  if (authSnapshot.phone && authSnapshot.phone !== normalizeString(rawProfile.phone)) {
    patch.phone = authSnapshot.phone
  }

  if (
    normalizeString(canonicalNebulaId) &&
    normalizeString(canonicalNebulaId) !== normalizeString(rawProfile.nebula_id)
  ) {
    patch.nebula_id = normalizeString(canonicalNebulaId)
  }

  if (
    authSnapshot.metadataDisplayName &&
    authSnapshot.metadataDisplayName !== normalizeString(rawProfile.full_name)
  ) {
    patch.full_name = authSnapshot.metadataDisplayName
  }

  if (
    authSnapshot.metadataAvatarUrl &&
    authSnapshot.metadataAvatarUrl !== normalizeString(rawProfile.avatar_url)
  ) {
    patch.avatar_url = authSnapshot.metadataAvatarUrl
  }

  if (
    authSnapshot.metadataAccountType &&
    authSnapshot.metadataAccountType !== normalizeString(rawProfile.account_type)
  ) {
    patch.account_type = authSnapshot.metadataAccountType
  }

  return patch
}

function maskEmail(email: string) {
  return email.replace(/(.{2}).*(@.*)/, '$1***$2')
}

function maskPhone(phone: string) {
  const digits = phone.replace(/\D/g, '')

  if (digits.length >= 7) {
    return phone.replace(/(\d{3})\d+(\d{4})/, '$1****$2')
  }

  return phone
}

function mergeContactStatus(
  rawContact: unknown,
  currentValue: string | null,
  type: 'email' | 'phone'
) {
  const raw =
    rawContact && typeof rawContact === 'object'
      ? (rawContact as Record<string, unknown>)
      : {}

  const value = currentValue ?? normalizeString(raw.value)
  const masked =
    value
      ? (type === 'email' ? maskEmail(value) : maskPhone(value))
      : normalizeString(raw.masked)
  const rawIsBound = typeof raw.is_bound === 'boolean' ? raw.is_bound : null
  const isBound = value ? true : rawIsBound ?? false

  if (!value && !masked && rawIsBound === null) {
    return undefined
  }

  return {
    ...raw,
    value: value ?? '',
    masked: masked ?? '',
    is_bound: isBound
  }
}

export function mergeBindingStatusRecord(
  rawBindingStatus: BindingStatusRecord | null | undefined,
  authUser: AuthUserLike,
  canonicalNebulaId?: string | null
) {
  const authSnapshot = getAuthProfileSnapshot(authUser)
  const raw =
    rawBindingStatus && typeof rawBindingStatus === 'object'
      ? rawBindingStatus
      : {}

  return {
    ...raw,
    user_id: authSnapshot.userId ?? normalizeString(raw.user_id),
    nebula_id:
      normalizeString(canonicalNebulaId) ??
      authSnapshot.metadataNebulaId ??
      normalizeString(raw.nebula_id),
    account_type:
      authSnapshot.metadataAccountType ??
      normalizeString(raw.account_type),
    email: mergeContactStatus(raw.email, authSnapshot.email, 'email'),
    phone: mergeContactStatus(raw.phone, authSnapshot.phone, 'phone')
  }
}
