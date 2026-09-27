#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# job.sh — the event stream behind long-running operations.
#
# Every log line is also appended to an NDJSON file when a job is active, so a
# control panel can start an install, hand the user a job id, and poll for
# progress instead of scraping a terminal. The same file is what makes
# `--detach` useful from a plain SSH session.
#
# Record shape (one JSON object per line, append-only):
#   {"ts":1758900000,"event":"start","pid":1234,"label":"install 3x-ui"}
#   {"ts":1758900001,"event":"log","level":"info","msg":"..."}
#   {"ts":1758900042,"event":"done","code":0}
# ──────────────────────────────────────────────────────────────────────────────

# job_emit <level> <message...> — called by every log_* function.
job_emit() {
  local level="$1"; shift
  [ -n "${VPN_SETUP_JOB_FILE:-}" ] || return 0
  printf '{"ts":%s,"event":"log","level":"%s","msg":"%s"}\n' \
    "$(date +%s)" "$level" "$(json_escape "$*")" >>"$VPN_SETUP_JOB_FILE" 2>/dev/null || true
  return 0
}

# job_mark <event> [message] — a lifecycle marker rather than a log line.
job_mark() {
  local event="$1" msg="${2:-}"
  [ -n "${VPN_SETUP_JOB_FILE:-}" ] || return 0
  printf '{"ts":%s,"event":"%s","msg":"%s"}\n' \
    "$(date +%s)" "$event" "$(json_escape "$msg")" >>"$VPN_SETUP_JOB_FILE" 2>/dev/null || true
  return 0
}

# job_start <label> — open a job file. Honours an id passed in through the
# environment so a detached child writes into the file its parent announced.
job_start() {
  local label="${1:-vpnsetup}"
  local inherited=0
  [ -n "${VPN_SETUP_JOB_FILE:-}" ] && inherited=1

  mkdir -p "$JOBS_DIR" 2>/dev/null || true

  VPN_SETUP_JOB_ID="${VPN_SETUP_JOB_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
  VPN_SETUP_JOB_FILE="$JOBS_DIR/$VPN_SETUP_JOB_ID.ndjson"
  export VPN_SETUP_JOB_ID VPN_SETUP_JOB_FILE

  local line
  line="$(printf '{"ts":%s,"event":"start","pid":%s,"label":"%s"}' \
    "$(date +%s)" "$$" "$(json_escape "$label")")"

  if [ "$inherited" = "1" ]; then
    # The parent already created the file and announced it; append so its
    # record of the pid survives next to ours.
    printf '%s\n' "$line" >>"$VPN_SETUP_JOB_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$line" >"$VPN_SETUP_JOB_FILE" 2>/dev/null || true
    printf '%s\n' "$label" >"$JOBS_DIR/$VPN_SETUP_JOB_ID.label" 2>/dev/null || true
    chmod 600 "$JOBS_DIR/$VPN_SETUP_JOB_ID.label" 2>/dev/null || true
  fi

  chmod 600 "$VPN_SETUP_JOB_FILE" 2>/dev/null || true
  job_prune "${VPN_SETUP_JOBS_KEEP:-50}"
  return 0
}

