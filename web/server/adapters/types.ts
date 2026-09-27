export type PanelId = 'marzban' | 'remnawave' | '3x-ui'

export type UserStatus = 'active' | 'disabled' | 'limited' | 'expired'

export interface UnifiedUser {
  id: string
  username: string
  status: UserStatus
  usedBytes: number
  limitBytes: number
  expiresAt: string | null
  subscriptionUrl: string | null
  online: boolean | null
}

export interface UnifiedNode {
  id: string
  name: string
  address: string
  status: string
  usersOnline: number | null
}

export interface UnifiedStats {
  totalUsers: number
  activeUsers: number
  onlineNow: number | null
}

export interface PanelAdapter {
  id: PanelId
  configured: boolean
  listUsers(): Promise<UnifiedUser[]>
  listNodes(): Promise<UnifiedNode[]>
  getStats(): Promise<UnifiedStats>
}

export function notConfigured(id: PanelId): PanelAdapter {
  const err = () => Promise.reject(new Error(`${id} is not configured on the server`))
  return { id, configured: false, listUsers: err, listNodes: err, getStats: err }
}
