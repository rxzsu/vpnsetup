#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# vpnsetup — bootstrap installer.
#
#   curl -fsSL https://raw.githubusercontent.com/rxzsu/vpnsetup/main/install.sh | sudo bash
#
# This script is deliberately self-contained: it is piped from curl, so it
# cannot assume any local file exists. It installs the prerequisites, caches
# the modules in /opt/vpnsetup-setup, drops the `vpnsetup` command in
# /usr/local/bin and then hands over to the real manager.
#
# No `set -e`: every step that matters is checked explicitly, so a failure
# produces a readable message instead of a silent abort.
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Repository the modules are downloaded from ────────────────────────────────
readonly DEFAULT_REPO="rxzsu/vpnsetup"
readonly DEFAULT_BRANCH="main"
# ──────────────────────────────────────────────────────────────────────────────

readonly INSTALLER_VERSION="0.1.0"
readonly REPO="${VPN_SETUP_REPO:-$DEFAULT_REPO}"
readonly BRANCH="${VPN_SETUP_BRANCH:-$DEFAULT_BRANCH}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
readonly SETUP_DIR="${VPN_SETUP_INSTALL_DIR:-/opt/vpnsetup-setup}"
readonly CLI_PATH="/usr/local/bin/vpnsetup"
readonly TMUX_SESSION="vpnsetup"

C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_MAGENTA=''; C_BOLD=''; C_DIM=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_CYAN=$'\033[0;36m'; C_MAGENTA=$'\033[0;35m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
fi

say()    { printf '%s[INFO]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
ok()     { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()   { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail()   { printf '%s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
dim()    { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
have()   { command -v "$1" >/dev/null 2>&1; }

banner() {
  clear 2>/dev/null || true
  printf '\n'
  printf '%s┌──────────────────────────────────────────────────────────────┐%s\n' "$C_MAGENTA" "$C_RESET"
  printf '%s│%s  %sVPN Setup%s %s— bootstrap installer%s\n' \
    "$C_MAGENTA" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$C_MAGENTA" "$C_RESET"
  printf '   %sv%s%s · repo %s\n\n' "$C_DIM" "$INSTALLER_VERSION" "$C_RESET" "$REPO"
}

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ──────────────────────────────────────────────────────────────────────────────
detect_pm() {
  have apt-get && { printf 'apt'; return; }
  have dnf     && { printf 'dnf'; return; }
  have yum     && { printf 'yum'; return; }
  have apk     && { printf 'apk'; return; }
  have pacman  && { printf 'pacman'; return; }
  have zypper  && { printf 'zypper'; return; }
  printf 'unknown'
}

pkg_install() {
  case "$(detect_pm)" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    yum)    yum install -y -q "$@" ;;
    apk)    apk add --no-cache --quiet "$@" ;;
    pacman) pacman -Sy --noconfirm --quiet "$@" ;;
    zypper) zypper -q install -y "$@" ;;
    *)      return 1 ;;
  esac
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  have "$cmd" && return 0
  say "Installing $pkg..."
  case "$(detect_pm)" in
    apt) apt-get update -qq >/dev/null 2>&1 || true ;;
    apk) apk update --quiet >/dev/null 2>&1 || true ;;
  esac
  pkg_install "$pkg" >/dev/null 2>&1 || true
  have "$cmd" || fail "Could not install '$pkg'. Install it manually and re-run."
}

ensure_docker() {
  if have docker; then
    ok "Docker present"
  else
    say "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/vpnsetup-get-docker.sh \
      || fail "Could not download the Docker installer."
    sh /tmp/vpnsetup-get-docker.sh || fail "Docker installation failed."
    rm -f /tmp/vpnsetup-get-docker.sh
    ok "Docker installed"
  fi

  if have systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi
  docker info >/dev/null 2>&1 || fail "The Docker daemon is not reachable. Try: systemctl start docker"

  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose present"
    return 0
  fi

  say "Installing the Docker Compose plugin..."
  pkg_install docker-compose-plugin >/dev/null 2>&1 || true
  if ! docker compose version >/dev/null 2>&1; then
    local arch; arch="$(uname -m)"
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose \
      || fail "Could not download the Compose plugin."
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  docker compose version >/dev/null 2>&1 || fail "Docker Compose is still unavailable."
  ok "Docker Compose installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Modules
# ──────────────────────────────────────────────────────────────────────────────
readonly MODULES=(
  "install.sh"
  "lib/common.sh"
  "lib/docker.sh"
  "lib/proxy.sh"
  "lib/backup.sh"
  "lib/panels.sh"
  "lib/doctor.sh"
  "lib/ui.sh"
  "lib/main.sh"
  "lib/panels/3x-ui.sh"
  "lib/panels/marzban.sh"
  "lib/panels/remnawave.sh"
)

fetch_modules() {
  # When the script is piped from curl there is no file on disk, so
  # BASH_SOURCE is empty and we fall through to downloading.
  local src="${BASH_SOURCE[0]:-}"
  local script_dir=""
  if [ -n "$src" ]; then
    script_dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd || printf '')"
  fi

  rm -rf "$SETUP_DIR"
  mkdir -p "$SETUP_DIR/lib/panels" "$SETUP_DIR/bin"

  local from_local=0
  if [ -n "$script_dir" ] && [ -f "$script_dir/lib/main.sh" ]; then
    from_local=1
    say "Using modules from the local checkout ($script_dir)"
  else
    say "Downloading modules from ${REPO}@${BRANCH}..."
  fi

  local f
  for f in "${MODULES[@]}"; do
    if [ "$from_local" -eq 1 ] && [ -f "$script_dir/$f" ]; then
      cp "$script_dir/$f" "$SETUP_DIR/$f" || fail "Could not copy $f"
    else
      curl -fsSL "${RAW_BASE}/${f}" -o "$SETUP_DIR/$f" || fail "Could not download $f from ${RAW_BASE}/${f}"
    fi
  done

  if [ "$from_local" -eq 1 ] && [ -f "$script_dir/bin/vpnsetup" ]; then
    cp "$script_dir/bin/vpnsetup" "$SETUP_DIR/bin/vpnsetup"
  else
    curl -fsSL "${RAW_BASE}/bin/vpnsetup" -o "$SETUP_DIR/bin/vpnsetup" \
      || fail "Could not download bin/vpnsetup"
  fi

  chmod +x "$SETUP_DIR/bin/vpnsetup"
  ok "Modules cached in $SETUP_DIR"
}

