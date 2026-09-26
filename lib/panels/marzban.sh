#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Marzban — multi-protocol Xray panel by Gozargah. AGPL-3.0.
#   https://github.com/Gozargah/Marzban
#
# Unlike the other two panels this one is installed by Marzban's own script,
# because that script does real work we should not reimplement (yq, the compose
# layout, the xray config seed, version resolution). It is also the thing that
# stays correct as upstream evolves.
#
# Two problems with that script, both handled below:
#   1. it finishes with `docker compose logs -f`, which never returns;
#   2. it leaves the panel bound to 0.0.0.0 on port 8000.
#
# It also keeps upstream's own paths (/opt/marzban, /var/lib/marzban) so the
# `marzban` command keeps working for the operator.
# ──────────────────────────────────────────────────────────────────────────────

readonly MARZBAN_SCRIPT_URL="https://raw.githubusercontent.com/Gozargah/Marzban-scripts/master/marzban.sh"
readonly MARZBAN_DIR="/opt/marzban"
readonly MARZBAN_DATA="/var/lib/marzban"

# Run the upstream installer and return once the stack is up.
_marzban_bootstrap() {
  local script="$1" log="$LOG_DIR/marzban-install.log"
  mkdir -p "$LOG_DIR"
  : > "$log"

  log_info "Running the upstream Marzban installer — this takes a few minutes."
  log_dim "  log: $log"

  # The script ends with `docker compose logs -f`, which streams forever. Give
  # it its own session so the entire process group can be stopped once the
  # container is up, instead of blocking our installer on a log tail.
  local launcher=(bash "$script" install --database sqlite)
  if have_cmd setsid; then
    setsid "${launcher[@]}" </dev/null >>"$log" 2>&1 &
  else
    "${launcher[@]}" </dev/null >>"$log" 2>&1 &
  fi
  local pid=$!

  local waited=0
  while [ "$waited" -lt 420 ]; do
    if compose_service_running "$MARZBAN_DIR" marzban; then
      sleep 3
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_error "The upstream installer exited before Marzban came up. Last lines:"
      tail -30 "$log" 2>/dev/null | sed 's/^/    /' >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done

  # Stop the installer and its `logs -f` child together.
  kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if compose_service_running "$MARZBAN_DIR" marzban; then
    log_ok "Marzban container is up."
    return 0
  fi

  log_error "Marzban did not start within ${waited}s. Last lines:"
  tail -30 "$log" 2>/dev/null | sed 's/^/    /' >&2
  return 1
}

# Create the first sudo admin. Returns 0 and echoes the password on success.
_marzban_create_admin() {
  local user="admin" pass
  pass="$(gen_hex 10)"

  if dc "$MARZBAN_DIR" exec -T -e CLI_PROG_NAME="marzban cli" \
       marzban marzban-cli admin create --sudo --username "$user" --password "$pass" \
       >/dev/null 2>&1; then
    printf '%s %s' "$user" "$pass"
    return 0
  fi

  # Fallback: the env-based admin, still supported and read on boot.
  log_warn "Could not create the admin through the CLI — falling back to env credentials."
  env_set "$MARZBAN_DIR/.env" SUDO_USERNAME "$user"
  env_set "$MARZBAN_DIR/.env" SUDO_PASSWORD "$pass"
  dc "$MARZBAN_DIR" up -d >/dev/null 2>&1 || true
  sleep 5
  printf '%s %s' "$user" "$pass"
  return 0
}

