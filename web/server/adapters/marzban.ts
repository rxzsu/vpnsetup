import { config } from '../config'
import {
  notConfigured,
  unsupported,
  type PanelAdapter,
  type UnifiedNode,
  type UnifiedUser,
  type UserStatus,
} from './types'

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

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const run = async () =>
    fetch(`${config.marzban.url}${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${await token()}`, ...(init?.headers ?? {}) },
    })
  let res = await run()
  if (res.status === 401) {
    cachedToken = ''
    res = await run()
  }
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`marzban request failed (${res.status})${detail ? `: ${detail.slice(0, 200)}` : ''}`)
  }
  const text = await res.text()
  return (text ? JSON.parse(text) : {}) as T
}

async function get<T>(path: string): Promise<T> {
  return req<T>(path)
}

async function mut<T>(method: string, path: string, body?: unknown): Promise<T> {
  return req<T>(path, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
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
interface MarzbanNode {
  id: number
  name: string
  address: string
  status: string
}

function mapNode(n: MarzbanNode): UnifiedNode {
  return { id: String(n.id), name: n.name, address: n.address, status: n.status, usersOnline: null }
}

  return {
    id: 'marzban',
    configured: true,
    supportsRevoke: true,
    nodeCapabilities: { canAdd: true, canDelete: true, canRestart: true, canToggle: true },
    async listUsers() {
      const data = await get<{ users: MarzbanUser[] }>('/api/users?offset=0&limit=1000')
      return data.users.map(mapUser)
    },
    async createUser(input) {
      const created = await mut<MarzbanUser>('POST', '/api/user', {
        username: input.username,
        status: 'active',
        // Minimal vless identity; inbounds omitted = all inbounds.
        proxies: { vless: { id: crypto.randomUUID() } },
        inbounds: {},
        data_limit: input.limitBytes ?? 0,
        expire: input.expiresAt ? Math.floor(new Date(input.expiresAt).getTime() / 1000) : 0,
      })
      return mapUser(created)
    },
    async updateUser(id, patch) {
      const body: Record<string, unknown> = {}
      if (patch.status) body.status = patch.status
      if (patch.limitBytes !== undefined) body.data_limit = patch.limitBytes
      if (patch.expiresAt !== undefined) {
        body.expire = patch.expiresAt ? Math.floor(new Date(patch.expiresAt).getTime() / 1000) : 0
      }
      const updated = await mut<MarzbanUser>('PUT', `/api/user/${encodeURIComponent(id)}`, body)
      return mapUser(updated)
    },
    async deleteUser(id) {
      await mut('DELETE', `/api/user/${encodeURIComponent(id)}`)
    },
    async resetTraffic(id) {
      await mut('POST', `/api/user/${encodeURIComponent(id)}/reset`)
    },
    async revokeSub(id) {
      const updated = await mut<MarzbanUser>('POST', `/api/user/${encodeURIComponent(id)}/revoke_sub`)
      return mapUser(updated)
    },
    async listNodes() {
      return (await get<MarzbanNode[]>('/api/nodes')).map(mapNode)
    },
    async createNode(input) {
      const created = await mut<MarzbanNode>('POST', '/api/node', {
        name: input.name,
        address: input.address,
        port: input.port ?? 62050,
        api_port: input.apiPort ?? 62051,
        usage_coefficient: 1,
        add_as_new_host: true,
      })
      return mapNode(created)
    },
    async deleteNode(id) {
      await mut('DELETE', `/api/node/${encodeURIComponent(id)}`)
    },
    async restartNode(id) {
      await mut('POST', `/api/node/${encodeURIComponent(id)}/reconnect`)
    },
    async setNodeEnabled(id, enabled) {
      // Empty modify reconnects the node (i.e. enables it again).
      const updated = await mut<MarzbanNode>(
        'PUT',
        `/api/node/${encodeURIComponent(id)}`,
        enabled ? {} : { status: 'disabled' },
      )
      return mapNode(updated)
    },
    listConfigProfiles: unsupported('marzban has no config profiles'),
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
