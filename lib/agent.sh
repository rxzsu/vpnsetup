#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# agent.sh — the boundary a control panel talks to.
#
# The web UI must not run as root and must not touch the Docker socket: either
# one gives a web page full control of the host. So the privileged side is a
# unix socket owned by the `vpnsetup` group, and behind it sits exactly one
# command — `vpnsetup rpc` — which reads a single JSON request and writes a
# single JSON response.
#
#   {"method":"install","params":{"panel":"3x-ui","domain":"p.example.com"}}
#   {"schema_version":1,"ok":true,"exit_code":0,"result":{...}}
#
# Transport is systemd socket activation (Accept=yes): no daemon of our own, no
# socat dependency, and every request gets a clean process. Access control is the
# socket's file mode — add the web user to the `vpnsetup` group and nothing else.
#
# jq is required, but only on this path: `rpc` is the one place that has to
# *parse* JSON, and hand-rolling that in bash would be a liability. Every other
# command only emits it.
# ──────────────────────────────────────────────────────────────────────────────

readonly AGENT_SOCKET="${VPN_SETUP_AGENT_SOCKET:-/run/vpnsetup/agent.sock}"
readonly AGENT_GROUP="${VPN_SETUP_AGENT_GROUP:-vpnsetup}"
readonly AGENT_SOCKET_UNIT="/etc/systemd/system/vpnsetup-agent.socket"
readonly AGENT_SERVICE_UNIT="/etc/systemd/system/vpnsetup-agent@.service"
readonly AGENT_TMPFILES="/etc/tmpfiles.d/vpnsetup-agent.conf"

# ──────────────────────────────────────────────────────────────────────────────
# Response helpers — usable even when jq is missing, since they only emit.
# ──────────────────────────────────────────────────────────────────────────────
_rpc_respond() {
  local ok="$1" code="$2" method="$3" result="$4" error="$5"
  json_emit \
    "$(json_pair ok "$(json_bool "$ok")")" \
    "$(json_pair exit_code "$(json_num "$code")")" \
    "$(json_pair method "$(json_nullable_str "$method")")" \
    "$(json_pair result "${result:-null}")" \
    "$(json_pair error "$(json_nullable_str "$error")")"
}

_rpc_fail() {
  local code="$1" method="$2" msg="$3"
  _rpc_respond 0 "$code" "$method" "null" "$msg"
  return "$code"
}

# ──────────────────────────────────────────────────────────────────────────────
# Request → command line
# ──────────────────────────────────────────────────────────────────────────────
# Method names are deliberately the same words as the CLI commands, with a dot
# where the CLI takes a subcommand. A control panel author should be able to
# guess the RPC surface from `vpnsetup help`.
_rpc_build_args() {
  local method="$1"
  local panel domain sub port allow name upstream alt archive service tail list

  panel="$(_rpc_param panel)"
  domain="$(_rpc_param domain)"
  sub="$(_rpc_param sub_domain)"
  port="$(_rpc_param port)"
  allow="$(_rpc_param allow_ips)"
  name="$(_rpc_param name)"
  upstream="$(_rpc_param upstream)"
  alt="$(_rpc_param alt_domain)"
  archive="$(_rpc_param archive)"
  service="$(_rpc_param service)"
  tail="$(_rpc_param tail)"
  list="$(_rpc_param list)"

  RPC_ARGS=()
  case "$method" in
    version) RPC_ARGS=(version) ;;
    status)  RPC_ARGS=(status) ;;
    panels)  RPC_ARGS=(panels) ;;
    sites)   RPC_ARGS=(sites) ;;
    jobs)    RPC_ARGS=(jobs) ;;
    doctor)  RPC_ARGS=(doctor) ;;

    job)
      [ -n "$panel" ] || panel="$(_rpc_param id)"
      RPC_ARGS=(job "$panel") ;;

    install)
      [ -n "$panel" ] || return "$EX_USAGE"
      [ -n "$domain" ] || return "$EX_USAGE"
      RPC_ARGS=(install "$panel" --domain "$domain")
      [ -n "$sub" ]   && RPC_ARGS+=(--sub-domain "$sub")
      [ -n "$port" ]  && RPC_ARGS+=(--port "$port")
      [ -n "$allow" ] && RPC_ARGS+=(--allow-ips "$allow")
      ;;

    update)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(update "$panel") ;;

    remove)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(remove "$panel") ;;

    backup)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(backup "$panel") ;;

    backups)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(backup list "$panel") ;;

    restore)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(restore "$panel")
      [ -n "$archive" ] && RPC_ARGS+=("$archive")
      ;;

    domain)
      [ -n "$panel" ] && [ -n "$domain" ] || return "$EX_USAGE"
      RPC_ARGS=(domain "$panel" "$domain") ;;

    allow-ips)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(allow-ips "$panel" "$list") ;;

    proxy)
      RPC_ARGS=(proxy)
      [ -n "$panel" ] && RPC_ARGS+=("$panel")
      ;;

    logs)
      [ -n "$panel" ] || return "$EX_USAGE"
      RPC_ARGS=(logs "$panel")
      [ -n "$service" ] && RPC_ARGS+=("$service")
      # A control panel never wants a stream that blocks forever.
      RPC_ARGS+=(--no-follow)
      [ -n "$tail" ] && RPC_ARGS+=(--tail "$tail")
      ;;

    site.add|site_add)
      [ -n "$name" ] && [ -n "$domain" ] && [ -n "$upstream" ] || return "$EX_USAGE"
      RPC_ARGS=(site add "$name" --domain "$domain" --upstream "$upstream")
      [ -n "$alt" ]   && RPC_ARGS+=(--alt-domain "$alt")
      [ -n "$allow" ] && RPC_ARGS+=(--allow-ips "$allow")
      ;;

    site.remove|site_remove)
      [ -n "$name" ] || return "$EX_USAGE"
      RPC_ARGS=(site remove "$name") ;;

    *)
      return "$EX_USAGE" ;;
  esac
  return 0
}

