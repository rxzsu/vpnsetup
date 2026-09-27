#!/usr/bin/env bash
# Smoke test for the pure logic in lib/. Runs on any bash; does not need root,
# Docker or Linux — it only exercises functions that touch strings and files.
set -uo pipefail

# Some sandboxes replace rm/rmdir/unlink with shims that quietly refuse local
# paths. That is fatal here in a way that looks like a bug in the code under
# test: the mkdir lock fallback cannot delete its directory, so every later
# lock acquisition pays the full timeout and the suite crawls. This script only
# ever deletes inside its own temp tree, so drop the shims for its own process.
unset -f rm rmdir unlink 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A project-local temp dir rather than mktemp: on Windows/Git Bash mktemp hands
# back a path under the drive-letter temp root, which some sandboxes refuse to
# delete, producing failures that have nothing to do with the code.
#
# The pid suffix is not decoration: the state files here are guarded by real
# locks, so two concurrent runs sharing one directory deadlock against each
# other and the failures look like bugs in the code under test. Each run gets
# its own tree; stale ones are ignored (and gitignored) rather than swept,
# because sweeping them is exactly the `rm -rf` that hangs in some sandboxes.
TMP="$ROOT/.smoke-tmp.$$"
rm -rf "$TMP"
mkdir -p "$TMP"
export VPN_SETUP_STATE="$TMP/state"
export VPN_SETUP_ROOT="$TMP/root"
export VPN_SETUP_BACKUP="$TMP/backup"
export VPN_SETUP_LOGS="$TMP/logs"
# Keep the suite quick: a contended lock should fail in seconds, not in the
# production default of 30.
export VPN_SETUP_LOCK_TIMEOUT=3

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

# A crude JSON well-formedness probe: there is no jq here on purpose, and the
# failures this is meant to catch (an unescaped quote, a dropped brace) all show
# up as unbalanced delimiters.
json_balanced() {
  local s="$1" o c ob cb
  o="$(printf '%s' "$s" | tr -cd '{' | wc -c)"
  c="$(printf '%s' "$s" | tr -cd '}' | wc -c)"
  ob="$(printf '%s' "$s" | tr -cd '[' | wc -c)"
  cb="$(printf '%s' "$s" | tr -cd ']' | wc -c)"
  if [ "$o" = "$c" ] && [ "$ob" = "$cb" ]; then printf 'yes'; else printf 'no'; fi
}

