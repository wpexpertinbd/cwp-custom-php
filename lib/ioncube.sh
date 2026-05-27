#!/bin/bash
# ioncube.sh — refresh /usr/local/ioncube/ with the latest loaders from ioncube.com,
# re-wire each detected /opt/alt/php-fpmNN to use them, restart services.
#
# Solves: CWP's "Rebuild Apache + PHP-FPM" and `sh /scripts/update_cwp` both
# overwrite /usr/local/ioncube/ with the stale bundled tarball that has no
# 8.4/8.5 loader. After every CWP rebuild, run:
#     bash install.sh --refresh-ioncube
# Or just rebuild any custom PHP with install.sh --php X.Y and it auto-fixes
# as a final step.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

IONCUBE_DIR="/usr/local/ioncube"
IONCUBE_TARBALL_URL_X86="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
IONCUBE_TARBALL_URL_ARM="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_aarch64.tar.gz"

# Returns 0 (stale, refresh) if:
#  - /usr/local/ioncube doesn't exist, OR
#  - any detected /opt/alt/php-fpmNN is missing its matching loader, OR
#  - USER-GUIDE.txt (always present in a fresh tarball) is older than 30 days
# Returns 1 (fresh, skip) otherwise.
is_ioncube_stale() {
    [ -d "$IONCUBE_DIR" ] || { log "ioncube: dir missing"; return 0; }

    local fpm major loader
    for fpm in /opt/alt/php-fpm*; do
        [ -d "$fpm" ] || continue
        major=$(basename "$fpm" | sed 's/^php-fpm//')   # 83 / 84 / 85
        # Convert 83 -> 8.3
        local dotver="${major:0:1}.${major:1}"
        loader="${IONCUBE_DIR}/ioncube_loader_lin_${dotver}.so"
        if [ ! -f "$loader" ]; then
            log "ioncube: missing loader for PHP ${dotver}  ($loader)"
            return 0
        fi
    done

    local guide="${IONCUBE_DIR}/USER-GUIDE.txt"
    if [ -f "$guide" ]; then
        local mtime; mtime=$(stat -c %Y "$guide" 2>/dev/null || echo 0)
        local now;   now=$(date +%s)
        local age_days=$(( (now - mtime) / 86400 ))
        if [ "$age_days" -gt 30 ]; then
            log "ioncube: USER-GUIDE.txt is ${age_days} days old (>30) — will refresh"
            return 0
        fi
    fi

    return 1
}

# Main entry — idempotent, safe to re-run
refresh_ioncube() {
    section "Refresh ioncube loaders"

    require_root

    # ---- Backup ----
    if [ -d "$IONCUBE_DIR" ]; then
        backup_file "$IONCUBE_DIR"
    fi

    # ---- Download fresh tarball ----
    local arch tarball url
    arch=$(uname -m)
    case "$arch" in
        x86_64)  url="$IONCUBE_TARBALL_URL_X86" ;;
        aarch64) url="$IONCUBE_TARBALL_URL_ARM" ;;
        *) die "Unsupported arch for ioncube: $arch" ;;
    esac
    tarball="/tmp/ioncube_loaders.${BH_RUN_STAMP}.tar.gz"

    log "Downloading $url"
    if ! curl -fsSL --max-time 120 -o "$tarball" "$url"; then
        err "ioncube download failed"
        return 1
    fi

    if ! file "$tarball" | grep -qiE "gzip compressed data|tar archive"; then
        err "ioncube tarball does not look valid"
        rm -f "$tarball"
        return 1
    fi
    ok "Downloaded $(du -h "$tarball" | awk '{print $1}')"

    # ---- Replace /usr/local/ioncube ----
    log "Extracting to /usr/local/"
    cd /usr/local || die "cannot cd /usr/local"

    # Remove existing dir AFTER backup; tarball extracts as ioncube/
    rm -rf "$IONCUBE_DIR"
    if ! tar -xzf "$tarball"; then
        err "ioncube tarball extraction failed"
        rm -f "$tarball"
        return 1
    fi
    rm -f "$tarball"

    [ -d "$IONCUBE_DIR" ] || die "ioncube/ directory not created by tarball"

    # ---- Fix permissions ----
    chown -R root:root "$IONCUBE_DIR"
    find "$IONCUBE_DIR" -type d -exec chmod 755 {} \;
    find "$IONCUBE_DIR" -type f -exec chmod 644 {} \;
    ok "Permissions fixed (root:root, 755 dirs, 644 files)"

    # ---- Re-wire each detected /opt/alt/php-fpmNN ----
    local restarted=0
    local fpm major dotver loader inidir inifile php
    for fpm in /opt/alt/php-fpm*; do
        [ -d "$fpm" ] || continue
        major=$(basename "$fpm" | sed 's/^php-fpm//')
        dotver="${major:0:1}.${major:1}"
        loader="${IONCUBE_DIR}/ioncube_loader_lin_${dotver}.so"
        inidir="${fpm}/usr/php/php.d"
        inifile="${inidir}/ioncube.ini"      # plain name — matches the BiswasHost convention
        php="${fpm}/usr/bin/php"

        if [ ! -f "$loader" ]; then
            warn "  PHP ${dotver}: no loader available (${loader}) — skipping"
            continue
        fi
        [ -d "$inidir" ] || mkdir -p "$inidir"

        # Clean up older prefixed variants we may have left behind in earlier runs
        rm -f "${inidir}/00-ioncube.ini" "${inidir}/01-ioncube.ini" 2>/dev/null

        echo "zend_extension=${loader}" > "$inifile"
        ok "  PHP ${dotver}: wired ${inifile} -> ${loader}"

        # Verify it loads via CLI
        if [ -x "$php" ]; then
            if "$php" -v 2>&1 | grep -qi "ionCube"; then
                ok "  PHP ${dotver}: ionCube loader verified via CLI"
            else
                warn "  PHP ${dotver}: ionCube did NOT appear in php -v output"
            fi
        fi

        # Restart the matching FPM service if it exists
        if systemctl list-unit-files 2>/dev/null | grep -q "php-fpm${major}.service"; then
            systemctl restart "php-fpm${major}" \
                && ok "  PHP ${dotver}: php-fpm${major} restarted" \
                || warn "  PHP ${dotver}: php-fpm${major} restart failed"
            restarted=$((restarted + 1))
        fi
    done

    # ---- Trigger CWP refresh if available ----
    if [ -x /scripts/update_cwp ]; then
        log "Running /scripts/update_cwp"
        sh /scripts/update_cwp >/dev/null 2>&1 \
            && ok "/scripts/update_cwp completed" \
            || warn "/scripts/update_cwp returned non-zero (often harmless)"
    fi

    ok "ioncube refresh done. Restarted ${restarted} FPM service(s)."
}

# Auto-run wrapper: called at end of --php flow.
# Skips if BH_SKIP_IONCUBE=1 or if loaders are fresh.
maybe_refresh_ioncube() {
    if [ "${BH_SKIP_IONCUBE:-0}" -eq 1 ]; then
        log "ioncube: skipped (BH_SKIP_IONCUBE=1)"
        return 0
    fi
    if is_ioncube_stale; then
        refresh_ioncube
    else
        ok "ioncube: loaders are fresh and complete — no refresh needed"
    fi
}
