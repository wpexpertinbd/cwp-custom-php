#!/bin/bash
# helpers.sh — shared logging, version-compare, backup utilities
# Sourced by install.sh and all lib/*.sh

# Colours (only if stdout is a TTY)
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Boss-tag header on each section
section() {
    printf '\n%s========== %s ==========%s\n' "$C_BLD" "$*" "$C_RST"
}

# version_lt 7.61.0 7.62.0  -> returns 0 (true)
version_lt() {
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<3; i++)); do
        local a=${ver1[i]:-0}
        local b=${ver2[i]:-0}
        if ((10#$a < 10#$b)); then return 0
        elif ((10#$a > 10#$b)); then return 1
        fi
    done
    return 1
}

# php_short 8.4  -> 84;   php_short 8.3 -> 83
php_short() { echo "${1//./}"; }

# Validate "8.3", "8.4", "8.5" only
valid_major() {
    case "$1" in
        8.3|8.4|8.5) return 0 ;;
        *) return 1 ;;
    esac
}

# Timestamped backup root, created on demand
backup_root() {
    local root="/root/cwp-php-backups/$BH_RUN_STAMP"
    mkdir -p "$root"
    echo "$root"
}

# backup_file <path>  — copies file/dir into backup_root preserving sub-path
backup_file() {
    local src="$1"
    [ -e "$src" ] || return 0
    local root; root="$(backup_root)"
    local dst="${root}${src}"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    log "backup: $src -> $dst"
}

# Resolve "latest" -> newest published PHPVER for a given major (php.net)
resolve_php_version() {
    local major="$1" hint="$2"
    if [ -z "$hint" ] || [ "$hint" = "latest" ]; then
        local url="https://www.php.net/releases/?json&max=1&version=${major}"
        local json
        if json=$(curl -fsSL --max-time 15 "$url" 2>/dev/null); then
            local ver
            ver=$(echo "$json" | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
            if [ -n "$ver" ]; then echo "$ver"; return 0; fi
        fi
        # Fallback hard-coded defaults (kept current as of repo last update)
        case "$major" in
            8.3) echo "8.3.31" ;;
            8.4) echo "8.4.21" ;;
            8.5) echo "8.5.6"  ;;
        esac
    else
        echo "$hint"
    fi
}

# Require root
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must run as root."
}

# Bump PHP + Nginx + Apache upload/memory limits via CWP's bundled helper.
# Single entry point — the CWP script edits every PHP version's php.ini, plus
# nginx client_max_body_size and Apache LimitRequestBody. Pass 0 to skip.
apply_big_upload() {
    local size_mb="${1:-2048}"
    if [ -z "$size_mb" ] || [ "$size_mb" = "0" ]; then
        log "big-upload: skipped (size=0)"
        return 0
    fi
    if ! [[ "$size_mb" =~ ^[0-9]+$ ]]; then
        warn "big-upload: invalid size '${size_mb}' (not a number) — skipping"
        return 0
    fi
    if [ ! -x /scripts/php_big_file_upload ] && [ ! -f /scripts/php_big_file_upload ]; then
        warn "big-upload: /scripts/php_big_file_upload not present (non-CWP box?) — skipping"
        return 0
    fi
    section "Bumping upload + memory limits to ${size_mb} MB (PHP + Nginx + Apache)"
    log "Running: sh /scripts/php_big_file_upload ${size_mb} all"
    if sh /scripts/php_big_file_upload "$size_mb" all; then
        ok "Limits bumped: upload_max_filesize / post_max_size / memory_limit / client_max_body_size / LimitRequestBody = ${size_mb} MB"
    else
        warn "/scripts/php_big_file_upload returned non-zero — verify settings manually."
    fi
}

# Run-stamp shared across all sourced scripts in a single install.sh invocation
: "${BH_RUN_STAMP:=$(date +%Y%m%d-%H%M%S)}"
export BH_RUN_STAMP
