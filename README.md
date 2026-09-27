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

**v0.2.0 makes this scriptable.** Every command can emit JSON, every failure has
its own exit code, long operations can run in the background with a job id you
can poll, and the privileged side is reachable over a unix socket — so a web
control panel can drive the whole thing without running as root. See
[Machine interface](#machine-interface).

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
- `jq` — only for the `rpc` endpoint, and installed on demand

---

## Commands

```bash
vpnsetup                      # interactive menu
vpnsetup install 3x-ui        # install a specific panel
vpnsetup panels               # list every panel, installed or not
vpnsetup status               # containers + Caddy sites
vpnsetup doctor               # diagnose host, containers, DNS, TLS, backups
vpnsetup logs marzban         # tail logs (Ctrl+C to stop)
vpnsetup logs marzban panel   # tail one compose service
vpnsetup update 3x-ui         # pull new images and restart
vpnsetup backup remnawave     # write a backup archive
vpnsetup backup list remnawave
vpnsetup restore remnawave    # restore from an archive
vpnsetup proxy                # re-apply Caddy + certificates
vpnsetup domain marzban       # move a panel to another domain, keeping its data
vpnsetup allow-ips marzban    # restrict panel access to a list of IPs
vpnsetup allow-ips marzban clear
vpnsetup remove 3x-ui         # remove the panel and its data
vpnsetup attach               # reattach to a running tmux setup session
vpnsetup help
```

Publishing something that is not a panel:

```bash
vpnsetup sites                                    # what the proxy publishes
vpnsetup site add grafana --domain metrics.example.com --upstream 127.0.0.1:3000
vpnsetup site add api --domain api.example.com --upstream 8080 --allow-ips 10.0.0.0/8
vpnsetup site remove grafana
```

Watching long operations:

```bash
vpnsetup install remnawave --detach     # returns a job id immediately
vpnsetup jobs                           # every job, newest first
vpnsetup job 20260927-143012-4821       # progress of one job
```

The control-panel endpoint:

```bash
vpnsetup agent install                  # set up the unix-socket agent
vpnsetup agent status
echo '{"method":"panels"}' | sudo vpnsetup rpc
```

Only `install`, `update`, `backup`, `restore`, `proxy`, `domain`, `allow-ips`,
`site`, `remove`, `agent`, `rpc` and `doctor` need root. `panels`, `sites`,
`jobs`, `job`, `status` and `logs` do not.

---

## Machine interface

The design rule behind everything below: **stdout carries data, stderr carries
prose.** Under `--json` a command writes exactly one JSON document to stdout and
every human-facing line — banners, warnings, progress — goes to stderr. A caller
never has to guess where the payload ends, and `vpnsetup panels --json | jq .`
works even when the command is chatty.

```bash
vpnsetup panels --json
```

```json
{"schema_version":1,"panels":[{"id":"3x-ui","name":"3x-ui","description":"Xray panel,
single binary, SQLite by default","upstream":"https://github.com/MHSanaei/3x-ui",
"license":"GPL-3.0","default_port":2053,"installed":true}]}
```

Every payload carries `schema_version` (currently `1`) at the top level, so a
consumer can refuse a shape it does not understand instead of misreading it.
Colours are forced off under `--json` regardless of `NO_COLOR`.

### Exit codes

An exit code is a contract, not a hint. The taxonomy exists because the worst
failure mode of a manager like this is *doing nothing and reporting success*.

| Code | Name | Meaning |
|---|---|---|
| `0` | ok | The command did what it said |
| `1` | failed | It ran and something broke |
| `2` | usage | Bad command, bad flag, or a required parameter is missing |
| `3` | conflict | The request contradicts current state (port taken, site owned by a panel) |
| `4` | not found | No such panel, job, site or backup |
| `5` | precondition | The host cannot do this (not root, no systemd, no Docker) |
| `6` | partial | The main step worked, a follow-up did not — e.g. installed but the certificate is not confirmed yet |
| `7` | cancelled | A human declined a confirmation |

`6` is the one worth internalising: "the panel is installed but Caddy has not
finished issuing the certificate" is neither success nor failure, and a control
panel has to be able to say so.

### Non-interactive runs

```bash
vpnsetup install 3x-ui --domain panel.example.com --non-interactive --yes
```

`--non-interactive` never prompts. Missing input or a confirmation that is not
covered by `--yes` becomes **an error** (`2`), never a silent no-op. The old
behaviour — printing "Cancelled." and returning `0` — is exactly the bug this
flag exists to prevent: an unattended caller could not tell a skipped install
from a completed one.

### Background jobs

`--detach` re-executes the CLI in its own session, prints a job id and returns
immediately. The child writes an append-only NDJSON stream plus a status file:

```bash
vpnsetup install remnawave --detach --json
# {"schema_version":1,"job_id":"20260927-143012-4821","pid":4821,"state":"running"}
```

```
$LOG_DIR/jobs/<id>.ndjson   one JSON object per line
$LOG_DIR/jobs/<id>.status   the exit code, written when the job ends
$LOG_DIR/jobs/<id>.label    what the job was
$LOG_DIR/jobs/<id>.out      raw combined output
```

```json
{"ts":1758900000,"event":"start","pid":4821,"label":"vpnsetup install remnawave"}
{"ts":1758900001,"event":"log","level":"info","msg":"Pulling images..."}
{"ts":1758900042,"event":"done","code":0}
```

`vpnsetup jobs --json` and `vpnsetup job <id> --json` read those files back:

```json
{"schema_version":1,"jobs":[{"id":"20260927-143012-4821","label":"vpnsetup install remnawave",
"state":"running","exit_code":null,"pid":4821,"last_message":"Pulling images...","events":7}]}
```

`state` is `running`, `done`, `failed`, or `aborted`. `aborted` is what a job
killed by a reboot looks like — the pid is gone and no exit code was ever
written, so reporting it as `running` forever would be a lie. The last 50 job
records are kept (`VPN_SETUP_JOBS_KEEP`).

The job record is closed by an `EXIT` trap, not by the command returning
normally, so a `die` halfway through an install still leaves a terminal event and
a real exit code behind.

### Audit trail

Every mutating command appends one tab-separated line to `$LOG_DIR/audit.log`:
`UTC`, user, action, detail. This is the activity feed a panel shows and the
answer to "who changed that domain at 3am".

```
2026-09-27T11:30:12Z  root  install  3x-ui --domain panel.example.com
2026-09-27T11:41:55Z  root  rpc      domain
```

### Agent over a unix socket

The web UI must not run as root and must not hold the Docker socket — either one
gives a web page full control of the host. So the privileged side is a unix
socket owned by the `vpnsetup` group, and behind it sits exactly one command:

```bash
vpnsetup agent install
usermod -aG vpnsetup www-data     # grant the web user access
```

```bash
curl --unix-socket /run/vpnsetup/agent.sock \
     -d '{"method":"install","params":{"panel":"3x-ui","domain":"p.example.com"}}' \
     http://localhost/
```

```json
{"schema_version":1,"ok":true,"exit_code":0,"method":"install","result":{...},"error":null}
```

- **Transport is systemd socket activation** (`Accept=yes`): no daemon of our
  own, no `socat` dependency, and each request gets a clean process. Units are
  `vpnsetup-agent.socket` and `vpnsetup-agent@.service`.
- **Access control is the socket's file mode** — `0660`, group `vpnsetup`. Add
  the web user to that group and nothing else is needed.
- **Methods mirror the CLI**, with a dot where the CLI takes a subcommand:
  `version`, `status`, `panels`, `sites`, `jobs`, `doctor`, `job`, `install`,
  `update`, `remove`, `backup`, `backups`, `restore`, `domain`, `allow-ips`,
  `proxy`, `logs`, `site.add`, `site.remove`. A panel author can predict the RPC
  surface from `vpnsetup help`.
- The command runs in a subshell, so a `die` mid-request answers with an error
  instead of killing the endpoint.
- Set `"yes": true` in `params` to answer confirmations. `logs` always runs with
  `--no-follow`, because a panel never wants a stream that blocks forever.
- The response always carries `exit_code`, so the panel sees the same taxonomy
  the shell does — `{"ok":false,"exit_code":5,...}` means "not root", not
  "something went wrong".

`jq` is required, but **only on this path** — `rpc` is the one place that has to
*parse* JSON, and hand-rolling that in bash would be a liability. Every other
command only emits it. `vpnsetup agent status --json` reports whether `jq` is
present, so a panel can check before it calls.

### Published sites

The proxy used to be rendered from panel state, which meant only panels could
ever be published. It is now rendered from a **site registry** in
`$STATE_DIR/sites/<name>.env`:

```
SITE_NAME=grafana
KIND=app                  # panel | app
DOMAIN=metrics.example.com
ALT_DOMAIN=               # optional second hostname on the same upstream
UPSTREAM=127.0.0.1:3000   # host:port, or a bare port meaning loopback
ALLOW_IPS=10.0.0.0/8      # optional
MANAGED_BY=               # panel id for KIND=panel
```

A panel install derives its entry automatically; anything else registers one
directly and gets the same TLS, headers and allowlist machinery:

```bash
vpnsetup site add grafana --domain metrics.example.com --upstream 3000
```

```json
{"schema_version":1,"sites":[{"name":"grafana","kind":"app","domain":"metrics.example.com",
"alt_domain":null,"upstream":"127.0.0.1:3000","allow_ips":"10.0.0.0/8","managed_by":null}]}
```

A site whose `KIND=panel` cannot be added or removed by hand — it belongs to the
panel that owns it, and the command returns `3` rather than letting the registry
and the panel drift apart.

### Diagnostics

```bash
vpnsetup doctor
vpnsetup doctor --json
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

`--json` gives the same run in a shape a dashboard can render:

```json
{"schema_version":1,"healthy":false,"summary":{"passed":14,"warnings":2,"failed":0},
"checks":[{"level":"ok","section":"Host","message":"debian x86_64, kernel 6.8.0-45-generic"}]}
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
VPN_SETUP_PANEL=remnawave VPN_SETUP_DOMAIN=panel.example.com vpnsetup install --non-interactive --yes
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
| `VPN_SETUP_JOBS_KEEP` | `50` | Job records retained |
| `VPN_SETUP_LOCK_TIMEOUT` | `30` | Seconds to wait for a lock before giving up |
| `VPN_SETUP_AGENT_SOCKET` | `/run/vpnsetup/agent.sock` | Agent socket path |
| `VPN_SETUP_AGENT_GROUP` | `vpnsetup` | Group allowed to talk to the agent |
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
lib/json.sh         JSON emitters (no jq needed to produce output)
lib/lock.sh         exclusive locks: flock, or an atomic mkdir fallback
lib/common.sh       logging, OS/package detection, secrets, prompts, state files
lib/job.sh          NDJSON job streams and the audit log
lib/sites.sh        the site registry the reverse proxy is rendered from
lib/docker.sh       Docker/Compose bootstrap, compose wrappers, health waits
lib/proxy.sh        Caddy; renders the Caddyfile from sites, reloads on change
lib/backup.sh       archive-based backup and restore
lib/panels.sh       panel catalog + shared install/update/remove flow
lib/doctor.sh       read-only diagnostics
lib/agent.sh        unix-socket RPC endpoint for a control panel
lib/ui.sh           banner and menus
lib/main.sh         module loading, flag parsing, dispatch, help
lib/panels/*.sh     one module per panel
```

Five ideas carry the design:

**State, not guesswork.** Installing a panel writes
`/etc/vpnsetup/panels/<id>.env`. `status`, `logs`, `update`, `backup` and
`remove` all read that file, so nothing has to be re-derived from a running
container, and there is no per-panel branching scattered through the manager.
Writes are atomic (a temp file with the pid in its name, then `mv`), so a reader
never sees half a file.

**One writer at a time.** Two `state_set` calls do a read-modify-write of the
same file, and two installs of the same panel both create directories. So there
are real locks: `flock` when it exists, an atomic `mkdir` when it does not, and
`state_set` takes a short `state` lock inside the per-panel one. A lock belongs
to the *current shell*, which is why `lock_take` must never be called inside
`$(...)` — the lock would be released the moment the substitution exits.

**The Caddyfile is generated, never hand-edited.** `lib/proxy.sh` renders one
site block per entry in the site registry and reloads Caddy. Installing a panel,
publishing an app or removing either one therefore just re-renders — which is
what lets several things share one server without fighting over ports 80/443.
The generated config is validated with `caddy validate` before it is applied, so
a bad config cannot take down a proxy that is currently serving traffic.

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

A new panel does not have to know anything about the site registry: after
`panel_install_<slug>` returns, the shared flow calls `site_sync_from_panel`,
which derives `DOMAIN`, `ALT_DOMAIN` (from `SUB_DOMAIN`), `UPSTREAM` and
`ALLOW_IPS` from the state file.

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
| `/etc/vpnsetup/sites/` | Site registry — what the proxy publishes (mode `600`) |
| `/etc/vpnsetup/locks/` | Lock files |
| `/var/backups/vpnsetup/<panel>/` | Backup archives |
| `/var/log/vpnsetup/jobs/` | Job event streams, statuses and raw output |
| `/var/log/vpnsetup/audit.log` | Who changed what, one line per mutating command |
| `/run/vpnsetup/agent.sock` | Agent socket (mode `0660`, group `vpnsetup`) |
| `/etc/systemd/system/vpnsetup-agent*.{socket,service}` | Agent units |
| `/etc/tmpfiles.d/vpnsetup-agent.conf` | Recreates `/run/vpnsetup` on boot |

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
vpnsetup backup list remnawave --json
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
- **The agent socket is a root boundary.** Its mode (`0660`) and group are the
  entire access-control story, so treat membership of `vpnsetup` as equivalent to
  sudo for this tool. The web user needs no Docker socket and no root. The
  endpoint never accepts a command line from the caller — only a method name and
  named parameters, which are turned into a fixed `argv` internally.
- **Secrets** are generated on the machine with `openssl` (or `/dev/urandom`) and
  never leave it. `.env` files are mode `600`.
- **DNS preflight** warns when the domain does not resolve to this server. Behind
  Cloudflare's proxy the addresses legitimately differ, but HTTP-01 validation
  will fail unless the record is DNS-only or you switch to DNS-01.
- Remnawave's metrics endpoint stays on `127.0.0.1:3001`.

---

## Development

```bash
bash tests/smoke.sh          # 358 checks: JSON, exit codes, locks, sites, jobs, agent
bash -n install.sh lib/*.sh lib/panels/*.sh
```

The smoke test runs anywhere bash does — it needs no root, Docker or Linux, and
it exercises only the pure logic. Checks that depend on something the host cannot
provide (file modes on a filesystem without them, a filesystem that refuses to
delete a directory, for instance) are skipped with a note rather than reported as
failures.

Two habits keep the suite honest, both learned the hard way:

- **Nothing lock-taking may run inside `$(...)`.** A lock belongs to the shell
  that took it, so a lock taken in a command substitution is released the instant
  the substitution exits. One section of the suite exists purely to document
  that.
- **Each run gets its own temp tree** (`.smoke-tmp.<pid>`). The state files are
  guarded by real locks, so two concurrent runs sharing one directory deadlock
  against each other and the failures look like bugs in the code under test.

The suite also drops any `rm`/`rmdir`/`unlink` shell shims for its own process.
Some sandboxes install shims that quietly refuse local paths; the mkdir lock
fallback then cannot delete its directory, and every later lock acquisition pays
the full timeout. That turned a ten-second suite into an eight-minute one, with
failures pointing at code that was correct.

Line endings matter: `.gitattributes` forces LF for shell scripts. A CRLF
checkout breaks them on Linux, including the local-checkout path in `install.sh`.

---

## License

MIT — see [LICENSE](LICENSE). The panels themselves are their authors' work under
their own licenses; this project only installs them from upstream.
