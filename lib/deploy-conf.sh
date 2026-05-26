#!/bin/bash
# deploy-conf.sh — seed /usr/local/cwp/.conf/php-fpm_conf/ with known-good
# php{NN}.conf / php{NN}_pre.conf / php{NN}_external.conf if missing.
#
# Normally CWP generates these the first time you click "Build" in the GUI.
# We ship a copy so the unattended install works without the manual GUI step,
# AND so the mbstring fix (which depends on a corrected php{NN}.conf) is in
# place from day one.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

CONFBASE="/usr/local/cwp/.conf/php-fpm_conf"

deploy_conf() {
    local major="$1"
    local short; short="$(php_short "$major")"
    local repo_conf="${REPO_ROOT}/selector/php-fpm_conf"

    # EL9 ships no seeded php-fpm_conf — CWP generates clean ones natively.
    if [ "${BH_EL_MAJOR:-8}" -eq 9 ]; then
        log "EL9: skipping php-fpm_conf seed (CWP generates these natively on EL9)"
        return 0
    fi

    section "Deploy build configs for PHP $major"

    mkdir -p "$CONFBASE"

    local kind
    for kind in '' '_pre' '_external'; do
        local target="${CONFBASE}/php${short}${kind}.conf"
        local source="${repo_conf}/php${short}${kind}.conf"

        if [ -f "$source" ]; then
            if [ -f "$target" ]; then
                # Only overwrite if user asked --force-conf, else just back up the new one
                if [ "${BH_FORCE_CONF:-0}" -eq 1 ]; then
                    backup_file "$target"
                    install -m 0755 "$source" "$target"
                    ok "php${short}${kind}.conf overwritten (--force-conf)"
                else
                    ok "php${short}${kind}.conf already present — kept (use --force-conf to overwrite)"
                fi
            else
                install -m 0755 "$source" "$target"
                ok "php${short}${kind}.conf seeded from repo"
            fi
            dos2unix -q "$target" 2>/dev/null || true
        fi
    done
}