panel_install_marzban() {
  local id="$1" domain="$2"

  if [ -d "$MARZBAN_DIR" ]; then
    log_warn "An existing Marzban installation was found at $MARZBAN_DIR."
    log_warn "Reinstalling will delete it and its data in $MARZBAN_DATA."
    confirm "Remove the existing installation and continue?" "n" || { log_info "Cancelled."; return 1; }
    dc "$MARZBAN_DIR" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$MARZBAN_DIR"
  fi

  local port
  port="$(ask_panel_port "Panel port" "8000")" || return 1
  if port_in_use "$port"; then
    log_warn "Port $port is already in use on this host."
    confirm "Use it anyway?" "n" || return 1
  fi

  # Marzban serves subscriptions from the same uvicorn port, so a separate
  # subscription domain is just a second Caddy site pointing at the same place.
  local sub_domain
  sub_domain="$(ask_optional_sub_domain "$domain")" || return 1

  # ── Upstream install ───────────────────────────────────────────────────────
  local script="/tmp/vpnsetup-marzban-$(gen_hex 4).sh"
  log_info "Downloading the upstream installer..."
  curl -fsSL "$MARZBAN_SCRIPT_URL" -o "$script" || die "Could not download $MARZBAN_SCRIPT_URL"
  chmod +x "$script"

  if ! _marzban_bootstrap "$script"; then
    rm -f "$script"
    return 1
  fi
  rm -f "$script"

  # ── Harden the .env ────────────────────────────────────────────────────────
  # The panel is moved onto loopback: Caddy is the only thing that should reach
  # it from the outside. Xray is a separate process in the same container and
  # keeps binding whatever public ports the inbounds define.
  log_info "Applying configuration..."
  local env_file="$MARZBAN_DIR/.env"
  [ -f "$env_file" ] || die "Upstream installer did not create $env_file"

  env_set "$env_file" UVICORN_HOST "127.0.0.1"
  env_set "$env_file" UVICORN_PORT "$port"
  env_set "$env_file" SQLALCHEMY_DATABASE_URL "sqlite:////var/lib/marzban/db.sqlite3"
  env_set "$env_file" XRAY_JSON "/var/lib/marzban/xray_config.json"
  env_set "$env_file" XRAY_SUBSCRIPTION_URL_PREFIX "https://${sub_domain:-$domain}"

  if ! grep -qE '^JWT_ACCESS_TOKEN_SECRET_KEY' "$env_file"; then
    printf '\n# Generated by vpnsetup\n' >> "$env_file"
    printf 'JWT_ACCESS_TOKEN_SECRET_KEY = "%s"\n' "$(gen_hex 32)" >> "$env_file"
    printf 'JWT_REFRESH_TOKEN_SECRET_KEY = "%s"\n' "$(gen_hex 32)" >> "$env_file"
  fi
  chmod 600 "$env_file"

  dc "$MARZBAN_DIR" up -d || die "Could not restart Marzban with the new configuration."

  log_info "Waiting for the dashboard..."
  if wait_http_ok "http://127.0.0.1:$port/dashboard/" 120; then
    log_ok "Dashboard is answering on 127.0.0.1:$port"
  else
    log_warn "Dashboard did not answer in time — check: docker compose -f $MARZBAN_DIR/docker-compose.yml logs"
  fi

  # ── First admin ────────────────────────────────────────────────────────────
  log_info "Creating the sudo admin..."
  local creds; creds="$(_marzban_create_admin)"
  local admin_user="${creds%% *}" admin_pass="${creds##* }"

  # ── State ──────────────────────────────────────────────────────────────────
  state_write "$id" \
    "PANEL_NAME=$(panel_catalog_name "$id")" \
    "DOMAIN=$domain" \
    "SUB_DOMAIN=$sub_domain" \
    "PORT=$port" \
    "INSTALL_DIR=$MARZBAN_DIR" \
    "DATA_DIR=$MARZBAN_DATA" \
    "MODE=upstream" \
    "SERVICE=marzban" \
    "BACKUP_KIND=sqlite" \
    "BACKUP_SQLITE=$MARZBAN_DATA/db.sqlite3" \
    "BACKUP_SERVICE=marzban" \
    "BACKUP_FILES=$MARZBAN_DIR/.env,$MARZBAN_DIR/docker-compose.yml"

  printf '\n'
  log_ok "Marzban is running on port $port (bound to loopback)."
  ui_kv "Panel URL" "https://$domain/dashboard/"
  [ -n "$sub_domain" ] && ui_kv "Subscription" "https://$sub_domain"
  ui_kv "Username" "$admin_user"
  ui_kv "Password" "$admin_pass"
  printf '\n'
  log_dim "If the login is rejected, create the admin manually:"
  log_dim "  docker compose -f $MARZBAN_DIR/docker-compose.yml exec marzban marzban-cli admin create --sudo"
}

# Marzban bakes its public subscription URL into .env, so a domain change has to
# be pushed into the panel as well, not just into the reverse proxy.
panel_set_domain_marzban() {
  local id="$1" domain="$2"
  local env_file="$MARZBAN_DIR/.env"
  [ -f "$env_file" ] || { log_error "Missing $env_file"; return 1; }

  local sub; sub="$(state_get "$id" SUB_DOMAIN)"
  env_set "$env_file" XRAY_SUBSCRIPTION_URL_PREFIX "https://${sub:-$domain}"
  chmod 600 "$env_file"

  dc "$MARZBAN_DIR" up -d >/dev/null 2>&1 || return 1
  return 0
}

panel_update_marzban() {
  local id="$1"
  # Upstream's own update path: it also refreshes the helper script and the
  # pinned image, so delegating keeps us correct.
  local script="/tmp/vpnsetup-marzban-update-$(gen_hex 4).sh"
  curl -fsSL "$MARZBAN_SCRIPT_URL" -o "$script" || die "Could not download the update script."
  bash "$script" update || { rm -f "$script"; die "Marzban update failed."; }
  rm -f "$script"
}

panel_uninstall_marzban() {
  local id="$1"
  dc "$MARZBAN_DIR" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$MARZBAN_DIR" "$MARZBAN_DATA"
  # The upstream installer drops a helper CLI in /usr/local/bin; it is useless
  # once the stack is gone.
  rm -f /usr/local/bin/marzban
}
