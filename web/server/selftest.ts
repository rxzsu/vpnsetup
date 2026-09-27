// Boot test: login flow + auth guard + SPA fallback. Run with:
//   WEB_ADMIN_PASSWORD_HASH=$(bun server/hash-password.ts pw) bun server/selftest.ts
import { spawn } from 'node:child_process'

const hash = process.env.WEB_ADMIN_PASSWORD_HASH
if (!hash) {
  console.error('set WEB_ADMIN_PASSWORD_HASH first')
  process.exit(1)
}

const child = spawn('bun', ['server/index.ts'], {
  env: { ...process.env, WEB_PORT: '3199' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
await new Promise((r) => setTimeout(r, 1500))

const base = 'http://127.0.0.1:3199'
let failures = 0
const check = (label: string, cond: boolean) => {
  console.log(`${cond ? 'ok  ' : 'FAIL'} ${label}`)
  if (!cond) failures++
}

try {
  const me0 = (await (await fetch(`${base}/api/auth/me`)).json()) as { loggedIn: boolean }
  check('me before login is false', me0.loggedIn === false)

  const rpc0 = await fetch(`${base}/api/rpc`, {
    method: 'POST',
    body: JSON.stringify({ method: 'panels' }),
  })
  check('rpc without session is 401', rpc0.status === 401)

  const bad = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'wrong' }),
  })
  check('wrong password is 401', bad.status === 401)

  const good = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'secret123' }),
  })
  const cookie = good.headers.get('set-cookie') ?? ''
  check('login ok + httpOnly cookie', good.status === 200 && cookie.includes('HttpOnly'))

  const me1 = (await (
    await fetch(`${base}/api/auth/me`, { headers: { cookie } })
  ).json()) as { loggedIn: boolean; username: string }
  check('me after login', me1.loggedIn === true && me1.username === 'admin')

  const rpc1 = await fetch(`${base}/api/rpc`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', cookie },
    body: JSON.stringify({ method: 'nosuchmethod' }),
  })
  check('disallowed method is 400', rpc1.status === 400)

  const panels = await fetch(`${base}/api/panels`, { headers: { cookie } })
  const panelsBody = (await panels.json()) as { message?: string }
  check(
    'panels without agent socket is 502 (not crash)',
    panels.status === 502 && !!panelsBody.message,
  )

  const index = await (await fetch(`${base}/`)).text()
  check('SPA index served', index.includes('<div id="app">'))

  const authed = { 'Content-Type': 'application/json', cookie }
  const create = await fetch(`${base}/api/panels/marzban/users`, {
    method: 'POST',
    headers: authed,
    body: JSON.stringify({ username: 'test' }),
  })
  check('create on unconfigured panel is 502', create.status === 502)

  const del = await fetch(`${base}/api/panels/marzban/users/test`, {
    method: 'DELETE',
    headers: { cookie },
  })
  check('delete on unconfigured panel is 502', del.status === 502)

  const noName = await fetch(`${base}/api/panels/marzban/users`, {
    method: 'POST',
    headers: authed,
    body: JSON.stringify({}),
  })
  check('create without username is 400', noName.status === 400)

  const nodeCreate = await fetch(`${base}/api/panels/marzban/nodes`, {
    method: 'POST',
    headers: authed,
    body: JSON.stringify({ name: 'n1', address: '10.0.0.1' }),
  })
  check('node create on unconfigured panel is 502', nodeCreate.status === 502)

  const noAddr = await fetch(`${base}/api/panels/marzban/nodes`, {
    method: 'POST',
    headers: authed,
    body: JSON.stringify({ name: 'n1' }),
  })
  check('node create without address is 400', noAddr.status === 400)

  const opts = await fetch(`${base}/api/panels/remnawave/node-options`, { headers: { cookie } })
  check('node-options on unconfigured panel is 502', opts.status === 502)

  const toggle = await fetch(`${base}/api/panels/3x-ui/nodes/1`, {
    method: 'PATCH',
    headers: authed,
    body: JSON.stringify({ enabled: true }),
  })
  check('node toggle on unconfigured panel is 502', toggle.status === 502)
} finally {
  child.kill()
}

process.exit(failures ? 1 : 0)
