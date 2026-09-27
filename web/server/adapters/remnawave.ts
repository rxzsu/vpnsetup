import { config } from '../config'
import { notConfigured, type PanelAdapter, type UnifiedUser, type UserStatus } from './types'

interface RemnaUser {
  id: number
  username: string
  status: string
  trafficLimitBytes: number
  expireAt: string
  subscriptionUrl: string
  userTraffic?: { usedTrafficBytes: number }
}

function headers() {
  return { Authorization: `Bearer ${config.remnawave.token}` }
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${config.remnawave.url}${path}`, { headers: headers() })
  if (!res.ok) throw new Error(`remnawave request failed (${res.status})`)
  const data = (await res.json()) as { response: T }
  return data.response
}

function mapStatus(s: string): UserStatus {
  if (s === 'DISABLED') return 'disabled'
  if (s === 'LIMITED') return 'limited'
  if (s === 'EXPIRED') return 'expired'
  return 'active'
}

export function remnawaveAdapter(): PanelAdapter {
  const { url, token } = config.remnawave
  if (!url || !token) return notConfigured('remnawave')
  return {
    id: 'remnawave',
    configured: true,
    async listUsers() {
      const data = await get<{ users: RemnaUser[] }>('/api/users/?start=0&size=1000')
      return data.users.map(
        (u): UnifiedUser => ({
          id: String(u.id),
          username: u.username,
          status: mapStatus(u.status),
          usedBytes: u.userTraffic?.usedTrafficBytes ?? 0,
          limitBytes: u.trafficLimitBytes ?? 0,
          expiresAt: u.expireAt ?? null,
          subscriptionUrl: u.subscriptionUrl ?? null,
          online: null,
        }),
      )
    },
    async listNodes() {
      const data = await get<{ uuid: string; name: string; address: string; isConnected: boolean }[]>(
        '/api/nodes/',
      )
      return data.map((n) => ({
        id: n.uuid,
        name: n.name,
        address: n.address,
        status: n.isConnected ? 'connected' : 'offline',
        usersOnline: null,
      }))
    },
    async getStats() {
      const s = await get<{
        users: { totalUsers: number }
        onlineStats: { onlineNow: number }
      }>('/api/system/stats')
      return { totalUsers: s.users.totalUsers, activeUsers: s.users.totalUsers, onlineNow: s.onlineStats.onlineNow }
    },
  }
}
