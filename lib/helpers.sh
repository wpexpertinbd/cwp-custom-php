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

# ── Build throttling ─────────────────────────────────────────────────
# Compiling PHP is the single heaviest thing this script does. On a busy
# shared-hosting box an unniced `make -j$(nproc)` will happily take every
# core and starve the customers' php-fpm workers — which shows up as slow
# sites and, behind Varnish, 503s. So:
#   * leave 2 cores unused by default (still fast, keeps the panel usable)
#   * run the compiler at nice 10 so ANY normal-priority process (php-fpm,
#     mysqld, nginx) preempts it instantly
#   * run it at ionice class 3 (idle) so the disk stays responsive
# Override with --jobs N / BH_MAKE_JOBS, and BH_BUILD_NICE=0 to disable.
build_jobs() {
    if [ -n "${BH_MAKE_JOBS:-}" ]; then echo "$BH_MAKE_JOBS"; return; fi
    local n=1
    command -v nproc >/dev/null 2>&1 && n="$(nproc)"
    if [ "$n" -gt 3 ]; then echo "$((n - 2))"; else echo 1; fi
}

# Prefix for the compile commands: nice + ionice when available.
build_nice_prefix() {
    [ "${BH_BUILD_NICE:-10}" = "0" ] && return 0
    local p=""
    command -v nice   >/dev/null 2>&1 && p="nice -n ${BH_BUILD_NICE:-10}"
    command -v ionice >/dev/null 2>&1 && p="ionice -c3 $p"
    echo "$p"
}

# Validate "8.2", "8.3", "8.4", "8.5" only
valid_major() {
    case "$1" in
        8.2|8.3|8.4|8.5) return 0 ;;
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
            # php.net returns the version as the TOP-LEVEL JSON KEY, e.g.
            #   {"8.4.24":{"announcement":true,"tags":["security"],...}}
            # There is NO "version":"x.y.z" field — the old parser looked for
            # one, always got nothing, and silently fell through to the
            # hard-coded list below. Result: every `--php X=latest` install
            # quietly built a STALE release (the whole fleet ended up pinned to
            # the fallback versions for months). Parse the key instead.
            ver=$(printf '%s' "$json" | sed -nE 's/^\{"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' | head -1)
            # belt-and-braces: first bare quoted version matching this major
            [ -n "$ver" ] || ver=$(printf '%s' "$json" \
                | grep -oE "\"${major//./\\.}\.[0-9]+\"" | head -1 | tr -d '"')
            # never accept an answer from the wrong branch
            case "$ver" in
                "${major}."*) echo "$ver"; return 0 ;;
                *) [ -n "$ver" ] && warn "php.net returned '$ver' for branch $major — ignoring" ;;
            esac
        fi
        warn "could not resolve latest $major from php.net — using built-in fallback (may be outdated)"
        # Fallback hard-coded defaults (verified 2026-08-02; keep in sync)
        case "$major" in
            8.2) echo "8.2.33" ;;
            8.3) echo "8.3.33" ;;
            8.4) echo "8.4.24" ;;
            8.5) echo "8.5.9"  ;;
        esac
    else
        echo "$hint"
    fi
}

# Require root
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must run as root."
}

# Point /usr/local/bin/php, php-cgi, phpdbg, php-config, phpize at one of our
# /opt/alt/php-fpmNN/usr/bin/ binaries via symlinks. This is the canonical way
# to bridge "CWP system PHP" (which uses /usr/local/bin/php-cgi) to our custom
# builds — replaces the manual ln -sfn ritual.
# Argument is a PHP major like 8.3 (or empty/0 to skip).
apply_system_php_symlinks() {
    local major="$1"
    if [ -z "$major" ] || [ "$major" = "0" ]; then
        return 0
    fi
    if ! valid_major "$major"; then
        warn "system-php: invalid major '${major}' — skipping"
        return 0
    fi
    local short; short="$(php_short "$major")"
    local src_dir="/opt/alt/php-fpm${short}/usr/bin"
    if [ ! -x "${src_dir}/php" ]; then
        warn "system-php: ${src_dir}/php not present — skipping (build that version first)"
        return 0
    fi
    section "Pointing /usr/local/bin/ system PHP -> /opt/alt/php-fpm${short}/usr/bin/"
    local linked=0 missing=0 b
    for b in php php-cgi phpdbg php-config phpize; do
        if [ -x "${src_dir}/${b}" ]; then
            ln -sfn "${src_dir}/${b}" "/usr/local/bin/${b}"
            ok "  /usr/local/bin/${b} -> ${src_dir}/${b}"
            linked=$((linked + 1))
        else
            log "  skip ${b} (not in ${src_dir})"
            missing=$((missing + 1))
        fi
    done
    hash -r 2>/dev/null || true
    ok "Linked ${linked} system PHP binaries to /opt/alt/php-fpm${short}/usr/bin/"
    log "Reloading httpd so it picks up the new system php-cgi"
    systemctl reload httpd 2>/dev/null \
        || warn "httpd reload returned non-zero (sites may need manual restart)"
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