# _rpc_param <key> — read a string out of the flattened params table.
_rpc_param() {
  local key="$1" line
  [ -n "${RPC_PARAMS:-}" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<<"$RPC_PARAMS"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# rpc — one request on stdin, one response on stdout.
# ──────────────────────────────────────────────────────────────────────────────
cmd_rpc() {
  local line=""
  IFS= read -r line || true

  if [ -z "$line" ]; then
    _rpc_fail "$EX_USAGE" "" "Empty request."
    return "$EX_USAGE"
  fi

  if ! have_cmd jq; then
    log_info "Installing jq (needed to parse requests)..."
    pkg_refresh >/dev/null 2>&1 || true
    pkg_install jq >/dev/null 2>&1 || true
  fi
  if ! have_cmd jq; then
    _rpc_fail "$EX_PRECOND" "" "jq is required by the rpc endpoint and could not be installed."
    return "$EX_PRECOND"
  fi

  local method
  method="$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null)"
  if [ -z "$method" ]; then
    _rpc_fail "$EX_USAGE" "" "The request has no \"method\" field."
    return "$EX_USAGE"
  fi

  # Flatten params once rather than shelling out to jq per field.
  RPC_PARAMS="$(printf '%s' "$line" | jq -r '(.params // {}) | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null || true)"

  audit_write "rpc" "$method"

  RPC_ARGS=()
  if ! _rpc_build_args "$method"; then
    _rpc_fail "$EX_USAGE" "$method" "Unknown method or missing required parameters: $method"
    return "$EX_USAGE"
  fi

  # Every RPC answer is JSON, and a control panel has no terminal to confirm at.
  OPT_JSON=1
  export NO_COLOR=1
  if [ "$(_rpc_param yes)" = "true" ]; then OPT_YES=1; else OPT_YES=0; fi
  OPT_NONINTERACTIVE=1

  # The command runs in a subshell on purpose: `die` calls exit, and without
  # this the whole endpoint would die mid-request instead of answering.
  local errfile="$JOBS_DIR/rpc.$$.err" out rc err
  mkdir -p "$JOBS_DIR" 2>/dev/null || true

  out="$(vpnsetup_main ${RPC_ARGS[@]+"${RPC_ARGS[@]}"} 2>"$errfile")"
  rc=$?
  err="$(tail -c 1000 "$errfile" 2>/dev/null | tr -d '\r')"
  rm -f "$errfile" 2>/dev/null || true

  # If the command produced a JSON document, embed it as-is; otherwise pass the
  # text through as a string so nothing is silently lost.
  local result="null"
  if [ -n "$out" ]; then
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      result="$out"
    else
      result="$(json_str "$out")"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    _rpc_respond 1 0 "$method" "$result" ""
  else
    _rpc_respond 0 "$rc" "$method" "$result" "$err"
  fi
  return "$rc"
}

# ──────────────────────────────────────────────────────────────────────────────
# agent install / uninstall / status
# ──────────────────────────────────────────────────────────────────────────────
_agent_unit_socket() {
  cat <<UNIT
[Unit]
Description=vpnsetup agent socket

[Socket]
ListenStream=$AGENT_SOCKET
SocketMode=0660
SocketGroup=$AGENT_GROUP
RemoveOnStop=yes

[Install]
WantedBy=sockets.target
UNIT
}

_agent_unit_service() {
  cat <<UNIT
[Unit]
Description=vpnsetup agent request
After=vpnsetup-agent.socket

[Service]
Type=oneshot
StandardInput=socket
StandardOutput=socket
ExecStart=/usr/local/bin/vpnsetup rpc
UNIT
}

cmd_agent() {
  local action="${1:-status}"

  case "$action" in
    status)    _agent_status ;;
    install)   _agent_install ;;
    uninstall|remove) _agent_uninstall ;;
    run)
      # Foreground mode, for debugging without systemd.
      exec /usr/local/bin/vpnsetup rpc
      ;;
    *)
      log_error "Usage: vpnsetup agent install|uninstall|status"
      return "$EX_USAGE"
      ;;
  esac
}

