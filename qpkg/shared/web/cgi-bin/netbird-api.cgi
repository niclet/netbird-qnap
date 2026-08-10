#!/bin/sh
# Netbird VPN CGI API for the QNAP web UI.
# Actions: load, save, status, restart.
#
# Every field the settings page can edit comes from NB_OPTION_TABLE in
# netbird-common.sh, so this file does not need to change when an option is
# added -- only the table and the HTML form do.

CONF=/etc/config/qpkg.conf
QPKG_NAME="netbird"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
NETBIRD_CONF="${QPKG_ROOT}/netbird.conf"
NETBIRD_BIN="${QPKG_ROOT}/netbird"
LAST_ERROR="${QPKG_ROOT}/last-error"

if [ -z "$QPKG_ROOT" ] || [ ! -f "${QPKG_ROOT}/netbird-common.sh" ]; then
    # Answer with JSON rather than letting the shell error land as a bare 500,
    # so the settings page can show something useful.
    printf 'Content-Type: application/json\r\n\r\n'
    printf '{"ok":false,"error":"Netbird QPKG install path could not be resolved (getcfg returned \\"%s\\"). Reinstall the package."}' "$QPKG_ROOT"
    exit 0
fi

# shellcheck source=../../netbird-common.sh
. "${QPKG_ROOT}/netbird-common.sh"

# Read POST body
read_body() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null
    fi
}

# Output JSON response
json_response() {
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '%s' "$1"
}

json_error() {
    json_response "{\"ok\":false,\"error\":\"$(nb_json_escape "$1")\"}"
}

# json_has reports whether a key is present in the request at all, so that a
# request carrying only some fields updates only those fields.
json_has() {
    case "$1" in
        *"\"$2\""*) return 0 ;;
        *) return 1 ;;
    esac
}

# json_val extracts a JSON string value, still escaped -- json_unescape
# finishes the job.
#
# This walks the string in awk rather than matching it with sed. A naive
# sed "[^\"]*" stops at the first escaped quote, and the regex that would not
# needs BRE alternation (\|), which is a GNU extension that BSD sed rejects
# outright. awk's index/substr are POSIX and behave the same everywhere.
json_val() {
    printf '%s' "$1" | awk -v key="$2" '
    {
        pat = "\"" key "\""
        i = index($0, pat)
        if (i == 0) exit
        rest = substr($0, i + length(pat))
        sub(/^[ \t]*:[ \t]*/, "", rest)
        if (substr(rest, 1, 1) != "\"") exit
        rest = substr(rest, 2)
        out = ""
        n = length(rest)
        j = 1
        while (j <= n) {
            c = substr(rest, j, 1)
            if (c == "\\") { out = out c substr(rest, j + 1, 1); j += 2; continue }
            if (c == "\"") break
            out = out c
            j++
        }
        printf "%s", out
    }'
}

