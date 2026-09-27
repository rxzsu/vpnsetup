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

export interface CreateUserInput {
  username: string
  /** 0 = unlimited */
  limitBytes?: number
  /** ISO date or null = never */
  expiresAt?: string | null
  /** 3x-ui only: inbound ids to attach to */
  inboundIds?: number[]
}

export interface UpdateUserInput {
  status?: 'active' | 'disabled'
  limitBytes?: number
  expiresAt?: string | null
}

export interface CreateNodeInput {
  name: string
  address: string
  /** panel↔node API port; panel default when omitted */
  port?: number
  /** Marzban only */
  apiPort?: number
  /** Remnawave only: config profile + inbound uuids to activate */
  profileUuid?: string
  inboundUuids?: string[]
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

export interface PanelAdapter {
  id: PanelId
  configured: boolean
  /** false when the panel has no equivalent (e.g. revoke on 3x-ui rotates subId instead) */
  supportsRevoke: boolean
  nodeCapabilities: NodeCapabilities
  listUsers(): Promise<UnifiedUser[]>
  createUser(input: CreateUserInput): Promise<UnifiedUser>
  updateUser(id: string, patch: UpdateUserInput): Promise<UnifiedUser>
  deleteUser(id: string): Promise<void>
  resetTraffic(id: string): Promise<void>
  revokeSub(id: string): Promise<UnifiedUser>
  listNodes(): Promise<UnifiedNode[]>
  createNode(input: CreateNodeInput): Promise<UnifiedNode>
  deleteNode(id: string): Promise<void>
  restartNode(id: string): Promise<void>
  setNodeEnabled(id: string, enabled: boolean): Promise<UnifiedNode>
  /** Remnawave only: profiles + inbounds for the add-node form */
  listConfigProfiles(): Promise<ConfigProfile[]>
  getStats(): Promise<UnifiedStats>
}

const unsupported = (what: string) => () =>
  Promise.reject(Object.assign(new Error(what), { status: 400 }))

export function notConfigured(id: PanelId): PanelAdapter {
  const err = () =>
    Promise.reject(
      Object.assign(new Error(`${id} is not configured on the server`), { status: 502 }),
    )
  return {
    id,
    configured: false,
    supportsRevoke: false,
    nodeCapabilities: { canAdd: false, canDelete: false, canRestart: false, canToggle: false },
    listUsers: err,
    createUser: err,
    updateUser: err,
    deleteUser: err,
    resetTraffic: err,
    revokeSub: err,
    listNodes: err,
    createNode: err,
    deleteNode: err,
    restartNode: err,
    setNodeEnabled: err,
    listConfigProfiles: err,
    getStats: err,
  }
}

export { unsupported }
