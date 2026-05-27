#!/bin/bash
# install.sh — one-shot installer/updater for custom PHP-FPM on CWP EL8.
#
# Usage examples (run as root):
#   bash install.sh --php 8.4
#   bash install.sh --php 8.4=8.4.21
#   bash install.sh --php 8.4=latest
#   bash install.sh --php 8.3,8.4,8.5
#   bash install.sh --php 8.4 --build-only      # skip GUI scaffolding deploy
#   bash install.sh --fix-dnf                    # only repair /etc/ld.so.conf.d/curl-local.conf trap
#   bash install.sh --php 8.4 --force-conf       # overwrite existing php{NN}.conf
#
# One-liner over the network:
#   curl -fsSL https://raw.githubusercontent.com/<user>/cwp-custom-php-el8/main/install.sh \
#     | bash -s -- --php 8.4
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Auto-logging: redirect all stdout/stderr to a log file AND keep terminal.
# Default: /root/cwp-custom-php-<hostname>-<stamp>.log
# Override via:  BH_LOG_FILE=/path/to/log.txt  bash install.sh ...
# Disable via:   BH_LOG_FILE=/dev/null  bash install.sh ...
# Or by passing --no-log (handled below before exec redirect).
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--no-log" ]; then
    shift
    BH_LOG_FILE=/dev/null
fi
BH_RUN_STAMP="${BH_RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
BH_HOST_SHORT="${BH_HOST_SHORT:-$(hostname -s 2>/dev/null || echo host)}"
BH_LOG_FILE="${BH_LOG_FILE:-/root/cwp-custom-php-${BH_HOST_SHORT}-${BH_RUN_STAMP}.log}"
if [ "$BH_LOG_FILE" != "/dev/null" ]; then
    mkdir -p "$(dirname "$BH_LOG_FILE")" 2>/dev/null || true
    # tee with -a so we don't truncate on re-runs that share a stamp
    exec > >(tee -a "$BH_LOG_FILE") 2>&1
    printf '\n[install.sh] %s — logging to %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BH_LOG_FILE"
fi
export BH_RUN_STAMP BH_LOG_FILE

# Print log path at exit so user always knows where it lives
_print_log_on_exit() {
    local rc=$?
    if [ "$BH_LOG_FILE" != "/dev/null" ]; then
        printf '\n[install.sh] exit %s — log at: %s\n' "$rc" "$BH_LOG_FILE"
    fi
}
trap _print_log_on_exit EXIT

# -----------------------------------------------------------------------------
# Locate REPO_ROOT: support both "bash install.sh" and "curl|bash"
# -----------------------------------------------------------------------------
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # curl|bash mode — clone repo to a temp dir
    REPO_ROOT="/tmp/cwp-custom-php-$$"
    : "${BH_REPO_URL:=https://github.com/wpexpertinbd/cwp-custom-php.git}"
    : "${BH_REPO_BRANCH:=main}"
    echo "[install.sh] curl|bash mode — cloning $BH_REPO_URL ($BH_REPO_BRANCH) -> $REPO_ROOT"
    command -v git >/dev/null 2>&1 || { dnf install -y git >/dev/null 2>&1 || { echo "git required"; exit 1; } ; }
    git clone --depth 1 --branch "$BH_REPO_BRANCH" "$BH_REPO_URL" "$REPO_ROOT" >/dev/null
fi
export REPO_ROOT

# -----------------------------------------------------------------------------
# Sources
# -----------------------------------------------------------------------------
# shellcheck source=lib/helpers.sh
. "${REPO_ROOT}/lib/helpers.sh"
# shellcheck source=lib/preflight.sh
. "${REPO_ROOT}/lib/preflight.sh"
# shellcheck source=lib/deploy-gui.sh
. "${REPO_ROOT}/lib/deploy-gui.sh"
# shellcheck source=lib/deploy-conf.sh
. "${REPO_ROOT}/lib/deploy-conf.sh"
# shellcheck source=lib/build-php.sh
. "${REPO_ROOT}/lib/build-php.sh"
# shellcheck source=lib/postcheck.sh
. "${REPO_ROOT}/lib/postcheck.sh"
# shellcheck source=lib/ioncube.sh
. "${REPO_ROOT}/lib/ioncube.sh"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
PHP_SPECS=""            # comma list: "8.3" or "8.4=8.4.21"
BUILD_ONLY=0
FIX_DNF_ONLY=0
REFRESH_IONCUBE_ONLY=0
FORCE_CONF=0
BIG_UPLOAD_MB="${BH_BIG_UPLOAD_MB:-2048}"   # default 2048 MB; set 0 to skip

