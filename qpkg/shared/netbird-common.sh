#!/bin/sh
# Shared helpers for the Netbird QPKG service script and the web API CGI.
# POSIX sh only -- QTS ships BusyBox ash, not bash.
#
# The single source of truth for "what can be configured" is NB_OPTION_TABLE
# below. The service script turns it into a 'netbird up' argv, the CGI turns it
# into the JSON the settings page reads and writes. Adding an option means
# adding one row here plus one field in web/index.html.

# Option table rows are CONF_KEY|netbird-up-flag|type. No spaces anywhere in a
# row: the table is iterated with word splitting.
#
#   str    emitted as "--flag value" when non-empty
#   secret same as str, but redacted from the service log
#   int    same as str
#   list   same as str (comma-separated; netbird parses it into a slice)
#   bool   emitted as "--flag=true" or "--flag=false"
#          empty means "unset" -- the flag is not passed at all, so netbird
#          keeps whatever the profile already has. This matters: netbird only
#          applies a boolean whose cobra flag is Changed, and an unset
#          ServerSSHAllowed means ON upstream, so blindly passing
#          "--allow-server-ssh=false" would disable SSH on peers that have it.
#   local  config-only, never passed to 'netbird up'
NB_OPTION_TABLE='
SETUP_KEY|setup-key|secret
MANAGEMENT_URL|management-url|str
ADMIN_URL|admin-url|str
HOSTNAME|hostname|str
PRESHARED_KEY|preshared-key|secret
LOG_LEVEL||local
LOG_FILE||local
ALLOW_SERVER_SSH|allow-server-ssh|bool
ENABLE_SSH_ROOT|enable-ssh-root|bool
ENABLE_SSH_SFTP|enable-ssh-sftp|bool
ENABLE_SSH_LOCAL_PORT_FORWARDING|enable-ssh-local-port-forwarding|bool
ENABLE_SSH_REMOTE_PORT_FORWARDING|enable-ssh-remote-port-forwarding|bool
DISABLE_SSH_AUTH|disable-ssh-auth|bool
SSH_JWT_CACHE_TTL|ssh-jwt-cache-ttl|int
INTERFACE_NAME|interface-name|str
WIREGUARD_PORT|wireguard-port|int
MTU|mtu|int
NETWORK_MONITOR|network-monitor|bool
DISABLE_AUTO_CONNECT|disable-auto-connect|bool
EXTRA_IFACE_BLACKLIST|extra-iface-blacklist|list
DNS_RESOLVER_ADDRESS|dns-resolver-address|str
EXTRA_DNS_LABELS|extra-dns-labels|list
DNS_ROUTER_INTERVAL|dns-router-interval|str
EXTERNAL_IP_MAP|external-ip-map|list
DISABLE_CLIENT_ROUTES|disable-client-routes|bool
DISABLE_SERVER_ROUTES|disable-server-routes|bool
DISABLE_DNS|disable-dns|bool
DISABLE_FIREWALL|disable-firewall|bool
BLOCK_LAN_ACCESS|block-lan-access|bool
BLOCK_INBOUND|block-inbound|bool
DISABLE_IPV6|disable-ipv6|bool
ENABLE_ROSENPASS|enable-rosenpass|bool
ROSENPASS_PERMISSIVE|rosenpass-permissive|bool
EXTRA_ARGS||local
'

# NetBird's own default, from client/internal/profilemanager/config.go.
# (The old api.wiretrustee.com endpoint now serves an expired certificate.)
NB_DEFAULT_MANAGEMENT_URL="https://api.netbird.io:443"

# nb_conf_keys prints every config key, one per line.
nb_conf_keys() {
    for __nb_row in $NB_OPTION_TABLE; do
        printf '%s\n' "${__nb_row%%|*}"
    done
}

