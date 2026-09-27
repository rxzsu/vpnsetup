export const config = {
  port: Number(process.env.WEB_PORT ?? 3100),
  adminUser: process.env.WEB_ADMIN_USER ?? 'admin',
  adminPasswordHash: process.env.WEB_ADMIN_PASSWORD_HASH ?? '',
  sessionTtlMs: Number(process.env.WEB_SESSION_TTL_HOURS ?? 12) * 3600_000,
  agentSocket: process.env.VPN_SETUP_AGENT_SOCKET ?? '/run/vpnsetup/agent.sock',

  marzban: {
    url: (process.env.MARZBAN_URL ?? '').replace(/\/$/, ''),
    username: process.env.MARZBAN_USERNAME ?? '',
    password: process.env.MARZBAN_PASSWORD ?? '',
  },
  remnawave: {
    url: (process.env.REMNAWAVE_URL ?? '').replace(/\/$/, ''),
    token: process.env.REMNAWAVE_TOKEN ?? '',
  },
  xui: {
    // Full base including webBasePath, e.g. http://127.0.0.1:2053/abc123
    url: (process.env.XUI_URL ?? '').replace(/\/$/, ''),
    token: process.env.XUI_TOKEN ?? '',
  },
}

export function requireAdminSetup() {
  if (!config.adminPasswordHash) {
    throw new Error(
      'WEB_ADMIN_PASSWORD_HASH is not set. Generate one with: bun server/hash-password.ts <password>',
    )
  }
}
