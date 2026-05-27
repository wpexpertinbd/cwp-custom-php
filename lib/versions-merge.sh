#!/bin/bash
# versions-merge.sh — keep CWP's versions.ini in sync with our installed PHP-FPM versions.
#
# CWP's auto-updates and /scripts/update_cwp periodically REWRITE
# /usr/local/cwpsrv/htdocs/resources/conf/elN/php-fpm_selector/versions.ini
# with CWP's bundled file (which only lists 5.x-8.3). Our custom 8.4 / 8.5
# (and any newer point releases for 8.2 / 8.3 we manage) silently disappear
# from the CWP UI's PHP-FPM Selector dropdown — admins can no longer assign
# new tenants to those versions even though the services keep running.
#
# This module is called from the --refresh-ioncube flow as the standing
# recovery command. It's additive:
#   - If a [X.Y] section is MISSING from versions.ini → append our copy
#   - If a [X.Y] section EXISTS but our latest point release is missing →
#     append that one version[] line into that section
#   - If a section exists and our latest IS present → no-op
#   - Sections for versions we DON'T manage (5.x, 7.x, 8.0, 8.1) are
#     never touched. CWP's updates to those flow through unchanged.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Detect installed /opt/alt/php-fpm-NN dirs that look real.
# Skip .rollback / .failed / .bak dirs. Skip empty/broken installs.
_vm_detect_installed_majors() {
    local fpm major
    for fpm in /opt/alt/php-fpm*; do
        [ -d "$fpm" ] || continue
        major=$(basename "$fpm" | sed 's/^php-fpm//')
        case "$major" in (*.rollback.*|*.failed.*|*.bak.*|*.old.*) continue ;; esac
        # Only consider modern majors we manage (82, 83, 84, 85)
        case "$major" in
            82|83|84|85)
                [ -x "${fpm}/usr/bin/php" ] || continue
                # Print as dot version: 82 -> 8.2
                echo "${major:0:1}.${major:1}"
                ;;
        esac
    done
}

# Extract one [X.Y] section from an INI file (header + all version[] lines
# until the next section header or EOF).
_vm_extract_section() {
    local file="$1" want="$2"
    awk -v want="[$want]" '
        $0 == want { in_section = 1; print; next }
        in_section && /^[[:space:]]*\[/ { exit }
        in_section { print }
    ' "$file"
}

# Get the LATEST (first) version[] line in a section of our repo's versions.ini
# Our repo lists newest -> oldest, so the first version[] in the section is latest.
_vm_repo_latest() {
    local want="$1"
    local repo_file="${REPO_ROOT}/selector/versions.ini"
    _vm_extract_section "$repo_file" "$want" \
        | grep -E '^version\[\]=' \
        | head -1
}

# Main merge function — called from install.sh
ensure_versions_ini() {
    local CWP_SEL="/usr/local/cwpsrv/htdocs/resources/conf/el${BH_EL_MAJOR:-8}/php-fpm_selector"
    local LIVE="${CWP_SEL}/versions.ini"
    local REPO_VERSIONS="${REPO_ROOT}/selector/versions.ini"

    section "Auto-merge versions.ini — ensure our PHP-FPM versions are visible in CWP UI"

    if [ ! -f "$LIVE" ]; then
        warn "Live versions.ini not found: $LIVE — skipping merge"
        return 0
    fi
    if [ ! -f "$REPO_VERSIONS" ]; then
        warn "Repo versions.ini not found: $REPO_VERSIONS — skipping merge"
        return 0
    fi

    # Detect installed custom PHP versions
    local detected=()
    while IFS= read -r v; do
        [ -n "$v" ] && detected+=("$v")
    done < <(_vm_detect_installed_majors)

    if [ ${#detected[@]} -eq 0 ]; then
        log "No /opt/alt/php-fpm{82,83,84,85} detected — nothing to merge into versions.ini"
        return 0
    fi

    log "Detected installed custom PHP majors: ${detected[*]}"

    # Backup before modifying
    backup_file "$LIVE"

    local changed=0 ver
    for ver in "${detected[@]}"; do
        if ! grep -qE "^\[${ver}\][[:space:]]*$" "$LIVE"; then
            # Section missing entirely — append from repo
            local block; block=$(_vm_extract_section "$REPO_VERSIONS" "$ver")
            if [ -z "$block" ]; then
                warn "  [${ver}]: missing in BOTH live AND repo — please update repo versions.ini"
                continue
            fi
            {
                # Ensure file ends with newline before append
                tail -c1 "$LIVE" | od -An -c | grep -q '\\n' || echo "" >> "$LIVE"
                echo ""
                echo "$block"
            } >> "$LIVE"
            ok "  [${ver}]: section APPENDED to versions.ini ($(echo "$block" | grep -c '^version\[\]=') version entries)"
            changed=$((changed + 1))
            continue
        fi

        # Section exists. Check if our latest version[] is already in there.
        local latest_line; latest_line=$(_vm_repo_latest "$ver")
        if [ -z "$latest_line" ]; then
            log "  [${ver}]: no latest entry in repo (unusual) — leaving live file as-is"
            continue
        fi

        if grep -qF "$latest_line" "$LIVE"; then
            ok "  [${ver}]: present, our latest ${latest_line#version[]=} already listed"
            continue
        fi

        # Insert latest_line right after the [X.Y] header so it appears first in UI dropdown.
        # awk-based atomic insert to a temp file, then mv into place.
        local tmp; tmp=$(mktemp)
        awk -v hdr="[${ver}]" -v ins="$latest_line" '
            { print }
            $0 == hdr { print ins; inserted = 1 }
            END { if (!inserted) exit 1 }
        ' "$LIVE" > "$tmp" && mv "$tmp" "$LIVE" \
            && ok "  [${ver}]: appended ${latest_line#version[]=} (new latest)" \
            || { rm -f "$tmp"; warn "  [${ver}]: insert failed — leaving file as-is"; }
        changed=$((changed + 1))
    done

    if [ "$changed" -eq 0 ]; then
        ok "versions.ini already in sync — no changes needed"
    else
        ok "versions.ini updated — ${changed} section/entry change(s)"
    fi
}
