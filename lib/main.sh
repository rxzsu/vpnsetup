#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# main.sh — module loading, command dispatch, help text.
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# Global flags
#
# Parsed before anything is sourced, so NO_COLOR is already set by the time
# common.sh decides whether to emit escape sequences, and so that every prompt
# can consult OPT_NONINTERACTIVE without the command knowing about the flag.
# ──────────────────────────────────────────────────────────────────────────────
OPT_JSON=0
OPT_YES=0
OPT_NONINTERACTIVE=0
OPT_DETACH=0
OPT_JOB=0
OPT_REINSTALL=0
OPT_FOLLOW=1
OPT_TAIL=200
VPN_SETUP_ARGS=()

vpnsetup_parse_flags() {
  local a

  # Reset first: parsing twice in one process (a test, or a re-entrant caller)
  # must not inherit the previous run's flags.
  OPT_JSON=0
  OPT_YES=0
  OPT_NONINTERACTIVE=0
  OPT_DETACH=0
  OPT_JOB=0
  OPT_REINSTALL=0
  OPT_FOLLOW=1
  OPT_TAIL=200
  VPN_SETUP_ARGS=()

  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --json)                          OPT_JSON=1 ;;
      --yes|-y)                        OPT_YES=1 ;;
      --no-interactive|--non-interactive|--batch)
                                       OPT_NONINTERACTIVE=1 ;;
      --detach)                        OPT_DETACH=1 ;;
      --job)                           OPT_JOB=1 ;;
      --reinstall)                     OPT_REINSTALL=1 ;;
      --no-follow)                     OPT_FOLLOW=0 ;;
      --tail)                          shift; OPT_TAIL="${1:-200}" ;;
      --tail=*)                        OPT_TAIL="${a#*=}" ;;
      *)                               VPN_SETUP_ARGS+=("$a") ;;
    esac
    shift
  done

  case "$OPT_TAIL" in ''|*[!0-9]*) OPT_TAIL=200 ;; esac

  # Machine-readable output has no room for escape sequences.
  if [ "$OPT_JSON" = "1" ] && [ -z "${NO_COLOR:-}" ]; then
    NO_COLOR=1
    export NO_COLOR
  fi
  return 0
}

VPN_SETUP_LOADED=0

