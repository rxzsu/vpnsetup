#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# doctor.sh — diagnostics.
#
# Answers the only question that matters when a panel will not open: which layer
# is broken. Checks run from the bottom up (host → docker → panel → proxy → TLS)
# so the first failure is the one worth fixing.
#
# Every check is best-effort and read-only: doctor never changes anything, and a
# check it cannot perform degrades to a warning rather than a false failure.
# ──────────────────────────────────────────────────────────────────────────────

readonly DOCTOR_BACKUP_STALE_DAYS="${VPN_SETUP_BACKUP_STALE_DAYS:-7}"
readonly DOCTOR_CERT_WARN_DAYS="${VPN_SETUP_CERT_WARN_DAYS:-14}"
readonly DOCTOR_DISK_FAIL_MB="${VPN_SETUP_DISK_FAIL_MB:-200}"
readonly DOCTOR_DISK_WARN_MB="${VPN_SETUP_DISK_WARN_MB:-1024}"

DOCTOR_OK=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

# Every check is also recorded, so the same run can be rendered as a report for
# a human or as a document for a control panel. Entries are
# "<level><TAB><section><TAB><message>".
DOCTOR_CHECKS=()
DOCTOR_SECTION_NAME=""

_doctor_record() {
  local level="$1" tag="$2" color="$3" msg="$4"
  DOCTOR_CHECKS+=("$level"$'\t'"$DOCTOR_SECTION_NAME"$'\t'"$msg")
  if [ "${OPT_JSON:-0}" = "1" ]; then
    printf '  %s%s%s %s\n' "$color" "$tag" "$C_RESET" "$msg" >&2
  else
    printf '  %s%s%s %s\n' "$color" "$tag" "$C_RESET" "$msg"
  fi
}

doctor_ok()   { DOCTOR_OK=$((DOCTOR_OK + 1));     _doctor_record ok   'ok  ' "$C_BGREEN"  "$*"; }
doctor_warn() { DOCTOR_WARN=$((DOCTOR_WARN + 1)); _doctor_record warn 'warn' "$C_BYELLOW" "$*"; }
doctor_fail() { DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); _doctor_record fail 'fail' "$C_BRED"    "$*"; }
doctor_note() {                                   _doctor_record note ' .. ' "$C_DIM"     "$*"; }

doctor_section() {
  DOCTOR_SECTION_NAME="$1"
  if [ "${OPT_JSON:-0}" = "1" ]; then
    printf '\n%s%s%s\n' "$C_BOLD$C_BWHITE" "$1" "$C_RESET" >&2
  else
    printf '\n%s%s%s\n' "$C_BOLD$C_BWHITE" "$1" "$C_RESET"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Host
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_host() {
  doctor_section "Host"

  doctor_ok "$(detect_os) $(uname -m), kernel $(uname -r)"

  local avail
  avail="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail" ]; then
    if [ "$avail" -lt "$DOCTOR_DISK_FAIL_MB" ]; then
      doctor_fail "/ has only ${avail} MB free"
    elif [ "$avail" -lt "$DOCTOR_DISK_WARN_MB" ]; then
      doctor_warn "/ has ${avail} MB free"
    else
      doctor_ok "/ has ${avail} MB free"
    fi
  fi

  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  avail="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail" ]; then
    if [ "$avail" -lt "$DOCTOR_DISK_FAIL_MB" ]; then
      doctor_fail "$BACKUP_DIR has only ${avail} MB free"
    elif [ "$avail" -lt "$DOCTOR_DISK_WARN_MB" ]; then
      doctor_warn "$BACKUP_DIR has ${avail} MB free"
    else
      doctor_ok "$BACKUP_DIR has ${avail} MB free"
    fi
  fi

  # Every supported panel ships a VPN dataplane; without forwarding it accepts
  # connections and silently passes no traffic.
  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '0')" = "1" ]; then
    doctor_ok "net.ipv4.ip_forward is enabled"
  else
    doctor_warn "net.ipv4.ip_forward is disabled — VPN traffic will not be forwarded"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Docker
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_docker() {
  doctor_section "Docker"

  if ! have_cmd docker; then
    doctor_fail "docker is not installed"
    return 0
  fi

  doctor_ok "$(docker --version 2>/dev/null | cut -d, -f1)"

  if ! docker info >/dev/null 2>&1; then
    doctor_fail "the Docker daemon is not reachable"
    return 0
  fi
  doctor_ok "Docker daemon is reachable"

  if docker compose version >/dev/null 2>&1; then
    doctor_ok "compose $(docker compose version --short 2>/dev/null || printf 'v2')"
  else
    doctor_fail "the Docker Compose plugin is missing"
  fi

  # Reclaimable space is informational — only the operator can judge whether
  # pruning is safe.
  local reclaim
  reclaim="$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | tail -1)"
  [ -n "$reclaim" ] && doctor_note "docker reclaimable space: $reclaim"
}

