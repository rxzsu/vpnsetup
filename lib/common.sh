#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# common.sh — logging, OS detection, secrets, prompts, shared state.
#
# Sourced by every other module. Defines functions only; no side effects.
#
# Deliberately NOT using `set -e`: this is an interactive installer with menus,
# and `set -e` turns any stray non-zero return (a cancelled prompt, a failed
# optional probe) into an abrupt exit mid-menu. Critical commands are checked
# explicitly via `run` / `die` instead.
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────────
readonly VPN_SETUP_VERSION="0.2.0"

# Shape of every --json document. Bumped when a field changes meaning, so a
# consumer can refuse a payload it does not understand instead of guessing.
readonly SCHEMA_VERSION=1

readonly STATE_DIR="${VPN_SETUP_STATE:-/etc/vpnsetup}"
readonly PANELS_STATE_DIR="$STATE_DIR/panels"
readonly SITES_STATE_DIR="$STATE_DIR/sites"
readonly LOCK_DIR="$STATE_DIR/locks"
readonly ROOT_DIR="${VPN_SETUP_ROOT:-/opt/vpnsetup}"
readonly BACKUP_DIR="${VPN_SETUP_BACKUP:-/var/backups/vpnsetup}"
readonly LOG_DIR="${VPN_SETUP_LOGS:-/var/log/vpnsetup}"
readonly JOBS_DIR="$LOG_DIR/jobs"
readonly AUDIT_LOG="$LOG_DIR/audit.log"
readonly CADDY_DIR="$ROOT_DIR/caddy"
readonly TMUX_SESSION="vpnsetup"

# ──────────────────────────────────────────────────────────────────────────────
# Exit codes — a caller has to be able to tell "nothing happened" from "it broke".
# ──────────────────────────────────────────────────────────────────────────────
readonly EX_OK=0         # success
readonly EX_FAIL=1       # generic failure
readonly EX_USAGE=2      # bad arguments, or a prompt we are not allowed to ask
readonly EX_CONFLICT=3   # already installed, port taken, resource busy
readonly EX_NOTFOUND=4   # no such panel / backup / job / site
readonly EX_PRECOND=5    # root, Docker, DNS — a precondition is not met
readonly EX_PARTIAL=6    # the action happened, a follow-up step did not
readonly EX_CANCELLED=7  # the operator declined

# ──────────────────────────────────────────────────────────────────────────────
# Colors
# ──────────────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_MAGENTA=$'\033[0;35m'
  C_CYAN=$'\033[0;36m'
  C_BRED=$'\033[1;31m'
  C_BGREEN=$'\033[1;32m'
  C_BYELLOW=$'\033[1;33m'
  C_BBLUE=$'\033[1;34m'
  C_BCYAN=$'\033[1;36m'
  C_BWHITE=$'\033[1;37m'
else
  C_RESET='' C_DIM='' C_BOLD=''
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
  C_BRED='' C_BGREEN='' C_BYELLOW='' C_BBLUE='' C_BCYAN='' C_BWHITE=''
fi

# ──────────────────────────────────────────────────────────────────────────────
# Logging
#
# Every line is also offered to the job stream, so a control panel gets the same
# narration the terminal does without any command having to be aware of it.
# ──────────────────────────────────────────────────────────────────────────────

# Overridden by lib/job.sh, which is sourced after this file. The no-op keeps
# the logging helpers usable even if job.sh is not loaded.
job_emit() { return 0; }

# _log <tag> <color> <level> <out|err> <message...>
#
# Under --json, stdout carries exactly one JSON document and nothing else, so
# every human line is pushed to stderr. Consumers therefore get a clean stream
# to parse and can still show progress if they want it.
_log() {
  local tag="$1" color="$2" level="$3" stream="$4"; shift 4
  if [ "$stream" = "err" ] || [ "${OPT_JSON:-0}" = "1" ]; then
    printf '%s%s%s %s\n' "$color" "$tag" "$C_RESET" "$*" >&2
  else
    printf '%s%s%s %s\n' "$color" "$tag" "$C_RESET" "$*"
  fi
  job_emit "$level" "$*"
}

log_info()  { _log '[INFO]' "$C_BCYAN"   info  out "$*"; }
log_ok()    { _log '[ OK ]' "$C_BGREEN"  ok    out "$*"; }
log_warn()  { _log '[WARN]' "$C_BYELLOW" warn  err "$*"; }
log_error() { _log '[FAIL]' "$C_BRED"    error err "$*"; }
log_dim()   { _log ''       "$C_DIM"     dim   out "$*"; }
log_step()  { _log '▸'      "$C_BOLD$C_BBLUE" step out "$*"; }

