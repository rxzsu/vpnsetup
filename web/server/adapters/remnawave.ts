import { config } from '../config'
import {
  notConfigured,
  type ConfigProfile,
  type PanelAdapter,
  type UnifiedNode,
  type UnifiedUser,
  type UserStatus,
} from './types'

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

async function callRaw(path: string, init?: RequestInit): Promise<Response> {
  const res = await fetch(`${config.remnawave.url}${path}`, {
    ...init,
    headers: { ...headers(), ...(init?.headers ?? {}) },
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(
      `remnawave request failed (${res.status})${detail ? `: ${detail.slice(0, 200)}` : ''}`,
    )
  }
  return res
}

async function get<T>(path: string): Promise<T> {
  const data = (await (await callRaw(path)).json()) as { response: T }
  return data.response
}

async function mut<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await callRaw(path, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  if (!text) return {} as T
  return (JSON.parse(text) as { response: T }).response ?? (JSON.parse(text) as T)
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
  function mapUser(u: RemnaUser): UnifiedUser {
    return {
      id: String(u.id),
      username: u.username,
      status: mapStatus(u.status),
      usedBytes: u.userTraffic?.usedTrafficBytes ?? 0,
      limitBytes: u.trafficLimitBytes ?? 0,
      expiresAt: u.expireAt ?? null,
      subscriptionUrl: u.subscriptionUrl ?? null,
      online: null,
    }
  }

interface RemnaNode {
  uuid: string
  name: string
  address: string
  isConnected: boolean
  isDisabled: boolean
}

interface RemnaProfile {
  uuid: string
  name: string
  inbounds: ConfigProfile['inbounds']
}

async function fetchProfiles(): Promise<ConfigProfile[]> {
  const data = await get<RemnaProfile[] | { total: number; config_profiles: RemnaProfile[] }>(
    '/api/config-profiles/',
  )
  const list = Array.isArray(data) ? data : data.config_profiles
  return list.map((p) => ({ uuid: p.uuid, name: p.name, inbounds: p.inbounds ?? [] }))
}

  return {
    id: 'remnawave',
    configured: true,
    supportsRevoke: true,
    nodeCapabilities: { canAdd: true, canDelete: true, canRestart: true, canToggle: true },
    async listUsers() {
      const data = await get<{ users: RemnaUser[] }>('/api/users/?start=0&size=1000')
      return data.users.map(mapUser)
    },
    async createUser(input) {
      if (!input.expiresAt) throw new Error('remnawave requires an expiry date')
      const created = await mut<RemnaUser>('POST', '/api/users/', {
        username: input.username,
        expireAt: input.expiresAt,
        trafficLimitBytes: input.limitBytes ?? 0,
      })
      return mapUser(created)
    },
    async updateUser(id, patch) {
      const body: Record<string, unknown> = { id: Number(id) }
      if (patch.limitBytes !== undefined) body.trafficLimitBytes = patch.limitBytes
      if (patch.expiresAt !== undefined) body.expireAt = patch.expiresAt
      if (patch.status) {
        // Status flips go through dedicated actions, not PATCH.
        await mut('POST', `/api/users/${id}/actions/${patch.status === 'active' ? 'enable' : 'disable'}`)
      }
      if (Object.keys(body).length > 1) {
        const updated = await mut<RemnaUser>('PATCH', '/api/users/', body)
        return mapUser(updated)
      }
      const fresh = await get<RemnaUser>(`/api/users/${id}`)
      return mapUser(fresh)
    },
    async deleteUser(id) {
      await mut('DELETE', `/api/users/${id}`)
    },
    async resetTraffic(id) {
      await mut('POST', `/api/users/${id}/actions/reset-traffic`)
    },
    async revokeSub(id) {
      const updated = await mut<RemnaUser>('POST', `/api/users/${id}/actions/revoke`)
      return mapUser(updated)
    },
    async listNodes() {
      const data = await get<RemnaNode[]>('/api/nodes/')
      return data.map(
        (n): UnifiedNode => ({
          id: n.uuid,
          name: n.name,
          address: n.address,
          status: n.isDisabled ? 'disabled' : n.isConnected ? 'connected' : 'offline',
          usersOnline: null,
        }),
      )
    },
    async createNode(input) {
      if (!input.profileUuid) throw new Error('remnawave requires a config profile')
      const created = await mut<RemnaNode>('POST', '/api/nodes/', {
        name: input.name,
        address: input.address,
        port: input.port ?? 62050,
        configProfile: {
          activeConfigProfileUuid: input.profileUuid,
          // Pass through the panel's own inbound objects; the backend validates them.
          activeInbounds: input.inboundUuids?.length
            ? (await fetchProfiles())
                .find((p) => p.uuid === input.profileUuid)
                ?.inbounds.filter((i) => input.inboundUuids!.includes(i.uuid)) ?? []
            : [],
        },
      })
      return {
        id: created.uuid,
        name: created.name,
        address: created.address,
        status: 'offline',
        usersOnline: null,
      }
    },
    async deleteNode(id) {
      await mut('DELETE', `/api/nodes/${encodeURIComponent(id)}`)
    },
    async restartNode(id) {
      await mut('POST', `/api/nodes/${encodeURIComponent(id)}/actions/restart`)
    },
    async setNodeEnabled(id, enabled) {
      await mut('POST', `/api/nodes/${encodeURIComponent(id)}/actions/${enabled ? 'enable' : 'disable'}`)
      const fresh = await get<RemnaNode>(`/api/nodes/${encodeURIComponent(id)}`)
      return {
        id: fresh.uuid,
        name: fresh.name,
        address: fresh.address,
        status: fresh.isDisabled ? 'disabled' : fresh.isConnected ? 'connected' : 'offline',
        usersOnline: null,
      }
    },
    listConfigProfiles: fetchProfiles,
    async getStats() {
      const s = await get<{
        users: { totalUsers: number }
        onlineStats: { onlineNow: number }
      }>('/api/system/stats')
      return { totalUsers: s.users.totalUsers, activeUsers: s.users.totalUsers, onlineNow: s.onlineStats.onlineNow }
    },
  }
}
