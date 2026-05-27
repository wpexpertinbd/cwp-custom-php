#!/bin/bash
# preflight.sh — OS/CWP/arch sanity, ca-cert refresh, defuse the curl-local.conf trap

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

preflight() {
    section "Preflight"
    require_root

    # Arch
    local arch; arch=$(uname -m)
    [ "$arch" = "x86_64" ] || die "Unsupported arch: $arch (only x86_64 supported)"
    ok "arch: x86_64"

    # OS = EL8 or EL9 family
    if [ ! -f /etc/redhat-release ]; then
        die "Not a RHEL-family OS (no /etc/redhat-release). EL8 or EL9 required."
    fi
    local rel; rel=$(cat /etc/redhat-release | tr -d '\n')
    if   grep -qE '(release 8|AlmaLinux.*8|Rocky.*8|CentOS.*8|CloudLinux.*8)' /etc/redhat-release; then
        BH_EL_MAJOR=8
    elif grep -qE '(release 9|AlmaLinux.*9|Rocky.*9|CentOS.*9|CloudLinux.*9)' /etc/redhat-release; then
        BH_EL_MAJOR=9
    else
        die "Unsupported OS: $rel  (only EL8 and EL9 supported)"
    fi
    export BH_EL_MAJOR
    ok "OS: $rel  (EL${BH_EL_MAJOR})"

    # CWP present
    if [ ! -d /usr/local/cwpsrv ]; then
        die "CWP not detected (/usr/local/cwpsrv missing). Install CWP first."
    fi
    local sel_dir="/usr/local/cwpsrv/htdocs/resources/conf/el${BH_EL_MAJOR}/php-fpm_selector"
    if [ ! -d "$sel_dir" ]; then
        die "CWP PHP-FPM selector dir missing: $sel_dir"
    fi
    ok "CWP detected (selector: $sel_dir)"

    # Disable the libcurl/ld.so trap that breaks dnf
    fix_curl_ld_trap

    # Refresh CA certs (covers the 'cURL error 60' issue from the guide)
    log "Refreshing ca-certificates"
    dnf install -y ca-certificates >/dev/null 2>&1 || warn "ca-certificates install failed"
    update-ca-trust force-enable >/dev/null 2>&1 || true
    update-ca-trust extract >/dev/null 2>&1 || true
    ok "ca-certificates refreshed"

    # Base toolchain
    log "Ensuring base toolchain (gcc, make, autoconf, wget, git, file, rsync, dos2unix, unzip)"
    dnf install -y gcc gcc-c++ make autoconf wget git file rsync dos2unix unzip >/dev/null 2>&1 \
        || warn "Some base packages may have failed to install"
    ok "toolchain present"
}

