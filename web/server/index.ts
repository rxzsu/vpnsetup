import path from 'node:path'
import { config, requireAdminSetup } from './config'
import {
  SESSION_COOKIE,
  clearSessionCookie,
  createSession,
  destroySession,
  getSession,
  sessionCookie,
  verifyLogin,
} from './auth'
import { callAgent } from './rpc'
import { marzbanAdapter } from './adapters/marzban'
import { remnawaveAdapter } from './adapters/remnawave'
import { xuiAdapter } from './adapters/xui'
import type { PanelId } from './adapters/types'

requireAdminSetup()

const DIST = path.join(import.meta.dir, '..', 'dist')

function adapters() {
  return { marzban: marzbanAdapter(), remnawave: remnawaveAdapter(), '3x-ui': xuiAdapter() }
}

function json(data: unknown, status = 200): Response {
  return Response.json(data, { status })
}

function err(e: unknown, fallback = 500): Response {
  const status = (e as { status?: number })?.status ?? fallback
  return json({ message: (e as Error).message ?? 'internal error' }, status)
}

function cookieToken(req: Request): string | null {
  const header = req.headers.get('cookie') ?? ''
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=')
    if (k === SESSION_COOKIE) return rest.join('=')
  }
  return null
}

async function panelsSummary() {
  const [catalog, status] = await Promise.all([
    callAgent('panels') as Promise<{ panels: { id: string; name: string; license: string; installed: boolean }[] }>,
    callAgent('status').catch(() => null) as Promise<{
      panels: { id: string; domain: string | null; port: number | null }[]
    } | null>,
  ])
  const live = new Map((status?.panels ?? []).map((p) => [p.id, p]))
  const ad = adapters()
  return catalog.panels.map((p) => ({
    id: p.id,
    name: p.name,
    license: p.license,
    installed: p.installed,
    domain: live.get(p.id)?.domain ?? null,
    port: live.get(p.id)?.port ?? null,
    manageable: p.installed && (ad[p.id as PanelId]?.configured ?? false),
  }))
}

Bun.serve({
  port: config.port,
  hostname: '127.0.0.1',
  async fetch(req) {
    const url = new URL(req.url)

    if (url.pathname === '/api/auth/login' && req.method === 'POST') {
      const body = (await req.json().catch(() => null)) as {
        username?: string
        password?: string
      } | null
      if (!body?.username || !body?.password) return json({ message: 'username and password required' }, 400)
      if (!(await verifyLogin(body.username, body.password))) {
        return json({ message: 'invalid credentials' }, 401)
      }
      const { token, expiresAt } = createSession(body.username)
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Set-Cookie': sessionCookie(token, expiresAt) },
      })
    }

    if (url.pathname === '/api/auth/logout' && req.method === 'POST') {
      destroySession(cookieToken(req))
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Set-Cookie': clearSessionCookie() },
      })
    }

    if (url.pathname === '/api/auth/me') {
      const s = getSession(cookieToken(req))
      return s ? json({ loggedIn: true, username: s.username }) : json({ loggedIn: false })
    }

    // Static frontend is public (it contains the login screen itself).
    // Only /api/* below requires a session.
    if (!url.pathname.startsWith('/api/')) {
      const filePath = path.join(DIST, url.pathname === '/' ? 'index.html' : url.pathname.slice(1))
      const file = Bun.file(filePath)
      if (await file.exists()) return new Response(file)
      return new Response(Bun.file(path.join(DIST, 'index.html')))
    }

    const session = getSession(cookieToken(req))
    if (!session) return json({ message: 'unauthorized' }, 401)

    try {
      if (url.pathname === '/api/rpc' && req.method === 'POST') {
        const body = (await req.json()) as { method: string; params?: Record<string, unknown> }
        return json(await callAgent(body.method, body.params ?? {}))
      }

      if (url.pathname === '/api/panels') {
        return json({ panels: await panelsSummary() })
      }

      const m = url.pathname.match(/^\/api\/panels\/([^/]+)\/(users|nodes|stats)$/)
      if (m && req.method === 'GET') {
        const adapter = adapters()[m[1] as PanelId]
        if (!adapter) return json({ message: 'unknown panel' }, 404)
        if (m[2] === 'users') return json({ users: await adapter.listUsers() })
        if (m[2] === 'nodes') return json({ nodes: await adapter.listNodes() })
        return json({ stats: await adapter.getStats() })
      }
    } catch (e) {
      return err(e)
    }

    return json({ message: 'not found' }, 404)
  },
})

// eslint-disable-next-line no-console
console.log(`vpnsetup web listening on http://127.0.0.1:${config.port}`)
