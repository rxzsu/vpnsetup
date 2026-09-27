#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# json.sh — output helpers for the machine-readable interface.
#
# There is no jq dependency on purpose: this runs on a bare server in the middle
# of an install. Everything here only *builds* JSON — nothing parses it.
#
# The style is functional: build fragments with json_pair, then join them with
# json_object / json_array. A loop accumulates into a string, which is why the
# helpers print instead of mutating anything global.
# ──────────────────────────────────────────────────────────────────────────────

# json_escape <string> — make a string safe inside double quotes.
json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Any other C0 control byte would make the document invalid; drop it rather
  # than emit a raw byte. The case guard keeps the common path allocation-free.
  case "$s" in
    *[[:cntrl:]]*) s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')" ;;
  esac
  printf '%s' "$s"
}

json_str() { printf '"%s"' "$(json_escape "${1-}")"; }

json_bool() {
  case "${1-}" in
    1|true|yes|on) printf 'true' ;;
    *)             printf 'false' ;;
  esac
}

# json_num <value> — never emit something that would break the document.
json_num() {
  case "${1-}" in
    ''|*[!0-9.-]*) printf '0' ;;
    *)             printf '%s' "$1" ;;
  esac
}

# json_nullable_str <value> — a string, or null when empty, so a consumer can
# tell "absent" from "empty".
json_nullable_str() {
  if [ -z "${1-}" ]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

json_pair() { printf '"%s":%s' "$(json_escape "$1")" "$2"; }

# json_object <"key":value>... — join pre-rendered pairs.
json_object() {
  local sep="" p
  printf '{'
  for p in "$@"; do printf '%s%s' "$sep" "$p"; sep=','; done
  printf '}'
}

# json_array <rendered-value>... — join pre-rendered values.
json_array() {
  local sep="" v
  printf '['
  for v in "$@"; do printf '%s%s' "$sep" "$v"; sep=','; done
  printf ']'
}

# json_emit <"key":value>... — one document per run, terminated by a newline.
# Every --json command ends here so the schema version travels with the payload
# and a consumer can refuse a shape it does not understand.
json_emit() {
  json_object "$(json_pair schema_version "$(json_num "$SCHEMA_VERSION")")" "$@"
  printf '\n'
}
