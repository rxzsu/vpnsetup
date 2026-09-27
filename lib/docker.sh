#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# docker.sh — Docker/Compose bootstrap and thin wrappers.
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# Install / verify Docker + Compose plugin
# ──────────────────────────────────────────────────────────────────────────────
ensure_docker() {
  if have_cmd docker; then
    log_ok "Docker present ($(docker --version 2>/dev/null | cut -d, -f1))"
  else
    log_info "Installing Docker..."
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
      die "Could not download the Docker installer. Check network access."
    fi
    sh /tmp/get-docker.sh || die "Docker installation failed."
    rm -f /tmp/get-docker.sh
    log_ok "Docker installed"
  fi

  if have_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi

  if ! docker info >/dev/null 2>&1; then
    die "The Docker daemon is not reachable. Try: systemctl start docker"
  fi

  ensure_compose
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    log_ok "Docker Compose present ($(docker compose version --short 2>/dev/null || printf 'v2'))"
    return 0
  fi

  log_info "Installing the Docker Compose plugin..."
  # Try the distro package first — it tracks the distro's docker packaging.
  if ! pkg_install docker-compose-plugin >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    local arch
    arch="$(uname -m)"
    local plugin_dir="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$plugin_dir"
    if ! curl -fsSL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
        -o "$plugin_dir/docker-compose"; then
      die "Could not download the Compose plugin."
    fi
    chmod +x "$plugin_dir/docker-compose"
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose is still unavailable."
  log_ok "Docker Compose installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Compose helpers
# ──────────────────────────────────────────────────────────────────────────────
# dc <dir> <args...> — run `docker compose` with the given project directory.
dc() {
  local dir="$1"; shift
  ( cd "$dir" && docker compose "$@" )
}

# dc_env <dir> <envfile> <args...>
dc_env() {
  local dir="$1" envfile="$2"; shift 2
  ( cd "$dir" && docker compose --env-file "$envfile" "$@" )
}

compose_pull() {
  local dir="$1"
  log_info "Pulling images..."
  dc "$dir" pull || die "docker compose pull failed in $dir"
}

compose_up() {
  local dir="$1"
  log_info "Starting containers..."
  dc "$dir" up -d || die "docker compose up failed in $dir"
}

compose_down() {
  local dir="$1" purge="${2:-no}"
  [ -d "$dir" ] || return 0
  if [ "$purge" = "purge" ]; then
    dc "$dir" down -v --remove-orphans >/dev/null 2>&1 || true
  else
    dc "$dir" down --remove-orphans >/dev/null 2>&1 || true
  fi
}

compose_ps() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  dc "$dir" ps
}

# ──────────────────────────────────────────────────────────────────────────────
# Health / readiness
# ──────────────────────────────────────────────────────────────────────────────
# wait_http <url> <timeout_seconds> [label]
wait_http() {
  local url="$1" timeout="${2:-120}" label="${3:-service}"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# wait_http_ok <url> <timeout> — succeed on any response that proves an HTTP
# server is answering: 2xx, 3xx, or an auth wall (401/403). A 5xx does NOT
# count: the app is up but broken, and reporting that as ready would send the
# operator looking in the wrong place.
wait_http_ok() {
  local url="$1" timeout="${2:-120}"
  local waited=0 code
  while [ "$waited" -lt "$timeout" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || printf '000')"
    case "$code" in
      2??|3??|401|403) return 0 ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'missing'
}

container_running() {
  [ "$(container_state "$1")" = "running" ]
}

# Resolve a compose service to its container id. Upstream stacks do not always
# set container_name, so never assume a container name for a panel.
compose_container_id() {
  local dir="$1" service="$2"
  [ -d "$dir" ] || return 1
  dc "$dir" ps -q "$service" 2>/dev/null | head -1
}

compose_service_running() {
  local id; id="$(compose_container_id "$1" "$2")"
  [ -n "$id" ] && [ "$(container_state "$id")" = "running" ]
}

compose_container_ids() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  dc "$dir" ps -q 2>/dev/null || true
}

# compose_containers <dir> — one line per container: name|service|state|health
#
# `docker compose ps --format json` only exists in newer Compose releases and its
# shape has changed between them, so the facts are read from `docker inspect`
# instead. That output is a stable, documented contract.
compose_containers() {
  local dir="$1" ids
  ids="$(compose_container_ids "$dir")"
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect --format '{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' \
    $ids 2>/dev/null | sed 's#^/##' || true
}

# compose_containers_json <dir> — the same facts as a JSON array.
compose_containers_json() {
  local dir="$1" items="" name svc state health
  while IFS='|' read -r name svc state health; do
    [ -n "$name" ] || continue
    items="${items:+$items,}$(json_object \
      "$(json_pair name "$(json_str "$name")")" \
      "$(json_pair service "$(json_str "$svc")")" \
      "$(json_pair state "$(json_str "$state")")" \
      "$(json_pair health "$(json_str "$health")")")"
  done < <(compose_containers "$dir")
  printf '[%s]' "$items"
}

# wait_container_running <name> <timeout>
wait_container_running() {
  local name="$1" timeout="${2:-90}" waited=0 state
  while [ "$waited" -lt "$timeout" ]; do
    state="$(container_state "$name")"
    [ "$state" = "running" ] && return 0
    case "$state" in
      exited|dead)
        log_error "Container $name stopped unexpectedly ($state). Recent logs:"
        docker logs --tail=40 "$name" 2>&1 | sed 's/^/    /' >&2 || true
        return 1
        ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# Wait until a Postgres container actually accepts an authenticated query.
# `pg_isready` alone reports ready before the init phase has applied the
# password, which makes the first migration fail.
wait_postgres() {
  local dir="$1" service="$2" user="$3" db="$4" pass="$5" timeout="${6:-120}"
  local waited=0 cid
  while [ "$waited" -lt "$timeout" ]; do
    cid="$(compose_container_id "$dir" "$service")"
    if [ -n "$cid" ] && docker exec -e PGPASSWORD="$pass" "$cid" \
         psql -U "$user" -d "$db" -c 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

docker_available() {
  have_cmd docker && docker info >/dev/null 2>&1
}