# Source order mirrors vpnsetup_load — several modules call into earlier ones.
# shellcheck source=/dev/null
. "$ROOT/lib/json.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/lock.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/job.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/sites.sh"
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
. "$ROOT/lib/agent.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/main.sh"
for m in "$ROOT"/lib/panels/*.sh; do . "$m"; done

echo "secrets"
check "gen_hex 4 length"        "8"  "$(printf '%s' "$(gen_hex 4)" | wc -c | tr -d ' ')"
check "gen_hex 32 length"       "64" "$(printf '%s' "$(gen_hex 32)" | wc -c | tr -d ' ')"
check "gen_hex is hex"          "yes" "$(printf '%s' "$(gen_hex 8)" | grep -qE '^[0-9a-f]+$' && echo yes || echo no)"

echo "json helpers"
check "escapes backslash"       'a\\b'   "$(json_escape 'a\b')"
check "escapes quote"           'a\"b'   "$(json_escape 'a"b')"
check "escapes newline"         'a\nb'   "$(json_escape $'a\nb')"
check "escapes tab"             'a\tb'   "$(json_escape $'a\tb')"
check "strips other controls"   'ab'     "$(json_escape $'a\001b')"
check "leaves utf-8 alone"      'панель' "$(json_escape 'панель')"
check "json_str wraps"          '"x"'    "$(json_str 'x')"
check "json_bool 1"             "true"   "$(json_bool 1)"
check "json_bool 0"             "false"  "$(json_bool 0)"
check "json_num keeps digits"   "2053"   "$(json_num 2053)"
check "json_num rejects junk"   "0"      "$(json_num 'abc')"
check "json_nullable empty"     "null"   "$(json_nullable_str '')"
check "json_nullable value"     '"v"'    "$(json_nullable_str 'v')"
check "json_array joins"        '[1,2]'  "$(json_array 1 2)"
check "json_object joins"       '{"a":1}' "$(json_object "$(json_pair a 1)")"
check "json_pair escapes key"   '"a\"b":1' "$(json_pair 'a"b' 1)"
check "json_emit has schema"    "yes"    "$(json_emit "$(json_pair a 1)" | grep -q '"schema_version":1' && echo yes || echo no)"
check "json_emit is balanced"   "yes"    "$(json_balanced "$(json_emit "$(json_pair a 1)")")"

echo "exit codes"
check "EX_OK"                   "0" "$EX_OK"
check "EX_USAGE"                "2" "$EX_USAGE"
check "EX_CONFLICT"             "3" "$EX_CONFLICT"
check "EX_NOTFOUND"             "4" "$EX_NOTFOUND"
check "EX_PRECOND"              "5" "$EX_PRECOND"
check "EX_PARTIAL"              "6" "$EX_PARTIAL"
check "EX_CANCELLED"            "7" "$EX_CANCELLED"

echo "validation"
check "domain valid"            "yes" "$(is_valid_domain panel.example.com && echo yes || echo no)"
check "domain rejects scheme"   "no"  "$(is_valid_domain https://panel.example.com && echo yes || echo no)"
check "domain rejects port"     "no"  "$(is_valid_domain panel.example.com:443 && echo yes || echo no)"
check "domain rejects bare host" "no" "$(is_valid_domain localhost && echo yes || echo no)"
check "port 443 valid"          "yes" "$(is_valid_port 443 && echo yes || echo no)"
check "port 0 invalid"          "no"  "$(is_valid_port 0 && echo yes || echo no)"
check "port 70000 invalid"      "no"  "$(is_valid_port 70000 && echo yes || echo no)"
check "port abc invalid"        "no"  "$(is_valid_port abc && echo yes || echo no)"

echo "option parsing"
check "opt_value long"          "x"    "$(opt_value domain 'd' --domain x)"
check "opt_value equals form"   "x"    "$(opt_value domain 'd' --domain=x)"
check "opt_value default"       "d"    "$(opt_value domain 'd' --other x)"
check "opt_value missing value" ""     "$(opt_value domain 'd' --domain)"
check "opt_has present"         "yes"  "$(opt_has domain --domain x && echo yes || echo no)"
check "opt_has absent"          "no"   "$(opt_has domain --other x && echo yes || echo no)"
check "opt_positionals"         "3x-ui" "$(opt_positionals 3x-ui --domain x)"
check "opt_positionals bare"    "a b"  "$(opt_positionals a b | tr '\n' ' ' | sed 's/ $//')"

echo "flags"
vpnsetup_parse_flags --json --yes install 3x-ui --domain panel.example.com
check "OPT_JSON set"            "1"   "$OPT_JSON"
check "OPT_YES set"             "1"   "$OPT_YES"
check "global flags stripped"   "4"   "${#VPN_SETUP_ARGS[@]}"
check "command kept"            "install" "${VPN_SETUP_ARGS[0]}"
check "positional kept"         "3x-ui" "${VPN_SETUP_ARGS[1]}"
check "command option kept"     "--domain" "${VPN_SETUP_ARGS[2]}"
vpnsetup_parse_flags --tail=500 --no-follow logs marzban
check "OPT_TAIL from equals"    "500" "$OPT_TAIL"
check "OPT_FOLLOW cleared"      "0"   "$OPT_FOLLOW"
check "OPT_JSON reset"          "0"   "$OPT_JSON"
check "OPT_YES reset"           "0"   "$OPT_YES"
vpnsetup_parse_flags --tail bogus
check "OPT_TAIL rejects junk"   "200" "$OPT_TAIL"
vpnsetup_parse_flags

echo "locks"
# lock_take must not run inside $(...) — the lock would die with the subshell.
# That is exactly the trap this section is here to document.
lock_take test-lock
check "lock acquired"           "yes" "$(lock_held test-lock && echo yes || echo no)"
# flock uses a file, the mkdir fallback uses a directory — assert that one of
# them appeared rather than pinning the implementation.
check "lock artifact exists"    "yes" "$({ [ -e "$LOCK_DIR/test-lock.lock" ] || [ -d "$LOCK_DIR/test-lock.lock.d" ]; } && echo yes || echo no)"
lock_take test-lock-inner
check "nested lock tracked"     "2"   "${#LOCK_NAMES[@]}"
lock_release
check "inner released first"    "yes" "$(lock_held test-lock && echo yes || echo no)"
lock_release
check "locks released"          "0"   "${#LOCK_NAMES[@]}"
check "lock_held false after"   "no"  "$(lock_held test-lock && echo yes || echo no)"
# The mkdir fallback must remove its directory; flock leaves its (harmless,
# empty) lock file behind on purpose.
#
# Only assert this where the filesystem can actually delete a directory. In some
# sandboxes `rm` is a shim that silently refuses local paths, so the lock's pid
# file survives, `rmdir` then fails on a non-empty directory, and the check fails
# for a reason that has nothing to do with the locking code. Probe first, and
# make the probe a hard gate rather than a soft one: a leftover lock directory
# turns every later lock acquisition into a timeout, which is what made this
# suite take minutes instead of seconds.
if have_cmd flock; then
  printf '  skip mkdir-fallback cleanup — flock is present, that path is unused\n'
elif [ -d "$LOCK_DIR/test-lock.lock.d" ]; then
  printf '  skip mkdir-fallback cleanup — this filesystem will not delete the lock directory\n'
  printf '       (every later lock now pays the timeout; VPN_SETUP_LOCK_TIMEOUT is %s)\n' "$VPN_SETUP_LOCK_TIMEOUT"
  LOCK_CLEANUP_BROKEN=1
else
  check "mkdir fallback cleans up" "no" "$([ -d "$LOCK_DIR/test-lock.lock.d" ] && echo yes || echo no)"
fi
# A second holder must be refused. The timeout is short so the test stays quick.
lock_take test-contended 1
( lock_take test-contended 1 ) 2>/dev/null
check "second holder refused"   "1"   "$?"
lock_release

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
check "known id"                "yes" "$(panel_is_known 3x-ui && echo yes || echo no)"
check "unknown id rejected"     "no"  "$(panel_is_known nosuch && echo yes || echo no)"

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
state_write "probe" "DOMAIN=x.example.com" >/dev/null 2>&1
check "state_write returns 0"   "0" "$?"
check "state_write is atomic"   "0" "$(ls "$VPN_SETUP_STATE/panels"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
state_delete "probe"
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
check "no temp files left"      "0" "$(ls "$TMP"/.env.vpnsetup.tmp.* 2>/dev/null | wc -l | tr -d ' ')"

echo "x-ui settings parsing"
SAMPLE="$(printf 'port: 2053\nwebBasePath: /abc123/\nusername: k7Xq\npassword: p@ss w0rd\n')"
check "parse port"              "2053"     "$(_x3ui_field '[Pp]ort' "$SAMPLE")"
check "parse webBasePath"       "/abc123/" "$(_x3ui_field '[Ww]eb[Bb]ase[Pp]ath' "$SAMPLE")"
check "parse username"          "k7Xq"     "$(_x3ui_field '[Uu]sername' "$SAMPLE")"
check "parse password w/ space" "p@ss w0rd" "$(_x3ui_field '[Pp]assword' "$SAMPLE")"
check "parse missing key"       ""         "$(_x3ui_field '[Nn]ope' "$SAMPLE")"

echo "site registry"
check "upstream host:port"      "yes" "$(is_valid_upstream '127.0.0.1:3000' && echo yes || echo no)"
check "upstream bare port"      "yes" "$(is_valid_upstream '3000' && echo yes || echo no)"
check "upstream rejects junk"   "no"  "$(is_valid_upstream 'not-an-upstream' && echo yes || echo no)"
check "upstream rejects big port" "no" "$(is_valid_upstream '127.0.0.1:99999' && echo yes || echo no)"
check "upstream_normalize bare" "127.0.0.1:3000" "$(upstream_normalize 3000)"
check "upstream_normalize kept" "10.0.0.5:8080" "$(upstream_normalize 10.0.0.5:8080)"
check "upstream_host"           "127.0.0.1" "$(upstream_host 3000)"
check "upstream_port"           "8080"      "$(upstream_port 10.0.0.5:8080)"

site_write "web" "KIND=app" "DOMAIN=web.example.com" "UPSTREAM=127.0.0.1:9090" "ALLOW_IPS=" "ALT_DOMAIN="
check "site_exists"             "yes" "$(site_exists web && echo yes || echo no)"
check "site_get DOMAIN"         "web.example.com" "$(site_get web DOMAIN)"
check "site_get default"        "d"   "$(site_get web NOPE d)"
check "site kind"               "app" "$(site_get web KIND)"
site_set "web" ALLOW_IPS "203.0.113.5"
check "site_set updates"        "203.0.113.5" "$(site_get web ALLOW_IPS)"
check "site_set keeps others"   "web.example.com" "$(site_get web DOMAIN)"
site_delete "web"
check "site_delete"             "no"  "$(site_exists web && echo yes || echo no)"

echo "panel to site sync"
state_write "3x-ui" "PANEL_NAME=3x-ui" "DOMAIN=panel.example.com" "PORT=2053"
state_write "remnawave" "PANEL_NAME=Remnawave" "DOMAIN=rw.example.com" "PORT=3000" "SUB_DOMAIN=sub.example.com"
state_write "marzban" "PANEL_NAME=Marzban" "DOMAIN=m.example.com" "PORT=8000" "ALLOW_IPS=203.0.113.5,10.0.0.0/8"
site_sync_all
check "panel site created"      "yes" "$(site_exists 3x-ui && echo yes || echo no)"
check "panel site kind"         "panel" "$(site_get 3x-ui KIND)"
check "panel site managed_by"   "3x-ui" "$(site_get 3x-ui MANAGED_BY)"
check "panel site upstream"     "127.0.0.1:2053" "$(site_get 3x-ui UPSTREAM)"
check "sub becomes alt_domain"  "sub.example.com" "$(site_get remnawave ALT_DOMAIN)"
check "no alt when unset"       ""    "$(site_get 3x-ui ALT_DOMAIN)"
check "allow_ips carried over"  "203.0.113.5,10.0.0.0/8" "$(site_get marzban ALLOW_IPS)"
check "site count"              "3"   "$(site_ids | wc -l | tr -d ' ')"

echo "caddyfile rendering"
proxy_render
CADDY="$VPN_SETUP_ROOT/caddy/Caddyfile"
check "site 1 present"          "yes" "$(grep -q '^panel.example.com {' "$CADDY" && echo yes || echo no)"
check "site 2 present"          "yes" "$(grep -q '^rw.example.com {' "$CADDY" && echo yes || echo no)"
check "sub site present"        "yes" "$(grep -q '^sub.example.com {' "$CADDY" && echo yes || echo no)"
check "upstream port 2053"      "yes" "$(grep -q 'reverse_proxy 127.0.0.1:2053' "$CADDY" && echo yes || echo no)"
check "sub shares panel port"   "2"   "$(grep -c 'reverse_proxy 127.0.0.1:3000' "$CADDY")"
check "renders from sites"      "yes" "$(grep -q 'sites/\*\.env' "$CADDY" && echo yes || echo no)"
check "no temp file left"       "0"   "$(ls "$VPN_SETUP_ROOT/caddy"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"

echo "caddy block hardening"
check "HSTS present"            "yes" "$(grep -q 'Strict-Transport-Security' "$CADDY" && echo yes || echo no)"
check "nosniff present"         "yes" "$(grep -q 'X-Content-Type-Options' "$CADDY" && echo yes || echo no)"
check "frame options present"   "yes" "$(grep -q 'X-Frame-Options' "$CADDY" && echo yes || echo no)"
check "server header removed"   "yes" "$(grep -q '^        -Server$' "$CADDY" && echo yes || echo no)"
check "allowlist rendered"      "yes" "$(grep -q 'not remote_ip 203.0.113.5 10.0.0.0/8' "$CADDY" && echo yes || echo no)"
check "acme path exempted"      "yes" "$(grep -q 'not path /.well-known/acme-challenge/\*' "$CADDY" && echo yes || echo no)"
check "deny rule present"       "yes" "$(grep -q 'respond @denied' "$CADDY" && echo yes || echo no)"
check "allowlist on panel only" "1"   "$(grep -c '@denied {' "$CADDY")"
check "sub site not restricted" "1"   "$(grep -c '^sub.example.com {' "$CADDY")"

echo "app sites render too"
site_write "dash" "KIND=app" "DOMAIN=dash.example.com" "UPSTREAM=127.0.0.1:9000" "ALLOW_IPS=" "ALT_DOMAIN="
proxy_render
check "app site rendered"       "yes" "$(grep -q '^dash.example.com {' "$CADDY" && echo yes || echo no)"
check "app upstream rendered"   "yes" "$(grep -q 'reverse_proxy 127.0.0.1:9000' "$CADDY" && echo yes || echo no)"
check "kind shown in comment"   "yes" "$(grep -q '^# dash (app)$' "$CADDY" && echo yes || echo no)"
site_delete "dash"
proxy_render

echo "port guards"
# Start from a clean slate: earlier sections left three panels in the state,
# and a port guard that reads other panels must not see them.
rm -f "$VPN_SETUP_STATE/panels"/*.env
state_write "marzban" "PANEL_NAME=Marzban" "DOMAIN=m.example.com" "PORT=8000"
check "reserves 80"             "3"  "$(validate_panel_port 80 >/dev/null 2>&1; echo $?)"
check "reserves 443"            "3"  "$(validate_panel_port 443 >/dev/null 2>&1; echo $?)"
check "rejects taken port"      "3"  "$(validate_panel_port 8000 >/dev/null 2>&1; echo $?)"
check "owner of 8000"           "marzban" "$(panel_owner_of_port 8000)"
check "owner of free port"      ""    "$(panel_owner_of_port 2053)"
check "ip list single"          "yes" "$(is_valid_ip_list 203.0.113.5 && echo yes || echo no)"
check "ip list cidr + multi"    "yes" "$(is_valid_ip_list '203.0.113.5,10.0.0.0/8' && echo yes || echo no)"
check "ip list rejects junk"    "no"  "$(is_valid_ip_list 'not-an-ip' && echo yes || echo no)"
check "ip list rejects empty"   "no"  "$(is_valid_ip_list '' && echo yes || echo no)"

# A port held by something outside vpnsetup must be refused too. Which port that
# is depends on the machine, so the assertion adapts rather than guessing.
if port_in_use 2053; then
  check "rejects port in use"   "3" "$(validate_panel_port 2053 >/dev/null 2>&1; echo $?)"
else
  check "accepts free port"     "0" "$(validate_panel_port 2053 >/dev/null 2>&1; echo $?)"
fi

echo "confirmation contract"
# confirm_action exits rather than returning, so each case runs in a subshell
# and the status is read from it.
( OPT_YES=1; confirm_action 'x' 'n' ) >/dev/null 2>&1
check "honours --yes"           "0" "$?"
( OPT_YES=0; OPT_NONINTERACTIVE=0; have_tty() { return 1; }; confirm_action 'x' 'n' ) >/dev/null 2>&1
check "declined exits 7"        "7" "$?"
( OPT_YES=0; OPT_NONINTERACTIVE=1; confirm_action 'x' 'n' ) >/dev/null 2>&1
check "batch without --yes is 2" "2" "$?"
( OPT_YES=1; OPT_NONINTERACTIVE=1; confirm_action 'x' 'n' ) >/dev/null 2>&1
check "batch with --yes proceeds" "0" "$?"

echo "state_set"
state_set "marzban" DOMAIN "new.example.com"
check "value updated"           "new.example.com" "$(state_get marzban DOMAIN)"
check "other keys preserved"    "8000" "$(state_get marzban PORT)"
state_set "marzban" ALLOW_IPS "203.0.113.5"
check "new key appended"        "203.0.113.5" "$(state_get marzban ALLOW_IPS)"
state_set "marzban" ALLOW_IPS ""
check "key cleared"             "" "$(state_get marzban ALLOW_IPS)"
check "no duplicate keys"       "1" "$(grep -c '^ALLOW_IPS' "$VPN_SETUP_STATE/panels/marzban.env")"
state_set nosuch KEY v >/dev/null 2>&1
check "state_set unknown panel" "4" "$?"

echo "jobs"
job_start "install 3x-ui"
check "job id set"              "yes" "$([ -n "$VPN_SETUP_JOB_ID" ] && echo yes || echo no)"
check "job file exists"         "yes" "$([ -f "$VPN_SETUP_JOB_FILE" ] && echo yes || echo no)"
check "start event recorded"    "yes" "$(grep -q '"event":"start"' "$VPN_SETUP_JOB_FILE" && echo yes || echo no)"
check "start records pid"       "yes" "$(grep -q "\"pid\":$$" "$VPN_SETUP_JOB_FILE" && echo yes || echo no)"
log_info "pulling images"
check "log line recorded"       "yes" "$(grep -q '"msg":"pulling images"' "$VPN_SETUP_JOB_FILE" && echo yes || echo no)"
check "log level recorded"      "yes" "$(grep -q '"level":"info"' "$VPN_SETUP_JOB_FILE" && echo yes || echo no)"
check "job running"             "yes" "$(job_running "$VPN_SETUP_JOB_ID" && echo yes || echo no)"
JOB_KEEP="$VPN_SETUP_JOB_ID"
job_finish 0
check "job status written"      "0"   "$(job_code "$JOB_KEEP")"
check "done event recorded"     "yes" "$(grep -q '"event":"done"' "$VPN_SETUP_JOB_FILE" && echo yes || echo no)"
check "job no longer running"   "no"  "$(job_running "$JOB_KEEP" && echo yes || echo no)"
check "job label kept"          "install 3x-ui" "$(job_label "$JOB_KEEP")"
check "job json balanced"       "yes" "$(json_balanced "$(_job_json "$JOB_KEEP")")"
check "job json has state"      "yes" "$(_job_json "$JOB_KEEP" | grep -q '"state":"done"' && echo yes || echo no)"

unset VPN_SETUP_JOB_ID VPN_SETUP_JOB_FILE
job_start "install marzban"
job_finish 6
check "failed job code"         "6"   "$(job_code "$VPN_SETUP_JOB_ID")"
check "failed job state"        "yes" "$(_job_json "$VPN_SETUP_JOB_ID" | grep -q '"state":"failed"' && echo yes || echo no)"
unset VPN_SETUP_JOB_ID VPN_SETUP_JOB_FILE
check "job json after unset"    "yes" "$(json_balanced "$(_job_json "$JOB_KEEP")")"

echo "panel json"
state_write "3x-ui" "PANEL_NAME=3x-ui" "DOMAIN=panel.example.com" "PORT=2053" "INSTALL_DIR=$TMP/root/3x-ui"
check "panel json balanced"     "yes" "$(json_balanced "$(_panel_json 3x-ui)")"
check "panel json has id"       "yes" "$(_panel_json 3x-ui | grep -q '"id":"3x-ui"' && echo yes || echo no)"
check "panel json has port"     "yes" "$(_panel_json 3x-ui | grep -q '"port":2053' && echo yes || echo no)"
check "panel json null sub"     "yes" "$(_panel_json 3x-ui | grep -q '"sub_domain":null' && echo yes || echo no)"
check "panel json empty containers" "yes" "$(_panel_json 3x-ui | grep -q '"containers":\[\]' && echo yes || echo no)"
check "catalog json balanced"   "yes" "$(json_balanced "$(_catalog_entry_json marzban)")"
check "catalog json installed"  "yes" "$(_catalog_entry_json marzban | grep -q '"installed":true' && echo yes || echo no)"
check "catalog json available"  "yes" "$(_catalog_entry_json remnawave | grep -q '"installed":false' && echo yes || echo no)"
check "site json balanced"      "yes" "$(json_balanced "$(_site_json 3x-ui)")"

echo "backup helpers"
printf 'x' > "$TMP/size-probe"
check "file size"               "1"   "$(_file_size "$TMP/size-probe")"
check "human size bytes"        "1B"  "$(_human_size 1)"
check "human size kb"           "1K"  "$(_human_size 1024)"
check "human size mb"           "1.0M" "$(_human_size 1048576)"
check "mtime is numeric"        "yes" "$(case "$(_file_mtime "$TMP/size-probe")" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)"

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

echo "new commands"
for fn in cmd_set_domain cmd_set_allow_ips ask_panel_port validate_panel_port \
          panel_owner_of_port ask_optional_sub_domain is_valid_ip_list \
          state_set wait_http_ok _caddy_site_block site_sync_from_panel \
          site_sync_all site_write site_set site_delete is_valid_upstream \
          upstream_normalize cmd_sites cmd_site_add cmd_site_remove \
          cmd_panels cmd_jobs cmd_job cmd_backup_list \
          json_escape json_emit json_object json_array lock_take lock_release \
          job_start job_finish job_running audit_write \
          opt_value opt_has opt_positionals confirm_action; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done
for fn in panel_set_domain_marzban panel_set_domain_remnawave; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done
check "wait_http_any removed"   "no" "$(declare -F wait_http_any >/dev/null && echo yes || echo no)"
check "SUB_PORT no longer used" "no" "$(grep -rq 'SUB_PORT' "$ROOT/lib" && echo yes || echo no)"
check "proxy renders from sites" "yes" "$(grep -q 'site_ids' "$ROOT/lib/proxy.sh" && echo yes || echo no)"

echo "agent"
for fn in cmd_rpc cmd_agent _rpc_respond _rpc_fail _rpc_param _rpc_build_args \
          _agent_unit_socket _agent_unit_service _agent_status \
          _agent_install _agent_uninstall; do
  check "defined $fn" "yes" "$(declare -F "$fn" >/dev/null && echo yes || echo no)"
done

check "agent socket default"    "/run/vpnsetup/agent.sock" "$AGENT_SOCKET"
check "agent group default"     "vpnsetup" "$AGENT_GROUP"

# The unit files are the whole access-control story: if SocketGroup or the mode
# drifts, either everyone can drive root or nobody can.
sock_unit="$(_agent_unit_socket)"
check "socket unit listens"     "yes" "$(printf '%s' "$sock_unit" | grep -q "^ListenStream=$AGENT_SOCKET$" && echo yes || echo no)"
check "socket unit mode"        "yes" "$(printf '%s' "$sock_unit" | grep -q '^SocketMode=0660$' && echo yes || echo no)"
check "socket unit group"       "yes" "$(printf '%s' "$sock_unit" | grep -q "^SocketGroup=$AGENT_GROUP$" && echo yes || echo no)"
check "socket unit target"      "yes" "$(printf '%s' "$sock_unit" | grep -q '^WantedBy=sockets.target$' && echo yes || echo no)"

svc_unit="$(_agent_unit_service)"
check "service unit oneshot"    "yes" "$(printf '%s' "$svc_unit" | grep -q '^Type=oneshot$' && echo yes || echo no)"
check "service stdin is socket" "yes" "$(printf '%s' "$svc_unit" | grep -q '^StandardInput=socket$' && echo yes || echo no)"
check "service stdout is socket" "yes" "$(printf '%s' "$svc_unit" | grep -q '^StandardOutput=socket$' && echo yes || echo no)"
check "service runs rpc"        "yes" "$(printf '%s' "$svc_unit" | grep -q '^ExecStart=/usr/local/bin/vpnsetup rpc$' && echo yes || echo no)"

# _rpc_param reads the table jq would have flattened. No jq here on purpose —
# this asserts the consumer side of the contract, not the flattener.
RPC_PARAMS=$'panel=3x-ui\ndomain=panel.example.com\nport=2053\nallow_ips=1.2.3.4'
check "rpc_param reads first"   "3x-ui" "$(_rpc_param panel)"
check "rpc_param reads middle"  "panel.example.com" "$(_rpc_param domain)"
check "rpc_param reads last"    "1.2.3.4" "$(_rpc_param allow_ips)"
check "rpc_param missing empty" "" "$(_rpc_param nosuch)"
check "rpc_param exact key"     "" "$(_rpc_param pan)"
RPC_PARAMS=""
check "rpc_param empty table"   "" "$(_rpc_param panel)"

# A method is a CLI command line, and a control panel author should be able to
# predict it from `vpnsetup help`. Assert on the whole line, not a substring.
# rpc_args only prints; rpc_rc only reports the status — keeping them apart is
# what makes the "missing parameter" checks below mean anything.
rpc_args() { _rpc_build_args "$1" >/dev/null 2>&1; printf '%s' "${RPC_ARGS[*]}"; }
rpc_rc()   { _rpc_build_args "$1" >/dev/null 2>&1; }
RPC_PARAMS=$'panel=3x-ui\ndomain=panel.example.com'
check "rpc version"             "version" "$(rpc_args version)"
check "rpc install minimal"     "install 3x-ui --domain panel.example.com" "$(rpc_args install)"
RPC_PARAMS=$'panel=marzban\ndomain=m.example.com\nsub_domain=sub.example.com\nport=8443\nallow_ips=1.2.3.4,5.6.7.8'
check "rpc install full"        "install marzban --domain m.example.com --sub-domain sub.example.com --port 8443 --allow-ips 1.2.3.4,5.6.7.8" "$(rpc_args install)"
RPC_PARAMS=$'panel=remnawave'
check "rpc update"              "update remnawave" "$(rpc_args update)"
check "rpc remove"              "remove remnawave" "$(rpc_args remove)"
check "rpc backup"              "backup remnawave" "$(rpc_args backup)"
check "rpc backups lists"       "backup list remnawave" "$(rpc_args backups)"
check "rpc status"              "status" "$(rpc_args status)"
check "rpc panels"              "panels" "$(rpc_args panels)"
check "rpc sites"               "sites" "$(rpc_args sites)"
check "rpc jobs"                "jobs" "$(rpc_args jobs)"
check "rpc doctor"              "doctor" "$(rpc_args doctor)"
RPC_PARAMS=""
check "rpc proxy bare"          "proxy" "$(rpc_args proxy)"
RPC_PARAMS=$'panel=remnawave'
check "rpc proxy with panel"    "proxy remnawave" "$(rpc_args proxy)"
RPC_PARAMS=$'panel=3x-ui\narchive=/root/backups/x.tar.gz'
check "rpc restore with archive" "restore 3x-ui /root/backups/x.tar.gz" "$(rpc_args restore)"
RPC_PARAMS=$'panel=3x-ui'
check "rpc restore without archive" "restore 3x-ui" "$(rpc_args restore)"
RPC_PARAMS=$'panel=3x-ui\nlist=1.2.3.4'
check "rpc allow-ips"           "allow-ips 3x-ui 1.2.3.4" "$(rpc_args allow-ips)"
RPC_PARAMS=$'panel=3x-ui'
check "rpc allow-ips clears"    "allow-ips 3x-ui " "$(rpc_args allow-ips)"
RPC_PARAMS=$'panel=3x-ui\ndomain=panel.example.com'
RPC_PARAMS=$'panel=3x-ui\ndomain=panel.example.com'
check "rpc domain"              "domain 3x-ui panel.example.com" "$(rpc_args domain)"
RPC_PARAMS=$'panel=3x-ui\nservice=xray\ntail=100'
check "rpc logs never follows"  "yes" "$(rpc_args logs | grep -q -- '--no-follow' && echo yes || echo no)"
check "rpc logs keeps tail"     "yes" "$(rpc_args logs | grep -q -- '--tail 100' && echo yes || echo no)"
check "rpc logs keeps service"  "logs 3x-ui xray" "$(rpc_args logs | sed 's/ --no-follow.*//')"
RPC_PARAMS=$'name=grafana\ndomain=metrics.example.com\nupstream=127.0.0.1:3000'
check "rpc site.add"            "site add grafana --domain metrics.example.com --upstream 127.0.0.1:3000" "$(rpc_args site.add)"
RPC_PARAMS=$'name=grafana\ndomain=metrics.example.com\nupstream=3000\nalt_domain=alt.example.com\nallow_ips=10.0.0.1'
check "rpc site.add full"       "site add grafana --domain metrics.example.com --upstream 3000 --alt-domain alt.example.com --allow-ips 10.0.0.1" "$(rpc_args site.add)"
RPC_PARAMS=$'name=grafana'
check "rpc site.remove"         "site remove grafana" "$(rpc_args site.remove)"
check "rpc site_remove alias"   "site remove grafana" "$(rpc_args site_remove)"
check "rpc site_add alias"      "" "$(rpc_args site_add)"
RPC_PARAMS=$'id=abc123'
check "rpc job falls back to id" "job abc123" "$(rpc_args job)"
RPC_PARAMS=$'panel=3x-ui'
check "rpc job prefers panel"   "job 3x-ui" "$(rpc_args job)"