usage() {
    cat <<'EOF'
Usage: install.sh --php <major[=version|=latest]>[,major2[=ver],...] [options]

Required:
  --php X.Y[=VER]       PHP majors to install/update. Accepts:
                          --php 8.4                  -> latest 8.4.x
                          --php 8.4=8.4.21           -> pinned
                          --php 8.4=latest           -> resolve newest
                          --php 8.3,8.4,8.5          -> multiple
                          --php 8.3=8.3.31,8.4=latest

Options:
  --build-only          Skip deploying GUI scaffolding (versions.ini, *.ini,
                        external_modules/, pre_run/). Use for repeat builds
                        when scaffolding is already in place.
  --force-conf          Overwrite existing /usr/local/cwp/.conf/php-fpm_conf/
                        php{NN}*.conf files with the repo copies (backed up).
  --fix-dnf             Run ONLY the curl-ld.so trap repair and exit. Useful
                        if previous manual curl-from-source install broke
                        dnf/yum/nginx repo.
  --refresh-ioncube     Post-CWP-rebuild recovery. Auto-installs libzip if
                        CWP UI rebuild removed it, re-downloads latest ioncube
                        loaders from ioncube.com, re-wires every
                        /opt/alt/php-fpmNN, restarts ALL custom php-fpm
                        services. Run this after ANY CWP UI rebuild
                        (PHP Version Switcher, PHP Selector, PHP-FPM
                        Selector, Rebuild Apache+PHP).
  --disable-ext=LIST    Comma-list of extensions to disable post-build (.ini
                        renamed to .ini.disabled, .so kept on disk).
                        Default: mongodb,sourceguardian — both emit noisy
                        deprecation/version warnings on every CLI invocation.
                        Pass --disable-ext= (empty) to disable nothing.
  --big-upload=SIZE_MB  After build, run CWP's /scripts/php_big_file_upload
                        SIZE_MB all  — bumps upload_max_filesize, post_max_size,
                        memory_limit (PHP) + client_max_body_size (Nginx) +
                        LimitRequestBody (Apache) across ALL PHP versions on
                        the box. Default: 2048 (2GB).
                        Pass --big-upload=0 to skip.
  --clean-shadow-libs   When preflight detects shadow libs/binaries in
                        /usr/local/lib*/ or /usr/local/bin/, auto-quarantine
                        them to /root/cwp-php-backups/stale-libs/. Default is
                        to warn-only (safer for unknown servers). Use this on
                        your fleet after you've confirmed the pattern is safe.
  --system-php=X.Y      After build, symlink /usr/local/bin/{php,php-cgi,
                        phpdbg,php-config,phpize} -> /opt/alt/php-fpmXY/usr/
                        bin/. Makes "CWP system PHP" use our custom build.
                        Replaces the manual ln -sfn ritual. Example:
                        --system-php=8.3
  --no-log              Disable automatic log file creation. Logs are written
                        to /root/cwp-custom-php-<host>-<stamp>.log by default.
                        Override path via BH_LOG_FILE env var.
  -h, --help            This text.

Examples:
  bash install.sh --php 8.4
  bash install.sh --php 8.3=8.3.31,8.4=8.4.21,8.5=latest
  bash install.sh --fix-dnf
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --php)        PHP_SPECS="$2"; shift 2 ;;
        --php=*)      PHP_SPECS="${1#*=}"; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --force-conf) FORCE_CONF=1; shift ;;
        --fix-dnf)    FIX_DNF_ONLY=1; shift ;;
        --refresh-ioncube) REFRESH_IONCUBE_ONLY=1; shift ;;
        --disable-ext)     BH_DISABLE_EXTENSIONS="$2"; shift 2 ;;
        --disable-ext=*)   BH_DISABLE_EXTENSIONS="${1#*=}"; shift ;;
        --big-upload)      BIG_UPLOAD_MB="$2"; shift 2 ;;
        --big-upload=*)    BIG_UPLOAD_MB="${1#*=}"; shift ;;
        --clean-shadow-libs) BH_CLEAN_SHADOW_LIBS=1; shift ;;
        --system-php)        BH_SYSTEM_PHP="$2"; shift 2 ;;
        --system-php=*)      BH_SYSTEM_PHP="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done
export BH_FORCE_CONF="$FORCE_CONF"
export BH_DISABLE_EXTENSIONS
export BH_CLEAN_SHADOW_LIBS="${BH_CLEAN_SHADOW_LIBS:-0}"

