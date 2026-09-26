#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# panels.sh — panel catalog and the shared install/update/remove flow.
#
# Each panel module lives in lib/panels/<id>.sh and must define:
#   panel_install_<slug>   <id> <domain>   — install and write the state file
#   panel_uninstall_<slug> <id>            — remove containers and data
#   panel_update_<slug>    <id>            — optional, defaults to pull + up
#
# <slug> is the id with non-alphanumerics stripped: "3x-ui" -> "3xui".
# ──────────────────────────────────────────────────────────────────────────────

readonly PANEL_IDS=(3x-ui marzban remnawave)

panel_catalog_ids() {
  local id
  for id in "${PANEL_IDS[@]}"; do printf '%s\n' "$id"; done
}

panel_catalog_name() {
  case "$1" in
    3x-ui)     printf '3x-ui' ;;
    marzban)   printf 'Marzban' ;;
    remnawave) printf 'Remnawave' ;;
    *)         printf '%s' "$1" ;;
  esac
}

panel_catalog_desc() {
  case "$1" in
    3x-ui)     printf 'Xray panel, single binary, SQLite by default' ;;
    marzban)   printf 'Multi-protocol Xray panel with REST API' ;;
    remnawave) printf 'Panel + nodes, PostgreSQL, subscription page' ;;
    *)         printf '' ;;
  esac
}

panel_catalog_upstream() {
  case "$1" in
    3x-ui)     printf 'https://github.com/MHSanaei/3x-ui' ;;
    marzban)   printf 'https://github.com/Gozargah/Marzban' ;;
    remnawave) printf 'https://github.com/remnawave/backend' ;;
    *)         printf '' ;;
  esac
}

panel_catalog_license() {
  case "$1" in
    3x-ui)     printf 'GPL-3.0' ;;
    marzban)   printf 'AGPL-3.0' ;;
    remnawave) printf 'AGPL-3.0' ;;
    *)         printf 'unknown' ;;
  esac
}

panel_default_port() {
  case "$1" in
    3x-ui)     printf '2053' ;;
    marzban)   printf '8000' ;;
    remnawave) printf '3000' ;;
    *)         printf '8080' ;;
  esac
}

# Which installed panel already claims this port, if any.
panel_owner_of_port() {
  local port="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$(state_get "$id" PORT)" = "$port" ]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(state_ids)
  return 1
}

# validate_panel_port <port> — reject ports that cannot host a panel.
validate_panel_port() {
  local port="$1" owner
  case "$port" in
    80|443)
      log_error "Port $port belongs to the reverse proxy (Caddy) and cannot host a panel."
      return 1
      ;;
  esac
  owner="$(panel_owner_of_port "$port")" || true
  if [ -n "$owner" ]; then
    log_error "Port $port is already used by $(panel_catalog_name "$owner")."
    return 1
  fi
  return 0
}

# ask_panel_port <prompt> <default> — like ask_port, but the answer has to be a
# port that can actually host a panel. A port supplied through the environment
# is a configuration error rather than something to re-prompt about, so it
# fails the install instead of looping.
ask_panel_port() {
  local prompt="$1" default="$2" port

  if [ -n "${VPN_SETUP_PORT:-}" ]; then
    port="$(ask_port "$prompt" "$default")"
    validate_panel_port "$port" || return 1
    printf '%s' "$port"; return 0
  fi

  if ! have_tty; then printf '%s' "$default"; return 0; fi

  while true; do
    port="$(ask_port "$prompt" "$default")"
    if validate_panel_port "$port"; then printf '%s' "$port"; return 0; fi
  done
}

