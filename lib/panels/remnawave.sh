#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Remnawave — panel + nodes, PostgreSQL + Valkey. AGPL-3.0.
#   https://github.com/remnawave/backend
#
# Upstream ships a production compose file and a documented .env contract, so
# this module follows the official manual install path: fetch both files, fill
# in the secrets the docs tell you to generate, and start the stack.
#
# The stack publishes everything on 127.0.0.1 only — upstream is explicit that
# Remnawave must never be exposed directly — so Caddy is not optional here.
# ──────────────────────────────────────────────────────────────────────────────

readonly REMNAWAVE_DIR="/opt/remnawave"
readonly REMNAWAVE_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
readonly REMNAWAVE_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

# Upstream pins the host side of the panel port to 3000 in the compose file, so
# that is the port Caddy must target. The metrics port stays on 3001.
readonly REMNAWAVE_PORT="3000"
readonly REMNAWAVE_METRICS_PORT="3001"

panel_install_remnawave() {
  local id="$1" domain="$2"
  local dir="$REMNAWAVE_DIR"

  if port_in_use "$REMNAWAVE_PORT"; then
    log_warn "Port $REMNAWAVE_PORT is already in use on this host."
    log_warn "Remnawave's upstream compose binds the panel to 127.0.0.1:$REMNAWAVE_PORT."
    confirm "Continue anyway?" "n" || return 1
  fi

  # The upstream compose pins the host-side port, so it cannot be renumbered
  # here — but it still must not collide with another panel we manage.
  validate_panel_port "$REMNAWAVE_PORT" || return 1

  # Remnawave serves subscriptions from the panel port at /api/sub, so a
  # separate subscription domain is only a second Caddy site.
  local sub_domain
  sub_domain="$(ask_optional_sub_domain "$domain")" || return 1

  log_info "Creating the stack in $dir"
  mkdir -p "$dir"

  log_info "Fetching the upstream compose file and env template..."
  curl -fsSL "$REMNAWAVE_COMPOSE_URL" -o "$dir/docker-compose.yml" \
    || die "Could not download the Remnawave compose file."
  curl -fsSL "$REMNAWAVE_ENV_URL" -o "$dir/.env" \
    || die "Could not download the Remnawave env template."

  # ── Secrets ────────────────────────────────────────────────────────────────
  log_info "Generating secrets..."
  local app_secret metrics_pass webhook_secret pg_pass
  app_secret="$(gen_hex 32)"
  metrics_pass="$(gen_hex 32)"
  # The webhook header secret must be exactly 64 characters, [A-Za-z0-9] only.
  webhook_secret="$(gen_hex 32)"
  pg_pass="$(gen_hex 24)"

  local env_file="$dir/.env"
  env_set "$env_file" APP_SECRET "$app_secret"
  env_set "$env_file" METRICS_PASS "$metrics_pass"
  env_set "$env_file" WEBHOOK_SECRET_HEADER "$webhook_secret"

  env_set "$env_file" POSTGRES_USER postgres
  env_set "$env_file" POSTGRES_PASSWORD "$pg_pass"
  env_set "$env_file" POSTGRES_DB postgres
  env_set "$env_file" DATABASE_URL "postgresql://postgres:${pg_pass}@remnawave-db:5432/postgres"

  env_set "$env_file" PANEL_DOMAIN "$domain"
  env_set "$env_file" FRONT_END_DOMAIN "https://$domain"
  env_set "$env_file" SUB_PUBLIC_DOMAIN "${sub_domain:-$domain}/api/sub"

  chmod 600 "$env_file"
  log_ok "Secrets written to $env_file"

  # ── Start ──────────────────────────────────────────────────────────────────
  compose_pull "$dir"
  dc "$dir" up -d || die "Could not start Remnawave."

  log_info "Waiting for PostgreSQL..."
  if ! wait_postgres "$dir" remnawave-db postgres postgres "$pg_pass" 150; then
    log_error "PostgreSQL did not become ready. Logs:"
    dc "$dir" logs --tail=40 remnawave-db 2>&1 | sed 's/^/    /' >&2 || true
    return 1
  fi
  log_ok "PostgreSQL is accepting connections."

  log_info "Waiting for the panel..."
  if wait_http_ok "http://127.0.0.1:$REMNAWAVE_PORT" 150; then
    log_ok "Panel is answering on 127.0.0.1:$REMNAWAVE_PORT"
  else
    log_warn "The panel did not answer in time. Logs:"
    dc "$dir" logs --tail=40 remnawave 2>&1 | sed 's/^/    /' >&2 || true
  fi

  # ── State ──────────────────────────────────────────────────────────────────
  state_write "$id" \
    "PANEL_NAME=$(panel_catalog_name "$id")" \
    "DOMAIN=$domain" \
    "SUB_DOMAIN=$sub_domain" \
    "PORT=$REMNAWAVE_PORT" \
    "METRICS_PORT=$REMNAWAVE_METRICS_PORT" \
    "INSTALL_DIR=$dir" \
    "MODE=upstream" \
    "SERVICE=remnawave" \
    "BACKUP_KIND=postgres" \
    "BACKUP_PG_SERVICE=remnawave-db" \
    "BACKUP_PG_USER=postgres" \
    "BACKUP_PG_DB=postgres" \
    "BACKUP_FILES=$dir/.env,$dir/docker-compose.yml"

  printf '\n'
  log_ok "Remnawave is running."
  ui_kv "Panel URL" "https://$domain"
  ui_kv "Subscription" "https://${sub_domain:-$domain}/api/sub"
  printf '\n'
  log_dim "Create the first admin from the panel's registration screen."
  log_dim "Metrics stay on 127.0.0.1:$REMNAWAVE_METRICS_PORT (user: admin)."
}

# The panel domain and the public subscription domain both live in .env.
panel_set_domain_remnawave() {
  local id="$1" domain="$2"
  local env_file="$REMNAWAVE_DIR/.env"
  [ -f "$env_file" ] || { log_error "Missing $env_file"; return 1; }

  local sub; sub="$(state_get "$id" SUB_DOMAIN)"
  env_set "$env_file" PANEL_DOMAIN "$domain"
  env_set "$env_file" FRONT_END_DOMAIN "https://$domain"
  env_set "$env_file" SUB_PUBLIC_DOMAIN "${sub:-$domain}/api/sub"
  chmod 600 "$env_file"

  dc "$REMNAWAVE_DIR" up -d >/dev/null 2>&1 || return 1
  return 0
}

panel_update_remnawave() {
  local id="$1" dir; dir="$(state_get "$id" INSTALL_DIR)"
  [ -d "$dir" ] || die "Install directory missing: $dir"

  # The image tag is `remnawave/backend:3`, so pulling really does move to the
  # newest 3.x build.
  compose_pull "$dir"
  dc "$dir" up -d || die "docker compose up failed"
}

panel_uninstall_remnawave() {
  local id="$1" dir; dir="$(state_get "$id" INSTALL_DIR)"
  # down -v removes the named volumes declared in the compose file, so the
  # database goes with it.
  compose_down "$dir" purge
  rm -rf "$dir"
}
