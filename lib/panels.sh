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
#
# Commands return the EX_* codes from common.sh, so a caller can tell "nothing
# happened" from "it broke". See vpnsetup_help.
# ──────────────────────────────────────────────────────────────────────────────

readonly PANEL_IDS=(3x-ui marzban remnawave)

panel_catalog_ids() {
  local id
  for id in "${PANEL_IDS[@]}"; do printf '%s\n' "$id"; done
}

panel_is_known() {
  local id="$1" p
  for p in "${PANEL_IDS[@]}"; do [ "$p" = "$id" ] && return 0; done
  return 1
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
#
# Three separate ways a port can be unusable, and only the first two used to be
# checked. The third is the one that bites: a port held by some unrelated service
# on the host passed validation and only failed once the panel tried to bind it,
# which is after the install has already done its work.
validate_panel_port() {
  local port="$1" owner
  case "$port" in
    80|443)
      log_error "Port $port belongs to the reverse proxy (Caddy) and cannot host a panel."
      return "$EX_CONFLICT"
      ;;
  esac

  owner="$(panel_owner_of_port "$port")" || true
  if [ -n "$owner" ]; then
    log_error "Port $port is already used by $(panel_catalog_name "$owner")."
    return "$EX_CONFLICT"
  fi

  if port_in_use "$port"; then
    log_error "Port $port is already in use on this host by something else."
    log_dim "  Check with: ss -ltnp | grep ':$port'"
    return "$EX_CONFLICT"
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
    validate_panel_port "$port" || return "$EX_CONFLICT"
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
      return "$EX_USAGE"
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
    return "$EX_PRECOND"
  fi

  if [ -n "$server_ip" ] && [ "$resolved" != "$server_ip" ]; then
    log_warn "$domain resolves to $resolved, but this server is $server_ip."
    log_warn "That is expected behind Cloudflare/proxy, but HTTP-01 validation"
    log_warn "will fail unless the record is DNS-only (grey cloud) or you use DNS-01."
    return "$EX_PRECOND"
  fi

  log_ok "DNS OK: $domain -> $resolved"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# JSON views
# ──────────────────────────────────────────────────────────────────────────────
_catalog_entry_json() {
  local id="$1"
  json_object \
    "$(json_pair id "$(json_str "$id")")" \
    "$(json_pair name "$(json_str "$(panel_catalog_name "$id")")")" \
    "$(json_pair description "$(json_str "$(panel_catalog_desc "$id")")")" \
    "$(json_pair upstream "$(json_str "$(panel_catalog_upstream "$id")")")" \
    "$(json_pair license "$(json_str "$(panel_catalog_license "$id")")")" \
    "$(json_pair default_port "$(json_num "$(panel_default_port "$id")")")" \
    "$(json_pair installed "$(json_bool "$(state_exists "$id" && printf 1 || printf 0)")")"
}

_panel_json() {
  local id="$1" dir sub allow
  dir="$(state_get "$id" INSTALL_DIR)"
  sub="$(state_get "$id" SUB_DOMAIN)"
  [ "$sub" = "$(state_get "$id" DOMAIN)" ] && sub=""
  allow="$(state_get "$id" ALLOW_IPS)"

  json_object \
    "$(json_pair id "$(json_str "$id")")" \
    "$(json_pair name "$(json_str "$(panel_catalog_name "$id")")")" \
    "$(json_pair domain "$(json_nullable_str "$(state_get "$id" DOMAIN)")")" \
    "$(json_pair sub_domain "$(json_nullable_str "$sub")")" \
    "$(json_pair port "$(json_num "$(state_get "$id" PORT)")")" \
    "$(json_pair allow_ips "$(json_nullable_str "$allow")")" \
    "$(json_pair install_dir "$(json_str "$dir")")" \
    "$(json_pair containers "$(compose_containers_json "$dir")")"
}

# ──────────────────────────────────────────────────────────────────────────────
# panels — the catalog, including what is not installed yet
# ──────────────────────────────────────────────────────────────────────────────
cmd_panels() {
  local id

  if [ "$OPT_JSON" = "1" ]; then
    local items=""
    for id in "${PANEL_IDS[@]}"; do
      items="${items:+$items,}$(_catalog_entry_json "$id")"
    done
    json_emit "$(json_pair panels "[$items]")"
    return 0
  fi

  ui_title "Panels"
  printf '  %s%-12s %-9s %-6s %s%s\n' "$C_DIM" 'ID' 'LICENSE' 'PORT' 'STATE' "$C_RESET"
  local state
  for id in "${PANEL_IDS[@]}"; do
    if state_exists "$id"; then
      state="${C_BGREEN}installed${C_RESET}"
    else
      state="${C_DIM}available${C_RESET}"
    fi
    printf '  %s%-12s%s %-9s %-6s %s\n' "$C_BWHITE" "$id" "$C_RESET" \
      "$(panel_catalog_license "$id")" "$(panel_default_port "$id")" "$state"
  done
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Shared install entry point
# ──────────────────────────────────────────────────────────────────────────────
cmd_install() {
  local args=("$@")

  # Named options win over the environment: that is the order a control panel
  # expects, and it keeps the env-var path (CI, cloud-init) working unchanged.
  local v
  v="$(opt_value domain '' ${args[@]+"${args[@]}"})";       [ -n "$v" ] && export VPN_SETUP_DOMAIN="$v"
  v="$(opt_value sub-domain '' ${args[@]+"${args[@]}"})";   [ -n "$v" ] && export VPN_SETUP_SUB_DOMAIN="$v"
  v="$(opt_value port '' ${args[@]+"${args[@]}"})";         [ -n "$v" ] && export VPN_SETUP_PORT="$v"
  v="$(opt_value allow-ips '' ${args[@]+"${args[@]}"})";    [ -n "$v" ] && export VPN_SETUP_ALLOW_IPS="$v"

  local id
  id="$(opt_positionals ${args[@]+"${args[@]}"} | head -1)"
  [ -n "$id" ] || id="${VPN_SETUP_PANEL:-}"

  if [ -z "$id" ]; then
    id="$(ui_select_panel)" || return "$EX_USAGE"
  fi
  [ -n "$id" ] || return "$EX_USAGE"

  # Reject unknown ids before touching the filesystem.
  if ! panel_is_known "$id"; then
    log_error "Unknown panel: '$id'. Available: ${PANEL_IDS[*]}"
    return "$EX_USAGE"
  fi

  local slug fn
  slug="$(id_slug "$id")"
  fn="panel_install_${slug}"
  if ! declare -F "$fn" >/dev/null; then
    log_error "No installer found for panel '$id'."
    return "$EX_FAIL"
  fi

  ui_title "Install $(panel_catalog_name "$id")"
  ui_kv "Upstream"   "$(panel_catalog_upstream "$id")"
  ui_kv "License"    "$(panel_catalog_license "$id")"
  ui_kv "Panel port" "$(panel_default_port "$id")"

  # Reinstalling used to be asked as a confirmation whose default answer is "no".
  # Without a terminal that meant the command printed "Cancelled" and returned 0,
  # so an automated caller was told the install succeeded while nothing at all
  # had happened. Now it is an explicit conflict with an explicit override.
  if state_exists "$id"; then
    if [ "$OPT_REINSTALL" != "1" ]; then
      log_warn "$(panel_catalog_name "$id") is already installed at $(state_get "$id" INSTALL_DIR)."
      confirm_action "Reinstall? This will WIPE its data." "n" "Pass --reinstall to wipe it."
    fi
    cmd_remove "$id" "quiet" || return $?
  fi

  require_root
  ensure_docker

  local domain
  domain="$(ask_domain "Panel domain (e.g. panel.example.com)")" || return $?
  panel_check_dns "$domain" || true

  # Optional hardening, asked up front so the install runs unattended afterwards.
  local allow_ips="${VPN_SETUP_ALLOW_IPS:-}"
  if [ -z "$allow_ips" ] && have_tty; then
    printf '\n' >&2
    log_dim "Panel access can be limited to specific IPs (comma-separated, CIDR allowed)." >&2
    log_dim "Leave empty to allow everyone — you will need one of these IPs to reach" >&2
    log_dim "the panel later, so do not lock yourself out." >&2
    allow_ips="$(ask "Allowed IPs (Enter = allow all)")"
  fi
  if [ -n "$allow_ips" ] && ! is_valid_ip_list "$allow_ips"; then
    log_warn "That does not look like an IP list — access will not be restricted."
    allow_ips=""
  fi

  "$fn" "$id" "$domain" || return $?

  if [ -n "$allow_ips" ]; then
    state_set "$id" ALLOW_IPS "$allow_ips" || log_warn "Could not record the IP allowlist."
  fi

  # Publish it: the proxy is rendered from the site registry, not from panel state.
  site_sync_from_panel "$id" || log_warn "The panel is installed but not published yet."

  log_step "Applying reverse proxy"
  proxy_up || log_warn "Caddy setup failed — run 'vpnsetup proxy' once DNS/ports are ready."

  local rc=0
  if ! proxy_wait_for_cert "$domain" 60; then rc="$EX_PARTIAL"; fi

  if [ "$OPT_JSON" = "1" ]; then
    json_emit \
      "$(json_pair panel "$(_panel_json "$id")")" \
      "$(json_pair url "$(json_str "https://$domain")")" \
      "$(json_pair certificate "$(json_bool "$([ "$rc" = "0" ] && printf 1 || printf 0)")")"
    return "$rc"
  fi

  printf '\n'
  log_ok "$(panel_catalog_name "$id") installed."
  ui_kv "Panel" "https://$domain"
  local sub; sub="$(state_get "$id" SUB_DOMAIN)"
  [ -n "$sub" ] && ui_kv "Subscription" "https://$sub"
  [ -n "$allow_ips" ] && ui_kv "Restricted to" "$allow_ips"
  ui_kv "Data" "$(state_get "$id" INSTALL_DIR)"
  ui_kv "Backups" "$(backup_dir_for "$id")"
  printf '\n'
  return "$rc"
}

# ──────────────────────────────────────────────────────────────────────────────
# Update
# ──────────────────────────────────────────────────────────────────────────────
cmd_update() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || { log_error "Panel '$id' is not installed."; return "$EX_NOTFOUND"; }

  local slug fn dir
  slug="$(id_slug "$id")"
  fn="panel_update_${slug}"
  dir="$(state_get "$id" INSTALL_DIR)"

  ui_title "Update $(panel_catalog_name "$id")"

  if declare -F "$fn" >/dev/null; then
    "$fn" "$id" || return $?
  else
    ensure_docker
    [ -d "$dir" ] || { log_error "Install directory missing: $dir"; return "$EX_NOTFOUND"; }
    compose_pull "$dir" || return "$EX_FAIL"
    dc "$dir" up -d || die "docker compose up failed"
  fi

  log_ok "Update finished."
  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair panel "$(_panel_json "$id")")"
    return 0
  fi
  dc "$dir" ps 2>/dev/null || true
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Status / logs / remove
# ──────────────────────────────────────────────────────────────────────────────
cmd_status() {
  if [ "$OPT_JSON" = "1" ]; then
    local items="" id
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      items="${items:+$items,}$(_panel_json "$id")"
    done < <(state_ids)

    local sites="" name
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      sites="${sites:+$sites,}$(json_str "$(site_get "$name" DOMAIN)")"
    done < <(site_ids)

    json_emit \
      "$(json_pair panels "[$items]")" \
      "$(json_pair caddy "$(json_object \
        "$(json_pair state "$(json_str "$(container_state "$CADDY_CONTAINER")")")" \
        "$(json_pair sites "[$sites]")")")"
    return 0
  fi

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
    ui_kv "Domain" "$(state_get "$id" DOMAIN '-')"
    ui_kv "Port"   "$(state_get "$id" PORT '-')"
    ui_kv "Dir"    "$dir"
    if [ -d "$dir" ]; then
      compose_containers "$dir" | while IFS='|' read -r n s st h; do
        printf '  %-28s %-12s %s%s\n' "$n" "$s" "$st" \
          "$([ "$h" != "-" ] && printf ' (%s)' "$h")"
      done
    fi
  done < <(state_ids)

  proxy_status
  return 0
}

cmd_logs() {
  local id="${1:-}" service="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || { log_error "Panel '$id' is not installed."; return "$EX_NOTFOUND"; }

  local dir; dir="$(state_get "$id" INSTALL_DIR)"
  [ -d "$dir" ] || { log_error "Install directory missing: $dir"; return "$EX_NOTFOUND"; }

  local tail_n="$OPT_TAIL"
  local svc=(); [ -n "$service" ] && svc=("$service")

  # Logs are a stream, so --json emits NDJSON: one object per line, which is the
  # only honest shape for output that never ends.
  if [ "$OPT_JSON" = "1" ]; then
    if [ "$OPT_FOLLOW" = "1" ]; then
      log_info "Streaming logs as NDJSON (Ctrl+C to stop)..." >&2
      dc "$dir" logs -f --tail="$tail_n" ${svc[@]+"${svc[@]}"} 2>&1 |
        while IFS= read -r line; do
          printf '{"panel":"%s","line":"%s"}\n' "$(json_escape "$id")" "$(json_escape "$line")"
        done
    else
      local lines="" line
      while IFS= read -r line; do
        lines="${lines:+$lines,}$(json_str "$line")"
      done < <(dc "$dir" logs --tail="$tail_n" ${svc[@]+"${svc[@]}"} 2>&1)
      json_emit "$(json_pair panel "$(json_str "$id")")" "$(json_pair lines "[$lines]")"
    fi
    return 0
  fi

  if [ "$OPT_FOLLOW" = "1" ]; then
    log_info "Tailing logs (Ctrl+C to stop)..."
    dc "$dir" logs -f --tail="$tail_n" ${svc[@]+"${svc[@]}"} || true
  else
    dc "$dir" logs --tail="$tail_n" ${svc[@]+"${svc[@]}"} || true
  fi
  return 0
}

cmd_remove() {
  local id="${1:-}" quiet="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  if ! state_exists "$id"; then
    log_warn "Panel '$id' is not installed — nothing to remove."
    return "$EX_NOTFOUND"
  fi

  local slug fn dir
  slug="$(id_slug "$id")"
  fn="panel_uninstall_${slug}"
  dir="$(state_get "$id" INSTALL_DIR)"

  ui_title "Remove $(panel_catalog_name "$id")"
  if [ "$quiet" != "quiet" ]; then
    log_warn "This deletes the containers, the data in $dir and the panel state."
    log_warn "Backups in $(backup_dir_for "$id") are kept."
    confirm_action "Continue?" "n" "Pass --yes to confirm."
  fi

  if declare -F "$fn" >/dev/null; then
    "$fn" "$id" || return $?
  else
    compose_down "$dir" purge
    rm -rf "$dir"
  fi

  state_delete "$id"
  site_delete "$id"
  proxy_reload || log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."

  log_ok "$(panel_catalog_name "$id") removed."
  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair removed "$(json_str "$id")")"
  fi
  return 0
}