install_cli() {
  # The shim re-execs the cached modules, so the CLI and the bootstrap share
  # exactly one copy of the logic.
  install -m 755 "$SETUP_DIR/bin/vpnsetup" "$CLI_PATH" \
    || fail "Could not install $CLI_PATH"
  ok "Command installed: $CLI_PATH"
}

# ──────────────────────────────────────────────────────────────────────────────
# tmux — survive an SSH drop mid-install
# ──────────────────────────────────────────────────────────────────────────────
tmux_wrap() {
  [ -n "${TMUX:-}" ] && return 0

  if ! have tmux; then
    pkg_install tmux >/dev/null 2>&1 || { warn "tmux is unavailable — continuing without it."; return 0; }
  fi

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    printf '\n%sAn existing setup session is running.%s\n' "$C_YELLOW" "$C_RESET"
    printf '  1) Attach to it (recommended)\n'
    printf '  2) Kill it and start fresh\n'
    printf '  3) Continue here without tmux\n'
    local choice
    read -rp "Choice [1]: " choice || choice=""
    case "${choice:-1}" in
      1) exec tmux attach-session -t "$TMUX_SESSION" ;;
      2) tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true ;;
      *) return 0 ;;
    esac
  fi

  printf '\n%sStarting a tmux session so an SSH drop cannot interrupt the install.%s\n' \
    "$C_YELLOW" "$C_RESET"
  dim "  Reattach later with: vpnsetup attach"
  sleep 2

  # Forward the environment the user may have set, quoting every value.
  local inner=""
  local v val
  for v in VPN_SETUP_PANEL VPN_SETUP_DOMAIN VPN_SETUP_PORT VPN_SETUP_ACTION \
           VPN_SETUP_REPO VPN_SETUP_BRANCH VPN_SETUP_3XUI_IMAGE; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && inner="${inner}${v}=$(printf '%q' "$val") "
  done

  exec tmux new-session -s "$TMUX_SESSION" "env ${inner}bash $(printf '%q' "$CLI_PATH")"
}

# ──────────────────────────────────────────────────────────────────────────────
main() {
  banner

  if [ "$(id -u)" != "0" ]; then
    fail "This installer must run as root. Try: sudo bash install.sh"
  fi

  # Second pass: the modules are already cached, we only need the terminal.
  if [ -n "${VPN_SETUP_TTY_REEXEC:-}" ]; then
    [ "${1:-}" != "--no-tmux" ] && tmux_wrap
    exec "$CLI_PATH"
  fi

  ensure_cmd curl
  ensure_cmd tar
  ensure_docker
  fetch_modules
  install_cli

  # `curl … | bash` leaves stdin connected to the pipe, not the terminal. A
  # prompt would then swallow the script itself, and bash cannot seek back on a
  # pipe — so we restart the cached copy with /dev/tty as stdin instead.
  if [ ! -t 0 ] && [ -t 1 ] && ( true </dev/tty ) 2>/dev/null; then
    say "Reconnecting to the terminal..."
    export VPN_SETUP_TTY_REEXEC=1
    exec bash "$SETUP_DIR/install.sh" "$@" </dev/tty
  fi

  # Truly headless (CI, cloud-init, `ssh host 'bash -s' < install.sh`): run once
  # and exit instead of trying to draw a menu.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    exec "$CLI_PATH" "${VPN_SETUP_ACTION:-help}"
  fi

  [ "${1:-}" != "--no-tmux" ] && tmux_wrap

  exec "$CLI_PATH"
}

main "$@"