# Missing required params must be refused, not silently turned into a no-op.
# This is the failure mode the whole exit-code taxonomy exists to prevent: an
# empty command line that "succeeds" looks identical to a real one.
RPC_PARAMS=""
check "rpc install needs panel" "2" "$(rpc_rc install; echo $?)"
RPC_PARAMS=$'panel=3x-ui'
check "rpc install needs domain" "2" "$(rpc_rc install; echo $?)"
RPC_PARAMS=""
check "rpc update needs panel"  "2" "$(rpc_rc update; echo $?)"
check "rpc site.add needs all"  "2" "$(rpc_rc site.add; echo $?)"
check "rpc unknown method"      "2" "$(rpc_rc nosuchmethod; echo $?)"
check "rpc ok method is 0"      "0" "$(rpc_rc status; echo $?)"
RPC_PARAMS=""

# The response envelope is what the panel parses, so it has to be well formed
# even on the failure path — that is the one a panel sees most often.
resp="$(_rpc_respond 1 0 version '{"a":1}' '')"
check "respond balanced"        "yes" "$(json_balanced "$resp")"
check "respond schema"          "yes" "$(printf '%s' "$resp" | grep -q '"schema_version":1' && echo yes || echo no)"
check "respond ok true"         "yes" "$(printf '%s' "$resp" | grep -q '"ok":true' && echo yes || echo no)"
check "respond embeds result"   "yes" "$(printf '%s' "$resp" | grep -q '"result":{"a":1}' && echo yes || echo no)"
check "respond null error"      "yes" "$(printf '%s' "$resp" | grep -q '"error":null' && echo yes || echo no)"
check "respond null method"     "yes" "$(_rpc_respond 1 0 '' null '' | grep -q '"method":null' && echo yes || echo no)"
fail_resp="$(_rpc_fail 5 install 'boom "quoted"' 2>/dev/null)"
check "fail balanced"           "yes" "$(json_balanced "$fail_resp")"
check "fail ok false"           "yes" "$(printf '%s' "$fail_resp" | grep -q '"ok":false' && echo yes || echo no)"
check "fail carries code"       "yes" "$(printf '%s' "$fail_resp" | grep -q '"exit_code":5' && echo yes || echo no)"
check "fail escapes message"    "yes" "$(printf '%s' "$fail_resp" | grep -q 'boom \\"quoted\\"' && echo yes || echo no)"
_rpc_fail 4 job nope >/dev/null 2>&1
check "fail returns code"       "4" "$?"

