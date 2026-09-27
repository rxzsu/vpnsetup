#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# backup.sh — generic backup/restore driven by the panel state file.
#
# Every panel records how it wants to be backed up:
#   BACKUP_KIND=sqlite|postgres|files
#   BACKUP_SQLITE=/path/to/db.sqlite          (sqlite)
#   BACKUP_SERVICE=<compose service>          (sqlite, stopped around the copy)
#   BACKUP_PG_SERVICE / _USER / _DB           (postgres)
#   BACKUP_FILES=/path/a,/path/b              (config, always included)
#
# Everything lands in a single timestamped archive:
#   $BACKUP_DIR/<id>/<id>-<timestamp>.tar.gz
# ──────────────────────────────────────────────────────────────────────────────

readonly BACKUP_KEEP="${VPN_SETUP_BACKUP_KEEP:-10}"

backup_dir_for() { printf '%s/%s' "$BACKUP_DIR" "$1"; }

# Size and mtime without assuming GNU stat: `stat -c` exists in coreutils and
# busybox, but the fallbacks cost nothing and keep this honest.
_file_size() {
  local n
  n="$(stat -c '%s' "$1" 2>/dev/null || true)"
  [ -n "$n" ] || n="$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
  printf '%s' "${n:-0}"
}

_file_mtime() {
  local n
  n="$(stat -c '%Y' "$1" 2>/dev/null || true)"
  [ -n "$n" ] || n="$(date -r "$1" +%s 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

_human_size() {
  local bytes="${1:-0}"
  if [ "$bytes" -ge 1073741824 ]; then
    printf '%s.%sG' "$((bytes / 1073741824))" "$(((bytes % 1073741824) / 107374182))"
  elif [ "$bytes" -ge 1048576 ]; then
    printf '%s.%sM' "$((bytes / 1048576))" "$(((bytes % 1048576) / 104857))"
  elif [ "$bytes" -ge 1024 ]; then
    printf '%sK' "$((bytes / 1024))"
  else
    printf '%sB' "$bytes"
  fi
}

backup_check_space() {
  local dir="$1" need_mb="${2:-200}" avail
  mkdir -p "$dir"
  avail="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail" ] && [ "$avail" -lt "$need_mb" ]; then
    log_error "Only ${avail} MB free in $dir — need at least ${need_mb} MB."
    return 1
  fi
  return 0
}