cmd_proxy_reapply() {
  local id="${1:-}"
  if [ -n "$id" ]; then
    state_exists "$id" || die_code "$EX_NOTFOUND" "Panel '$id' is not installed."
  fi
  ui_title "Reverse proxy + SSL"
  site_sync_all
  proxy_up || return "$EX_FAIL"
  if [ -n "$id" ]; then
    proxy_wait_for_cert "$(state_get "$id" DOMAIN)" 60 || true
  fi
  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair caddy_state "$(json_str "$(container_state "$CADDY_CONTAINER")")")"
  fi
  return 0
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
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || die_code "$EX_NOTFOUND" "Panel '$id' is not installed."

  local slug fn current
  slug="$(id_slug "$id")"
  fn="panel_set_domain_${slug}"
  current="$(state_get "$id" DOMAIN)"

  ui_title "Change domain — $(panel_catalog_name "$id")"
  ui_kv "Current" "${current:--}"

  if [ -z "$domain" ]; then
    domain="$(ask_domain "New domain")" || return $?
  fi
  is_valid_domain "$domain" || die_code "$EX_USAGE" "Not a valid domain: $domain"

  if [ "$domain" = "$current" ]; then
    log_info "Domain unchanged — nothing to do."
    if [ "$OPT_JSON" = "1" ]; then
      json_emit "$(json_pair changed false)" "$(json_pair domain "$(json_str "$domain")")"
    fi
    return 0
  fi

  panel_check_dns "$domain" || true

  state_set "$id" DOMAIN "$domain" || die_code "$EX_FAIL" "Could not update the state file."

  # Panels that bake their own domain into their configuration need to be told;
  # the rest only care about the reverse proxy.
  if declare -F "$fn" >/dev/null; then
    log_info "Updating the panel configuration..."
    "$fn" "$id" "$domain" || log_warn "The panel configuration was not updated — check its logs."
  fi

  site_sync_from_panel "$id" || log_warn "Could not update the published site."

  proxy_reload || { log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."; return "$EX_PARTIAL"; }
  proxy_wait_for_cert "$domain" 60 || true

  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair changed true)" "$(json_pair domain "$(json_str "$domain")")"
    return 0
  fi

  printf '\n'
  log_ok "Domain updated. Panel data was not touched."
  ui_kv "Panel" "https://$domain"
  log_dim "The old hostname stops working once DNS and the certificate catch up."
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Restrict panel access to a list of IPs. Subscriptions stay public.
# ──────────────────────────────────────────────────────────────────────────────
cmd_set_allow_ips() {
  local id="${1:-}" list="${2:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || die_code "$EX_NOTFOUND" "Panel '$id' is not installed."

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
        if [ "$OPT_JSON" = "1" ]; then
          json_emit "$(json_pair changed false)" "$(json_pair allow_ips null)"
        fi
        return 0
      fi
      state_set "$id" ALLOW_IPS "" || die_code "$EX_FAIL" "Could not update the state file."
      site_sync_from_panel "$id" || true
      proxy_reload || log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."
      log_ok "Access restriction removed — the panel is reachable from anywhere again."
      if [ "$OPT_JSON" = "1" ]; then
        json_emit "$(json_pair changed true)" "$(json_pair allow_ips null)"
      fi
      return 0
      ;;
  esac

  is_valid_ip_list "$list" || die_code "$EX_USAGE" "Not a valid IP list: $list"

  state_set "$id" ALLOW_IPS "$list" || die_code "$EX_FAIL" "Could not update the state file."
  site_sync_from_panel "$id" || true
  proxy_reload || die_code "$EX_FAIL" "Caddy rejected the new configuration — the previous one is still active."

  log_ok "Panel access restricted to: $list"
  log_dim "Subscriptions on the subscription domain remain public."
  log_warn "If you lock yourself out, SSH in and run: vpnsetup allow-ips $id clear"

  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair changed true)" "$(json_pair allow_ips "$(json_str "$list")")"
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Backup / restore
#
# `backup <panel>` used to be the only entry point, so the only way to see what
# archives exist was to read the directory by hand — which a control panel
# cannot do without duplicating the path logic. Hence `backup list`.
# ──────────────────────────────────────────────────────────────────────────────
cmd_backup() {
  local first="${1:-}" second="${2:-}"

  if [ "$first" = "list" ] || [ "$first" = "ls" ]; then
    cmd_backup_list "$second"
    return $?
  fi

  [ -n "$first" ] || first="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$first" || { log_error "Panel '$first' is not installed."; return "$EX_NOTFOUND"; }

  backup_create "$first" || return "$EX_FAIL"

  if [ "$OPT_JSON" = "1" ]; then
    local latest
    latest="$(backup_list "$first" | head -1)"
    json_emit \
      "$(json_pair panel "$(json_str "$first")")" \
      "$(json_pair archive "$(json_nullable_str "$latest")")"
  fi
  return 0
}