# json_unescape reverses the escapes JSON.stringify can produce for the kind of
# values this form carries. Newlines and tabs collapse to spaces: the config
# file is one key per line and a literal newline in a value would corrupt it.
json_unescape() {
    printf '%s' "$1" \
        | sed -e 's/\\n/ /g' -e 's/\\r/ /g' -e 's/\\t/ /g' \
              -e 's/\\"/"/g' -e 's|\\/|/|g' -e 's/\\\\/\\/g'
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Load config and return it as JSON
do_load() {
    nb_load_config "$NETBIRD_CONF"

    _out=""
    _sep=""
    for _row in $NB_OPTION_TABLE; do
        _key=${_row%%|*}
        eval "_val=\${NBQ_$_key-}"
        _out="${_out}${_sep}\"${_key}\":\"$(nb_json_escape "$_val")\""
        _sep=","
    done

    json_response "{\"ok\":true,\"config\":{${_out}}}"
}

# Save config from the JSON body
do_save() {
    BODY="$1"

    # Start from what is on disk so a partial request only changes what it sends.
    nb_load_config "$NETBIRD_CONF"

    _warning=""

    for _row in $NB_OPTION_TABLE; do
        _key=${_row%%|*}
        _type=$(nb_row_type "$_row")

        json_has "$BODY" "$_key" || continue

        _val=$(json_unescape "$(json_val "$BODY" "$_key")" | tr -d '\r\n')

        case "$_type" in
            bool)
                if [ -n "$_val" ]; then
                    _norm=$(nb_bool "$_val") || {
                        json_error "$_key must be true, false, or empty (got: $_val)"
                        return 0
                    }
                    _val="$_norm"
                fi
                ;;
            int)
                if [ -n "$_val" ] && ! is_uint "$_val"; then
                    json_error "$_key must be a whole number (got: $_val)"
                    return 0
                fi
                ;;
        esac

        case "$_key" in
            MANAGEMENT_URL|ADMIN_URL)
                if [ -n "$_val" ]; then
                    nb_url_ok "$_val" || {
                        json_error "$_key must start with https:// or http:// and include a host (got: $_val)"
                        return 0
                    }
                    if nb_url_is_plain_http "$_val"; then
                        _warning="Saved, but $_key uses plain http://. If that server sits behind a TLS-terminating proxy the gRPC call is answered with a redirect and netbird reports \"308 (Permanent Redirect); malformed header: missing HTTP content-type\". Use https:// unless you know the server speaks plain-text gRPC."
                    fi
                fi
                ;;
        esac

        eval "NBQ_${_key}=\$_val"
    done

    if nb_write_config "$NETBIRD_CONF"; then
        chmod 666 "$NETBIRD_CONF" 2>/dev/null
        if [ -n "$_warning" ]; then
            json_response "{\"ok\":true,\"warning\":\"$(nb_json_escape "$_warning")\"}"
        else
            json_response '{"ok":true}'
        fi
    else
        json_error "Failed to write $NETBIRD_CONF"
    fi
}

# Report status straight from netbird's own JSON, plus the human-readable
# detail view and whatever the last start recorded.
#
# The old implementation substring-matched "Connected" against the text output.
# The first line of that output is the *daemon* status, which reads Connected
# whenever the daemon process is alive -- including while Management is
# disconnected -- so the badge was green during a total outage.
do_status() {
    RAW=""
    TEXT=""
    if [ -x "$NETBIRD_BIN" ] && [ -S /var/run/netbird.sock ]; then
        RAW=$("$NETBIRD_BIN" status --json 2>/dev/null)
        TEXT=$("$NETBIRD_BIN" status -d 2>&1)
    else
        TEXT="Service not running"
    fi

    case "$RAW" in
        \{*) : ;;
        *) RAW="null" ;;
    esac

    ERR=""
    [ -f "$LAST_ERROR" ] && ERR=$(cat "$LAST_ERROR" 2>/dev/null)

    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":true,"status":%s,"text":"%s","lastError":"%s"}' \
        "$RAW" "$(nb_json_escape "$TEXT")" "$(nb_json_escape "$ERR")"
}

# Restart the service. This runs in the background because a restart performs
# 'netbird down' followed by 'netbird up' and can take longer than a CGI
# request should; the page polls status afterwards and surfaces lastError.
do_restart() {
    if [ ! -x "${QPKG_ROOT}/netbird.sh" ]; then
        json_error "${QPKG_ROOT}/netbird.sh is missing or not executable"
        return 0
    fi
    "${QPKG_ROOT}/netbird.sh" restart > /dev/null 2>&1 &
    json_response '{"ok":true,"restarting":true}'
}

# Route request
BODY=$(read_body)
ACTION=$(json_val "$BODY" "action")

case "$ACTION" in
    load)    do_load ;;
    save)    do_save "$BODY" ;;
    status)  do_status ;;
    restart) do_restart ;;
    *)       json_error "unknown action" ;;
esac