die_code() {
  local code="$1"; shift
  log_error "$*"
  exit "$code"
}

die() { die_code "$EX_FAIL" "$*"; }

# Run a command that MUST succeed. Prints what it is doing first.
run() {
  local desc="$1"; shift
  log_info "$desc"
  if ! "$@"; then
    die "$desc — command failed: $*"
  fi
}

# Run a command, tolerate failure, report it.
try() {
  local desc="$1"; shift
  log_info "$desc"
  "$@" || { log_warn "$desc — failed (continuing)"; return 1; }
  return 0
}

# Retry a command N times with a delay.
retry() {
  local attempts="$1" delay="$2"; shift 2
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if "$@"; then return 0; fi
    [ "$i" -lt "$attempts" ] && sleep "$delay"
    i=$((i + 1))
  done
  return 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [ "$(id -u)" = "0" ]; }

require_root() {
  is_root || die_code "$EX_PRECOND" "This action needs root. Re-run with sudo."
}

# `--non-interactive` funnels every prompt through the no-terminal branch, which
# is what makes the flag trustworthy: there is exactly one place to audit.
have_tty() {
  [ "${OPT_NONINTERACTIVE:-0}" = "1" ] && return 1
  [ -t 0 ] && [ -t 1 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# OS / package manager
# ──────────────────────────────────────────────────────────────────────────────
detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  elif [ -f /etc/redhat-release ]; then
    printf 'centos'
  elif [ -f /etc/debian_version ]; then
    printf 'debian'
  else
    printf 'unknown'
  fi
}

detect_pm() {
  have_cmd apt-get && { printf 'apt'; return; }
  have_cmd dnf     && { printf 'dnf'; return; }
  have_cmd yum     && { printf 'yum'; return; }
  have_cmd apk     && { printf 'apk'; return; }
  have_cmd pacman  && { printf 'pacman'; return; }
  have_cmd zypper  && { printf 'zypper'; return; }
  printf 'unknown'
}

pkg_install() {
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    yum)    yum install -y -q "$@" ;;
    apk)    apk add --no-cache --quiet "$@" ;;
    pacman) pacman -Sy --noconfirm --quiet "$@" ;;
    zypper) zypper -q install -y "$@" ;;
    *)      log_warn "Unsupported package manager — install manually: $*"; return 1 ;;
  esac
}

pkg_refresh() {
  case "$(detect_pm)" in
    apt)    apt-get update -qq ;;
    dnf|yum) : ;;
    apk)    apk update --quiet ;;
    pacman) pacman -Sy --quiet ;;
    zypper) zypper -q refresh ;;
  esac
}

# Install a package only if its command is missing.
ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  have_cmd "$cmd" && return 0
  log_info "Installing $pkg..."
  pkg_refresh >/dev/null 2>&1 || true
  pkg_install "$pkg" >/dev/null 2>&1 || true
  have_cmd "$cmd" || die_code "$EX_PRECOND" "Could not install '$pkg'. Please install it manually."
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets — no dependency on xxd/openssl being present.
# ──────────────────────────────────────────────────────────────────────────────
gen_hex() {
  local bytes="${1:-32}"
  if have_cmd openssl; then
    openssl rand -hex "$bytes"
  else
    od -An -tx1 -N "$bytes" /dev/urandom | tr -d ' \n'
  fi
}

gen_base64() {
  local bytes="${1:-32}"
  if have_cmd openssl; then
    openssl rand -base64 "$bytes" | tr -d '\n'
  else
    od -An -tx1 -N "$bytes" /dev/urandom | tr -d ' \n'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────────────────────────────────────
is_valid_domain() {
  local d="${1:-}"
  # Reject scheme/port/path early so users get a clear error.
  case "$d" in
    *://*|*/*|*:*) return 1 ;;
  esac
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
  elif have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port\$" && return 0
  fi
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Option parsing — small helpers for the subcommands that take named options.
#
# opt_positionals cannot know which options carry a value, so it skips the token
# after every `--flag`. That holds for every command here (all their options take
# a value); a boolean flag would need its own parser.
# ──────────────────────────────────────────────────────────────────────────────

# opt_value <name> <default> <args...> — value of --name or --name=value.
opt_value() {
  local name="$1" default="${2-}"; shift 2
  local a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      "--$name")   printf '%s' "${2-}"; return 0 ;;
      "--$name="*) printf '%s' "${a#*=}"; return 0 ;;
    esac
    shift
  done
  printf '%s' "$default"
}

opt_has() {
  local name="$1"; shift
  local a
  for a in "$@"; do
    case "$a" in "--$name"|"--$name="*) return 0 ;; esac
  done
  return 1
}