# `cmd_agent` must reject a typo rather than defaulting to something destructive.
cmd_agent nosuchaction >/dev/null 2>&1
check "agent rejects typo"      "2" "$?"
OPT_JSON=1
check "agent status json"       "yes" "$(json_balanced "$(_agent_status 2>/dev/null)")"
OPT_JSON=0

# The rpc path is the only one that parses JSON, so it is the only one that may
# depend on jq. If that dependency leaks elsewhere the installer stops working
# on hosts without jq.
check "jq only on rpc path"     "0" "$(grep -rl 'have_cmd jq' "$ROOT/lib" | grep -cv 'agent\.sh')"
check "rpc flattens params"     "yes" "$(grep -q 'to_entries\[\]' "$ROOT/lib/agent.sh" && echo yes || echo no)"
check "rpc guards with subshell" "yes" "$(grep -q 'vpnsetup_main \${RPC_ARGS\[@\]' "$ROOT/lib/agent.sh" && echo yes || echo no)"

echo "help output"
check "help mentions install"   "yes" "$(vpnsetup_help | grep -q 'install \[panel\]' && echo yes || echo no)"
check "help mentions attach"    "yes" "$(vpnsetup_help | grep -q 'attach' && echo yes || echo no)"
check "help lists all panels"   "yes" "$(vpnsetup_help | grep -q 'remnawave' && echo yes || echo no)"
check "help mentions domain"    "yes" "$(vpnsetup_help | grep -q 'domain <panel>' && echo yes || echo no)"
check "help mentions allow-ips" "yes" "$(vpnsetup_help | grep -q 'allow-ips <panel>' && echo yes || echo no)"
check "help documents sub domain" "yes" "$(vpnsetup_help | grep -q 'VPN_SETUP_SUB_DOMAIN' && echo yes || echo no)"
check "help mentions doctor"    "yes" "$(vpnsetup_help | grep -q '^  doctor' && echo yes || echo no)"
check "help mentions json"      "yes" "$(vpnsetup_help | grep -q '\-\-json' && echo yes || echo no)"
check "help mentions sites"     "yes" "$(vpnsetup_help | grep -q '^  sites' && echo yes || echo no)"
check "help mentions jobs"      "yes" "$(vpnsetup_help | grep -q '^  jobs' && echo yes || echo no)"
check "help documents exit codes" "yes" "$(vpnsetup_help | grep -q 'Exit codes:' && echo yes || echo no)"
check "help mentions batch flag" "yes" "$(vpnsetup_help | grep -q 'non-interactive' && echo yes || echo no)"