# ──────────────────────────────────────────────────────────────────────────────
# TLS + end-to-end HTTPS
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_https() {
  local domain="$1"
  [ -n "$domain" ] || return 0

  if ! have_cmd openssl; then
    doctor_warn "openssl is unavailable — skipping the TLS check for $domain"
    return 0
  fi

  # `timeout` is not guaranteed to exist; when it does it stops a filtered port
  # from hanging the whole run.
  local tmo=""
  have_cmd timeout && tmo="timeout 10"

  local enddate
  # shellcheck disable=SC2086
  enddate="$(echo | $tmo openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"

  if [ -z "$enddate" ]; then
    doctor_fail "TLS: no certificate could be retrieved for $domain"
  else
    local end_epoch now days
    end_epoch="$(date -d "$enddate" +%s 2>/dev/null || printf '')"
    if [ -z "$end_epoch" ]; then
      doctor_ok "TLS: certificate for $domain expires $enddate"
    else
      now="$(date +%s)"
      days=$(( (end_epoch - now) / 86400 ))
      if [ "$days" -lt 0 ]; then
        doctor_fail "TLS: certificate for $domain expired $(( -days )) days ago"
      elif [ "$days" -lt "$DOCTOR_CERT_WARN_DAYS" ]; then
        doctor_warn "TLS: certificate for $domain expires in $days days"
      else
        doctor_ok "TLS: certificate valid for $days more days"
      fi
    fi
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$domain" 2>/dev/null || printf '000')"
  case "$code" in
    2??|3??|401|403) doctor_ok "HTTPS https://$domain -> $code" ;;
    000)             doctor_fail "HTTPS https://$domain did not respond" ;;
    *)               doctor_fail "HTTPS https://$domain -> $code" ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Backups
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_backups() {
  local id="$1" latest mtime age
  latest="$(backup_list "$id" 2>/dev/null | head -1)"

  if [ -z "$latest" ]; then
    doctor_warn "no backups yet — run: vpnsetup backup $id"
    return 0
  fi

  mtime="$(date -r "$latest" +%s 2>/dev/null || printf '')"
  if [ -z "$mtime" ]; then
    doctor_note "latest backup: $(basename "$latest")"
    return 0
  fi

  age=$(( ( $(date +%s) - mtime ) / 86400 ))
  if [ "$age" -ge "$DOCTOR_BACKUP_STALE_DAYS" ]; then
    doctor_warn "latest backup is ${age} days old — run: vpnsetup backup $id"
  else
    doctor_ok "latest backup is ${age} days old"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# File permissions
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_permissions() {
  local id="$1" dir="$2" file mode checked=0 loose=0

  for file in "$dir/.env" "$PANELS_STATE_DIR/$id.env"; do
    [ -f "$file" ] || continue
    mode="$(stat -c '%a' "$file" 2>/dev/null || printf '')"
    [ -n "$mode" ] || continue
    checked=$((checked + 1))
    case "$mode" in
      600|400|640) ;;
      *) loose=1; doctor_warn "$(basename "$file") has mode $mode (expected 600)" ;;
    esac
  done

  [ "$checked" -gt 0 ] && [ "$loose" -eq 0 ] && doctor_ok "config files are not group/world readable"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# One panel
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_panel() {
  local id="$1"
  local name domain port dir
  name="$(panel_catalog_name "$id")"
  domain="$(state_get "$id" DOMAIN)"
  port="$(state_get "$id" PORT)"
  dir="$(state_get "$id" INSTALL_DIR)"

  doctor_section "$name ($id)"

  [ -n "$domain" ] && doctor_ok "domain: $domain" || doctor_fail "no domain recorded in the state file"

  if is_valid_port "$port"; then
    doctor_ok "panel port: $port"
  else
    doctor_fail "invalid panel port in the state file: '$port'"
  fi

  if [ ! -d "$dir" ]; then
    doctor_fail "install directory is missing: $dir"
    return 0
  fi
  doctor_ok "install directory: $dir"

  if [ -f "$dir/docker-compose.yml" ]; then
    doctor_ok "compose file present"
  else
    doctor_fail "compose file is missing from $dir"
  fi

  # ── Containers ─────────────────────────────────────────────────────────────
  local cid found=0
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found=$((found + 1))

    local cname state health restarts
    cname="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')"
    [ -n "$cname" ] || cname="$cid"
    state="$(container_state "$cid")"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || printf 'none')"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || printf '0')"
    case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

    if [ "$state" != "running" ]; then
      doctor_fail "$cname is $state"
      continue
    fi
    if [ "$health" = "unhealthy" ]; then
      doctor_warn "$cname is running but its healthcheck reports unhealthy"
      continue
    fi
    if [ "$restarts" -gt 5 ]; then
      doctor_warn "$cname has restarted ${restarts} times — check its logs"
      continue
    fi
    if [ "$health" = "none" ]; then
      doctor_ok "$cname is running"
    else
      doctor_ok "$cname is running, health: $health"
    fi
  done < <(dc "$dir" ps -q -a 2>/dev/null)

  [ "$found" -eq 0 ] && doctor_fail "no containers exist for this panel — the stack was never started"

  # ── Listening port ─────────────────────────────────────────────────────────
  if is_valid_port "$port"; then
    if port_in_use "$port"; then
      doctor_ok "port $port is listening"
    else
      doctor_fail "nothing is listening on port $port"
    fi
  fi

  # ── DNS ────────────────────────────────────────────────────────────────────
  if [ -n "$domain" ]; then
    local resolved server
    resolved="$(resolve_a "$domain")"
    if [ -z "$resolved" ]; then
      doctor_fail "DNS: $domain does not resolve"
    else
      server="$(public_ip)"
      if [ -n "$server" ] && [ "$resolved" != "$server" ]; then
        doctor_warn "DNS: $domain -> $resolved, this server is $server"
        doctor_note "expected behind Cloudflare/proxy; breaks HTTP-01 validation otherwise"
      else
        doctor_ok "DNS: $domain -> $resolved"
      fi
    fi
    doctor_check_https "$domain"
  fi

  doctor_check_backups "$id"
  doctor_check_permissions "$id" "$dir"
}

