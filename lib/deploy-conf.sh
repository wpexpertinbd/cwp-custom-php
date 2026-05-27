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

# Bootstrap /usr/local/cwp/.conf/php-fpm_conf/X.Y_last_build.ini.
#
# CWP's PHP-FPM Selector UI writes this file when admin clicks "Build" — it's
# CWP's record of "what was selected last build" so the UI checkboxes
# pre-populate correctly on next visit. On fresh servers where we deploy PHP
# without admin ever clicking Build, this file is MISSING and the UI shows
# "no previous build" state for our versions. Reported on s1/s3/s4 — boss
# wanted us to bootstrap it automatically.
#
# Format: same as our shipped X.Y.elN.ini but with values quoted AND a
# [version] block appended (major="8.4" minor="8.4.21").
#
# Called from build_php() AFTER atomic_swap succeeds (so we know the actual
# installed version for the [version] block's minor= field).
deploy_last_build_ini() {
    local major="$1"        # e.g. 8.4
    local phpver="${2:-}"   # e.g. 8.4.21 (actual installed)
    local target="${CONFBASE}/${major}_last_build.ini"

    # Find source ini — prefer EL-specific
    local repo_ini=""
    if [ -f "${REPO_ROOT}/selector/${major}.el${BH_EL_MAJOR:-8}.ini" ]; then
        repo_ini="${REPO_ROOT}/selector/${major}.el${BH_EL_MAJOR:-8}.ini"
    elif [ -f "${REPO_ROOT}/selector/${major}.ini" ]; then
        repo_ini="${REPO_ROOT}/selector/${major}.ini"
    else
        warn "deploy_last_build_ini: no source ini for ${major} — skipping"
        return 0
    fi

    # Backup existing
    [ -f "$target" ] && backup_file "$target"

    # Generate: transform CWP-selector-ini -> last_build.ini
    # CWP quotes assignment values; we mirror that. Then append [version] block.
    mkdir -p "$CONFBASE"
    awk -v ver="$major" -v minor="$phpver" '
        # Lines like  key=value  -> key="value"  (only for the keys CWP quotes)
        /^(default|required|info-file|option|script|pre-script|include)=/ {
            key = $0
            sub(/=.*/, "", key)
            val = $0
            sub(/^[^=]*=/, "", val)
            # Strip existing surrounding quotes if any
            sub(/^"/, "", val)
            sub(/"$/, "", val)
            printf "%s=\"%s\"\n", key, val
            next
        }
        { print }
        END {
            print "[version]"
            printf "major=\"%s\"\n", ver
            printf "minor=\"%s\"\n", minor
        }
    ' "$repo_ini" > "$target"

    ok "${major}_last_build.ini bootstrapped  (mirrors selector ini + [version] major=${major} minor=${phpver:-unset})"
}
