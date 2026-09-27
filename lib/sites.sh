#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# sites.sh — the registry the reverse proxy is rendered from.
#
# The proxy layer used to iterate panel state files, which meant only panels
# could ever be published. Sites decouple the two: a panel install derives its
# site entry, while anything else — a control panel, a dashboard, a static page —
# registers one directly with `vpnsetup site add` and gets the same domain,
# certificate and IP allowlist without hand-editing the Caddyfile.
#
#   $STATE_DIR/sites/<name>.env
#     SITE_NAME     the key, also the file name
#     KIND          panel | app
#     DOMAIN        primary hostname
#     ALT_DOMAIN    optional second hostname on the same upstream
#     UPSTREAM      host:port on the host (127.0.0.1:2053)
#     ALLOW_IPS     optional comma-separated IP/CIDR allowlist for DOMAIN
#     MANAGED_BY    panel id for KIND=panel sites; empty for apps
#
# Values here are domains, host:port pairs and IP lists — never free text — so
# the plain KEY=value form is safe and no quoting is needed.
# ──────────────────────────────────────────────────────────────────────────────

site_file() { printf '%s/%s.env' "$SITES_STATE_DIR" "$1"; }
site_exists() { [ -f "$(site_file "$1")" ]; }

site_ids() {
  local f
  for f in "$SITES_STATE_DIR"/*.env; do
    [ -e "$f" ] || continue
    basename "$f" .env
  done
}

# site_get <name> <KEY> [default]
site_get() {
  local name="$1" key="$2" default="${3-}"
  local file; file="$(site_file "$name")"
  [ -f "$file" ] || { printf '%s' "$default"; return 0; }
  local line
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  if [ -z "$line" ]; then printf '%s' "$default"; else printf '%s' "${line#*=}"; fi
}

# site_write <name> <KEY=value>... — full rewrite, atomic.
site_write() {
  local name="$1"; shift
  mkdir -p "$SITES_STATE_DIR" 2>/dev/null || true
  local file; file="$(site_file "$name")"
  local tmp="$file.tmp.$$"
  {
    printf 'SITE_NAME=%s\n' "$name"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } >"$tmp" || { log_error "Could not write $tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# site_set <name> <KEY> <value> — read-modify-write, so it takes the state lock.
site_set() {
  local name="$1" key="$2" value="$3"
  local file; file="$(site_file "$name")"
  [ -f "$file" ] || { log_error "No such site: $name"; return "$EX_NOTFOUND"; }

  lock_take "state" || return "$EX_FAIL"
  env_set "$file" "$key" "$value"; local rc=$?
  lock_release
  [ "$rc" -eq 0 ] || return "$rc"
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

site_delete() { rm -f "$(site_file "$1")"; }

# site_upsert <name> <KEY=value>...
site_upsert() { site_write "$@"; }

# ──────────────────────────────────────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────────────────────────────────────
is_valid_upstream() {
  local u="${1-}"
  # A bare port means loopback.
  if is_valid_port "$u"; then return 0; fi
  [[ "$u" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || return 1
  local p="${u##*:}"
  is_valid_port "$p"
}

# upstream_host <upstream>
upstream_host() {
  local u="$1"
  if is_valid_port "$u"; then printf '127.0.0.1'; else printf '%s' "${u%%:*}"; fi
}

# upstream_port <upstream>
upstream_port() {
  local u="$1"
  if is_valid_port "$u"; then printf '%s' "$u"; else printf '%s' "${u##*:}"; fi
}

# upstream_normalize <upstream> — always host:port.
upstream_normalize() {
  local u="$1"
  if is_valid_port "$u"; then printf '127.0.0.1:%s' "$u"; else printf '%s' "$u"; fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Panel → site
# ──────────────────────────────────────────────────────────────────────────────
# Derive the proxy-facing entry from a panel's state. Called after install,
# after a domain change and after an allowlist change, so the site registry is
# never stale relative to the panel it describes.
site_sync_from_panel() {
  local id="$1"
  state_exists "$id" || return "$EX_NOTFOUND"

  local domain port sub allow
  domain="$(state_get "$id" DOMAIN)"
  [ -n "$domain" ] || return 0

  port="$(state_get "$id" PORT)"
  is_valid_port "$port" || { log_warn "Panel $id has no usable port in its state — site not registered."; return "$EX_PRECOND"; }

  sub="$(state_get "$id" SUB_DOMAIN)"
  [ "$sub" = "$domain" ] && sub=""
  allow="$(state_get "$id" ALLOW_IPS)"

  site_write "$id" \
    "KIND=panel" \
    "MANAGED_BY=$id" \
    "DOMAIN=$domain" \
    "ALT_DOMAIN=$sub" \
    "UPSTREAM=127.0.0.1:$port" \
    "ALLOW_IPS=$allow"
}

site_sync_all() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    site_sync_from_panel "$id" || true
  done < <(state_ids)
}

# ──────────────────────────────────────────────────────────────────────────────
# Commands
# ──────────────────────────────────────────────────────────────────────────────
_site_json() {
  local name="$1"
  json_object \
    "$(json_pair name "$(json_str "$name")")" \
    "$(json_pair kind "$(json_str "$(site_get "$name" KIND 'app')")")" \
    "$(json_pair domain "$(json_nullable_str "$(site_get "$name" DOMAIN)")")" \
    "$(json_pair alt_domain "$(json_nullable_str "$(site_get "$name" ALT_DOMAIN)")")" \
    "$(json_pair upstream "$(json_nullable_str "$(site_get "$name" UPSTREAM)")")" \
    "$(json_pair allow_ips "$(json_nullable_str "$(site_get "$name" ALLOW_IPS)")")" \
    "$(json_pair managed_by "$(json_nullable_str "$(site_get "$name" MANAGED_BY)")")"
}

cmd_sites() {
  local ids items="" name
  ids="$(site_ids)"

  if [ "${OPT_JSON:-0}" = "1" ]; then
    for name in $ids; do items="${items:+$items,}$(_site_json "$name")"; done
    json_emit "$(json_pair sites "[$items]")"
    return 0
  fi

  if [ -z "$ids" ]; then
    log_warn "No sites registered."
    return 0
  fi

  ui_title "Sites"
  for name in $ids; do
    printf '  %s%-16s%s %-32s %-24s %s\n' "$C_BWHITE" "$name" "$C_RESET" \
      "$(site_get "$name" DOMAIN '-')" "$(site_get "$name" UPSTREAM '-')" \
      "$(site_get "$name" KIND 'app')"
  done
}

# cmd_site_add <name> [--domain d] [--upstream host:port] [--alt-domain a] [--allow-ips l]
cmd_site_add() {
  local args=("$@")
  local name="${args[0]-}"
  case "$name" in --*) name="" ;; esac
  [ -n "$name" ] || name="$(opt_value name '' "${args[@]}")"
  if [ -z "$name" ]; then
    log_error "Usage: vpnsetup site add <name> --domain <d> --upstream <host:port> [--allow-ips <list>]"
    return "$EX_USAGE"
  fi
  case "$name" in
    *[!A-Za-z0-9._-]*) log_error "Site name may only contain letters, digits, dot, dash and underscore."; return "$EX_USAGE" ;;
  esac

  local domain upstream alt allow
  domain="$(opt_value domain '' "${args[@]}")"
  upstream="$(opt_value upstream '' "${args[@]}")"
  alt="$(opt_value alt-domain '' "${args[@]}")"
  allow="$(opt_value allow-ips '' "${args[@]}")"

  [ -n "$domain" ] || { log_error "--domain is required."; return "$EX_USAGE"; }
  is_valid_domain "$domain" || { log_error "Not a valid domain: $domain"; return "$EX_USAGE"; }

  [ -n "$upstream" ] || { log_error "--upstream is required (host:port or a bare port)."; return "$EX_USAGE"; }
  is_valid_upstream "$upstream" || { log_error "Not a valid upstream: $upstream"; return "$EX_USAGE"; }
  upstream="$(upstream_normalize "$upstream")"

  if [ -n "$alt" ] && ! is_valid_domain "$alt"; then
    log_error "Not a valid --alt-domain: $alt"; return "$EX_USAGE"
  fi
  if [ -n "$allow" ] && ! is_valid_ip_list "$allow"; then
    log_error "Not a valid --allow-ips list: $allow"; return "$EX_USAGE"
  fi

  if [ "$(site_get "$name" KIND 'app')" = "panel" ]; then
    log_error "Site '$name' belongs to an installed panel and is managed by it."
    return "$EX_CONFLICT"
  fi

  site_write "$name" \
    "KIND=app" \
    "MANAGED_BY=" \
    "DOMAIN=$domain" \
    "ALT_DOMAIN=$alt" \
    "UPSTREAM=$upstream" \
    "ALLOW_IPS=$allow" || return "$EX_FAIL"

  log_ok "Site '$name' registered: https://$domain -> $upstream"
  proxy_reload || { log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."; return "$EX_PARTIAL"; }
  proxy_wait_for_cert "$domain" 60 || true
  return 0
}

cmd_site_remove() {
  local args=("$@")
  local name="${args[0]-}"
  case "$name" in --*) name="" ;; esac
  [ -n "$name" ] || { log_error "Usage: vpnsetup site remove <name>"; return "$EX_USAGE"; }

  site_exists "$name" || { log_error "No such site: $name"; return "$EX_NOTFOUND"; }

  if [ "$(site_get "$name" KIND 'app')" = "panel" ]; then
    log_error "Site '$name' is managed by a panel — remove the panel instead."
    return "$EX_CONFLICT"
  fi

  site_delete "$name"
  log_ok "Site '$name' removed."
  proxy_reload || { log_warn "Caddy was not reloaded — run 'vpnsetup proxy'."; return "$EX_PARTIAL"; }
  return 0
}