cmd_backup_list() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || { log_error "Panel '$id' is not installed."; return "$EX_NOTFOUND"; }

  local files; files="$(backup_list "$id")"

  if [ "$OPT_JSON" = "1" ]; then
    local items="" f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      items="${items:+$items,}$(json_object \
        "$(json_pair name "$(json_str "$(basename "$f")")")" \
        "$(json_pair path "$(json_str "$f")")" \
        "$(json_pair size "$(json_num "$(_file_size "$f")")")" \
        "$(json_pair modified "$(json_num "$(_file_mtime "$f")")")")"
    done <<<"$files"
    json_emit "$(json_pair panel "$(json_str "$id")")" "$(json_pair backups "[$items]")"
    return 0
  fi

  if [ -z "$files" ]; then
    log_warn "No backups for $id in $(backup_dir_for "$id")."
    return 0
  fi

  ui_title "Backups — $(panel_catalog_name "$id")"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '  %s  %8s  %s\n' "$(basename "$f")" \
      "$(_human_size "$(_file_size "$f")")" \
      "$(date -d "@$(_file_mtime "$f")" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '-')"
  done <<<"$files"
  return 0
}

cmd_restore() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(ui_select_installed)" || return "$EX_NOTFOUND"
  state_exists "$id" || { log_error "Panel '$id' is not installed."; return "$EX_NOTFOUND"; }

  backup_restore "$id" "${2:-}"
  return $?
}