# nb_row_flag / nb_row_type split a table row.
nb_row_flag() {
    __nb_rest=${1#*|}
    printf '%s' "${__nb_rest%%|*}"
}

nb_row_type() {
    __nb_rest=${1#*|}
    printf '%s' "${__nb_rest#*|}"
}

# nb_sq single-quotes a value so it can be written to the config file and read
# back by 'eval' or '.' without any of it being interpreted.
nb_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# nb_bool normalises a config value to true/false. Returns non-zero when the
# value is empty or unrecognised, which callers treat as "unset".
nb_bool() {
    case "$1" in
        true|TRUE|True|yes|YES|on|ON|1)     printf 'true' ;;
        false|FALSE|False|no|NO|off|OFF|0)  printf 'false' ;;
        *) return 1 ;;
    esac
}

# nb_url_ok accepts only an absolute http/https URL with a host, which is what
# netbird's parseURL requires. A bare host or a scheme-less value is rejected
# here rather than by the daemon, where the error is much harder to see.
nb_url_ok() {
    case "$1" in
        https://?*|http://?*) return 0 ;;
        *) return 1 ;;
    esac
}

# nb_url_is_plain_http reports a http:// URL. Not an error -- a management
# server can legitimately be plain HTTP -- but behind a TLS-redirecting proxy
# it produces a gRPC "unexpected HTTP status code 308" that reads as a total
# mystery, so the UI warns about it.
nb_url_is_plain_http() {
    case "$1" in
        http://?*) return 0 ;;
        *) return 1 ;;
    esac
}

# nb_load_config reads the config file and exports each key as NBQ_<KEY>.
#
# The file is sourced (so hand-written variants with different quoting still
# work) but only inside a subshell, and every key is unset first. Sourcing it
# directly into the caller would let an unrelated ambient variable masquerade
# as configuration -- HOSTNAME is always set by the shell on QTS, so the old
# code passed the NAS hostname to netbird even when the setting was blank.
nb_load_config() {
    __nb_file="$1"
    __nb_dump=$(
        for __nb_k in $(nb_conf_keys); do
            unset "$__nb_k" 2>/dev/null
        done
        [ -f "$__nb_file" ] && . "$__nb_file" >/dev/null 2>&1
        for __nb_k in $(nb_conf_keys); do
            eval "__nb_v=\${$__nb_k-}"
            __nb_v=$(printf '%s' "$__nb_v" | tr -d '\r\n')
            printf 'NBQ_%s=%s\n' "$__nb_k" "$(nb_sq "$__nb_v")"
        done
    )
    eval "$__nb_dump"
}

# nb_write_config writes every NBQ_<KEY> back out. Values are single-quoted, so
# a quote, backtick or $ in a field (entirely possible in EXTRA_ARGS or a
# pre-shared key) cannot break the file or inject into the service script.
nb_write_config() {
    __nb_file="$1"
    {
        echo "# Netbird VPN configuration for QNAP"
        echo "# Managed by the Netbird settings page. Hand edits are preserved,"
        echo "# but are rewritten in this form the next time you press Save."
        echo "#"
        echo "# Apply changes with:  /etc/init.d/netbird.sh restart"
        echo "# Booleans accept true/false; empty means 'leave netbird's current"
        echo "# setting alone' rather than 'off'."
        echo ""
        for __nb_k in $(nb_conf_keys); do
            eval "__nb_v=\${NBQ_$__nb_k-}"
            printf '%s=%s\n' "$__nb_k" "$(nb_sq "$__nb_v")"
        done
    } > "$__nb_file"
}

# nb_json_escape escapes a string for embedding in a JSON string literal.
#
# Newlines become the two characters \n by appending them to every line but the
# last and then dropping the real newlines. The obvious ':a;N;$!ba' hold-space
# trick is avoided on purpose: N at end of input exits without printing on BSD
# sed and is not guaranteed by POSIX, so it silently returns nothing.
#
# Tabs become spaces and carriage returns are dropped rather than being escaped
# properly -- neither appears in netbird's status output or in a config value,
# and matching a literal tab portably in a sed script is not worth the trouble.
nb_json_escape() {
    printf '%s\n' "$1" \
        | tr -d '\r' | tr '\t' ' ' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | sed -e '$!s/$/\\n/' \
        | tr -d '\n'
}

# nb_json_str pulls a top-level string field out of a JSON document.
nb_json_str() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | tail -1
}
