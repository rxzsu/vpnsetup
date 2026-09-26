#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# main.sh — module loading, command dispatch, help text.
# ──────────────────────────────────────────────────────────────────────────────

vpnsetup_load() {
  local lib_dir="$1"

  # shellcheck source=/dev/null
  . "$lib_dir/common.sh"
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
  . "$lib_dir/ui.sh"

  local module
  for module in "$lib_dir"/panels/*.sh; do
    [ -e "$module" ] || continue
    # shellcheck source=/dev/null
    . "$module"
  done

  state_init
}

vpnsetup_help() {
  cat <<HELP
vpnsetup ${VPN_SETUP_VERSION} — installer for open-source VPN panels

Usage:
  vpnsetup [command] [args]

Commands:
  (none)                 Interactive menu
  install [panel]        Install a panel (3x-ui | marzban | remnawave)
  status                 Show containers and Caddy sites
  doctor                 Diagnose the host, containers, DNS, TLS and backups
  logs <panel> [service] Tail logs (Ctrl+C to stop)
  update <panel>         Pull new images and restart
  backup <panel>         Create a backup archive
  restore <panel>        Restore from a backup archive
  proxy [panel]          Re-apply the reverse proxy and certificates
  domain <panel> [name]  Move a panel to another domain, keeping its data
  allow-ips <panel> [..] Restrict panel access to a list of IPs ('clear' to undo)
  remove <panel>         Remove a panel and its data
  attach                 Reattach to a running tmux setup session
  help                   This text
  version                Print the version

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
  VPN_SETUP_CERT_WARN_DAYS    Warn below this TLS lifetime in days (default 14)
  VPN_SETUP_BACKUP_STALE_DAYS Warn above this backup age in days    (default 7)
  NO_COLOR               Disable colored output

Unattended install:
  VPN_SETUP_PANEL=3x-ui VPN_SETUP_DOMAIN=panel.example.com \\
    vpnsetup install

Files:
  $STATE_DIR/panels/<id>.env      per-panel state
  $ROOT_DIR/<panel>/              panel stacks
  $CADDY_DIR/Caddyfile            generated reverse proxy config
  $BACKUP_DIR/<id>/               backups
  $LOG_DIR/                       install logs

Panels are installed from their upstream sources and keep their own licenses:
  3x-ui      GPL-3.0   https://github.com/MHSanaei/3x-ui
  Marzban    AGPL-3.0  https://github.com/Gozargah/Marzban
  Remnawave  AGPL-3.0  https://github.com/remnawave/backend
HELP
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
      require_root
      cmd_backup "${1:-}"
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
      printf 'vpnsetup %s\n' "$VPN_SETUP_VERSION"
      ;;

    *)
      log_error "Unknown command: $cmd"
      printf '\n'
      vpnsetup_help
      exit 1
      ;;
  esac
}

# Entry point used by bin/vpnsetup and install.sh.
# With no command and no terminal (CI, `ssh host 'bash -s' < script`) the
# action is taken from VPN_SETUP_ACTION so the script exits instead of hanging
# on a menu it cannot draw.
vpnsetup_entry() {
  vpnsetup_load "$1"
  shift

  local cmd="${1:-}"
  [ $# -gt 0 ] && shift

  if [ -z "$cmd" ] && ! have_tty; then
    cmd="${VPN_SETUP_ACTION:-help}"
  fi

  vpnsetup_main "$cmd" "$@"
}
