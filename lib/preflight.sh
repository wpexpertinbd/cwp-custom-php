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

fix_curl_ld_trap() {
    local f=/etc/ld.so.conf.d/curl-local.conf
    if [ -e "$f" ]; then
        warn "Found $f — this file points dnf/yum at custom libcurl and breaks repos."
        backup_file "$f"
        mv "$f" "${f}.disabled.${BH_RUN_STAMP}"
        ldconfig
        ok "Disabled $f (renamed to ${f}.disabled.${BH_RUN_STAMP})"
    fi
    # Verify librepo is using system libcurl
    if command -v ldd >/dev/null 2>&1 && [ -f /usr/lib64/librepo.so.0 ]; then
        if ldd /usr/lib64/librepo.so.0 2>/dev/null | grep -q "/usr/local/lib/libcurl"; then
            warn "librepo still linked to /usr/local/lib/libcurl — dnf may fail."
            warn "Investigate any other file under /etc/ld.so.conf.d/ pointing at /usr/local."
        fi
    fi
}