# backup_create <id>
backup_create() {
  local id="$1"
  state_exists "$id" || die "Panel '$id' is not installed."

  local name dir ts stage archive kind
  name="$(panel_catalog_name "$id")"
  dir="$(backup_dir_for "$id")"
  ts="$(date +%Y%m%d_%H%M%S)"
  archive="$dir/${id}-${ts}.tar.gz"
  stage="$(mktemp -d)"
  kind="$(state_get "$id" BACKUP_KIND 'files')"
  local install_dir; install_dir="$(state_get "$id" INSTALL_DIR)"

  backup_check_space "$dir" 200 || { rm -rf "$stage"; return 1; }

  log_step "Backing up $name"

  printf 'id=%s\nname=%s\ncreated=%s\nversion=%s\nkind=%s\n' \
    "$id" "$name" "$(date -Is)" "$VPN_SETUP_VERSION" "$kind" > "$stage/MANIFEST"

  # ── config files (always) ──────────────────────────────────────────────────
  local files_csv path
  files_csv="$(state_get "$id" BACKUP_FILES)"
  if [ -n "$files_csv" ]; then
    mkdir -p "$stage/config"
    local IFS=','
    for path in $files_csv; do
      [ -e "$path" ] || continue
      cp -a "$path" "$stage/config/" 2>/dev/null && log_dim "  + config $path"
    done
    unset IFS
  fi

  # ── payload ────────────────────────────────────────────────────────────────
  case "$kind" in
    sqlite)
      local sqlite_path service
      sqlite_path="$(state_get "$id" BACKUP_SQLITE)"
      service="$(state_get "$id" BACKUP_SERVICE)"
      [ -n "$sqlite_path" ] || { log_error "BACKUP_SQLITE is not set for $id"; rm -rf "$stage"; return 1; }

      # A live SQLite file can be copied mid-write and end up corrupt, so the
      # owning service is stopped for the duration of the copy.
      if [ -n "$service" ] && compose_service_running "$install_dir" "$service"; then
        log_info "Stopping $service for a consistent copy..."
        dc "$install_dir" stop "$service" >/dev/null 2>&1 || true
      fi
      if [ -f "$sqlite_path" ]; then
        mkdir -p "$stage/db"
        cp -a "$sqlite_path" "$stage/db/" || { log_error "Copy failed"; rm -rf "$stage"; return 1; }
        log_dim "  + db $sqlite_path"
      else
        log_warn "SQLite database not found at $sqlite_path — skipping."
      fi
      if [ -n "$service" ]; then
        dc "$install_dir" start "$service" >/dev/null 2>&1 || true
      fi
      ;;

    postgres)
      local service user db cid
      service="$(state_get "$id" BACKUP_PG_SERVICE)"
      user="$(state_get "$id" BACKUP_PG_USER)"
      db="$(state_get "$id" BACKUP_PG_DB)"
      cid="$(compose_container_id "$install_dir" "$service")"
      if [ -z "$cid" ]; then
        log_error "Postgres service '$service' is not running — cannot dump."
        rm -rf "$stage"; return 1
      fi
      log_info "Dumping PostgreSQL ($db)..."
      set -o pipefail
      if docker exec "$cid" pg_dump -U "$user" -d "$db" 2>/dev/null | gzip > "$stage/db.sql.gz"; then
        log_dim "  + db $db"
      else
        log_error "pg_dump failed."
        set +o pipefail
        rm -rf "$stage"; return 1
      fi
      set +o pipefail
      ;;

    files)
      log_dim "  (config-only backup)"
      ;;

    *)
      log_error "Unknown BACKUP_KIND: $kind"
      rm -rf "$stage"; return 1
      ;;
  esac

  # ── pack ───────────────────────────────────────────────────────────────────
  if ! tar -czf "$archive" -C "$stage" .; then
    log_error "Could not create the archive."
    rm -rf "$stage"; return 1
  fi

  # Verify before trusting it: an archive that cannot be listed is an archive
  # that cannot be restored, and discovering that during a restore is too late.
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    log_error "The archive failed its integrity check — removing it."
    rm -f "$archive"
    rm -rf "$stage"
    return 1
  fi

  chmod 600 "$archive"
  rm -rf "$stage"

  log_ok "Backup written: $archive ($(du -h "$archive" 2>/dev/null | cut -f1))"
  backup_prune "$id"
}

backup_prune() {
  local id="$1" dir count
  dir="$(backup_dir_for "$id")"
  count="$(ls -1 "$dir"/"$id"-*.tar.gz 2>/dev/null | wc -l)"
  if [ "$count" -gt "$BACKUP_KEEP" ]; then
    # Oldest first, delete everything beyond the keep limit.
    ls -1t "$dir"/"$id"-*.tar.gz 2>/dev/null | tail -n "+$((BACKUP_KEEP + 1))" | while read -r f; do
      rm -f "$f" && log_dim "  pruned $(basename "$f")"
    done
  fi
}

# backup_list <id> — newest first
backup_list() {
  local id="$1" dir
  dir="$(backup_dir_for "$id")"
  [ -d "$dir" ] || return 1
  ls -1t "$dir"/"$id"-*.tar.gz 2>/dev/null
}

