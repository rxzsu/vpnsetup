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
  nodes: (id: string) => req<{ nodes: UnifiedNode[] }>(`/api/panels/${id}/nodes`),
  stats: (id: string) => req<{ stats: UnifiedStats }>(`/api/panels/${id}/stats`),
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

export interface UnifiedStats {
  totalUsers: number
  activeUsers: number
  onlineNow: number | null
}
