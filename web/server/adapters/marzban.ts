import { config } from '../config'
import { notConfigured, type PanelAdapter, type UnifiedUser, type UserStatus } from './types'

interface MarzbanUser {
  username: string
  status: string
  used_traffic: number
  data_limit: number
  expire: number
  subscription_url: string
}

let cachedToken = ''
let cachedUntil = 0

async function token(): Promise<string> {
  if (cachedToken && Date.now() < cachedUntil) return cachedToken
  const { url, username, password } = config.marzban
  const res = await fetch(`${url}/api/admin/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username, password }),
  })
  if (!res.ok) throw new Error(`marzban login failed (${res.status})`)
  const data = (await res.json()) as { access_token: string }
  cachedToken = data.access_token
  cachedUntil = Date.now() + 23 * 3600_000
  return cachedToken
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${config.marzban.url}${path}`, {
    headers: { Authorization: `Bearer ${await token()}` },
  })
  if (res.status === 401) {
    cachedToken = ''
    const retry = await fetch(`${config.marzban.url}${path}`, {
      headers: { Authorization: `Bearer ${await token()}` },
    })
    if (!retry.ok) throw new Error(`marzban request failed (${retry.status})`)
    return (await retry.json()) as T
  }
  if (!res.ok) throw new Error(`marzban request failed (${res.status})`)
  return (await res.json()) as T
}

function mapStatus(s: string): UserStatus {
  if (s === 'disabled') return 'disabled'
  if (s === 'limited') return 'limited'
  if (s === 'expired') return 'expired'
  return 'active'
}

function mapUser(u: MarzbanUser): UnifiedUser {
  return {
    id: u.username,
    username: u.username,
    status: mapStatus(u.status),
    usedBytes: u.used_traffic ?? 0,
    limitBytes: u.data_limit ?? 0,
    expiresAt: u.expire ? new Date(u.expire * 1000).toISOString() : null,
    subscriptionUrl: u.subscription_url ?? null,
    online: null,
  }
}

export function marzbanAdapter(): PanelAdapter {
  const { url, username, password } = config.marzban
  if (!url || !username || !password) return notConfigured('marzban')
  return {
    id: 'marzban',
    configured: true,
    async listUsers() {
      const data = await get<{ users: MarzbanUser[] }>('/api/users?offset=0&limit=1000')
      return data.users.map(mapUser)
    },
    async listNodes() {
      const data = await get<
        { id: number; name: string; address: string; status: string }[]
      >('/api/nodes')
      return data.map((n) => ({
        id: String(n.id),
        name: n.name,
        address: n.address,
        status: n.status,
        usersOnline: null,
      }))
    },
    async getStats() {
      const s = await get<{
        total_user: number
        users_active: number
        online_users: number
      }>('/api/system')
      return { totalUsers: s.total_user, activeUsers: s.users_active, onlineNow: s.online_users }
    },
  }
}
