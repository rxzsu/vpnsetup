import { config } from './config'

// Methods a browser session may invoke. Mirrors `vpnsetup help`; destructive
// ones still require the caller's explicit intent (the CLI/RPC confirms via yes).
const ALLOWED_METHODS = new Set([
  'version',
  'status',
  'panels',
  'sites',
  'jobs',
  'job',
  'doctor',
  'install',
  'update',
  'remove',
  'backup',
  'backups',
  'restore',
  'domain',
  'allow-ips',
  'proxy',
  'logs',
  'site.add',
  'site.remove',
])

export async function callAgent(method: string, params: Record<string, unknown>): Promise<unknown> {
  if (!ALLOWED_METHODS.has(method)) {
    throw Object.assign(new Error(`method not allowed: ${method}`), { status: 400 })
  }
  const body = JSON.stringify({ method, params })
  let res: Response
  try {
    res = await fetch('http://localhost/', {
      // @ts-expect-error Bun supports unix sockets in fetch
      unix: config.agentSocket,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    })
  } catch (e) {
    throw Object.assign(
      new Error(`agent socket unreachable (${config.agentSocket}): ${(e as Error).message}`),
      { status: 502 },
    )
  }
  const data = (await res.json().catch(() => null)) as {
    ok?: boolean
    exit_code?: number
    result?: unknown
    error?: string
  } | null
  if (!data) throw Object.assign(new Error('agent returned no JSON'), { status: 502 })
  if (!data.ok) {
    throw Object.assign(new Error(data.error || `vpnsetup failed (exit ${data.exit_code})`), {
      status: 502,
    })
  }
  return data.result ?? null
}