# Scan /usr/local/lib*/ for libs that shadow system /usr/lib64 versions.
# Doesn't auto-remove — those libs may still be in use by other manually-
# installed software. Just warns with the exact mv commands.
check_shadow_libs() {
    local local_dirs=(/usr/local/lib /usr/local/lib64)
    # Libraries critical to PHP runtime that frequently cause symbol mismatches
    local watched=(libzip libcurl libssl libcrypto libxml2 libpng libjpeg libwebp libavif libonig libsodium)

    local found=0
    local d lib f sys_lib
    for d in "${local_dirs[@]}"; do
        [ -d "$d" ] || continue
        for lib in "${watched[@]}"; do
            # Find all numbered .so files under this dir for this lib
            for f in "$d"/${lib}.so.*; do
                [ -f "$f" ] || continue
                # Skip the unversioned symlink (lib.so) and major-only symlink (lib.so.X)
                # — we want actual files, which look like lib.so.X.Y or lib.so.X.Y.Z
                local base
                base="$(basename "$f")"
                if [[ "$base" =~ ^${lib}\.so\.[0-9]+\.[0-9]+ ]]; then
                    # Real file. Check if there's a corresponding system one in /usr/lib64
                    if [ -f "/usr/lib64/${lib}.so" ] || compgen -G "/usr/lib64/${lib}.so.*" > /dev/null; then
                        sys_lib=$(ls -1 /usr/lib64/${lib}.so.* 2>/dev/null | grep -vE '\.so\.[0-9]+$' | head -1)
                        [ -z "$sys_lib" ] && sys_lib="/usr/lib64/${lib}.so.*"
                        if [ "$found" -eq 0 ]; then
                            warn ""
                            warn "Found stale lib(s) in $d/ that may shadow system /usr/lib64 versions:"
                            warn "These cause undefined-symbol crashes if PHP builds against newer system"
                            warn "headers but the runtime linker picks the older /usr/local/lib version."
                            warn ""
                        fi
                        warn "  Shadow: $f"
                        warn "  System: $sys_lib  (RPM: $(rpm -qf /usr/lib64/${lib}.so.* 2>/dev/null | head -1))"
                        found=$((found + 1))
                    fi
                fi
            done
        done
    done

    if [ "$found" -gt 0 ]; then
        # Also scan /usr/local/bin/ for binaries that LINK against these shadow libs.
        # Moving the libs without also handling these binaries breaks them with
        # error 48 "Unknown option was passed in to libcurl" (or equivalent).
        check_shadow_bins

        # If user passed --clean-shadow-libs (or BH_CLEAN_SHADOW_LIBS=1), auto-quarantine.
        if [ "${BH_CLEAN_SHADOW_LIBS:-0}" -eq 1 ]; then
            auto_quarantine_shadows
            return 0
        fi

        warn ""
        warn "Cleanup (NOT auto-applied — these files may still be used by other software you"
        warn "installed manually). To quarantine all shadows and let RPM-installed libs take over:"
        warn ""
        warn "  mkdir -p /root/cwp-php-backups/stale-libs"
        warn "  mv /usr/local/lib64/{libzip,libcurl,libssl,libcrypto,libavif}.so* /root/cwp-php-backups/stale-libs/ 2>/dev/null"
        warn "  mv /usr/local/lib/{libzip,libcurl,libssl,libcrypto,libavif}.so*   /root/cwp-php-backups/stale-libs/ 2>/dev/null"
        warn "  ldconfig"
        warn ""
        warn "If you ALSO see warnings about /usr/local/bin/ binaries above, quarantine them too:"
        warn "  mv /usr/local/bin/{curl,lsphp,php,php-cgi,phpdbg} /root/cwp-php-backups/stale-libs/ 2>/dev/null"
        warn "  hash -r"
        warn ""
        warn "Or pass --clean-shadow-libs to install.sh to apply all of the above automatically."
        warn ""
        warn "Then verify:"
        warn "  ldd /opt/alt/php-fpm84/usr/bin/php | grep -E '(libzip|libcurl|libssl)'"
        warn "  systemctl restart php-fpm83 php-fpm84 php-fpm85"
        warn ""
        warn "If 'php -i | head -3' shows 'symbol lookup error', shadow libs are crashing PHP — clean them."
    else
        ok "No shadow libs detected in /usr/local/lib*/"
    fi
}