# -----------------------------------------------------------------------------
# --fix-dnf shortcut
# -----------------------------------------------------------------------------
if [ "$FIX_DNF_ONLY" -eq 1 ]; then
    require_root
    section "Fix dnf / curl-local.conf trap"
    fix_curl_ld_trap
    log "Testing dnf"
    if dnf -y makecache >/dev/null 2>&1; then
        ok "dnf works again"
    else
        err "dnf still failing — investigate /etc/ld.so.conf.d/ and ldd /usr/lib64/librepo.so.0"
        exit 1
    fi
    exit 0
fi

# --refresh-ioncube shortcut (standalone, no build).
# This is the canonical recovery command after ANY CWP UI rebuild
# (PHP Version Switcher, PHP Selector, PHP-FPM Selector, Rebuild Apache + PHP).
# CWP UI rebuilds can wipe BOTH /usr/local/ioncube/ AND the libzip RPM, so this
# path fixes both, then restarts every /opt/alt/php-fpmNN service to pick up
# the restored libs.
if [ "$REFRESH_IONCUBE_ONLY" -eq 1 ]; then
    require_root
    section "Post-CWP-rebuild recovery — libzip + ioncube + service restart"

    # 1. Restore libzip if CWP UI rebuild removed it
    check_libzip

    # 2. Restore ioncube loaders + re-wire every /opt/alt/php-fpmNN
    refresh_ioncube
    rc=$?

    # 3. Restart every detected /opt/alt/php-fpmNN service so the new libzip
    #    is loaded by running workers (without restart they keep the old
    #    file handles or fail to start if they were stopped).
    section "Restarting all custom php-fpmNN services"
    for fpm in /opt/alt/php-fpm*; do
        [ -d "$fpm" ] || continue
        major=$(basename "$fpm" | sed 's/^php-fpm//')
        # Skip rollback/failed/bak dirs
        case "$major" in (*.rollback.*|*.failed.*|*.bak.*|*.old.*) continue ;; esac
        if systemctl list-unit-files 2>/dev/null | grep -q "php-fpm${major}.service"; then
            if systemctl restart "php-fpm${major}" 2>/dev/null; then
                ver=$("${fpm}/usr/bin/php" -v 2>/dev/null | head -1)
                ok "  php-fpm${major} restarted  | ${ver:-?}"
            else
                warn "  php-fpm${major} restart failed — check journalctl -u php-fpm${major}"
            fi
        fi
    done

    exit "$rc"
fi

# Required arg
[ -n "$PHP_SPECS" ] || { usage; exit 2; }

# -----------------------------------------------------------------------------
# Main flow
# -----------------------------------------------------------------------------
preflight

IFS=',' read -r -a SPECS <<< "$PHP_SPECS"
BUILT=()

for spec in "${SPECS[@]}"; do
    spec="$(echo "$spec" | xargs)"        # trim
    [ -z "$spec" ] && continue
    major="${spec%%=*}"
    hint="${spec#*=}"
    [ "$hint" = "$spec" ] && hint=""      # no '=' means no hint

    if ! valid_major "$major"; then
        err "Unsupported PHP major: $major  (allowed: 8.3, 8.4, 8.5)"
        exit 2
    fi

    phpver="$(resolve_php_version "$major" "$hint")"
    [ -n "$phpver" ] || { err "Could not resolve PHP version for $major"; exit 2; }

    section "Target: PHP $major  ->  $phpver"

    if [ "$BUILD_ONLY" -eq 0 ]; then
        deploy_gui  "$major"
        deploy_conf "$major"
    else
        log "Skipping GUI/conf deploy (--build-only)"
    fi

    build_php "$(php_short "$major")" "$phpver"
    BUILT+=("$major:$phpver")
done

# -----------------------------------------------------------------------------
# Final report
# -----------------------------------------------------------------------------
# ioncube auto-heal (stale-only) — safety net for CWP rebuilds wiping /usr/local/ioncube
maybe_refresh_ioncube

# Bump PHP + Nginx + Apache upload/memory limits across all PHP versions via CWP's helper.
# Set BIG_UPLOAD_MB=0 (or --big-upload=0) to skip.
apply_big_upload "$BIG_UPLOAD_MB"

# Optional: point /usr/local/bin/php* at the built custom version.
apply_system_php_symlinks "${BH_SYSTEM_PHP:-}"

section "Summary"
for spec in "${BUILT[@]}"; do
    major="${spec%%:*}"
    postcheck "$major"
done

ok "All done. Backups: /root/cwp-php-backups/${BH_RUN_STAMP}/"
