#!/usr/bin/env bash
# Smoke test for the pure logic in lib/. Runs on any bash; does not need root,
# Docker or Linux — it only exercises functions that touch strings and files.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A project-local temp dir rather than mktemp: on Windows/Git Bash mktemp hands
# back a path under the drive-letter temp root, which some sandboxes refuse to
# delete, producing failures that have nothing to do with the code.
TMP="$ROOT/.smoke-tmp"
rm -rf "$TMP"
mkdir -p "$TMP"
export VPN_SETUP_STATE="$TMP/state"
export VPN_SETUP_ROOT="$TMP/root"
export VPN_SETUP_BACKUP="$TMP/backup"
export VPN_SETUP_LOGS="$TMP/logs"

pass=0
fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %-46s %s\n' "$label" "$actual"
    pass=$((pass + 1))
  else
    printf '  FAIL %-46s expected=%s actual=%s\n' "$label" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/docker.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/proxy.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/backup.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/panels.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/doctor.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/main.sh"
for m in "$ROOT"/lib/panels/*.sh; do . "$m"; done

echo "secrets"
check "gen_hex 4 length"        "8"  "$(printf '%s' "$(gen_hex 4)" | wc -c | tr -d ' ')"
check "gen_hex 32 length"       "64" "$(printf '%s' "$(gen_hex 32)" | wc -c | tr -d ' ')"
check "gen_hex is hex"          "yes" "$(printf '%s' "$(gen_hex 8)" | grep -qE '^[0-9a-f]+$' && echo yes || echo no)"

echo "validation"
check "domain valid"            "yes" "$(is_valid_domain panel.example.com && echo yes || echo no)"
check "domain rejects scheme"   "no"  "$(is_valid_domain https://panel.example.com && echo yes || echo no)"
check "domain rejects port"     "no"  "$(is_valid_domain panel.example.com:443 && echo yes || echo no)"
check "domain rejects bare host" "no" "$(is_valid_domain localhost && echo yes || echo no)"
check "port 443 valid"          "yes" "$(is_valid_port 443 && echo yes || echo no)"
check "port 0 invalid"          "no"  "$(is_valid_port 0 && echo yes || echo no)"
check "port 70000 invalid"      "no"  "$(is_valid_port 70000 && echo yes || echo no)"
check "port abc invalid"        "no"  "$(is_valid_port abc && echo yes || echo no)"

echo "ids"
check "id_slug 3x-ui"           "3xui" "$(id_slug 3x-ui)"
check "id_slug marzban"         "marzban" "$(id_slug marzban)"

echo "catalog"
check "catalog size"            "3" "$(panel_catalog_ids | wc -l | tr -d ' ')"
check "name 3x-ui"              "3x-ui" "$(panel_catalog_name 3x-ui)"
check "name remnawave"          "Remnawave" "$(panel_catalog_name remnawave)"
check "license marzban"         "AGPL-3.0" "$(panel_catalog_license marzban)"
check "default port 3x-ui"      "2053" "$(panel_default_port 3x-ui)"
check "default port marzban"    "8000" "$(panel_default_port marzban)"
check "default port remnawave"  "3000" "$(panel_default_port remnawave)"

echo "panel modules"
for slug in 3xui marzban remnawave; do
  for fn in "panel_install_$slug" "panel_uninstall_$slug" "panel_update_$slug"; do
    check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
  done
done

echo "state"
state_write "3x-ui" "PANEL_NAME=3x-ui" "DOMAIN=panel.example.com" "PORT=2053"
check "state_exists"            "yes" "$(state_exists 3x-ui && echo yes || echo no)"
check "state_get DOMAIN"        "panel.example.com" "$(state_get 3x-ui DOMAIN)"
check "state_get missing default" "fallback" "$(state_get 3x-ui NOPE fallback)"
check "state_ids"               "3x-ui" "$(state_ids)"
check "state_count"             "1" "$(state_count)"
state_delete "3x-ui"
check "state_delete"            "no" "$(state_exists 3x-ui && echo yes || echo no)"
check "state_count after delete" "0" "$(state_count)"

echo "env_set"
ENVF="$TMP/.env"
printf 'UVICORN_HOST = "0.0.0.0"\nUVICORN_PORT = 8000\n# SUDO_USERNAME = "admin"\nDATABASE_URL="x"\n' > "$ENVF"
env_set "$ENVF" UVICORN_HOST "127.0.0.1"
env_set "$ENVF" UVICORN_PORT "9000"
env_set "$ENVF" SUDO_USERNAME "root"
env_set "$ENVF" NEW_KEY "brand-new"
check "replaces quoted value"   'UVICORN_HOST=127.0.0.1' "$(grep '^UVICORN_HOST' "$ENVF")"
check "replaces numeric value"  'UVICORN_PORT=9000' "$(grep '^UVICORN_PORT' "$ENVF")"
check "uncomments key"          'SUDO_USERNAME=root' "$(grep '^SUDO_USERNAME' "$ENVF")"
check "appends missing key"     'NEW_KEY=brand-new' "$(grep '^NEW_KEY' "$ENVF")"
check "no duplicate keys"       "1" "$(grep -c '^UVICORN_HOST' "$ENVF")"
env_set "$ENVF" SPACED "a b c"
check "quotes value with space" 'SPACED="a b c"' "$(grep '^SPACED' "$ENVF")"
env_set "$ENVF" URL "postgresql://u:p@h:5432/db"
check "plain url unquoted"      'URL=postgresql://u:p@h:5432/db' "$(grep '^URL' "$ENVF")"
env_set "$ENVF" UVICORN_HOST "127.0.0.1"
check "idempotent"              "1" "$(grep -c '^UVICORN_HOST' "$ENVF")"

echo "x-ui settings parsing"
SAMPLE="$(printf 'port: 2053\nwebBasePath: /abc123/\nusername: k7Xq\npassword: p@ss w0rd\n')"
check "parse port"              "2053"     "$(_x3ui_field '[Pp]ort' "$SAMPLE")"
check "parse webBasePath"       "/abc123/" "$(_x3ui_field '[Ww]eb[Bb]ase[Pp]ath' "$SAMPLE")"
check "parse username"          "k7Xq"     "$(_x3ui_field '[Uu]sername' "$SAMPLE")"
check "parse password w/ space" "p@ss w0rd" "$(_x3ui_field '[Pp]assword' "$SAMPLE")"
check "parse missing key"       ""         "$(_x3ui_field '[Nn]ope' "$SAMPLE")"

echo "caddyfile rendering"
mkdir -p "$VPN_SETUP_STATE/panels"
state_write "3x-ui" "PANEL_NAME=3x-ui" "DOMAIN=panel.example.com" "PORT=2053"
state_write "remnawave" "PANEL_NAME=Remnawave" "DOMAIN=rw.example.com" "PORT=3000" "SUB_DOMAIN=sub.example.com"
proxy_render
check "site 1 present"          "yes" "$(grep -q '^panel.example.com {' "$VPN_SETUP_ROOT/caddy/Caddyfile" && echo yes || echo no)"
check "site 2 present"          "yes" "$(grep -q '^rw.example.com {' "$VPN_SETUP_ROOT/caddy/Caddyfile" && echo yes || echo no)"
check "sub site present"        "yes" "$(grep -q '^sub.example.com {' "$VPN_SETUP_ROOT/caddy/Caddyfile" && echo yes || echo no)"
check "upstream port 2053"      "yes" "$(grep -q 'reverse_proxy 127.0.0.1:2053' "$VPN_SETUP_ROOT/caddy/Caddyfile" && echo yes || echo no)"
check "sub shares panel port"   "2"   "$(grep -c 'reverse_proxy 127.0.0.1:3000' "$VPN_SETUP_ROOT/caddy/Caddyfile")"

echo "port guards"
# Start from a clean slate: the previous section left two panels in the state,
# and a port guard that reads other panels must not see them.
rm -f "$VPN_SETUP_STATE/panels"/*.env
state_write "marzban" "PANEL_NAME=Marzban" "DOMAIN=m.example.com" "PORT=8000"
check "reserves 80"             "no"  "$(validate_panel_port 80 2>/dev/null && echo yes || echo no)"
check "reserves 443"            "no"  "$(validate_panel_port 443 2>/dev/null && echo yes || echo no)"
check "rejects taken port"      "no"  "$(validate_panel_port 8000 2>/dev/null && echo yes || echo no)"
check "accepts free port"       "yes" "$(validate_panel_port 2053 2>/dev/null && echo yes || echo no)"
check "owner of 8000"           "marzban" "$(panel_owner_of_port 8000)"
check "owner of free port"      ""    "$(panel_owner_of_port 2053)"
check "ip list single"          "yes" "$(is_valid_ip_list 203.0.113.5 && echo yes || echo no)"
check "ip list cidr + multi"    "yes" "$(is_valid_ip_list '203.0.113.5,10.0.0.0/8' && echo yes || echo no)"
check "ip list rejects junk"    "no"  "$(is_valid_ip_list 'not-an-ip' && echo yes || echo no)"
check "ip list rejects empty"   "no"  "$(is_valid_ip_list '' && echo yes || echo no)"

echo "state_set"
state_set "marzban" DOMAIN "new.example.com"
check "value updated"           "new.example.com" "$(state_get marzban DOMAIN)"
check "other keys preserved"    "8000" "$(state_get marzban PORT)"
state_set "marzban" ALLOW_IPS "203.0.113.5"
check "new key appended"        "203.0.113.5" "$(state_get marzban ALLOW_IPS)"
state_set "marzban" ALLOW_IPS ""
check "key cleared"             "" "$(state_get marzban ALLOW_IPS)"
check "no duplicate keys"       "1" "$(grep -c '^ALLOW_IPS' "$VPN_SETUP_STATE/panels/marzban.env")"

echo "caddy block hardening"
state_set "marzban" DOMAIN "m.example.com"
state_set "marzban" SUB_DOMAIN "sub.example.com"
proxy_render
CADDY="$VPN_SETUP_ROOT/caddy/Caddyfile"
check "HSTS present"            "yes" "$(grep -q 'Strict-Transport-Security' "$CADDY" && echo yes || echo no)"
check "nosniff present"         "yes" "$(grep -q 'X-Content-Type-Options' "$CADDY" && echo yes || echo no)"
check "frame options present"   "yes" "$(grep -q 'X-Frame-Options' "$CADDY" && echo yes || echo no)"
check "server header removed"   "yes" "$(grep -q '^        -Server$' "$CADDY" && echo yes || echo no)"
check "sub site rendered"       "yes" "$(grep -q '^sub.example.com {' "$CADDY" && echo yes || echo no)"
check "sub uses panel port"     "2"   "$(grep -c 'reverse_proxy 127.0.0.1:8000' "$CADDY")"
check "no allowlist when unset" "no"  "$(grep -q '@denied' "$CADDY" && echo yes || echo no)"

state_set "marzban" ALLOW_IPS "203.0.113.5,10.0.0.0/8"
proxy_render
check "allowlist rendered"      "yes" "$(grep -q 'not remote_ip 203.0.113.5 10.0.0.0/8' "$CADDY" && echo yes || echo no)"
check "acme path exempted"      "yes" "$(grep -q 'not path /.well-known/acme-challenge/\*' "$CADDY" && echo yes || echo no)"
check "deny rule present"       "yes" "$(grep -q 'respond @denied' "$CADDY" && echo yes || echo no)"
check "allowlist on panel only" "1"   "$(grep -c '@denied {' "$CADDY")"

echo "new commands"
for fn in cmd_set_domain cmd_set_allow_ips ask_panel_port validate_panel_port \
          panel_owner_of_port ask_optional_sub_domain is_valid_ip_list \
          state_set wait_http_ok _caddy_site_block; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done
for fn in panel_set_domain_marzban panel_set_domain_remnawave; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done
check "wait_http_any removed"   "no" "$(declare -F wait_http_any >/dev/null && echo yes || echo no)"
check "SUB_PORT no longer used" "no" "$(grep -rq 'SUB_PORT' "$ROOT/lib" && echo yes || echo no)"

echo "doctor"
for fn in doctor_run doctor_check_host doctor_check_docker doctor_check_panel \
          doctor_check_caddy doctor_check_https doctor_check_backups \
          doctor_check_permissions resolve_a public_ip; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done

DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
doctor_ok "x" >/dev/null; doctor_warn "x" >/dev/null; doctor_fail "x" >/dev/null
check "ok counter"              "1" "$DOCTOR_OK"
check "warn counter"            "1" "$DOCTOR_WARN"
check "fail counter"            "1" "$DOCTOR_FAIL"

# A backup written today is fine; a missing one and a month-old one are not.
mkdir -p "$VPN_SETUP_BACKUP/fresh"
: > "$VPN_SETUP_BACKUP/fresh/fresh-20260101_000000.tar.gz"
DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
doctor_check_backups "fresh" >/dev/null 2>&1
check "fresh backup passes"     "1" "$DOCTOR_OK"
check "fresh backup no warn"    "0" "$DOCTOR_WARN"

DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
doctor_check_backups "missing" >/dev/null 2>&1
check "missing backup warns"    "1" "$DOCTOR_WARN"

mkdir -p "$VPN_SETUP_BACKUP/stale"
: > "$VPN_SETUP_BACKUP/stale/stale-20260101_000000.tar.gz"
touch -d "30 days ago" "$VPN_SETUP_BACKUP/stale/stale-20260101_000000.tar.gz" 2>/dev/null || true
DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
doctor_check_backups "stale" >/dev/null 2>&1
check "stale backup warns"      "1" "$DOCTOR_WARN"

# chmod is a no-op on NTFS, so probe first: asserting on file modes on a
# filesystem that cannot represent them would fail for the wrong reason.
probe="$TMP/.chmod-probe"
: > "$probe"
chmod 600 "$probe" 2>/dev/null || true
if [ "$(stat -c '%a' "$probe" 2>/dev/null)" = "600" ]; then
  mkdir -p "$VPN_SETUP_ROOT/permtest"
  printf 'X=1\n' > "$VPN_SETUP_ROOT/permtest/.env"
  state_write "permtest" "DOMAIN=p.example.com" "PORT=9999"
  chmod 600 "$VPN_SETUP_ROOT/permtest/.env" "$VPN_SETUP_STATE/panels/permtest.env" 2>/dev/null || true
  DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
  doctor_check_permissions "permtest" "$VPN_SETUP_ROOT/permtest" >/dev/null 2>&1
  check "tight perms pass"      "1" "$DOCTOR_OK"
  check "tight perms no warn"   "0" "$DOCTOR_WARN"

  chmod 644 "$VPN_SETUP_ROOT/permtest/.env" 2>/dev/null || true
  DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
  doctor_check_permissions "permtest" "$VPN_SETUP_ROOT/permtest" >/dev/null 2>&1
  check "loose perms warn"      "yes" "$([ "$DOCTOR_WARN" -ge 1 ] && echo yes || echo no)"
else
  printf '  skip permission checks — chmod has no effect on this filesystem\n'
fi

echo "help output"
check "help mentions install"   "yes" "$(vpnsetup_help | grep -q 'install \[panel\]' && echo yes || echo no)"
check "help mentions attach"    "yes" "$(vpnsetup_help | grep -q 'attach' && echo yes || echo no)"
check "help lists all panels"   "yes" "$(vpnsetup_help | grep -q 'remnawave' && echo yes || echo no)"
check "help mentions domain"    "yes" "$(vpnsetup_help | grep -q 'domain <panel>' && echo yes || echo no)"
check "help mentions allow-ips" "yes" "$(vpnsetup_help | grep -q 'allow-ips <panel>' && echo yes || echo no)"
check "help documents sub domain" "yes" "$(vpnsetup_help | grep -q 'VPN_SETUP_SUB_DOMAIN' && echo yes || echo no)"
check "help mentions doctor"    "yes" "$(vpnsetup_help | grep -q '^  doctor' && echo yes || echo no)"

rm -rf "$TMP"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