_agent_status() {
  local installed=0 enabled=0 active=0 sock=0 group=0

  [ -f "$AGENT_SOCKET_UNIT" ] && [ -f "$AGENT_SERVICE_UNIT" ] && installed=1
  [ -S "$AGENT_SOCKET" ] && sock=1
  have_cmd getent && getent group "$AGENT_GROUP" >/dev/null 2>&1 && group=1
  if have_cmd systemctl; then
    systemctl is-enabled vpnsetup-agent.socket >/dev/null 2>&1 && enabled=1
    systemctl is-active vpnsetup-agent.socket >/dev/null 2>&1 && active=1
  fi

  if [ "$OPT_JSON" = "1" ]; then
    json_emit \
      "$(json_pair installed "$(json_bool "$installed")")" \
      "$(json_pair enabled "$(json_bool "$enabled")")" \
      "$(json_pair active "$(json_bool "$active")")" \
      "$(json_pair socket_exists "$(json_bool "$sock")")" \
      "$(json_pair socket "$(json_str "$AGENT_SOCKET")")" \
      "$(json_pair group "$(json_str "$AGENT_GROUP")")" \
      "$(json_pair group_exists "$(json_bool "$group")")" \
      "$(json_pair jq "$(json_bool "$(have_cmd jq && printf 1 || printf 0)")")"
    return 0
  fi

  ui_title "Agent"
  ui_kv "Units" "$([ "$installed" = "1" ] && printf 'installed' || printf 'not installed')"
  ui_kv "Enabled" "$([ "$enabled" = "1" ] && printf yes || printf no)"
  ui_kv "Active" "$([ "$active" = "1" ] && printf yes || printf no)"
  ui_kv "Socket" "$AGENT_SOCKET $([ "$sock" = "1" ] && printf '(present)' || printf '(missing)')"
  ui_kv "Group" "$AGENT_GROUP $([ "$group" = "1" ] && printf '(exists)' || printf '(missing)')"
  printf '\n'
  log_dim "  Add a web user:  usermod -aG $AGENT_GROUP <user>"
  log_dim "  Smoke test it:   echo '{\"method\":\"version\"}' | sudo vpnsetup rpc"

  [ "$installed" = "1" ] || return "$EX_NOTFOUND"
  return 0
}

_agent_install() {
  require_root

  if ! have_cmd systemctl; then
    log_error "systemd is required for the agent (socket activation)."
    return "$EX_PRECOND"
  fi

  # A dedicated group is the whole access-control story: root owns the socket,
  # the group can talk to it, and the web UI needs no other privilege.
  if ! getent group "$AGENT_GROUP" >/dev/null 2>&1; then
    groupadd --system "$AGENT_GROUP" || { log_error "Could not create the group $AGENT_GROUP."; return "$EX_FAIL"; }
    log_ok "Created group $AGENT_GROUP"
  fi

  # /run is a tmpfs, so the directory has to be recreated on every boot.
  printf 'd %s 0750 root %s -\n' "$(dirname "$AGENT_SOCKET")" "$AGENT_GROUP" >"$AGENT_TMPFILES"
  mkdir -p "$(dirname "$AGENT_SOCKET")"
  chown "root:$AGENT_GROUP" "$(dirname "$AGENT_SOCKET")"
  chmod 0750 "$(dirname "$AGENT_SOCKET")"
  systemd-tmpfiles --create "$AGENT_TMPFILES" >/dev/null 2>&1 || true

  _agent_unit_socket >"$AGENT_SOCKET_UNIT"
  _agent_unit_service >"$AGENT_SERVICE_UNIT"

  systemctl daemon-reload || { log_error "systemctl daemon-reload failed."; return "$EX_FAIL"; }
  systemctl enable vpnsetup-agent.socket >/dev/null 2>&1 || true
  if ! systemctl restart vpnsetup-agent.socket; then
    log_error "Could not start vpnsetup-agent.socket."
    return "$EX_FAIL"
  fi

  log_ok "Agent socket is listening on $AGENT_SOCKET"
  printf '\n'
  log_dim "  Grant access:  usermod -aG $AGENT_GROUP <web-user>"
  log_dim "  Test it:       echo '{\"method\":\"status\"}' | sudo vpnsetup rpc"

  if [ "$OPT_JSON" = "1" ]; then
    json_emit \
      "$(json_pair installed true)" \
      "$(json_pair socket "$(json_str "$AGENT_SOCKET")")" \
      "$(json_pair group "$(json_str "$AGENT_GROUP")")"
  fi
  return 0
}

_agent_uninstall() {
  require_root

  if have_cmd systemctl; then
    systemctl disable --now vpnsetup-agent.socket >/dev/null 2>&1 || true
  fi

  rm -f "$AGENT_SOCKET_UNIT" "$AGENT_SERVICE_UNIT" "$AGENT_TMPFILES"
  rm -f "$AGENT_SOCKET" 2>/dev/null || true
  have_cmd systemctl && systemctl daemon-reload >/dev/null 2>&1 || true

  log_ok "Agent removed. The group $AGENT_GROUP was left in place."

  if [ "$OPT_JSON" = "1" ]; then
    json_emit "$(json_pair installed false)"
  fi
  return 0
}
