# vpnsetup

One-command installer and manager for **open-source VPN panels**. It puts a panel
behind Caddy with automatic Let's Encrypt TLS, keeps the stack in a known place,
gives you a single command to update / back up / remove it, and survives an SSH
drop in the middle of the install.

It installs other people's panels from their own upstream sources — it does not
vendor, fork or relicense them.

```bash
curl -fsSL https://raw.githubusercontent.com/rxzsu/vpnsetup/main/install.sh | sudo bash
```

Prefer to read before you run? Clone it instead:

```bash
git clone https://github.com/rxzsu/vpnsetup.git
cd vpnsetup
sudo bash install.sh
```

The bootstrap downloads the rest of the modules into `/etc/vpnsetup/lib` and
installs a `vpnsetup` command, so you only need the one-liner once. Re-running it
updates the installer in place.

---

## Supported panels

| Panel | Upstream | License | Database |
|---|---|---|---|
| **3x-ui** | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | GPL-3.0 | SQLite |
| **Marzban** | [Gozargah/Marzban](https://github.com/Gozargah/Marzban) | AGPL-3.0 | SQLite |
| **Remnawave** | [remnawave/backend](https://github.com/remnawave/backend) | AGPL-3.0 | PostgreSQL |

Deploying a panel means accepting *its* license. This installer is MIT.

---

## Requirements

- Linux with root access (Ubuntu 22.04+, Debian 12+, Fedora, RHEL/Alma/Rocky, Arch, Alpine)
- Docker and the Compose plugin — installed automatically if missing
- A domain with an `A` record pointing at the server, ports **80** and **443** open
- 1 vCPU / 1 GB RAM is enough for a small panel; Remnawave wants more (it runs
  PostgreSQL and Valkey alongside the app)

---

## Commands

```bash
vpnsetup                      # interactive menu
vpnsetup install 3x-ui        # install a specific panel
vpnsetup status               # containers + Caddy sites
vpnsetup doctor               # diagnose host, containers, DNS, TLS, backups
vpnsetup logs marzban         # tail logs (Ctrl+C to stop)
vpnsetup logs marzban panel   # tail one compose service
vpnsetup update 3x-ui         # pull new images and restart
vpnsetup backup remnawave     # write a backup archive
vpnsetup restore remnawave    # restore from an archive
vpnsetup proxy                # re-apply Caddy + certificates
vpnsetup domain marzban       # move a panel to another domain, keeping its data
vpnsetup allow-ips marzban    # restrict panel access to a list of IPs
vpnsetup allow-ips marzban clear
vpnsetup remove 3x-ui         # remove the panel and its data
vpnsetup attach               # reattach to a running tmux setup session
vpnsetup help
```

Only `install`, `update`, `backup`, `restore`, `proxy`, `domain`, `allow-ips`,
`doctor` and `remove` need root.

### Diagnostics

```bash
vpnsetup doctor
```

Checks run bottom-up, so the first failure is the one worth fixing:

```
Host
  ok   debian x86_64, kernel 6.8.0-45-generic
  ok   / has 41230 MB free
  warn net.ipv4.ip_forward is disabled — VPN traffic will not be forwarded

Docker
  ok   Docker version 27.3.1
  ok   Docker daemon is reachable

3x-ui (3x-ui)
  ok   domain: panel.example.com
  ok   vpnsetup-3x-ui is running, health: healthy
  ok   port 2053 is listening
  ok   DNS: panel.example.com -> 203.0.113.9
  ok   TLS: certificate valid for 68 more days
  ok   HTTPS https://panel.example.com -> 200
  warn latest backup is 12 days old — run: vpnsetup backup 3x-ui

Reverse proxy
  ok   Caddy container is running
  ok   the generated Caddyfile is valid
  ok   port 80 is bound
  ok   port 443 is bound
```

What it covers: disk space on `/` and the backup directory, IPv4 forwarding, Docker
and Compose, per-panel state and compose files, container state and restart
counts, healthcheck status, listening ports, DNS resolution against this server's
address, TLS expiry and the end-to-end HTTPS response, backup age, and config file
permissions.

It is read-only — doctor never changes anything — and **exits non-zero when a check
fails**, so it can be used from a monitoring script:

```bash
vpnsetup doctor || systemd-cat -t vpnsetup -p warning echo "vpnsetup doctor reported problems"
```

Thresholds are configurable: `VPN_SETUP_CERT_WARN_DAYS` (default 14) and
`VPN_SETUP_BACKUP_STALE_DAYS` (default 7).

### Changing a panel's domain

Reinstalling is not required — and for the SQLite-backed panels it would have
destroyed the database. The domain lives in the state file, so it is rewritten in
place:

```bash
vpnsetup domain marzban panel2.example.com
```

The command updates the state, pushes the change into the panel's own
configuration where the panel cares about its hostname (Marzban's subscription
prefix, Remnawave's `PANEL_DOMAIN` and `FRONT_END_DOMAIN`), re-renders the
Caddyfile and reloads Caddy. Panel data is untouched.

### Subscription domain

Marzban and Remnawave serve subscriptions from the panel port, so a subscription
domain is just a second Caddy site pointing at the same upstream:

```bash
VPN_SETUP_SUB_DOMAIN=sub.example.com vpnsetup install marzban
```

This is worth doing: it means you never hand out the panel hostname to clients.
3x-ui is not offered this option — its subscription service listens on a separate
port configured inside the panel UI, which is unknown at install time.

### Restricting access by IP

```bash
vpnsetup allow-ips marzban 203.0.113.5,10.0.0.0/8
vpnsetup allow-ips marzban clear      # undo
```

Every other client gets `403`. Two things worth knowing:

- The ACME challenge path is exempt, otherwise enabling the allowlist would break
  certificate renewal.
- The allowlist applies to the **panel** site only. Subscription sites stay
  public, or clients could not fetch their own subscriptions.

If you lock yourself out, SSH in and run `vpnsetup allow-ips <panel> clear`.

---

## Unattended install

Every prompt can be answered from the environment, so cloud-init and CI work:

```bash
VPN_SETUP_PANEL=3x-ui \
VPN_SETUP_DOMAIN=panel.example.com \
VPN_SETUP_PORT=2053 \
  bash install.sh
```

Or on an already-provisioned box:

```bash
VPN_SETUP_PANEL=remnawave VPN_SETUP_DOMAIN=panel.example.com vpnsetup install
```

Without a terminal the installer runs the requested action once and exits
instead of trying to draw a menu.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `VPN_SETUP_PANEL` | — | Panel id: `3x-ui`, `marzban`, `remnawave` |
| `VPN_SETUP_DOMAIN` | — | Panel domain, skips the prompt |
| `VPN_SETUP_SUB_DOMAIN` | — | Subscription domain (Marzban, Remnawave) |
| `VPN_SETUP_PORT` | per panel | Panel port, skips the prompt |
| `VPN_SETUP_ALLOW_IPS` | — | Comma-separated IP/CIDR allowlist for the panel |
| `VPN_SETUP_ACTION` | — | Action for a headless bootstrap run |
| `VPN_SETUP_3XUI_IMAGE` | `ghcr.io/mhsanaei/3x-ui:latest` | Pin the 3x-ui image |
| `VPN_SETUP_ROOT` | `/opt/vpnsetup` | Base directory for panel stacks |
| `VPN_SETUP_BACKUP` | `/var/backups/vpnsetup` | Backup directory |
| `VPN_SETUP_STATE` | `/etc/vpnsetup` | State directory |
| `VPN_SETUP_BACKUP_KEEP` | `10` | Backups retained per panel |
| `VPN_SETUP_CERT_WARN_DAYS` | `14` | `doctor` warns below this TLS lifetime |
| `VPN_SETUP_BACKUP_STALE_DAYS` | `7` | `doctor` warns above this backup age |
| `VPN_SETUP_REPO` / `VPN_SETUP_BRANCH` | repo in `install.sh` | Where the bootstrap fetches modules |
| `NO_COLOR` | — | Disable colored output |

Ports `80` and `443` belong to Caddy and are rejected as panel ports, as is any
port already claimed by another installed panel.

---

## How it works

```
install.sh          bootstrap: root check, prerequisites, Docker, module cache,
                    /usr/local/bin/vpnsetup, tty reattach, tmux wrapper, hand-off
bin/vpnsetup        CLI shim — locates the cached modules and dispatches
lib/common.sh       logging, OS/package detection, secrets, prompts, state files
lib/docker.sh       Docker/Compose bootstrap, compose wrappers, health waits
lib/proxy.sh        Caddy; renders the Caddyfile from state, reloads on change
lib/backup.sh       archive-based backup and restore
lib/panels.sh       panel catalog + shared install/update/remove flow
lib/doctor.sh       read-only diagnostics
lib/ui.sh           banner and menus
lib/main.sh         module loading, dispatch, help
lib/panels/*.sh     one module per panel
```

Three ideas carry the design:

**State, not guesswork.** Installing a panel writes
`/etc/vpnsetup/panels/<id>.env`. `status`, `logs`, `update`, `backup` and
`remove` all read that file, so nothing has to be re-derived from a running
container, and there is no per-panel branching scattered through the manager.

**The Caddyfile is generated, never hand-edited.** `lib/proxy.sh` renders one
site block per installed panel from the state files and reloads Caddy. Installing
or removing a panel therefore just re-renders — which is what lets several panels
share one server without fighting over ports 80/443. The generated config is
validated with `caddy validate` before it is applied, so a bad config cannot take
down a proxy that is currently serving traffic.

**Panels are installed from upstream.** Where upstream ships a documented
install path (Marzban's script, Remnawave's compose + env contract), the module
uses it, so the installer does not rot as those projects evolve. Where upstream
only documents `docker run` (3x-ui), the module writes its own small compose file.

**An SSH drop does not kill the install.** Before anything long-running starts,
the bootstrap hands over to a `tmux` session (`vpnsetup attach` to come back).
Two related details matter more than they look: when the bootstrap arrives
through a pipe (`curl … | bash`), stdin is the script itself, so any prompt would
eat the script — the bootstrap therefore re-executes its cached copy with
`/dev/tty` attached. And when there is no terminal at all (CI, cloud-init,
`ssh host 'bash -s' < install.sh`), it runs the action in `VPN_SETUP_ACTION` once
and exits instead of trying to draw a menu.

### Panel module contract

Add a panel by dropping `lib/panels/<id>.sh` and listing the id in `PANEL_IDS`
in `lib/panels.sh`. The file must define:

```bash
panel_install_<slug>   <id> <domain>   # install, then call state_write
panel_uninstall_<slug> <id>            # remove containers and data
panel_update_<slug>    <id>            # optional; defaults to pull + up
panel_set_domain_<slug> <id> <domain>  # optional; only if the panel stores its
                                       # own hostname and needs to be told
```

`<slug>` is the id with non-alphanumerics stripped (`3x-ui` → `3xui`).

State keys a module can write, beyond the required ones:

| Key | Meaning |
|---|---|
| `SUB_DOMAIN` | Second Caddy site on the same upstream port (subscriptions) |
| `ALLOW_IPS` | Comma-separated IP/CIDR allowlist applied to the panel site |
| `BACKUP_KIND` | `sqlite`, `postgres` or `files` |
| `BACKUP_SQLITE` / `BACKUP_SERVICE` | SQLite path and the service stopped around the copy |
| `BACKUP_PG_SERVICE` / `_USER` / `_DB` | PostgreSQL service and credentials |
| `BACKUP_FILES` | Comma-separated config files always included in a backup |

---

## Files on disk

| Path | Contents |
|---|---|
| `/opt/vpnsetup-setup/` | Cached modules used by the `vpnsetup` command |
| `/usr/local/bin/vpnsetup` | CLI entry point |
| `/opt/vpnsetup/3x-ui/` | 3x-ui compose file, database, certificates |
| `/opt/marzban/`, `/var/lib/marzban/` | Marzban (upstream paths, so the `marzban` command keeps working) |
| `/opt/remnawave/` | Remnawave compose file and `.env` |
| `/opt/vpnsetup/caddy/` | Caddy compose file, generated Caddyfile, TLS data |
| `/etc/vpnsetup/panels/` | Per-panel state (mode `600`) |
| `/var/backups/vpnsetup/<panel>/` | Backup archives |
| `/var/log/vpnsetup/` | Install logs (e.g. the Marzban bootstrap log) |

---

## Backups

Each panel declares how it should be backed up in its state file, and
`backup_create` follows that declaration:

- **3x-ui / Marzban (SQLite)** — the panel service is stopped, the database file
  is copied, the service is started again. Copying a live SQLite file can
  capture a torn write, so the brief stop is deliberate.
- **Remnawave (PostgreSQL)** — `pg_dump` piped through gzip.
- **Always** — the config files (`.env`, `docker-compose.yml`) are included, so a
  backup is enough to rebuild the panel.

Everything lands in one archive, `/var/backups/vpnsetup/<id>/<id>-<ts>.tar.gz`
(mode `600`), with a `MANIFEST` inside. The archive is verified with `tar -tzf`
before it is kept — an archive that cannot be listed is an archive that cannot be
restored, and finding that out during a restore is too late. The newest 10 are
kept (`VPN_SETUP_BACKUP_KEEP`). Backups stay on the same machine — copy them
off-box if they matter.

Restoring a PostgreSQL-backed panel stops the application first, restores the
dump, then starts it again, rather than fighting live connections and
half-applied migrations.

```bash
vpnsetup backup remnawave
vpnsetup restore remnawave            # pick from a list, newest first
vpnsetup restore remnawave /path/to/remnawave-20260926_120000.tar.gz
```

---

## Security notes

- **Panel ports.** 3x-ui and Marzban need host networking: Xray inbounds listen on
  ports you choose later in the UI, and a bridge network would hide them. That
  means the panel port itself is reachable directly, not only through Caddy.
  3x-ui is protected by its login, its brute-force limiter and a random web base
  path this installer generates. Marzban is bound to `127.0.0.1` — only Caddy
  reaches it. If you want 3x-ui locked to loopback too, restrict its port with a
  firewall rule and leave Caddy's `127.0.0.1` access intact.
- **Remnawave** publishes its services on `127.0.0.1` only, per upstream's
  instruction. Do not change that — Caddy is the intended entry point.
- **Response headers.** Every generated site sends HSTS, `X-Content-Type-Options`,
  `X-Frame-Options`, `Referrer-Policy` and drops the `Server` header.
- **IP allowlist.** `vpnsetup allow-ips` can pin a panel to specific addresses.
  It is opt-in, applies to the panel site only, and exempts the ACME challenge
  path so certificate renewal keeps working.
- **Secrets** are generated on the machine with `openssl` (or `/dev/urandom`) and
  never leave it. `.env` files are mode `600`.
- **DNS preflight** warns when the domain does not resolve to this server. Behind
  Cloudflare's proxy the addresses legitimately differ, but HTTP-01 validation
  will fail unless the record is DNS-only or you switch to DNS-01.
- Remnawave's metrics endpoint stays on `127.0.0.1:3001`.

---

## Development

```bash
bash tests/smoke.sh          # 118 checks: parsing, state, env files, Caddyfile, doctor
bash -n install.sh lib/*.sh lib/panels/*.sh
```

The smoke test runs anywhere bash does — it needs no root, Docker or Linux, and
it exercises only the pure logic. Checks that depend on something the host cannot
provide (file modes on a filesystem without them, for instance) are skipped with a
note rather than reported as failures.

Line endings matter: `.gitattributes` forces LF for shell scripts. A CRLF
checkout breaks them on Linux, including the local-checkout path in `install.sh`.

---

## License

MIT — see [LICENSE](LICENSE). The panels themselves are their authors' work under
their own licenses; this project only installs them from upstream.
