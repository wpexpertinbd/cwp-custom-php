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
# NOTE: only a FALLBACK. The repo snapshot goes stale the moment it is committed,
# so never treat it as the truth about what is installed — see _vm_installed_fullver.
_vm_repo_latest() {
    local want="$1"
    local repo_file="${REPO_ROOT}/selector/versions.ini"
    _vm_extract_section "$repo_file" "$want" \
        | grep -E '^version\[\]=' \
        | head -1
}

# Ask the INSTALLED binary what it actually is, e.g. 8.4 -> 8.4.24.
# This is the only trustworthy source: the repo snapshot lags reality, and
# resolve_php_version() only says what was *requested*, not what survived the
# build. If a build failed and rolled back, this reports the older version that
# is genuinely on disk — which is exactly what the UI dropdown should offer.
_vm_installed_fullver() {
    local major="$1"
    local short; short="$(php_short "$major")"
    local bin="/opt/alt/php-fpm${short}/usr/bin/php"
    [ -x "$bin" ] || return 1
    local v
    v=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null | tr -d '[:space:]')
    case "$v" in
        "${major}."*) echo "$v"; return 0 ;;
        *) return 1 ;;
    esac
}

# Recent published releases for a branch, straight from php.net, newest first.
# Emits NOTHING on any failure (offline, DNS, php.net down). Callers treat empty
# as "no upstream input" and still merge the installed + already-listed entries,
# so a network hiccup can never shrink the catalogue.
_vm_upstream_versions() {
    local major="$1"
    local url="https://www.php.net/releases/?json&max=40&version=${major}"
    curl -fsSL --max-time 20 "$url" 2>/dev/null \
        | grep -oE "\"${major//./\\.}\.[0-9]+\"" \
        | tr -d '"' \
        | sort -Vru
}

# Replace one [X.Y] section of an ini file with the block held in <blockfile>.
# The block comes from a file, not a shell variable, so multi-line content never
# has to survive awk -v quoting. Writes through the original inode so CWP's file
# keeps its owner/mode.
_vm_replace_section() {
    local file="$1" ver="$2" blockfile="$3"
    local tmp; tmp=$(mktemp) || return 1
    awk -v hdr="[${ver}]" '
        NR == FNR { blk = blk $0 "\n"; next }        # slurp the replacement
        $0 == hdr { printf "%s", blk; inside = 1; done = 1; next }
        inside && /^[[:space:]]*\[/ { inside = 0 }   # next section starts
        inside { next }                              # drop the stale body
        { print }
        END { if (!done) exit 1 }
    ' "$blockfile" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Render "[X.Y]" + one version[] line per entry (newest first) + a blank line.
_vm_render_block() {
    local ver="$1" list="$2" out="$3"
    { printf '[%s]\n' "$ver"
      printf '%s\n' "$list" | while IFS= read -r v; do
          [ -n "$v" ] && printf 'version[]=%s\n' "$v"
      done
      printf '\n'
    } > "$out"
}

# Main merge function — called from install.sh
ensure_versions_ini() {
    # BH_CWP_SEL exists so this can be exercised against a scratch copy off-box;
    # it is never set in production.
    local CWP_SEL="${BH_CWP_SEL:-/usr/local/cwpsrv/htdocs/resources/conf/el${BH_EL_MAJOR:-8}/php-fpm_selector}"
    local LIVE="${CWP_SEL}/versions.ini"
    local REPO_VERSIONS="${REPO_ROOT}/selector/versions.ini"

    section "Sync versions.ini — advertise every PHP release this box can offer"

    if [ ! -f "$LIVE" ]; then
        warn "Live versions.ini not found: $LIVE — skipping"
        return 0
    fi

    # Only these branches are ours to touch. 5.x / 7.x / 8.0 / 8.1 are CWP's and
    # flow through completely untouched, exactly as the header comment promises.
    local managed="8.2 8.3 8.4 8.5"

    backup_file "$LIVE"

    local changed=0 ver
    for ver in $managed; do
        local have_section=0 installed=""
        grep -qE "^\[${ver}\][[:space:]]*$" "$LIVE" && have_section=1
        installed=$(_vm_installed_fullver "$ver") || installed=""

        # Ignore a branch this box neither lists nor runs — don't invent sections.
        [ "$have_section" -eq 0 ] && [ -z "$installed" ] && continue

        # Build the UNION of everything we know about this branch:
        #   1. what CWP already lists   (never lose a CWP entry)
        #   2. what is actually installed  (the binary is the ground truth)
        #   3. what php.net has published  (this is the bit that used to be a
        #      manual "download CWP's ini, look up 8.4/8.5, re-upload" chore)
        #   4. the repo snapshot, last resort for an offline box
        # A union can only ever ADD. The old blind copy could REMOVE, which is
        # exactly how the catalogue kept regressing on every rebuild.
        local pool; pool=$(mktemp)
        if [ "$have_section" -eq 1 ]; then
            _vm_extract_section "$LIVE" "$ver" | sed -n 's/^version\[\]=//p' >> "$pool"
        fi
        [ -n "$installed" ] && printf '%s\n' "$installed" >> "$pool"
        _vm_upstream_versions "$ver" >> "$pool"
        if [ -f "$REPO_VERSIONS" ]; then
            _vm_extract_section "$REPO_VERSIONS" "$ver" | sed -n 's/^version\[\]=//p' >> "$pool"
        fi

        # Keep only well-formed releases of THIS branch, newest first, deduped.
        local merged
        merged=$(grep -E "^${ver//./\\.}\.[0-9]+$" "$pool" | sort -Vru)
        rm -f "$pool"
        if [ -z "$merged" ]; then
            warn "  [${ver}]: no usable versions found — leaving section as-is"
            continue
        fi

        # Skip the rewrite when nothing actually differs.
        local current=""
        [ "$have_section" -eq 1 ] && current=$(_vm_extract_section "$LIVE" "$ver" | sed -n 's/^version\[\]=//p')
        if [ "$current" = "$merged" ]; then
            ok "  [${ver}]: already in sync ($(printf '%s\n' "$merged" | grep -c .) releases, newest $(printf '%s\n' "$merged" | head -1))"
            continue
        fi

        local blk; blk=$(mktemp)
        _vm_render_block "$ver" "$merged" "$blk"

        local n_new n_old
        n_new=$(printf '%s\n' "$merged" | grep -c .)
        n_old=$(printf '%s\n' "$current" | grep -c . || true)

        if [ "$have_section" -eq 1 ]; then
            if _vm_replace_section "$LIVE" "$ver" "$blk"; then
                ok "  [${ver}]: ${n_old} -> ${n_new} releases, newest now $(printf '%s\n' "$merged" | head -1)"
                changed=$((changed + 1))
            else
                warn "  [${ver}]: rewrite failed — live file left untouched"
            fi
        else
            [ -s "$LIVE" ] && [ "$(tail -c1 "$LIVE" | wc -l)" -eq 0 ] && printf '\n' >> "$LIVE"
            printf '\n' >> "$LIVE"
            cat "$blk" >> "$LIVE"
            ok "  [${ver}]: section CREATED with ${n_new} releases, newest $(printf '%s\n' "$merged" | head -1)"
            changed=$((changed + 1))
        fi
        rm -f "$blk"
    done

    if [ "$changed" -eq 0 ]; then
        ok "versions.ini already in sync — no changes needed"
    else
        ok "versions.ini updated — ${changed} section(s) refreshed"
    fi
}