# Scan /usr/local/bin/ for binaries that link against shadow libs in /usr/local/lib*/.
# These binaries break (curl error 48, etc.) the moment shadow libs are moved aside,
# because they were compiled against the newer shadow versions. Identify them so the
# user can quarantine the matching binaries in the same cleanup pass.
check_shadow_bins() {
    [ -d /usr/local/bin ] || return 0
    command -v ldd >/dev/null 2>&1 || return 0

    local watched='libzip|libcurl|libssl|libcrypto|libxml2|libpng|libjpeg|libwebp|libavif|libonig|libsodium'
    local found=0
    local bin

    for bin in /usr/local/bin/*; do
        [ -x "$bin" ] || continue
        [ -f "$bin" ] || continue
        # Look for any link that points BACK at /usr/local/lib*/ for a watched lib
        local hits
        hits=$(ldd "$bin" 2>/dev/null \
                 | grep -E "($watched)\.so" \
                 | grep -E '/usr/local/lib' \
                 || true)
        if [ -n "$hits" ]; then
            if [ "$found" -eq 0 ]; then
                warn ""
                warn "Binaries in /usr/local/bin/ that depend on shadow libs (will break when libs are quarantined):"
                warn ""
            fi
            warn "  $bin"
            echo "$hits" | while read -r ln; do
                warn "    -> $ln"
            done
            found=$((found + 1))
        fi
    done
    if [ "$found" -gt 0 ]; then
        warn ""
        warn "Quarantine these binaries alongside the libs OR rebuild them against system /usr/lib64 libs."
        warn "Most common case: /usr/local/bin/curl built against custom libcurl — quarantine and let"
        warn "system /usr/bin/curl take over (PATH fallback) unless you specifically need the newer one."
    fi
}

fix_curl_ld_trap() {
    # Scan EVERY file in /etc/ld.so.conf.d/ for /usr/local references —
    # the trap isn't always called curl-local.conf.
    local trapped=0
    local f
    if [ -d /etc/ld.so.conf.d ]; then
        for f in /etc/ld.so.conf.d/*.conf; do
            [ -e "$f" ] || continue
            # Match any uncommented line containing /usr/local
            if grep -qE '^[[:space:]]*[^#].*\/usr\/local' "$f" 2>/dev/null; then
                warn "Found $f pointing at /usr/local — shadows system libcurl, breaks dnf."
                backup_file "$f"
                mv "$f" "${f}.disabled.${BH_RUN_STAMP}"
                ok "Disabled $f (renamed to ${f}.disabled.${BH_RUN_STAMP})"
                trapped=$((trapped + 1))
            fi
        done
    fi
    # Also check master /etc/ld.so.conf itself
    if [ -f /etc/ld.so.conf ] && grep -qE '^[[:space:]]*[^#].*\/usr\/local' /etc/ld.so.conf 2>/dev/null; then
        warn "/etc/ld.so.conf contains a /usr/local entry — commenting it out."
        backup_file /etc/ld.so.conf
        sed -ri 's|^([[:space:]]*[^#].*\/usr\/local.*)$|# disabled-by-cwp-custom-php: \1|' /etc/ld.so.conf
        trapped=$((trapped + 1))
    fi
    if [ "$trapped" -gt 0 ]; then
        ldconfig
        ok "Disabled $trapped ld.so trap entry/entries and ran ldconfig"
    fi

    # Scan /usr/local/lib*/ for SHADOW libs that override system ones at runtime.
    # Same pattern as the libcurl trap — old manual builds drop newer (or in some
    # cases OLDER) .so files into /usr/local/lib64 which is in ld's default search
    # path, silently overriding /usr/lib64 RPM-installed libs. Real-world break:
    # libzip 1.5.x in /usr/local/lib64 shadowed Remi's libzip 1.11.4 in /usr/lib64,
    # PHP 8.3 zip ext crashed on undefined symbol zip_compression_method_supported,
    # Blesta hit 503 while WordPress worked fine.
    check_shadow_libs

    # Verify librepo is using system libcurl
    if command -v ldd >/dev/null 2>&1 && [ -f /usr/lib64/librepo.so.0 ]; then
        if ldd /usr/lib64/librepo.so.0 2>/dev/null | grep -q "/usr/local/lib/libcurl"; then
            warn "librepo STILL linked to /usr/local/lib/libcurl after cleanup."
            warn ""
            warn "Cause: an old manual curl install dropped libcurl.so* directly into /usr/local/lib."
            warn "/usr/local/lib is in ld's default search path on EL8, so librepo finds it first."
            warn ""
            warn "This is cosmetic — PHP builds work fine using our isolated /opt/curl-8.7.1."
            warn "But to fully fix it, rename the rogue files aside (NOT auto-applied — they may be"
            warn "in use by other software you installed):"
            warn ""
            warn "  ls -la /usr/local/lib/libcurl*"
            warn "  ldconfig -p | grep libcurl"
            warn "  # if safe, then:"
            warn "  mkdir -p /root/cwp-php-backups/manual-libcurl"
            warn "  mv /usr/local/lib/libcurl* /root/cwp-php-backups/manual-libcurl/"
            warn "  ldconfig"
            warn "  ldd /usr/lib64/librepo.so.0 | grep libcurl   # should now point at /usr/lib64"
        else
            ok "librepo correctly uses system libcurl"
        fi
    fi
}