# backup_restore <id> [archive]
backup_restore() {
  local id="$1" archive="${2:-}"
  state_exists "$id" || die "Panel '$id' is not installed."

  if [ -z "$archive" ]; then
    local files=()
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(backup_list "$id")
    if [ "${#files[@]}" -eq 0 ]; then
      log_error "No backups found for $id in $(backup_dir_for "$id")"
      return 1
    fi
    printf '\n%sAvailable backups:%s\n' "$C_BOLD" "$C_RESET"
    local i=1 f
    for f in "${files[@]}"; do
      printf '  %s%d)%s %s %s(%s)%s\n' "$C_BBLUE" "$i" "$C_RESET" \
        "$(basename "$f")" "$C_DIM" "$(du -h "$f" 2>/dev/null | cut -f1)" "$C_RESET"
      i=$((i + 1))
    done
    printf '\n'
    local choice; choice="$(ask "Which backup (number, Enter = latest)" "1")"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
      log_warn "Cancelled."; return 1
    fi
    archive="${files[$((choice - 1))]}"
  fi

  [ -f "$archive" ] || die "Archive not found: $archive"

  log_warn "Restoring will OVERWRITE the current data of $(panel_catalog_name "$id")."
  confirm "Continue?" "n" || { log_info "Cancelled."; return 0; }

  local stage; stage="$(mktemp -d)"
  tar -xzf "$archive" -C "$stage" || { log_error "Could not read the archive."; rm -rf "$stage"; return 1; }

  local kind; kind="$(state_get "$id" BACKUP_KIND 'files')"
  local install_dir; install_dir="$(state_get "$id" INSTALL_DIR)"

  case "$kind" in
    sqlite)
      local target; target="$(state_get "$id" BACKUP_SQLITE)"
      local src; src="$(find "$stage/db" -type f 2>/dev/null | head -1)"
      [ -n "$src" ] || { log_error "No database found in the archive."; rm -rf "$stage"; return 1; }
      log_info "Stopping the panel before restoring the database..."
      dc "$install_dir" stop >/dev/null 2>&1 || true
      cp -a "$src" "$target" || { log_error "Restore failed."; rm -rf "$stage"; return 1; }
      dc "$install_dir" start >/dev/null 2>&1 || true
      log_ok "Database restored."
      ;;

    postgres)
      local service user db cid app
      service="$(state_get "$id" BACKUP_PG_SERVICE)"
      user="$(state_get "$id" BACKUP_PG_USER)"
      db="$(state_get "$id" BACKUP_PG_DB)"
      app="$(state_get "$id" SERVICE)"
      [ -f "$stage/db.sql.gz" ] || { log_error "No dump in the archive."; rm -rf "$stage"; return 1; }
      cid="$(compose_container_id "$install_dir" "$service")"
      [ -n "$cid" ] || die "Postgres service '$service' is not running."

      # Restoring under a running application means competing with live
      # connections and half-applied migrations, so the app is taken down first
      # and brought back only after the dump has landed.
      if [ -n "$app" ] && [ "$app" != "$service" ]; then
        log_info "Stopping $app before restoring..."
        dc "$install_dir" stop "$app" >/dev/null 2>&1 || true
      fi

      log_info "Restoring PostgreSQL ($db)..."
      set -o pipefail
      if gunzip -c "$stage/db.sql.gz" | docker exec -i "$cid" psql -U "$user" -d "$db" >/dev/null 2>&1; then
        log_ok "Database restored."
      else
        set +o pipefail
        log_error "Restore failed."
        if [ -n "$app" ]; then dc "$install_dir" start "$app" >/dev/null 2>&1 || true; fi
        rm -rf "$stage"
        return 1
      fi
      set +o pipefail

      if [ -n "$app" ] && [ "$app" != "$service" ]; then
        log_info "Starting $app..."
        if ! dc "$install_dir" up -d "$app" >/dev/null 2>&1; then
          log_warn "Could not start $app — run 'vpnsetup update $id' or check its logs."
        fi
      fi
      ;;

    files) log_dim "Config-only backup — nothing to restore into a database." ;;
  esac

  # Restore config files over the top of the live ones.
  if [ -d "$stage/config" ]; then
    local f base dest
    for f in "$stage"/config/*; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      dest="$(state_get "$id" INSTALL_DIR)/$base"
      cp -a "$f" "$dest" 2>/dev/null && log_dim "  restored $dest"
    done
  fi

  rm -rf "$stage"
  log_ok "Restore complete."
}