vpnsetup_load() {
  local lib_dir="$1"

  # Loading twice would re-declare every `readonly` constant and flood stderr.
  # The CLI only ever loads once, but a long-lived caller (a test harness, an
  # embedded agent) may not.
  [ "$VPN_SETUP_LOADED" = "1" ] && return 0

  # json and lock first: common.sh's logging and state helpers call into them.
  # shellcheck source=/dev/null
  . "$lib_dir/json.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/lock.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/common.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/job.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/sites.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/docker.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/proxy.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/backup.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/panels.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/doctor.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/agent.sh"
  # shellcheck source=/dev/null
  . "$lib_dir/ui.sh"

  local module
  for module in "$lib_dir"/panels/*.sh; do
    [ -e "$module" ] || continue
    # shellcheck source=/dev/null
    . "$module"
  done

  state_init
  VPN_SETUP_LOADED=1
  return 0
}

vpnsetup_help() {
  cat <<HELP
vpnsetup ${VPN_SETUP_VERSION} — installer for open-source VPN panels

Usage:
  vpnsetup [command] [args] [options]

Commands:
  (none)                 Interactive menu
  install [panel]        Install a panel (3x-ui | marzban | remnawave)
  panels                 List every panel, installed or not
  status                 Show panels, containers and Caddy sites
  doctor                 Diagnose the host, containers, DNS, TLS and backups
  logs <panel> [service] Tail logs (--tail N, --no-follow)
  update <panel>         Pull new images and restart
  backup <panel>         Create a backup archive
  backup list <panel>    List backup archives
  restore <panel> [file] Restore from a backup archive
  proxy [panel]          Re-apply the reverse proxy and certificates
  domain <panel> [name]  Move a panel to another domain, keeping its data
  allow-ips <panel> [..] Restrict panel access to a list of IPs ('clear' to undo)
  remove <panel>         Remove a panel and its data

  sites                  List published sites
  site add <name> ...    Publish anything behind Caddy (--domain, --upstream)
  site remove <name>     Unpublish a site

  jobs                   List background jobs
  job [id]               Show a job's progress
  agent <action>         Unix-socket agent for a control panel
  rpc                    One JSON request on stdin, one JSON response on stdout
  attach                 Reattach to a running tmux setup session
  help                   This text
  version                Print the version

Options:
  --json                 Machine-readable output; human lines move to stderr
  --yes, -y              Answer yes to every confirmation
  --non-interactive      Never prompt; missing input or a needed confirmation
                         becomes an error instead of a silent no-op
  --detach               Run in the background and print a job id
  --reinstall            Allow install to wipe an existing panel
  --tail N               Lines of log to show (default 200)
  --no-follow            Do not follow the log

Exit codes:
  0 ok   1 failed   2 usage   3 conflict   4 not found
  5 precondition   6 partial (installed, follow-up step failed)   7 cancelled

Environment (all optional):
  VPN_SETUP_PANEL        Panel id, skips the panel prompt
  VPN_SETUP_DOMAIN       Panel domain, skips the domain prompt
  VPN_SETUP_SUB_DOMAIN   Subscription domain, skips that prompt
  VPN_SETUP_PORT         Panel port, skips the port prompt
  VPN_SETUP_ALLOW_IPS    Comma-separated IP/CIDR allowlist for the panel
  VPN_SETUP_3XUI_IMAGE   Override the 3x-ui image tag
  VPN_SETUP_ROOT         Base directory          (default /opt/vpnsetup)
  VPN_SETUP_BACKUP       Backup directory        (default /var/backups/vpnsetup)
  VPN_SETUP_STATE        State directory         (default /etc/vpnsetup)
  VPN_SETUP_BACKUP_KEEP  Backups to retain       (default 10)
  VPN_SETUP_JOBS_KEEP    Job records to retain   (default 50)
  VPN_SETUP_LOCK_TIMEOUT Seconds to wait for a lock (default 30)
  VPN_SETUP_CERT_WARN_DAYS    Warn below this TLS lifetime in days (default 14)
  VPN_SETUP_BACKUP_STALE_DAYS Warn above this backup age in days    (default 7)
  NO_COLOR               Disable colored output

Unattended install:
  vpnsetup install 3x-ui --domain panel.example.com --non-interactive --yes

Files:
  \$STATE_DIR/panels/<id>.env     per-panel state
  \$STATE_DIR/sites/<name>.env    what the reverse proxy publishes
  \$ROOT_DIR/<panel>/             panel stacks
  \$CADDY_DIR/Caddyfile           generated reverse proxy config
  \$BACKUP_DIR/<id>/              backups
  \$LOG_DIR/jobs/<id>.ndjson      job event streams
  \$LOG_DIR/audit.log             who changed what

Panels are installed from their upstream sources and keep their own licenses:
  3x-ui      GPL-3.0   https://github.com/MHSanaei/3x-ui
  Marzban    AGPL-3.0  https://github.com/Gozargah/Marzban
  Remnawave  AGPL-3.0  https://github.com/remnawave/backend
HELP
}

# Commands that change something, and therefore get an audit line.
_vpnsetup_is_mutating() {
  case "$1" in
    install|update|remove|uninstall|restore|domain|set-domain|allow-ips|allow|\
    proxy|proxy-reapply|backup|site|agent|self-update) return 0 ;;
    *) return 1 ;;
  esac
}

vpnsetup_main() {
  local cmd="${1:-}"

  case "$cmd" in
    ""|menu)
      require_root
      ui_main_menu
      ;;

    install)
      shift
      require_root
      cmd_install "${1:-}"
      ;;

    panels|catalog)
      cmd_panels
      ;;

    status)
      cmd_status
      ;;

    doctor)
      require_root
      # The return value is the whole point: doctor exits non-zero when a check
      # fails, so it can be used from a monitoring script.
      doctor_run
      ;;

    logs)
      shift
      cmd_logs "${1:-}" "${2:-}"
      ;;

    update)
      shift
      require_root
      cmd_update "${1:-}"
      ;;

    backup)
      shift
      cmd_backup "${1:-}" "${2:-}"
      ;;

    restore)
      shift
      require_root
      cmd_restore "${1:-}" "${2:-}"
      ;;

    proxy|proxy-reapply)
      shift
      require_root
      cmd_proxy_reapply "${1:-}"
      ;;

    domain|set-domain)
      shift
      require_root
      cmd_set_domain "${1:-}" "${2:-}"
      ;;

    allow-ips|allow)
      shift
      require_root
      cmd_set_allow_ips "${1:-}" "${2:-}"
      ;;

    remove|uninstall)
      shift
      require_root
      cmd_remove "${1:-}"
      ;;

    sites)
      cmd_sites
      ;;

    site)
      shift
      require_root
      case "${1:-}" in
        add|publish)  shift; cmd_site_add "$@" ;;
        remove|rm|unpublish) shift; cmd_site_remove "$@" ;;
        *) log_error "Usage: vpnsetup site add|remove <name> ..."; return "$EX_USAGE" ;;
      esac
      ;;

    jobs)
      cmd_jobs
      ;;

    job)
      shift
      cmd_job "${1:-}" "${2:-}"
      ;;

    agent)
      shift
      require_root
      cmd_agent "${1:-}" "${2:-}"
      ;;

    rpc)
      require_root
      cmd_rpc
      ;;

    attach)
      if have_cmd tmux && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        exec tmux attach-session -t "$TMUX_SESSION"
      fi
      log_warn "No active setup session."
      ;;

    help|--help|-h)
      vpnsetup_help
      ;;

    version|--version|-v)
      if [ "$OPT_JSON" = "1" ]; then
        json_emit "$(json_pair version "$(json_str "$VPN_SETUP_VERSION")")"
      else
        printf 'vpnsetup %s\n' "$VPN_SETUP_VERSION"
      fi
      ;;

    *)
      log_error "Unknown command: $cmd"
      printf '\n' >&2
      vpnsetup_help >&2
      return "$EX_USAGE"
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Detached execution
#
# A control panel cannot hold a connection open for a ten-minute install, and an
# operator on a flaky SSH link should not have to either. `--detach` re-executes
# this same CLI with the job file in the environment, prints the job id and
# returns immediately; the child writes its exit code to <id>.status.
# ──────────────────────────────────────────────────────────────────────────────
vpnsetup_detach() {
  state_init
  mkdir -p "$JOBS_DIR" 2>/dev/null || true

  local id file out pid
  id="$(date +%Y%m%d-%H%M%S)-$$"
  file="$JOBS_DIR/$id.ndjson"
  out="$JOBS_DIR/$id.out"
  local label="vpnsetup $*"

  VPN_SETUP_JOB_ID="$id" VPN_SETUP_JOB_FILE="$file" \
    setsid "$VPN_SETUP_SELF" "$@" >"$out" 2>&1 </dev/null &
  pid=$!

  printf '{"ts":%s,"event":"start","pid":%s,"label":"%s"}\n' \
    "$(date +%s)" "$pid" "$(json_escape "$label")" >"$file" 2>/dev/null || true
  printf '%s\n' "$label" >"$JOBS_DIR/$id.label" 2>/dev/null || true
  chmod 600 "$file" "$JOBS_DIR/$id.label" "$out" 2>/dev/null || true

  job_prune "${VPN_SETUP_JOBS_KEEP:-50}"

  if [ "$OPT_JSON" = "1" ]; then
    json_emit \
      "$(json_pair job_id "$(json_str "$id")")" \
      "$(json_pair pid "$(json_num "$pid")")" \
      "$(json_pair state "$(json_str running)")"
    return 0
  fi

  log_ok "Started in the background."
  printf '\n'
  ui_kv "Job" "$id"
  ui_kv "PID" "$pid"
  ui_kv "Log" "$out"
  printf '\n'
  log_dim "  vpnsetup job $id     # progress"
  log_dim "  vpnsetup jobs        # every job"
  return 0
}

# Entry point used by bin/vpnsetup and install.sh.
# With no command and no terminal (CI, `ssh host 'bash -s' < script`) the
# action is taken from VPN_SETUP_ACTION so the script exits instead of hanging
# on a menu it cannot draw.
vpnsetup_entry() {
  local lib_dir="$1"; shift

  vpnsetup_parse_flags "$@"
  if [ "${#VPN_SETUP_ARGS[@]}" -gt 0 ]; then
    set -- "${VPN_SETUP_ARGS[@]}"
  else
    set --
  fi

  vpnsetup_load "$lib_dir"

  VPN_SETUP_SELF="${VPN_SETUP_SELF:-$0}"
  if [ ! -x "$VPN_SETUP_SELF" ]; then
    VPN_SETUP_SELF="$(command -v vpnsetup 2>/dev/null || printf '%s' "$0")"
  fi

  if [ "$OPT_DETACH" = "1" ]; then
    vpnsetup_detach "$@"
    return $?
  fi

  # Foreground but recorded: the agent uses this so it can hand back a job id
  # without giving up the process it is supervising.
  if [ -z "${VPN_SETUP_JOB_FILE:-}" ] && [ "${OPT_JOB:-0}" = "1" ]; then
    job_start "vpnsetup ${*:-menu}"
    if [ "$OPT_JSON" = "1" ]; then
      printf '{"schema_version":%s,"job_id":"%s"}\n' "$SCHEMA_VERSION" "$VPN_SETUP_JOB_ID" >&2
    else
      log_dim "Recording this run as job $VPN_SETUP_JOB_ID"
    fi
  fi

  local cmd="${1:-}"
  [ $# -gt 0 ] && shift

  if [ -z "$cmd" ] && ! have_tty; then
    cmd="${VPN_SETUP_ACTION:-help}"
  fi

  # The trap is what makes a job record trustworthy: `die` exits mid-command,
  # and the job still ends up with a terminal event and an exit code.
  if [ -n "${VPN_SETUP_JOB_FILE:-}" ]; then
    trap 'job_finish $?' EXIT
  fi

  _vpnsetup_is_mutating "$cmd" && audit_write "$cmd" "$*"

  vpnsetup_main "$cmd" "$@"
}
