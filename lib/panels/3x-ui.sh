#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 3x-ui — Xray panel by MHSanaei. GPL-3.0.
#   https://github.com/MHSanaei/3x-ui
#
# Host networking is mandatory, not a preference: Xray inbounds listen on
# arbitrary ports the operator picks later in the UI, and a bridge network would
# hide every one of them. That is also how the upstream docker run command works.
#
# Because the container shares the host network, the panel port is reachable
# directly as well as through Caddy. The panel is protected by its own login,
# its brute-force limiter and a random web base path that we generate.
# ──────────────────────────────────────────────────────────────────────────────

X3UI_IMAGE="${VPN_SETUP_3XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}"
readonly X3UI_CONTAINER="vpnsetup-3x-ui"

# Read one field out of `x-ui setting -show` output. Tolerant on purpose: the
# exact labels are upstream's business, and a parse miss must degrade to a
# sensible fallback rather than break the install.
_x3ui_field() {
  local pattern="$1" blob="$2"
  printf '%s\n' "$blob" \
    | sed -n "s/^[[:space:]]*${pattern}[[:space:]]*[:=][[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" \
    | head -1
}

# No subscription sub-domain is offered for 3x-ui: its subscription service
# listens on its own port, which is configured inside the panel UI and therefore
# unknown at install time. Subscriptions are served from the panel domain.

panel_install_3xui() {
  local id="$1" domain="$2"
  local dir="$ROOT_DIR/3x-ui"

  local port
  port="$(ask_panel_port "Panel port" "2053")" || return 1
  if port_in_use "$port"; then
    log_warn "Port $port is already in use on this host."
    confirm "Use it anyway?" "n" || return 1
  fi

  log_info "Creating the stack in $dir"
  mkdir -p "$dir/db" "$dir/cert" "$dir/acme"

  cat > "$dir/docker-compose.yml" <<YAML
services:
  panel:
    image: ${X3UI_IMAGE}
    container_name: ${X3UI_CONTAINER}
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
      - ./acme:/root/.acme.sh
    environment:
      XUI_ENABLE_FAIL2BAN: "true"
YAML

  ensure_ip_forward
  compose_pull "$dir"
  dc "$dir" up -d || die "Could not start 3x-ui."

  log_info "Waiting for the panel to come up..."
  wait_container_running "$X3UI_CONTAINER" 120 || return 1

  # ── Configure ──────────────────────────────────────────────────────────────
  # Both calls are best-effort. If a flag is unavailable in this build we keep
  # whatever the panel chose, then read the effective values back — so the
  # reverse proxy can never end up pointing at a port nothing listens on.
  local base_path; base_path="/$(gen_hex 5)"
  log_info "Setting the panel port to $port and a random web base path..."
  docker exec "$X3UI_CONTAINER" x-ui setting -port "$port" >/dev/null 2>&1 || true
  docker exec "$X3UI_CONTAINER" x-ui setting -webBasePath "$base_path" >/dev/null 2>&1 || true

  dc "$dir" restart >/dev/null 2>&1 || true
  wait_container_running "$X3UI_CONTAINER" 60 || return 1

  local settings eff_port eff_path user pass
  settings="$(docker exec "$X3UI_CONTAINER" x-ui setting -show 2>/dev/null || true)"
  eff_port="$(_x3ui_field '[Pp]ort' "$settings")"
  eff_path="$(_x3ui_field '[Ww]eb[Bb]ase[Pp]ath' "$settings")"
  user="$(_x3ui_field '[Uu]sername' "$settings")"
  pass="$(_x3ui_field '[Pp]assword' "$settings")"

  is_valid_port "$eff_port" || eff_port="$port"
  [ -n "$eff_path" ] || eff_path="/"
  case "$eff_path" in /*) ;; *) eff_path="/$eff_path" ;; esac

  # ── State ──────────────────────────────────────────────────────────────────
  state_write "$id" \
    "PANEL_NAME=$(panel_catalog_name "$id")" \
    "DOMAIN=$domain" \
    "PORT=$eff_port" \
    "INSTALL_DIR=$dir" \
    "MODE=compose" \
    "SERVICE=panel" \
    "BACKUP_KIND=sqlite" \
    "BACKUP_SQLITE=$dir/db/x-ui.db" \
    "BACKUP_SERVICE=panel" \
    "BACKUP_FILES=$dir/docker-compose.yml"

  printf '\n'
  log_ok "3x-ui is running on port $eff_port."
  ui_kv "Panel URL" "https://$domain$eff_path"
  if [ -n "$user" ]; then ui_kv "Username" "$user"; fi
  if [ -n "$pass" ]; then ui_kv "Password" "$pass"; fi
  if [ -z "$user" ] || [ -z "$pass" ]; then
    log_warn "Could not read the generated credentials automatically."
    log_dim "  docker exec $X3UI_CONTAINER x-ui setting -show"
  fi
  printf '\n'
  log_dim "The web base path is random on purpose — keep it out of public posts."
  log_dim "Xray inbounds you create later bind on the host network directly."
}

panel_update_3xui() {
  local id="$1" dir; dir="$(state_get "$id" INSTALL_DIR)"
  [ -d "$dir" ] || die "Install directory missing: $dir"
  # The image tag is floating by default, so a pull really does fetch the new
  # release. Pin VPN_SETUP_3XUI_IMAGE to a tag if you want reproducible deploys.
  compose_pull "$dir"
  dc "$dir" up -d || die "docker compose up failed"
}

panel_uninstall_3xui() {
  local id="$1" dir; dir="$(state_get "$id" INSTALL_DIR)"
  compose_down "$dir" purge
  rm -rf "$dir"
}
