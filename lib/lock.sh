#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# lock.sh — exclusive locks.
#
# Without these, the CLI and a control panel hitting the same server at the same
# time can lose each other's writes: two `state_set` calls do a read-modify-write
# of the same file, and two installs of the same panel both create directories.
#
# Two implementations behind one API — flock when it exists (util-linux, busybox),
# otherwise mkdir, which is atomic on every POSIX filesystem. A lock is held by
# the *current shell*, so lock_take must NOT be called inside a subshell or a
# command substitution: the lock would be released the moment it exits.
# ──────────────────────────────────────────────────────────────────────────────

LOCK_NAMES=()
LOCK_FDS=()

# lock_take <name> [timeout_seconds]
lock_take() {
  local name="$1" timeout="${2:-${VPN_SETUP_LOCK_TIMEOUT:-30}}"
  local path="$LOCK_DIR/$name.lock" fd

  mkdir -p "$LOCK_DIR" 2>/dev/null || true

  if ! have_cmd flock; then
    _lock_take_mkdir "$name" "$timeout" || return 1
    LOCK_NAMES+=("$name")
    return 0
  fi

  # Two descriptors is the whole depth this program needs: a per-panel operation
  # lock, and a short state lock taken inside it.
  case "${#LOCK_FDS[@]}" in
    0) fd=9 ;;
    1) fd=8 ;;
    *) log_error "Internal error: too many nested locks."; return 1 ;;
  esac

  eval "exec $fd>>\"\$path\"" 2>/dev/null || {
    log_error "Could not open the lock file $path"
    return 1
  }

  if ! flock -w "$timeout" "$fd" 2>/dev/null; then
    eval "exec $fd>&-"
    log_error "Another vpnsetup operation holds the '$name' lock."
    log_dim "  Wait for it to finish. If nothing is running, delete $path."
    return 1
  fi

  LOCK_FDS+=("$fd")
  LOCK_NAMES+=("$name")
  return 0
}

# lock_release — release the most recently taken lock.
lock_release() {
  local n="${#LOCK_NAMES[@]}"
  [ "$n" -gt 0 ] || return 0

  # Two statements, not one: bash expands every word of a command before the
  # builtin runs, so `local idx=... name="${LOCK_NAMES[$idx]}"` would evaluate
  # the subscript while idx is still unbound.
  local idx=$((n - 1))
  local name="${LOCK_NAMES[$idx]}"

  if have_cmd flock; then
    local fd="${LOCK_FDS[$idx]:-9}"
    flock -u "$fd" 2>/dev/null || true
    eval "exec $fd>&-" 2>/dev/null || true
  else
    _lock_drop_mkdir "$name"
  fi

  # Truncate both stacks rather than `unset 'arr[idx]'`: an arithmetic subscript
  # under `set -u` is one more thing that can fail in a way nobody expects.
  if [ "$idx" -gt 0 ]; then
    LOCK_NAMES=("${LOCK_NAMES[@]:0:$idx}")
    LOCK_FDS=("${LOCK_FDS[@]:0:$idx}")
  else
    LOCK_NAMES=()
    LOCK_FDS=()
  fi
  return 0
}

lock_release_all() {
  while [ "${#LOCK_NAMES[@]}" -gt 0 ]; do lock_release; done
}

# lock_held <name> — true when this shell already holds that lock. Used to make
# lock acquisition idempotent: taking the same lock twice on two descriptors
# would deadlock against itself, since flock conflicts per open file description
# even within one process.
lock_held() {
  local n
  [ "${#LOCK_NAMES[@]}" -gt 0 ] || return 1
  for n in "${LOCK_NAMES[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# lock_take_once <name> [timeout] — take the lock unless it is already held.
lock_take_once() {
  lock_held "$1" && return 0
  lock_take "$@"
}

# _lock_drop_mkdir <name> — remove a fallback lock.
#
# rmdir rather than `rm -rf`: it only removes an empty directory, so a lock that
# somehow contains something else is left alone instead of being destroyed.
_lock_drop_mkdir() {
  local dir="$LOCK_DIR/$1.lock.d"
  rm -f "$dir/pid" 2>/dev/null || true
  rmdir "$dir" 2>/dev/null || true
}

# _lock_take_mkdir — fallback for systems without flock. mkdir(2) is atomic, so
# the winner of the race is decided by the kernel. A lock whose owner is gone is
# broken rather than blocking forever — but only a bounded number of times: if
# the directory cannot actually be removed (a stale handle, a read-only mount),
# retrying forever would hang the command with no output at all.
_lock_take_mkdir() {
  local name="$1" timeout="${2:-30}" dir="$LOCK_DIR/$name.lock.d" waited=0 owner
  local breaks=0 stale

  while ! mkdir "$dir" 2>/dev/null; do
    stale=0
    owner="$(cat "$dir/pid" 2>/dev/null || true)"

    if [ -n "$owner" ]; then
      kill -0 "$owner" 2>/dev/null || stale=1
    elif [ "$waited" -ge 3 ]; then
      # No pid recorded. Either the holder died between mkdir and the pid write,
      # or something else created the directory; neither is a lock.
      stale=1
    fi

    if [ "$stale" = "1" ] && [ "$breaks" -lt 3 ]; then
      breaks=$((breaks + 1))
      log_warn "Breaking a stale lock ('$name'${owner:+, pid $owner is gone})."
      _lock_drop_mkdir "$name"
      [ -d "$dir" ] && sleep 1
      continue
    fi

    if [ "$waited" -ge "$timeout" ]; then
      log_error "Another vpnsetup operation holds the '$name' lock."
      log_dim "  Wait for it to finish. If nothing is running, delete $dir."
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
  return 0
}

# lock_run <name> <command...> — convenience for a short critical section.
lock_run() {
  local name="$1"; shift
  lock_take "$name" || return 1
  "$@"; local rc=$?
  lock_release
  return "$rc"
}