# Auto-quarantine: move shadow libs + their dependent binaries to backup dir.
# Triggered by --clean-shadow-libs / BH_CLEAN_SHADOW_LIBS=1 when check_shadow_libs
# detects something. Mirrors the manual commands we print otherwise.
auto_quarantine_shadows() {
    section "Auto-quarantining shadow libs + binaries (--clean-shadow-libs)"

    local stale_dir="/root/cwp-php-backups/stale-libs"
    mkdir -p "$stale_dir"

    local moved=0 lib bin

    # Libs in /usr/local/lib64
    for lib in libzip libcurl libssl libcrypto libavif libxml2 libpng libjpeg libwebp libonig libsodium; do
        for f in /usr/local/lib64/${lib}.so* /usr/local/lib/${lib}.so*; do
            [ -e "$f" ] || continue
            mv "$f" "$stale_dir/" 2>/dev/null && moved=$((moved + 1))
        done
    done

    if [ "$moved" -gt 0 ]; then
        ldconfig
        ok "Quarantined ${moved} shadow lib file(s) -> ${stale_dir}/"
    fi

    # Binaries in /usr/local/bin that we know commonly depend on shadow libs.
    # Check each ldd; only move if it actually links to /usr/local/lib*
    local moved_bins=0
    for bin in /usr/local/bin/curl /usr/local/bin/lsphp /usr/local/bin/php \
               /usr/local/bin/php-cgi /usr/local/bin/phpdbg \
               /usr/local/bin/pcre2grep /usr/local/bin/pcre2test \
               /usr/local/bin/zipcmp /usr/local/bin/zipmerge /usr/local/bin/ziptool
    do
        [ -x "$bin" ] || continue
        # If the binary STILL resolves cleanly (system libs only), leave it alone.
        # Only move if it references the now-quarantined /usr/local/lib path.
        # Easier check: just move it — it was built against the lib we removed,
        # so it's broken now. Better to quarantine than leave a broken binary.
        # But we can be conservative: only move if ldd shows "not found".
        if ldd "$bin" 2>/dev/null | grep -qE 'not found|/usr/local/lib'; then
            mv "$bin" "$stale_dir/" 2>/dev/null && moved_bins=$((moved_bins + 1))
        fi
    done

    if [ "$moved_bins" -gt 0 ]; then
        hash -r 2>/dev/null || true
        ok "Quarantined ${moved_bins} shadow binary/binaries -> ${stale_dir}/"
    fi

    if [ "$moved" -eq 0 ] && [ "$moved_bins" -eq 0 ]; then
        log "Nothing to quarantine (libs/bins may have already been cleaned)"
        return 0
    fi

    # Final verification: librepo + dnf should be clean now
    if command -v ldd >/dev/null 2>&1 && [ -f /usr/lib64/librepo.so.0 ]; then
        if ldd /usr/lib64/librepo.so.0 2>/dev/null | grep -q "/usr/local"; then
            warn "librepo STILL has /usr/local in its dependency chain — investigate manually"
        else
            ok "librepo cleanly references /lib64/ — dnf should work"
        fi
    fi
}