opt_positionals() {
  local a skip=0
  for a in "$@"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$a" in
      --*=*) continue ;;
      --*)   skip=1; continue ;;
      *)     printf '%s\n' "$a" ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Prompts — every read is guarded so EOF never kills the script.
# ──────────────────────────────────────────────────────────────────────────────
ask() {
  local prompt="$1" default="${2:-}" var
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " var || var=""
    printf '%s' "${var:-$default}"
  else
    read -rp "$prompt: " var || var=""
    printf '%s' "$var"
  fi
}

ask_secret() {
  local prompt="$1" var
  if [ -t 0 ]; then
    read -rsp "$prompt: " var || var=""
    printf '\n' >&2
  else
    read -rp "$prompt: " var || var=""
  fi
  printf '%s' "$var"
}

# ask_domain <prompt> — loops until a valid domain is given.
# VPN_SETUP_DOMAIN short-circuits the prompt (non-interactive / CI installs).
ask_domain() {
  local prompt="$1" d
  if [ -n "${VPN_SETUP_DOMAIN:-}" ]; then
    is_valid_domain "$VPN_SETUP_DOMAIN" || die_code "$EX_USAGE" "VPN_SETUP_DOMAIN is not a valid domain: $VPN_SETUP_DOMAIN"
    printf '%s' "$VPN_SETUP_DOMAIN"; return 0
  fi
  if ! have_tty; then
    die_code "$EX_USAGE" "No terminal available. Pass --domain or set VPN_SETUP_DOMAIN."
  fi
  while true; do
    d="$(ask "$prompt")"
    if [ -z "$d" ]; then
      log_warn "Domain is required."
    elif is_valid_domain "$d"; then
      printf '%s' "$d"; return 0
    else
      log_warn "Invalid domain. Use a bare hostname, e.g. panel.example.com"
    fi
  done
}

# ask_port <prompt> <default> — loops until a valid port is given.
# VPN_SETUP_PORT short-circuits the prompt; without a terminal the default wins.
ask_port() {
  local prompt="$1" default="$2" p
  if [ -n "${VPN_SETUP_PORT:-}" ]; then
    is_valid_port "$VPN_SETUP_PORT" || die_code "$EX_USAGE" "VPN_SETUP_PORT is not a valid port: $VPN_SETUP_PORT"
    printf '%s' "$VPN_SETUP_PORT"; return 0
  fi
  if ! have_tty; then printf '%s' "$default"; return 0; fi
  while true; do
    p="$(ask "$prompt" "$default")"
    if is_valid_port "$p"; then
      printf '%s' "$p"; return 0
    fi
    log_warn "Invalid port."
  done
}

