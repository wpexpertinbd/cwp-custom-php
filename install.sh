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
  --refresh-ioncube     Run ONLY the ioncube refresh and exit. Re-downloads
                        latest loaders from ioncube.com, re-wires every
                        /opt/alt/php-fpmNN, restarts services. Run this
                        after CWP rebuilds (which wipe /usr/local/ioncube).
  --disable-ext=LIST    Comma-list of extensions to disable post-build (.ini
                        renamed to .ini.disabled, .so kept on disk).
                        Default: mongodb,sourceguardian — both emit noisy
                        deprecation/version warnings on every CLI invocation.
                        Pass --disable-ext= (empty) to disable nothing.
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
        -h|--help)    usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done
export BH_FORCE_CONF="$FORCE_CONF"
export BH_DISABLE_EXTENSIONS

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

# --refresh-ioncube shortcut (standalone, no build)
if [ "$REFRESH_IONCUBE_ONLY" -eq 1 ]; then
    require_root
    refresh_ioncube
    exit $?
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

section "Summary"
for spec in "${BUILT[@]}"; do
    major="${spec%%:*}"
    postcheck "$major"
done

ok "All done. Backups: /root/cwp-php-backups/${BH_RUN_STAMP}/"
