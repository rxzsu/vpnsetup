#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# ui.sh — banner, menus, interactive selection.
# Requires common.sh and panels.sh to be sourced first.
# ──────────────────────────────────────────────────────────────────────────────

ui_banner() {
  clear 2>/dev/null || true
  printf '\n'
  printf '%s┌──────────────────────────────────────────────────────────────┐%s\n' "$C_MAGENTA" "$C_RESET"
  printf '%s│%s  %sVPN Setup%s %s— multi-panel installer%s                      %s│%s\n' \
    "$C_MAGENTA" "$C_RESET" "$C_BOLD$C_BWHITE" "$C_RESET" "$C_DIM" "$C_RESET" "$C_MAGENTA" "$C_RESET"
  printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$C_MAGENTA" "$C_RESET"
  printf '   %sv%s%s  ·  %s\n' "$C_DIM" "$VPN_SETUP_VERSION" "$C_RESET" "$(detect_os)/$(detect_pm)"
  printf '\n'
}

ui_title() {
  local text="$1"
  printf '\n%s%s%s\n' "$C_BOLD$C_BCYAN" "$text" "$C_RESET"
  printf '%s%s%s\n' "$C_MAGENTA" "$(printf '─%.0s' $(seq 1 62))" "$C_RESET"
}

ui_kv() {
  printf '  %s%-16s%s %s\n' "$C_BWHITE" "$1" "$C_RESET" "$2"
}

# ──────────────────────────────────────────────────────────────────────────────
# Selection helpers
# ──────────────────────────────────────────────────────────────────────────────

# ui_select_installed <prompt> — prints the chosen panel id, or nothing if the
# user cancels. Returns 1 when there is nothing to choose from.
# VPN_SETUP_PANEL short-circuits the choice (non-interactive / CI).
ui_select_installed() {
  local prompt="${1:-Select panel}"

  if [ -n "${VPN_SETUP_PANEL:-}" ]; then
    printf '%s' "$VPN_SETUP_PANEL"; return 0
  fi

  local ids=()
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done < <(state_ids)

  [ "${#ids[@]}" -eq 0 ] && return 1
  if [ "${#ids[@]}" -eq 1 ]; then printf '%s' "${ids[0]}"; return 0; fi

  local i=1 id
  printf '\n' >&2
  for id in "${ids[@]}"; do
    printf '  %s%d)%s %-12s %s%s%s\n' "$C_BBLUE" "$i" "$C_RESET" \
      "$(panel_catalog_name "$id")" "$C_DIM" "$(state_get "$id" DOMAIN 'no domain')" "$C_RESET" >&2
    i=$((i + 1))
  done
  printf '\n' >&2

  local choice
  choice="$(ask "$prompt (number)" "1")"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ids[@]}" ]; then
    log_warn "Invalid choice."
    return 1
  fi
  printf '%s' "${ids[$((choice - 1))]}"
}

# ui_select_panel — prints the id of the panel to install.
ui_select_panel() {
  if [ -n "${VPN_SETUP_PANEL:-}" ]; then
    printf '%s' "$VPN_SETUP_PANEL"; return 0
  fi

  local ids=() id
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done < <(panel_catalog_ids)

  local i=1
  printf '\n'
  for id in "${ids[@]}"; do
    printf '  %s%d)%s %s%-12s%s %s\n' "$C_BBLUE" "$i" "$C_RESET" \
      "$C_BOLD$C_BWHITE" "$(panel_catalog_name "$id")" "$C_RESET" "$(panel_catalog_desc "$id")"
    i=$((i + 1))
  done
  printf '\n'

  local choice
  choice="$(ask "Which panel (number)" "1")"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ids[@]}" ]; then
    log_warn "Invalid choice."
    return 1
  fi
  printf '%s' "${ids[$((choice - 1))]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main menu
# ──────────────────────────────────────────────────────────────────────────────
ui_main_menu() {
  while true; do
    ui_banner
    local n; n="$(state_count)"
    if [ "$n" -gt 0 ]; then
      printf '%sInstalled panels:%s\n' "$C_BOLD" "$C_RESET"
      local id
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        printf '  %s•%s %-12s %s%s%s  %s%s%s\n' "$C_BGREEN" "$C_RESET" \
          "$(panel_catalog_name "$id")" "$C_BWHITE" "$(state_get "$id" DOMAIN '-')" "$C_RESET" \
          "$C_DIM" "port $(state_get "$id" PORT '-')" "$C_RESET"
      done < <(state_ids)
      printf '\n'
    fi

    printf '%sActions:%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s1)%s Install a panel\n'                       "$C_BBLUE" "$C_RESET"
    printf '  %s2)%s Show status\n'                           "$C_BBLUE" "$C_RESET"
    printf '  %s3)%s Show logs\n'                             "$C_BBLUE" "$C_RESET"
    printf '  %s4)%s Update a panel\n'                        "$C_BBLUE" "$C_RESET"
    printf '  %s5)%s Backup\n'                                "$C_BBLUE" "$C_RESET"
    printf '  %s6)%s Restore from backup\n'                   "$C_BBLUE" "$C_RESET"
    printf '  %s7)%s Re-apply reverse proxy + SSL\n'          "$C_BBLUE" "$C_RESET"
    printf '  %s8)%s Change a panel domain\n'                 "$C_BBLUE" "$C_RESET"
    printf '  %s9)%s Restrict access by IP\n'                 "$C_BBLUE" "$C_RESET"
    printf '  %sd)%s Run diagnostics  %s(doctor)%s\n'          "$C_BBLUE" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %sr)%s Remove a panel  %s(destructive)%s\n'      "$C_RED"   "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s0)%s Exit\n'                                  "$C_RED"   "$C_RESET"
    printf '\n'

    local choice; choice="$(ask "Choice" "0")"
    local id
    case "$choice" in
      1) id="$(ui_select_panel)" && cmd_install "$id"; press_any_key ;;
      2) cmd_status; press_any_key ;;
      3) id="$(ui_select_installed)" && cmd_logs "$id"; ;;
      4) id="$(ui_select_installed)" && cmd_update "$id"; press_any_key ;;
      5) id="$(ui_select_installed)" && cmd_backup "$id"; press_any_key ;;
      6) id="$(ui_select_installed)" && cmd_restore "$id"; press_any_key ;;
      7) id="$(ui_select_installed)" && cmd_proxy_reapply "$id"; press_any_key ;;
      8) id="$(ui_select_installed)" && cmd_set_domain "$id"; press_any_key ;;
      9) id="$(ui_select_installed)" && cmd_set_allow_ips "$id"; press_any_key ;;
      d) doctor_run; press_any_key ;;
      r) id="$(ui_select_installed)" && cmd_remove "$id"; press_any_key ;;
      0) printf '\n%sBye.%s\n\n' "$C_DIM" "$C_RESET"; exit 0 ;;
      *) log_warn "Invalid choice"; sleep 1 ;;
    esac
  done
}