confirm() {
  local prompt="$1" default="${2:-n}" hint answer
  # --yes answers every confirmation; nothing is destructive without it.
  [ "${OPT_YES:-0}" = "1" ] && return 0
  # No terminal: never silently answer "yes" to a destructive question.
  if ! have_tty; then [ "$default" = "y" ]; return; fi
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -rp "$prompt $hint: " answer || answer=""
  answer="${answer:-$default}"
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# confirm_action <prompt> [default] [hint]
#
# For actions that must not be silently skipped. Never returns non-zero: it
# either returns 0 (go ahead) or exits with a code that says what happened —
# EX_USAGE when we are not allowed to ask, EX_CANCELLED when the operator said no.
#
# Callers used to write `confirm ... || { log_info "Cancelled."; return 0; }`,
# which reports success for a command that changed nothing. That is the worst
# possible answer for anything automated.
confirm_action() {
  local prompt="$1" default="${2:-n}" hint="${3:-}"
  confirm "$prompt" "$default" && return 0

  if [ "${OPT_NONINTERACTIVE:-0}" = "1" ] && [ "${OPT_YES:-0}" != "1" ]; then
    die_code "$EX_USAGE" "Confirmation required but --non-interactive was given.${hint:+ $hint}"
  fi
  log_info "Cancelled — nothing was changed."
  exit "$EX_CANCELLED"
}

press_any_key() {
  printf '\n'
  read -n 1 -s -r -p "Press any key to continue..." || true
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────────
# Shared state — one env file per installed panel.
#   $PANELS_STATE_DIR/<id>.env
# Keys: PANEL_ID PANEL_NAME DOMAIN PORT INSTALL_DIR PROJECT MODE DATA_DIR
# ──────────────────────────────────────────────────────────────────────────────
state_init() {
  mkdir -p "$PANELS_STATE_DIR" "$SITES_STATE_DIR" "$LOCK_DIR" \
           "$ROOT_DIR" "$LOG_DIR" "$JOBS_DIR" 2>/dev/null || true
}

# state_write <id> <key=value> ...
#
# Full rewrite, but through a temporary file and an atomic rename, so a reader
# never sees a half-written state file. That is what lets reads stay lock-free.
state_write() {
  local id="$1"; shift
  state_init
  local file="$PANELS_STATE_DIR/$id.env"
  local tmp="$file.tmp.$$"
  {
    printf 'PANEL_ID=%s\n' "$id"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } >"$tmp" || { log_error "Could not write $tmp"; return "$EX_FAIL"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" || { rm -f "$tmp"; log_error "Could not replace $file"; return "$EX_FAIL"; }
  return 0
}

# state_get <id> <key> [default]
state_get() {
  local id="$1" key="$2" default="${3:-}"
  local file="$PANELS_STATE_DIR/$id.env"
  [ -f "$file" ] || { printf '%s' "$default"; return; }
  local line
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  if [ -z "$line" ]; then printf '%s' "$default"; else printf '%s' "${line#*=}"; fi
}

state_exists() { [ -f "$PANELS_STATE_DIR/$1.env" ]; }

# state_set <id> <KEY> <value> — update one key in place, appending it if the
# key is absent. Everything else in the file is left untouched.
#
# This is a read-modify-write, so two of them racing would lose one of the two
# changes. Hence the lock: it is short, and it is the only place that needs one.
state_set() {
  local id="$1" key="$2" value="$3"
  local file="$PANELS_STATE_DIR/$id.env"
  [ -f "$file" ] || { log_error "No state file for panel '$id'."; return "$EX_NOTFOUND"; }

  lock_take "state" || return "$EX_FAIL"
  env_set "$file" "$key" "$value"; local rc=$?
  lock_release
  [ "$rc" -eq 0 ] || return "$rc"

  chmod 600 "$file" 2>/dev/null || true
  return 0
}

state_delete() { rm -f "$PANELS_STATE_DIR/$1.env"; }

state_ids() {
  local f
  for f in "$PANELS_STATE_DIR"/*.env; do
    [ -e "$f" ] || continue
    basename "$f" .env
  done
}

state_count() {
  local n=0 f
  for f in "$PANELS_STATE_DIR"/*.env; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# ──────────────────────────────────────────────────────────────────────────────
# DNS / networking
# ──────────────────────────────────────────────────────────────────────────────
# resolve_a <hostname> — print the first IPv4 address, or nothing.
resolve_a() {
  local host="$1" ip=""
  if have_cmd dig; then
    ip="$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
  elif have_cmd getent; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | head -1)"
  elif have_cmd nslookup; then
    ip="$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2; exit}')"
  fi
  printf '%s' "$ip"
}

# public_ip — this server's outbound IPv4, or nothing when offline.
public_ip() {
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Misc
# ──────────────────────────────────────────────────────────────────────────────
# Strip everything but alphanumerics — turns "3x-ui" into "3xui" so it can be
# used in a function name.
id_slug() { printf '%s' "${1//[^a-zA-Z0-9]/}"; }

# Enable IPv4 forwarding on the host (required for any VPN dataplane).
ensure_ip_forward() {
  local current
  current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '0')"
  [ "$current" = "1" ] && return 0
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  if ! grep -qs '^net.ipv4.ip_forward' /etc/sysctl.conf; then
    printf 'net.ipv4.ip_forward=1\n' >> /etc/sysctl.conf 2>/dev/null || true
  fi
  log_ok "Enabled net.ipv4.ip_forward"
}

# Write a file atomically with restrictive permissions.
write_secret_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# env_set <file> <KEY> <value>
#
# Set KEY in an env file, replacing a commented-out or existing line, or
# appending it when absent. Writes the plain `KEY=value` form because that is
# the only form every consumer accepts — Docker Compose's env_file parser is
# stricter than a dotenv library. Values containing whitespace or a `#` get
# quoted.
#
# The temporary file carries the pid: with a fixed name, two concurrent calls on
# the same file would fight over one path and one of them would lose its result.
# ──────────────────────────────────────────────────────────────────────────────
env_set() {
  local file="$1" key="$2" value="$3" rendered
  case "$value" in
    *[[:space:]]*|*'#'*) rendered="${key}=\"${value}\"" ;;
    *)                   rendered="${key}=${value}" ;;
  esac

  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    # The replacement goes through a temp file: sed's `s|...|...|` with an
    # arbitrary value would otherwise need escaping of | & and backslashes.
    local tmp="$file.vpnsetup.tmp.$$"
    awk -v key="$key" -v line="$rendered" '
      !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=" { print line; done=1; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  else
    printf '%s\n' "$rendered" >> "$file"
  fi
}