echo "bootstrap"
# The bootstrap is the one file that cannot be sourced, so assert on its
# contents instead: the invariants below have each broken a real install.
check "install.sh parses"       "yes" "$(bash -n "$ROOT/install.sh" 2>/dev/null && echo yes || echo no)"
check "all scripts parse"       "0"   "$(bad=0; for f in "$ROOT"/install.sh "$ROOT"/bin/vpnsetup "$ROOT"/lib/*.sh "$ROOT"/lib/panels/*.sh; do bash -n "$f" 2>/dev/null || bad=$((bad+1)); done; printf '%s' "$bad")"
check "repo is not a placeholder" "yes" "$(grep -q 'readonly DEFAULT_REPO="rxzsu/vpnsetup"' "$ROOT/install.sh" && echo yes || echo no)"
check "cli shim uses same repo" "yes" "$(grep -q 'VPN_SETUP_REPO:-rxzsu/vpnsetup' "$ROOT/bin/vpnsetup" && echo yes || echo no)"
check "install.sh is cached too" "yes" "$(grep -q '^  "install.sh"$' "$ROOT/install.sh" && echo yes || echo no)"
check "tty reattach guarded"    "yes" "$(grep -q 'VPN_SETUP_TTY_REEXEC' "$ROOT/install.sh" && echo yes || echo no)"
check "headless fallback kept"  "yes" "$(grep -q 'VPN_SETUP_ACTION:-help' "$ROOT/install.sh" && echo yes || echo no)"
check "bootstrap caches every lib" "0" \
  "$(n=0; for f in "$ROOT"/lib/*.sh "$ROOT"/lib/panels/*.sh; do b="lib/${f#"$ROOT"/lib/}"; grep -q "^  \"$b\"$" "$ROOT/install.sh" || n=$((n+1)); done; printf '%s' "$n")"

# `grep -c $'\r'` is unreliable in Git Bash (it reports CR on pure-LF files);
# counting the bytes with tr is the check that actually holds.
crlf=0
for f in "$ROOT"/install.sh "$ROOT"/bin/vpnsetup "$ROOT"/lib/*.sh "$ROOT"/lib/panels/*.sh "$ROOT"/tests/smoke.sh; do
  [ "$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')" -gt 0 ] && crlf=$((crlf + 1))
done
check "all scripts are LF"      "0"   "$crlf"
check "gitattributes pins LF"   "yes" "$(grep -q 'eol=lf' "$ROOT/.gitattributes" && echo yes || echo no)"

rm -rf "$TMP"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
