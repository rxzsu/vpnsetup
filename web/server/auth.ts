import { config } from './config'

interface Session {
  username: string
  expiresAt: number
}

const sessions = new Map<string, Session>()

function newToken(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex')
}

export async function verifyLogin(username: string, password: string): Promise<boolean> {
  if (username !== config.adminUser || !config.adminPasswordHash) return false
  try {
    return await Bun.password.verify(password, config.adminPasswordHash)
  } catch {
    return false
  }
}

export function createSession(username: string): { token: string; expiresAt: number } {
  const token = newToken()
  const expiresAt = Date.now() + config.sessionTtlMs
  sessions.set(token, { username, expiresAt })
  return { token, expiresAt }
}

export function getSession(token: string | null): Session | null {
  if (!token) return null
  const s = sessions.get(token)
  if (!s) return null
  if (s.expiresAt < Date.now()) {
    sessions.delete(token)
    return null
  }
  return s
}

export function destroySession(token: string | null) {
  if (token) sessions.delete(token)
}

export const SESSION_COOKIE = 'vpnweb_session'

export function sessionCookie(token: string, expiresAt: number): string {
  return `${SESSION_COOKIE}=${token}; HttpOnly; SameSite=Lax; Path=/; Expires=${new Date(expiresAt).toUTCString()}`
}

export function clearSessionCookie(): string {
  return `${SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT`
}