# ask_optional_sub_domain <panel-domain> — prints a domain or an empty string.
# Only offered where subscriptions are genuinely served by the panel itself on
# the same port (Marzban, Remnawave).
ask_optional_sub_domain() {
  local panel_domain="$1" sub

  if [ -n "${VPN_SETUP_SUB_DOMAIN:-}" ]; then
    if is_valid_domain "$VPN_SETUP_SUB_DOMAIN"; then
      printf '%s' "$VPN_SETUP_SUB_DOMAIN"
    else
      log_error "VPN_SETUP_SUB_DOMAIN is not a valid domain: $VPN_SETUP_SUB_DOMAIN"
      return 1
    fi
    return 0
  fi

  if ! have_tty; then printf ''; return 0; fi

  printf '\n' >&2
  log_dim "Subscriptions can live on their own domain, so you never hand out the" >&2
  log_dim "panel hostname to every client. Leave empty to use the panel domain." >&2

  sub="$(ask "Subscription domain (Enter = same as panel)")"
  if [ -z "$sub" ]; then printf ''; return 0; fi
  if ! is_valid_domain "$sub"; then
    log_warn "Not a valid domain — subscriptions will use the panel domain."
    printf ''; return 0
  fi
  printf '%s' "$sub"
}

# Loose validation of a comma-separated IP/CIDR list — enough to catch typos
# before they reach Caddy, which does the real check and refuses to reload.
is_valid_ip_list() {
  local list="$1" item
  [ -n "$list" ] || return 1
  local IFS=','
  for item in $list; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [ -n "$item" ] || return 1
    case "$item" in
      *[!0-9a-fA-F:./]*) return 1 ;;
    esac
  done
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# DNS preflight — warn, never block. Cloudflare-proxied records legitimately
# differ from the server IP, and the operator may know better than we do.
# ──────────────────────────────────────────────────────────────────────────────
panel_check_dns() {
  local domain="$1" server_ip resolved

  server_ip="$(public_ip)"
  resolved="$(resolve_a "$domain")"

  if [ -z "$resolved" ]; then
    log_warn "Could not resolve $domain — the A-record may not exist yet."
    log_warn "Caddy cannot issue a certificate until DNS points here."
    return 1
  fi

  if [ -n "$server_ip" ] && [ "$resolved" != "$server_ip" ]; then
    log_warn "$domain resolves to $resolved, but this server is $server_ip."
    log_warn "That is expected behind Cloudflare/proxy, but HTTP-01 validation"
    log_warn "will fail unless the record is DNS-only (grey cloud) or you use DNS-01."
    return 1
  fi

  log_ok "DNS OK: $domain -> $resolved"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Shared install entry point
# ──────────────────────────────────────────────────────────────────────────────
cmd_install() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    id="$(ui_select_panel)" || return 1
  fi
  [ -n "$id" ] || return 1

  # Reject unknown ids before touching the filesystem.
  local known=0 p
  for p in "${PANEL_IDS[@]}"; do [ "$p" = "$id" ] && known=1 && break; done
  if [ "$known" -ne 1 ]; then
    log_error "Unknown panel: '$id'. Available: ${PANEL_IDS[*]}"
    return 1
  fi

  local slug fn
  slug="$(id_slug "$id")"
  fn="panel_install_${slug}"
  if ! declare -F "$fn" >/dev/null; then
    log_error "No installer found for panel '$id'."
    return 1
  fi

  ui_title "Install $(panel_catalog_name "$id")"
  printf '  %s%-12s%s %s\n' "$C_BWHITE" 'Upstream' "$C_RESET" "$(panel_catalog_upstream "$id")"
  printf '  %s%-12s%s %s\n' "$C_BWHITE" 'License'  "$C_RESET" "$(panel_catalog_license "$id")"
  printf '  %s%-12s%s %s\n' "$C_BWHITE" 'Panel port' "$C_RESET" "$(panel_default_port "$id")"
  printf '\n'

  if state_exists "$id"; then
    log_warn "$(panel_catalog_name "$id") is already installed at $(state_get "$id" INSTALL_DIR)."
    confirm "Reinstall? This will WIPE its data." "n" || { log_info "Cancelled."; return 0; }
    cmd_remove "$id" "quiet" || true
  fi

  require_root
  ensure_docker

  local domain
  domain="$(ask_domain "Panel domain (e.g. panel.example.com)")"
  panel_check_dns "$domain" || true

  # Optional hardening, asked up front so the install runs unattended afterwards.
  local allow_ips="${VPN_SETUP_ALLOW_IPS:-}"
  if [ -z "$allow_ips" ] && have_tty; then
    printf '\n'
    log_dim "Panel access can be limited to specific IPs (comma-separated, CIDR allowed)."
    log_dim "Leave empty to allow everyone — you will need one of these IPs to reach"
    log_dim "the panel later, so do not lock yourself out."
    allow_ips="$(ask "Allowed IPs (Enter = allow all)")"
  fi
  if [ -n "$allow_ips" ] && ! is_valid_ip_list "$allow_ips"; then
    log_warn "That does not look like an IP list — access will not be restricted."
    allow_ips=""
  fi

  "$fn" "$id" "$domain" || return 1

  if [ -n "$allow_ips" ]; then
    state_set "$id" ALLOW_IPS "$allow_ips" || log_warn "Could not record the IP allowlist."
  fi

  log_step "Applying reverse proxy"
  proxy_up || log_warn "Caddy setup failed — run 'vpnsetup proxy' once DNS/ports are ready."

  printf '\n'
  log_ok "$(panel_catalog_name "$id") installed."
  ui_kv "Panel" "https://$domain"
  local sub; sub="$(state_get "$id" SUB_DOMAIN)"
  [ -n "$sub" ] && ui_kv "Subscription" "https://$sub"
  [ -n "$allow_ips" ] && ui_kv "Restricted to" "$allow_ips"
  ui_kv "Data" "$(state_get "$id" INSTALL_DIR)"
  ui_kv "Backups" "$(backup_dir_for "$id")"
  printf '\n'
  proxy_wait_for_cert "$domain" 60 || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Update
# ──────────────────────────────────────────────────────────────────────────────
cmd_update() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1

  local slug fn dir
  slug="$(id_slug "$id")"
  fn="panel_update_${slug}"
  dir="$(state_get "$id" INSTALL_DIR)"

  ui_title "Update $(panel_catalog_name "$id")"

  if declare -F "$fn" >/dev/null; then
    "$fn" "$id"
  else
    ensure_docker
    [ -d "$dir" ] || { log_error "Install directory missing: $dir"; return 1; }
    compose_pull "$dir"
    dc "$dir" up -d || die "docker compose up failed"
  fi

  log_ok "Update finished."
  dc "$dir" ps 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Status / logs / remove
# ──────────────────────────────────────────────────────────────────────────────
cmd_status() {
  ui_title "Status"
  if [ "$(state_count)" -eq 0 ]; then
    log_warn "No panels installed."
    proxy_status
    return 0
  fi

  local id dir
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    dir="$(state_get "$id" INSTALL_DIR)"
    printf '\n%s%s%s %s(%s)%s\n' "$C_BOLD$C_BWHITE" "$(panel_catalog_name "$id")" "$C_RESET" \
      "$C_DIM" "$id" "$C_RESET"
    printf '  %s%-12s%s %s\n' "$C_BWHITE" 'Domain' "$C_RESET" "$(state_get "$id" DOMAIN '-')"
    printf '  %s%-12s%s %s\n' "$C_BWHITE" 'Port'   "$C_RESET" "$(state_get "$id" PORT '-')"
    printf '  %s%-12s%s %s\n' "$C_BWHITE" 'Dir'    "$C_RESET" "$dir"
    if [ -d "$dir" ]; then
      dc "$dir" ps 2>/dev/null | sed 's/^/  /' || true
    fi
  done < <(state_ids)

  proxy_status
}

cmd_logs() {
  local id="${1:-}" service="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  local dir; dir="$(state_get "$id" INSTALL_DIR)"
  [ -d "$dir" ] || { log_error "Install directory missing: $dir"; return 1; }
  log_info "Tailing logs (Ctrl+C to stop)..."
  dc "$dir" logs -f --tail=200 ${service:+"$service"} || true
}

cmd_remove() {
  local id="${1:-}" quiet="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  state_exists "$id" || { log_warn "Panel '$id' is not installed."; return 0; }

  local slug fn dir
  slug="$(id_slug "$id")"
  fn="panel_uninstall_${slug}"
  dir="$(state_get "$id" INSTALL_DIR)"

  ui_title "Remove $(panel_catalog_name "$id")"
  if [ "$quiet" != "quiet" ]; then
    log_warn "This deletes the containers, the data in $dir and the panel state."
    log_warn "Backups in $(backup_dir_for "$id") are kept."
    confirm "Continue?" "n" || { log_info "Cancelled."; return 0; }
  fi

  if declare -F "$fn" >/dev/null; then
    "$fn" "$id"
  else
    compose_down "$dir" purge
    rm -rf "$dir"
  fi

  state_delete "$id"
  proxy_reload || true
  log_ok "$(panel_catalog_name "$id") removed."
}

cmd_proxy_reapply() {
  local id="${1:-}"
  if [ -n "$id" ]; then
    state_exists "$id" || die "Panel '$id' is not installed."
  fi
  ui_title "Reverse proxy + SSL"
  proxy_up || return 1
  if [ -n "$id" ]; then
    proxy_wait_for_cert "$(state_get "$id" DOMAIN)" 60 || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Change a panel's domain without touching its data.
#
# Reinstalling used to be the only way to move a panel to another hostname, and
# for the SQLite-backed panels that means destroying the database. The domain
# lives in the state file, so it can be rewritten in place.
# ──────────────────────────────────────────────────────────────────────────────
cmd_set_domain() {
  local id="${1:-}" domain="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  state_exists "$id" || die "Panel '$id' is not installed."

  local slug fn current
  slug="$(id_slug "$id")"
  fn="panel_set_domain_${slug}"
  current="$(state_get "$id" DOMAIN)"

  ui_title "Change domain — $(panel_catalog_name "$id")"
  ui_kv "Current" "${current:--}"

  if [ -z "$domain" ]; then
    domain="$(ask_domain "New domain")"
  fi
  is_valid_domain "$domain" || die "Not a valid domain: $domain"

  if [ "$domain" = "$current" ]; then
    log_info "Domain unchanged — nothing to do."
    return 0
  fi

  panel_check_dns "$domain" || true

  state_set "$id" DOMAIN "$domain" || die "Could not update the state file."

  # Panels that bake their own domain into their configuration need to be told;
  # the rest only care about the reverse proxy.
  if declare -F "$fn" >/dev/null; then
    log_info "Updating the panel configuration..."
    "$fn" "$id" "$domain" || log_warn "The panel configuration was not updated — check its logs."
  fi

  proxy_reload || { log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."; return 1; }
  proxy_wait_for_cert "$domain" 60 || true

  printf '\n'
  log_ok "Domain updated. Panel data was not touched."
  ui_kv "Panel" "https://$domain"
  log_dim "The old hostname stops working once DNS and the certificate catch up."
}

# ──────────────────────────────────────────────────────────────────────────────
# Restrict panel access to a list of IPs. Subscriptions stay public.
# ──────────────────────────────────────────────────────────────────────────────
cmd_set_allow_ips() {
  local id="${1:-}" list="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  state_exists "$id" || die "Panel '$id' is not installed."

  ui_title "Restrict access — $(panel_catalog_name "$id")"
  local current; current="$(state_get "$id" ALLOW_IPS)"
  ui_kv "Current" "${current:-everyone}"

  # A lockout has to be undoable, so clearing is an explicit path.
  if [ -z "$list" ] && have_tty; then
    log_dim "Comma-separated IPs or CIDRs. Enter 'clear' to remove the restriction."
    list="$(ask "Allowed IPs")"
  fi

  case "$list" in
    ""|clear|none)
      if [ -z "$current" ]; then
        log_info "No restriction is set — nothing to do."
        return 0
      fi
      state_set "$id" ALLOW_IPS "" || die "Could not update the state file."
      proxy_reload || log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."
      log_ok "Access restriction removed — the panel is reachable from anywhere again."
      return 0
      ;;
  esac

  is_valid_ip_list "$list" || die "Not a valid IP list: $list"

  state_set "$id" ALLOW_IPS "$list" || die "Could not update the state file."
  proxy_reload || die "Caddy rejected the new configuration — the previous one is still active."

  log_ok "Panel access restricted to: $list"
  log_dim "Subscriptions on the subscription domain remain public."
  log_warn "If you lock yourself out, SSH in and run: vpnsetup allow-ips $id clear"
}

cmd_backup() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  backup_create "$id"
}

cmd_restore() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return 1
  backup_restore "$id" "${2:-}"
}