# job_finish <exit_code> — close the job. Wired to an EXIT trap so a `die`
# halfway through still leaves a terminal record behind.
job_finish() {
  local code="${1:-0}"
  [ -n "${VPN_SETUP_JOB_FILE:-}" ] || return 0
  [ -f "$VPN_SETUP_JOB_FILE" ] || return 0

  local event="done"
  [ "$code" = "0" ] || event="fail"

  printf '{"ts":%s,"event":"%s","code":%s}\n' \
    "$(date +%s)" "$event" "$(json_num "$code")" >>"$VPN_SETUP_JOB_FILE" 2>/dev/null || true
  printf '%s\n' "$code" >"$JOBS_DIR/$VPN_SETUP_JOB_ID.status" 2>/dev/null || true
  chmod 600 "$JOBS_DIR/$VPN_SETUP_JOB_ID.status" 2>/dev/null || true
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Audit trail
# ──────────────────────────────────────────────────────────────────────────────
# audit_write <action> [detail...] — one tab-separated line per mutating command.
# This is the activity feed a control panel shows, and the answer to "who
# changed that domain at 3am".
audit_write() {
  local action="$1"; shift
  [ -n "${AUDIT_LOG:-}" ] || return 0
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  local who="${SUDO_USER:-}"
  [ -n "$who" ] || who="$(id -un 2>/dev/null || printf 'unknown')"
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$who" "$action" "$*" \
    >>"$AUDIT_LOG" 2>/dev/null || true
  chmod 600 "$AUDIT_LOG" 2>/dev/null || true
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Reading jobs back
# ──────────────────────────────────────────────────────────────────────────────
job_ids() {
  local f
  for f in "$JOBS_DIR"/*.ndjson; do
    [ -e "$f" ] || continue
    basename "$f" .ndjson
  done
}

# Newest first.
job_ids_newest() {
  local f
  for f in $(ls -1t "$JOBS_DIR"/*.ndjson 2>/dev/null); do
    basename "$f" .ndjson
  done
}

job_file() { printf '%s/%s.ndjson' "$JOBS_DIR" "$1"; }

job_label() { cat "$JOBS_DIR/$1.label" 2>/dev/null || true; }

# job_code <id> — the exit code, or an empty string while it is still running.
job_code() { cat "$JOBS_DIR/$1.status" 2>/dev/null || true; }

job_pid() {
  sed -n '1s/.*"pid":\([0-9]*\).*/\1/p' "$(job_file "$1")" 2>/dev/null | head -1
}

# job_running <id> — true only when the process is genuinely still alive, so a
# job killed by a reboot is not reported as running forever.
job_running() {
  local id="$1" pid
  [ -n "$(job_code "$id")" ] && return 1
  pid="$(job_pid "$id")"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

job_last_msg() {
  tail -1 "$(job_file "$1")" 2>/dev/null |
    sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' || true
}

job_prune() {
  local keep="${1:-50}" n=0 id
  for id in $(job_ids_newest); do
    n=$((n + 1))
    [ "$n" -gt "$keep" ] || continue
    rm -f "$(job_file "$id")" "$JOBS_DIR/$id.status" "$JOBS_DIR/$id.label" \
          "$JOBS_DIR/$id.out" 2>/dev/null || true
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Commands
# ──────────────────────────────────────────────────────────────────────────────
_job_json() {
  local id="$1" code state
  code="$(job_code "$id")"
  if [ -n "$code" ]; then
    [ "$code" = "0" ] && state="done" || state="failed"
  elif job_running "$id"; then
    state="running"
  else
    state="aborted"
  fi

  json_object \
    "$(json_pair id "$(json_str "$id")")" \
    "$(json_pair label "$(json_str "$(job_label "$id")")")" \
    "$(json_pair state "$(json_str "$state")")" \
    "$(json_pair exit_code "$(json_nullable_str "$code")")" \
    "$(json_pair pid "$(json_num "$(job_pid "$id")")")" \
    "$(json_pair last_message "$(json_str "$(job_last_msg "$id")")")" \
    "$(json_pair events "$(json_num "$(wc -l <"$(job_file "$id")" 2>/dev/null | tr -d ' ')")")"
}

cmd_jobs() {
  local ids items="" id
  ids="$(job_ids_newest)"

  if [ "${OPT_JSON:-0}" = "1" ]; then
    for id in $ids; do items="${items:+$items,}$(_job_json "$id")"; done
    json_emit "$(json_pair jobs "[$items]")"
    return 0
  fi

  if [ -z "$ids" ]; then
    log_warn "No jobs recorded yet."
    return 0
  fi

  ui_title "Jobs"
  local code state
  for id in $ids; do
    code="$(job_code "$id")"
    if [ -n "$code" ]; then
      [ "$code" = "0" ] && state="done" || state="failed ($code)"
    elif job_running "$id"; then
      state="running"
    else
      state="aborted"
    fi
    printf '  %s%-22s%s %-14s %s\n' "$C_BWHITE" "$id" "$C_RESET" "$state" \
      "$(job_label "$id")"
  done
}

cmd_job() {
  local id="${1:-}" tail_n="${2:-20}"
  if [ -z "$id" ]; then
    id="$(job_ids_newest | head -1)"
  fi
  [ -n "$id" ] || { log_error "No jobs recorded yet."; return "$EX_NOTFOUND"; }

  if [ ! -f "$(job_file "$id")" ]; then
    log_error "No such job: $id"
    return "$EX_NOTFOUND"
  fi

  if [ "${OPT_JSON:-0}" = "1" ]; then
    local items="" line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      items="${items:+$items,}$line"
    done < <(tail -n "$tail_n" "$(job_file "$id")" 2>/dev/null)
    json_emit "$(_job_json "$id")" "$(json_pair events "[$items]")"
    return 0
  fi

  ui_title "Job $id"
  ui_kv "Label" "$(job_label "$id")"
  if [ -n "$(job_code "$id")" ]; then
    ui_kv "Exit code" "$(job_code "$id")"
  elif job_running "$id"; then
    ui_kv "State" "running (pid $(job_pid "$id"))"
  else
    ui_kv "State" "aborted"
  fi
  printf '\n'
  tail -n "$tail_n" "$(job_file "$id")" 2>/dev/null |
    sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' |
    sed 's/^/  /' || true
}
