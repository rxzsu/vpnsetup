import { config } from '../config'
import { notConfigured, unsupported, type PanelAdapter, type UnifiedNode, type UnifiedUser } from './types'

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
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`3x-ui request failed (${res.status})${detail ? `: ${detail.slice(0, 200)}` : ''}`)
  }
  const data = (await res.json()) as { success: boolean; msg: string; obj: T }
  if (!data.success) throw new Error(`3x-ui: ${data.msg}`)
  return data.obj
}

function post<T>(path: string, body?: unknown): Promise<T> {
  return call<T>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

function toMs(iso: string | null | undefined): number {
  return iso ? new Date(iso).getTime() : 0
}

function mapRow(c: XuiClient): UnifiedUser {
  return {
    id: c.email,
    username: c.email,
    status: c.enable ? 'active' : 'disabled',
    usedBytes: (c.up ?? 0) + (c.down ?? 0),
    limitBytes: c.totalGB ?? 0,
    expiresAt: c.expiryTime ? new Date(c.expiryTime).toISOString() : null,
    subscriptionUrl: null,
    online: null,
  }
}

export function xuiAdapter(): PanelAdapter {
  const { url, token } = config.xui
  if (!url || !token) return notConfigured('3x-ui')
  return {
    id: '3x-ui',
    configured: true,
    // No native revoke: rotating subId invalidates old subscription links.
    supportsRevoke: true,
    // Rows are inbounds; the only meaningful action is the enable toggle.
    nodeCapabilities: { canAdd: false, canDelete: false, canRestart: false, canToggle: true },
    async listUsers() {
      return (await call<XuiClient[]>('/panel/api/clients/list')).map(mapRow)
    },
    async createUser(input) {
      if (!input.inboundIds?.length) throw new Error('3x-ui requires at least one inbound')
      await post('/panel/api/clients/add', {
        client: {
          email: input.username,
          enable: true,
          totalGB: input.limitBytes ?? 0,
          expiryTime: toMs(input.expiresAt),
        },
        inboundIds: input.inboundIds,
      })
      const created = await call<{ client: XuiClient }>('/panel/api/clients/get/' + encodeURIComponent(input.username))
      return mapRow(created.client)
    },
    async updateUser(id, patch) {
      const current = await call<{ client: XuiClient & Record<string, unknown> }>(
        '/panel/api/clients/get/' + encodeURIComponent(id),
      )
      const client = { ...current.client }
      if (patch.status) client.enable = patch.status === 'active'
      if (patch.limitBytes !== undefined) client.totalGB = patch.limitBytes
      if (patch.expiresAt !== undefined) client.expiryTime = toMs(patch.expiresAt)
      await post('/panel/api/clients/update/' + encodeURIComponent(id), client)
      const fresh = await call<{ client: XuiClient }>('/panel/api/clients/get/' + encodeURIComponent(id))
      return mapRow(fresh.client)
    },
    async deleteUser(id) {
      await post('/panel/api/clients/del/' + encodeURIComponent(id))
    },
    async resetTraffic(id) {
      await post('/panel/api/clients/resetTraffic/' + encodeURIComponent(id))
    },
    async revokeSub(id) {
      const current = await call<{ client: XuiClient & Record<string, unknown> }>(
        '/panel/api/clients/get/' + encodeURIComponent(id),
      )
      const client = {
        ...current.client,
        subId: Buffer.from(crypto.getRandomValues(new Uint8Array(8))).toString('hex'),
      }
      await post('/panel/api/clients/update/' + encodeURIComponent(id), client)
      const fresh = await call<{ client: XuiClient }>('/panel/api/clients/get/' + encodeURIComponent(id))
      return mapRow(fresh.client)
    },
    async listNodes() {
      // 3x-ui has no standalone nodes API; inbounds are the unit of capacity.
      const inbounds = await call<{ id: number; remark: string; port: number; enable: boolean }[]>(
        '/panel/api/inbounds/list/slim',
      )
      return inbounds.map(
        (i): UnifiedNode => ({
          id: String(i.id),
          name: i.remark || `inbound-${i.id}`,
          address: `:${i.port}`,
          status: i.enable ? 'enabled' : 'disabled',
          usersOnline: null,
        }),
      )
    },
    createNode: unsupported('3x-ui has no nodes — manage inbounds instead'),
    deleteNode: unsupported('3x-ui has no nodes — manage inbounds instead'),
    restartNode: unsupported('3x-ui has no nodes — manage inbounds instead'),
    async setNodeEnabled(id, enabled) {
      await post(`/panel/api/inbounds/setEnable/${encodeURIComponent(id)}`, { enable })
      const inbounds = await call<{ id: number; remark: string; port: number; enable: boolean }[]>(
        '/panel/api/inbounds/list/slim',
      )
      const found = inbounds.find((i) => String(i.id) === id)
      if (!found) throw new Error('inbound not found after toggle')
      return {
        id: String(found.id),
        name: found.remark || `inbound-${found.id}`,
        address: `:${found.port}`,
        status: found.enable ? 'enabled' : 'disabled',
        usersOnline: null,
      }
    },
    listConfigProfiles: unsupported('3x-ui has no config profiles'),
    async getStats() {
      const rows = await call<XuiClient[]>('/panel/api/clients/list')
      const active = rows.filter((c) => c.enable).length
      return { totalUsers: rows.length, activeUsers: active, onlineNow: null }
    },
  }
}