# ──────────────────────────────────────────────────────────────────────────────
# Reverse proxy
# ──────────────────────────────────────────────────────────────────────────────
doctor_check_caddy() {
  doctor_section "Reverse proxy"

  if ! have_cmd docker || ! docker info >/dev/null 2>&1; then
    doctor_note "skipped — Docker is unavailable"
    return 0
  fi

  if ! container_running "$CADDY_CONTAINER"; then
    doctor_fail "the Caddy container is not running — panels are not reachable over HTTPS"
    doctor_note "start it with: vpnsetup proxy"
    return 0
  fi
  doctor_ok "Caddy container is running"

  if docker exec "$CADDY_CONTAINER" caddy validate \
       --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    doctor_ok "the generated Caddyfile is valid"
  else
    doctor_fail "the generated Caddyfile is invalid"
    docker exec "$CADDY_CONTAINER" caddy validate \
      --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -3 | sed 's/^/      /' || true
  fi

  # Caddy runs on the host network, so its ports do not show up in `docker ps`
  # port mappings — the best available signal is "bound while Caddy is running".
  local p
  for p in 80 443; do
    if port_in_use "$p"; then
      doctor_ok "port $p is bound"
    else
      doctor_fail "nothing is listening on port $p — certificates cannot be issued or renewed"
    fi
  done

  if [ -f "$CADDY_DIR/Caddyfile" ]; then
    local sites
    sites="$(grep -cE '^[^#[:space:]].*\{$' "$CADDY_DIR/Caddyfile" 2>/dev/null || printf '0')"
    doctor_note "serving $sites site block(s)"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────
doctor_run() {
  DOCTOR_OK=0
  DOCTOR_WARN=0
  DOCTOR_FAIL=0
  DOCTOR_CHECKS=()
  DOCTOR_SECTION_NAME=""

  ui_title "Diagnostics"

  doctor_check_host
  doctor_check_docker

  local id count
  count="$(state_count)"
  if [ "$count" -eq 0 ]; then
    doctor_section "Panels"
    doctor_note "no panels installed yet"
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      doctor_check_panel "$id"
    done < <(state_ids)
  fi

  doctor_check_caddy

  if [ "$OPT_JSON" = "1" ]; then
    local items="" i=0 n="${#DOCTOR_CHECKS[@]}" entry level rest section msg
    while [ "$i" -lt "$n" ]; do
      entry="${DOCTOR_CHECKS[$i]}"
      level="${entry%%$'\t'*}"
      rest="${entry#*$'\t'}"
      section="${rest%%$'\t'*}"
      msg="${rest#*$'\t'}"
      items="${items:+$items,}$(json_object \
        "$(json_pair level "$(json_str "$level")")" \
        "$(json_pair section "$(json_str "$section")")" \
        "$(json_pair message "$(json_str "$msg")")")"
      i=$((i + 1))
    done

    local healthy=0
    [ "$DOCTOR_FAIL" -eq 0 ] && healthy=1

    json_emit \
      "$(json_pair healthy "$(json_bool "$healthy")")" \
      "$(json_pair summary "$(json_object \
        "$(json_pair passed "$(json_num "$DOCTOR_OK")")" \
        "$(json_pair warnings "$(json_num "$DOCTOR_WARN")")" \
        "$(json_pair failed "$(json_num "$DOCTOR_FAIL")")")")" \
      "$(json_pair checks "[$items]")"

    [ "$DOCTOR_FAIL" -eq 0 ]
    return $?
  fi

  printf '\n'
  printf '%s%s%s\n' "$C_MAGENTA" "$(printf '─%.0s' $(seq 1 62))" "$C_RESET"
  if [ "$DOCTOR_FAIL" -gt 0 ]; then
    log_error "$DOCTOR_FAIL failed, $DOCTOR_WARN warnings, $DOCTOR_OK passed"
  elif [ "$DOCTOR_WARN" -gt 0 ]; then
    log_warn "$DOCTOR_WARN warnings, $DOCTOR_OK passed"
  else
    log_ok "$DOCTOR_OK checks passed"
  fi
  printf '\n'

  # Non-zero on any failure so doctor is usable from a monitoring script.
  [ "$DOCTOR_FAIL" -eq 0 ]
}
