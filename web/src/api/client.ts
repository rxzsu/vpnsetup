export interface ApiError {
  message: string
  code?: string
}

import { useAuthStore } from '../stores/auth'

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    ...init,
  })
  if (res.status === 401) {
    try {
      useAuthStore().loggedIn = false
    } catch {
      // pinia not ready (e.g. first boot check) — the caller handles it
    }
    throw new Error('unauthorized')
  }
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.message ?? `request failed (${res.status})`)
  return data as T
}

export const api = {
  login: (username: string, password: string) =>
    req<{ ok: true }>('/api/auth/login', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),
  logout: () => req<{ ok: true }>('/api/auth/logout', { method: 'POST' }),
  me: () => req<{ loggedIn: boolean; username?: string }>('/api/auth/me'),

  rpc: <T = unknown>(method: string, params: Record<string, unknown> = {}) =>
    req<T>('/api/rpc', { method: 'POST', body: JSON.stringify({ method, params }) }),

  panels: () => req<{ panels: PanelSummary[] }>('/api/panels'),
  users: (id: string) => req<{ users: UnifiedUser[] }>(`/api/panels/${id}/users`),
  nodes: (id: string) => req<{ nodes: UnifiedNode[]; capabilities: NodeCapabilities }>(`/api/panels/${id}/nodes`),
  stats: (id: string) => req<{ stats: UnifiedStats }>(`/api/panels/${id}/stats`),

  nodeOptions: (id: string) =>
    req<{ capabilities: NodeCapabilities; profiles: ConfigProfile[] }>(`/api/panels/${id}/node-options`),
  createNode: (id: string, input: CreateNodeInput) =>
    req<{ node: UnifiedNode }>(`/api/panels/${id}/nodes`, { method: 'POST', body: JSON.stringify(input) }),
  deleteNode: (id: string, nid: string) =>
    req<{ ok: true }>(`/api/panels/${id}/nodes/${encodeURIComponent(nid)}`, { method: 'DELETE' }),
  restartNode: (id: string, nid: string) =>
    req<{ ok: true }>(`/api/panels/${id}/nodes/${encodeURIComponent(nid)}/restart`, { method: 'POST' }),
  setNodeEnabled: (id: string, nid: string, enabled: boolean) =>
    req<{ node: UnifiedNode }>(`/api/panels/${id}/nodes/${encodeURIComponent(nid)}`, {
      method: 'PATCH',
      body: JSON.stringify({ enabled }),
    }),

  createUser: (id: string, input: CreateUserInput) =>
    req<{ user: UnifiedUser }>(`/api/panels/${id}/users`, {
      method: 'POST',
      body: JSON.stringify(input),
    }),
  updateUser: (id: string, uid: string, patch: UpdateUserInput) =>
    req<{ user: UnifiedUser }>(`/api/panels/${id}/users/${encodeURIComponent(uid)}`, {
      method: 'PATCH',
      body: JSON.stringify(patch),
    }),
  deleteUser: (id: string, uid: string) =>
    req<{ ok: true }>(`/api/panels/${id}/users/${encodeURIComponent(uid)}`, { method: 'DELETE' }),
  resetUser: (id: string, uid: string) =>
    req<{ ok: true }>(`/api/panels/${id}/users/${encodeURIComponent(uid)}/reset`, { method: 'POST' }),
  revokeUser: (id: string, uid: string) =>
    req<{ user: UnifiedUser }>(`/api/panels/${id}/users/${encodeURIComponent(uid)}/revoke`, {
      method: 'POST',
    }),
}

export interface CreateUserInput {
  username: string
  limitBytes?: number
  expiresAt?: string | null
  inboundIds?: number[]
}

export interface UpdateUserInput {
  status?: 'active' | 'disabled'
  limitBytes?: number
  expiresAt?: string | null
}

export interface PanelSummary {
  id: string
  name: string
  license: string
  installed: boolean
  domain: string | null
  port: number | null
  manageable: boolean
}

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

export interface NodeCapabilities {
  canAdd: boolean
  canDelete: boolean
  canRestart: boolean
  canToggle: boolean
}

export interface ConfigProfile {
  uuid: string
  name: string
  inbounds: { uuid: string; tag: string; type: string; port: number | null }[]
}

export interface CreateNodeInput {
  name: string
  address: string
  port?: number
  apiPort?: number
  profileUuid?: string
  inboundUuids?: string[]
}

export interface UnifiedStats {
  totalUsers: number
  activeUsers: number
  onlineNow: number | null
}
