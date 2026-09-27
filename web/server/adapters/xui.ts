import { config } from '../config'
import { notConfigured, type PanelAdapter, type UnifiedUser } from './types'

interface XuiClient {
  email: string
  enable: boolean
  up: number
  down: number
  totalGB: number
  expiryTime: number
}

function headers() {
  return { Authorization: `Bearer ${config.xui.token}` }
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${config.xui.url}${path}`, { headers: headers(), ...init })
  if (!res.ok) throw new Error(`3x-ui request failed (${res.status})`)
  const data = (await res.json()) as { success: boolean; msg: string; obj: T }
  if (!data.success) throw new Error(`3x-ui: ${data.msg}`)
  return data.obj
}

export function xuiAdapter(): PanelAdapter {
  const { url, token } = config.xui
  if (!url || !token) return notConfigured('3x-ui')
  return {
    id: '3x-ui',
    configured: true,
    async listUsers() {
      const rows = await call<XuiClient[]>('/panel/api/clients/list')
      return rows.map(
        (c): UnifiedUser => ({
          id: c.email,
          username: c.email,
          status: c.enable ? 'active' : 'disabled',
          usedBytes: (c.up ?? 0) + (c.down ?? 0),
          limitBytes: c.totalGB ?? 0,
          expiresAt: c.expiryTime ? new Date(c.expiryTime).toISOString() : null,
          subscriptionUrl: null,
          online: null,
        }),
      )
    },
    async listNodes() {
      // 3x-ui has no standalone nodes API; inbounds are the unit of capacity.
      const inbounds = await call<{ id: number; remark: string; port: number; enable: boolean }[]>(
        '/panel/api/inbounds/list/slim',
      )
      return inbounds.map((i) => ({
        id: String(i.id),
        name: i.remark || `inbound-${i.id}`,
        address: `:${i.port}`,
        status: i.enable ? 'enabled' : 'disabled',
        usersOnline: null,
      }))
    },
    async getStats() {
      const rows = await call<XuiClient[]>('/panel/api/clients/list')
      const active = rows.filter((c) => c.enable).length
      return { totalUsers: rows.length, activeUsers: active, onlineNow: null }
    },
  }
}
