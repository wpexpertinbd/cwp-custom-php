#!/bin/bash
# build-php.sh — unified PHP-FPM builder for EL8.
# Replaces /root/build-php-fpm{83,84,85}-el8.sh.
#
# Arguments are env vars:
#   PHPMAJOR  e.g. 84
#   PHPVER    e.g. 8.4.21
#
# Design choices (set by boss 2026-05-27):
#  - Isolated libcurl 8.7.1 in /opt/curl-8.7.1, used ONLY at PHP build-time.
#    Never written to /usr/local/lib, never added to /etc/ld.so.conf.d.
#  - Preserves /opt/alt/php-fpmNN/usr/etc/php-fpm.d/users/*.conf on rebuild.
#  - Stops, rebuilds, restarts — production-safe upgrade flow.
#
# Sources CWP's GUI-generated configure recipe from:
#   /usr/local/cwp/.conf/php-fpm_conf/php{NN}{,_pre,_external}.conf

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

build_php() {
    local PHPMAJOR="${1:?PHPMAJOR required}"   # 83 / 84 / 85
    local PHPVER="${2:?PHPVER required}"       # 8.4.21

    section "Build PHP ${PHPVER}  (php-fpm${PHPMAJOR})  — atomic-swap deploy"

    local FPMDIR="/opt/alt/php-fpm${PHPMAJOR}"                       # Final live path
    local STAGE_ROOT="/usr/local/src/php-build/stage-${BH_RUN_STAMP}-${PHPMAJOR}"
    local STAGE_FPMDIR="${STAGE_ROOT}${FPMDIR}"                      # Where DESTDIR puts the new install
    local CONFBASE="/usr/local/cwp/.conf/php-fpm_conf"

    [ -f "${CONFBASE}/php${PHPMAJOR}.conf" ] || \
        die "Missing build recipe: ${CONFBASE}/php${PHPMAJOR}.conf  (run deploy-conf first)"

    # ---- Build dependencies (idempotent, safe while live) ----
    install_build_deps

    # ---- Compiler env (build-time only) — branched by EL major ----
    export OPENSSL_CFLAGS="-I/usr/include"
    export OPENSSL_LIBS="-L/usr/lib64"

    if [ "${BH_EL_MAJOR:-8}" -eq 9 ]; then
        log "EL9 build profile: native OpenSSL 3.x, system curl, no PIE flags"
        export PKG_CONFIG_PATH="/usr/lib64/pkgconfig"
        export LDFLAGS="-lssl -lcrypto"
    else
        log "EL8 build profile: isolated curl, PIE flags, OpenSSL 1.1.1k"
        setup_isolated_curl
        export PKG_CONFIG_PATH="/opt/curl-8.7.1/lib/pkgconfig:/usr/lib64/pkgconfig"
        export CPPFLAGS="-I/opt/curl-8.7.1/include -I/usr/include"
        export LDFLAGS="-L/opt/curl-8.7.1/lib -L/usr/lib64 -lssl -lcrypto"
        export CFLAGS="${CFLAGS:-} -fPIE"
        export CXXFLAGS="${CXXFLAGS:-} -fPIE"
        export LDFLAGS="${LDFLAGS} -pie"
    fi

    # ---- CWP pre-conf (pcre2, libavif, ldap, etc.) ----
    if [ -e "${CONFBASE}/php${PHPMAJOR}_pre.conf" ]; then
        log "Running php${PHPMAJOR}_pre.conf"
        bash "${CONFBASE}/php${PHPMAJOR}_pre.conf" \
            || warn "php${PHPMAJOR}_pre.conf returned non-zero (non-fatal, continuing)"
    fi

    # ---- Resolve + download PHP source ----
    download_php_source "$PHPVER"

    # ---- Configure with FINAL prefix (path baked into binaries matches post-swap location) ----
    cd "/usr/local/src/php-build/php-${PHPVER}"
    chmod +x "${CONFBASE}/php${PHPMAJOR}.conf" 2>/dev/null || true
    log "Running php${PHPMAJOR}.conf (./configure)  — prefix=${FPMDIR}/usr  (the LIVE path)"
    bash "${CONFBASE}/php${PHPMAJOR}.conf"

    # ---- Compile ----
    log "Compiling PHP ${PHPVER} (this takes 5-15 minutes — tenants serve on EXISTING PHP during this window)"
    if command -v nproc >/dev/null 2>&1; then
        make -j"$(nproc)"
    else
        make
    fi

    # ---- Install to STAGING via INSTALL_ROOT (so live install untouched) ----
    # PHP's Makefile uses $(INSTALL_ROOT) for staging installs in install-modules,
    # install-cli, install-build, install-headers, install-fpm etc. Pure DESTDIR
    # is silently ignored by some of those targets in PHP 8.x — files end up at
    # the live path. We pass BOTH variables to cover every PHP version safely.
    log "Staged install -> ${STAGE_FPMDIR}  (INSTALL_ROOT + DESTDIR)"
    rm -rf "$STAGE_ROOT"
    mkdir -p "$STAGE_ROOT"

    # Snapshot live FPMDIR mtime so we can detect accidental writes to live.
    local LIVE_MTIME_BEFORE=""
    [ -d "${FPMDIR}/usr/sbin" ] && LIVE_MTIME_BEFORE=$(stat -c %Y "${FPMDIR}/usr/sbin" 2>/dev/null)

    INSTALL_ROOT="$STAGE_ROOT" DESTDIR="$STAGE_ROOT" make install \
        INSTALL_ROOT="$STAGE_ROOT" DESTDIR="$STAGE_ROOT"

    # Hard safety check: if staging dir is empty AND live dir mtime changed,
    # PHP wrote to live behind our back. Abort loudly before the user thinks
    # nothing happened.
    if [ ! -d "$STAGE_FPMDIR" ]; then
        if [ -n "$LIVE_MTIME_BEFORE" ]; then
            local LIVE_MTIME_AFTER
            LIVE_MTIME_AFTER=$(stat -c %Y "${FPMDIR}/usr/sbin" 2>/dev/null)
            if [ -n "$LIVE_MTIME_AFTER" ] && [ "$LIVE_MTIME_AFTER" != "$LIVE_MTIME_BEFORE" ]; then
                err "PHP make install wrote directly to LIVE ${FPMDIR} despite INSTALL_ROOT/DESTDIR."
                err "Atomic-swap protection failed. The new binaries are already in place at ${FPMDIR}."
                err "Service may be in an inconsistent state. Recommendation:"
                err "  1. Re-run this installer with the same flags (it will now atomic-swap correctly)"
                err "  2. OR manually run external modules:  bash ${CONFBASE}/php${PHPMAJOR}_external.conf"
                err "  3. OR run with BH_SKIP_ATOMIC_SWAP=1 to use the legacy rm-then-build path"
            fi
        fi
        die "INSTALL_ROOT/DESTDIR install did not produce $STAGE_FPMDIR"
    fi
    ok "PHP ${PHPVER} compiled and staged at ${STAGE_FPMDIR}"

    # ---- php.ini + FPM scaffolding INSIDE staging ----
    setup_fpm_scaffolding "$PHPMAJOR" "$FPMDIR" "$STAGE_FPMDIR"

    # ---- Systemd unit (paths reference the FINAL location, OK to install live) ----
    install_systemd_service "$PHPMAJOR" "$FPMDIR"

    # ---- Apache FPM proxy module ----
    install_apache_proxy_module

    # ====================================================================
    # ATOMIC SWAP — only blocking section. Tenants 502 for ~2-5 seconds.
    # ====================================================================
    atomic_swap "$PHPMAJOR" "$FPMDIR" "$STAGE_FPMDIR"

    # ---- External modules (imagick, redis, etc.) — now against the NEW LIVE install ----
    # During this window (~3-5 min), sites using these extensions get errors.
    # Core PHP is alive, but imagick/redis/memcache/ioncube haven't loaded yet.
    if [ -e "${CONFBASE}/php${PHPMAJOR}_external.conf" ]; then
        section "Building external modules (degraded window — imagick/redis/etc. unavailable)"
        log "Sites using these extensions will error for ~3-5 min until each module finishes"
        bash "${CONFBASE}/php${PHPMAJOR}_external.conf" || warn "Some external modules failed (non-fatal)"
        ok "External modules built; restarting FPM to load them"
        systemctl restart "php-fpm${PHPMAJOR}" || warn "php-fpm${PHPMAJOR} did not restart cleanly"
    fi

    # ---- Auto-disable noisy extensions ----
    disable_noisy_extensions "$FPMDIR"

    # ---- Monit integration ----
    integrate_monit "$PHPMAJOR"

    # ---- CSF pignore ----
    update_csf_pignore "$FPMDIR"

    # ---- Final restart so all extension changes take effect ----
    systemctl restart "php-fpm${PHPMAJOR}" || warn "final restart had issues"

    # ---- Cleanup staging (rollback dir kept) ----
    rm -rf "$STAGE_ROOT"
    rm -rf /usr/local/src/php-build /usr/local/src/build-dir
    ok "PHP ${PHPVER} (php-fpm${PHPMAJOR}) build finished"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Atomic swap: the only blocking section of the build. Stop FPM, move dirs,
# carry over user pool configs, restart FPM. ~2-5 sec downtime. If the new
# install fails to start, auto-roll-back to the previous install.
atomic_swap() {
    local PHPMAJOR="$1" FPMDIR="$2" STAGE_FPMDIR="$3"
    local SVC="php-fpm${PHPMAJOR}"
    local ROLLBACK_DIR="${FPMDIR}.rollback.${BH_RUN_STAMP}"

    section "Atomic swap  — ~2-5 sec downtime window"

    [ -d "$STAGE_FPMDIR" ] || die "Staging dir missing: $STAGE_FPMDIR  (build did not complete)"

    # Stop service so the binaries aren't held by running processes during mv.
    if systemctl list-unit-files 2>/dev/null | grep -q "${SVC}.service"; then
        log "Stopping ${SVC}"
        systemctl stop "$SVC" 2>/dev/null || true
    fi

    # Move old install aside as rollback; install new in its place.
    if [ -d "$FPMDIR" ]; then
        mv "$FPMDIR" "$ROLLBACK_DIR"
        ok "Old install preserved at ${ROLLBACK_DIR}  (delete when satisfied with new build)"
    fi
    mv "$STAGE_FPMDIR" "$FPMDIR"
    ok "Swapped staged install -> ${FPMDIR}"

    # Carry over user pool configs from the rollback dir.
    if [ -d "${ROLLBACK_DIR}/usr/etc/php-fpm.d/users" ] && \
       compgen -G "${ROLLBACK_DIR}/usr/etc/php-fpm.d/users/*.conf" > /dev/null; then
        mkdir -p "${FPMDIR}/usr/etc/php-fpm.d/users"
        cp -a "${ROLLBACK_DIR}/usr/etc/php-fpm.d/users/." "${FPMDIR}/usr/etc/php-fpm.d/users/"
        ok "Carried over $(ls "${FPMDIR}/usr/etc/php-fpm.d/users/"*.conf 2>/dev/null | wc -l) user pool configs"
    elif [ -z "$(ls -A /root/cwp-php-backups/*/php-fpm${PHPMAJOR}-users/*.conf 2>/dev/null | head -1)" ]; then
        log "No user pool configs to restore (fresh install)"
    else
        # No pools in rollback dir but a prior backup exists — fall back
        local prior
        prior=$(ls -1dt /root/cwp-php-backups/*/php-fpm${PHPMAJOR}-users 2>/dev/null \
                | while read -r d; do
                      compgen -G "${d}/*.conf" >/dev/null && echo "$d" && break
                  done | head -1)
        if [ -n "$prior" ]; then
            mkdir -p "${FPMDIR}/usr/etc/php-fpm.d/users"
            cp -a "${prior}/." "${FPMDIR}/usr/etc/php-fpm.d/users/"
            ok "Carried over pools from prior backup: $prior"
        fi
    fi

    # Reload systemd in case the unit file just got installed/updated.
    systemctl daemon-reload

    # Start new service.
    log "Starting ${SVC}"
    systemctl start "$SVC" 2>/dev/null

    # Give it a moment, then verify.
    sleep 2
    if systemctl is-active --quiet "$SVC"; then
        ok "${SVC} active  — atomic swap complete"
        return 0
    fi

    # FAILURE PATH — rollback.
    err "${SVC} failed to start with new install. Rolling back."
    systemctl stop "$SVC" 2>/dev/null || true
    if [ -d "$ROLLBACK_DIR" ]; then
        mv "$FPMDIR" "${FPMDIR}.failed.${BH_RUN_STAMP}"
        mv "$ROLLBACK_DIR" "$FPMDIR"
        systemctl daemon-reload
        systemctl start "$SVC"
        if systemctl is-active --quiet "$SVC"; then
            ok "Rolled back to previous install. Service restored. New (failed) build at ${FPMDIR}.failed.${BH_RUN_STAMP}"
        else
            err "Rollback restart ALSO failed. Manual intervention needed: check journalctl -u ${SVC}"
        fi
    else
        err "No rollback dir to restore from. Was this a fresh install?"
    fi
    die "atomic_swap failed — see logs above"
}

install_build_deps() {
    local pkgs=(
        krb5-devel glibc-common gnutls-devel
        libargon2 libargon2-devel libbsd-devel
        perl libzip libzip-devel pcre2 pcre2-devel
        libavif libavif-devel uw-imap-devel openssl-devel
        libjpeg-turbo libjpeg-turbo-devel libpng-devel
        libwebp-devel freetype-devel libxml2-devel
        sqlite-devel oniguruma oniguruma-devel
        libnghttp2-devel zlib-devel
        ImageMagick ImageMagick-devel
        libevent libevent-devel cyrus-sasl-devel
        libmemcached libmemcached-devel
    )
    log "Installing build dependencies (${#pkgs[@]} packages)"
    local pkg
    for pkg in "${pkgs[@]}"; do
        dnf -y install "$pkg" >/dev/null 2>&1 \
            || warn "skip: $pkg (not available)"
    done
    ok "build deps done"
}

setup_isolated_curl() {
    local CURL_VER="8.7.1"
    local CURL_PREFIX="/opt/curl-${CURL_VER}"

    if [ -x "${CURL_PREFIX}/bin/curl" ]; then
        ok "Isolated curl ${CURL_VER} already present at ${CURL_PREFIX}"
        return 0
    fi

    log "Building isolated curl ${CURL_VER} -> ${CURL_PREFIX}  (PHP build-time only)"
    set +e
    (
        cd /usr/local/src || exit 1
        rm -rf "curl-${CURL_VER}" "curl-${CURL_VER}.tar.gz"
        if ! wget -q "https://curl.se/download/curl-${CURL_VER}.tar.gz" \
                  -O "curl-${CURL_VER}.tar.gz"; then
            echo "FAIL_WGET"; exit 2
        fi
        tar -xzf "curl-${CURL_VER}.tar.gz" && cd "curl-${CURL_VER}" || exit 2
        # Note: don't pass --disable-shared=no (bogus). Just request what we need.
        # --without-libpsl: EL8 may lack libpsl-devel; curl doesn't strictly need it.
        ./configure --prefix="${CURL_PREFIX}" \
            --with-openssl \
            --with-nghttp2 \
            --with-zlib \
            --without-libpsl \
            --enable-shared \
            --enable-static
        if [ $? -ne 0 ]; then echo "FAIL_CONFIGURE"; exit 2; fi
        if command -v nproc >/dev/null 2>&1; then
            make -j"$(nproc)"
        else
            make
        fi
        if [ $? -ne 0 ]; then echo "FAIL_MAKE"; exit 2; fi
        make install
    )
    local rc=$?
    set -e

    if [ $rc -ne 0 ] || [ ! -x "${CURL_PREFIX}/bin/curl" ]; then
        warn "Isolated curl build failed — PHP will use system libcurl. Some features may be limited."
        return 0
    fi

    # NB: deliberately NOT writing to /etc/ld.so.conf.d — that's the dnf-breaking trap
    ok "Isolated curl ${CURL_VER} ready at ${CURL_PREFIX}"
}

download_php_source() {
    local PHPVER="$1"
    local CWP_URL="http://static.cdn-cwp.com/files/php/php-${PHPVER}.tar.gz"
    local PHPNET_URL="https://www.php.net/distributions/php-${PHPVER}.tar.gz"
    local GITHUB_URL="https://codeload.github.com/php/php-src/tar.gz/refs/tags/php-${PHPVER}"

    local PHPSOURCE=""
    local url
    for url in "$CWP_URL" "$PHPNET_URL" "$GITHUB_URL"; do
        log "Trying source: $url"
        local tmp="/tmp/php-test-${PHPVER}.tar.gz"
        rm -f "$tmp"
        if curl -L -fsS --max-time 30 -o "$tmp" "$url" 2>/dev/null && \
           file "$tmp" | grep -qiE "gzip compressed data|tar archive"; then
            PHPSOURCE="$url"
            rm -f "$tmp"
            break
        fi
        rm -f "$tmp"
    done

    [ -n "$PHPSOURCE" ] || die "Could not download a valid PHP source for ${PHPVER}"
    ok "Using PHP source: $PHPSOURCE"

    rm -rf /usr/local/src/php-build
    mkdir -p /usr/local/src/php-build
    cd /usr/local/src/php-build
    wget -q "$PHPSOURCE" -O "php-${PHPVER}.tar.gz"
    tar -xzf "php-${PHPVER}.tar.gz"
    [ -d "php-${PHPVER}" ] || die "PHP source did not extract as php-${PHPVER}/"
}

setup_fpm_scaffolding() {
    # FPMDIR = path that gets baked INTO the config content (the final live path
    # after atomic swap). TARGET = where the files actually get written to right
    # now (the staging dir during build; or = FPMDIR for the old in-place flow).
    local PHPMAJOR="$1" FPMDIR="$2" TARGET="${3:-$2}"

    mkdir -p "${TARGET}/usr/php/php.d" \
             "${TARGET}/usr/var/sockets" \
             "${TARGET}/usr/etc/php-fpm.d" \
             "${TARGET}/usr/etc/php-fpm.d/users"

    rsync php.ini-production "${TARGET}/usr/php/php.ini"

    sed -i 's/^short_open_tag.*/short_open_tag = On/'                            "${TARGET}/usr/php/php.ini"
    sed -i 's/^;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=1/'                         "${TARGET}/usr/php/php.ini"
    sed -i 's/.*mail.add_x_header.*/mail.add_x_header = On/'                    "${TARGET}/usr/php/php.ini"
    sed -i 's@.*mail.log.*@mail.log = /usr/local/apache/logs/phpmail.log@'      "${TARGET}/usr/php/php.ini"

    # File CONTENT references FPMDIR (the final live path after swap),
    # files themselves are WRITTEN to TARGET (staging during atomic-swap build).
    echo "include=${FPMDIR}/usr/etc/php-fpm.d/users/*.conf" > "${TARGET}/usr/etc/php-fpm.d/users.conf"
    echo "include=${FPMDIR}/usr/etc/php-fpm.d/*.conf"      > "${TARGET}/usr/etc/php-fpm.conf"

    cat > "${TARGET}/usr/etc/php-fpm.d/cwpsvc.conf" <<EOF
[cwpsvc]
listen = ${FPMDIR}/usr/var/sockets/cwpsvc.sock
listen.owner = cwpsvc
listen.group = cwpsvc
listen.mode = 0640
user = cwpsvc
group = cwpsvc
pm = ondemand
pm.max_children = 25
pm.process_idle_timeout = 15s
request_terminate_timeout = 0
EOF

    ok "FPM scaffolding written to ${TARGET}  (content paths -> ${FPMDIR})"
}

install_systemd_service() {
    local PHPMAJOR="$1" FPMDIR="$2"
    if [ -f sapi/fpm/php-fpm.service ]; then
        cp sapi/fpm/php-fpm.service "/usr/lib/systemd/system/php-fpm${PHPMAJOR}.service"
        sed -i "s|\${exec_prefix}|${FPMDIR}/usr|g" "/usr/lib/systemd/system/php-fpm${PHPMAJOR}.service"
        sed -i "s|\${prefix}|${FPMDIR}/usr|g"      "/usr/lib/systemd/system/php-fpm${PHPMAJOR}.service"
        systemctl daemon-reload
        systemctl enable "php-fpm${PHPMAJOR}" >/dev/null 2>&1
        ok "systemd unit php-fpm${PHPMAJOR}.service installed"
    else
        warn "sapi/fpm/php-fpm.service missing — service not installed"
    fi
}

# Rename listed extensions' .ini -> .ini.disabled so PHP won't load them.
# Default list (BH_DISABLE_EXTENSIONS): mongodb, sourceguardian.
#  - mongodb: bundled mongodb-1.17/1.18 emits PHP 8.3+ deprecation warnings about
#    missing string return type on __toString() interfaces.
#  - sourceguardian: the SG loader installed by the bundled script doesn't always
#    match the PHP point release's Zend API; produces noisy "requires Zend API
#    420220829, you have 420230831" warnings on every CLI invocation.
# .so files stay on disk — flip the .disabled suffix back to enable.
disable_noisy_extensions() {
    local FPMDIR="$1"
    local inidir="${FPMDIR}/usr/php/php.d"
    [ -d "$inidir" ] || return 0

    local list="${BH_DISABLE_EXTENSIONS:-mongodb,sourceguardian}"
    [ -z "$list" ] && return 0

    log "Auto-disabling noisy extensions: $list  (override with BH_DISABLE_EXTENSIONS=)"
    local ext
    IFS=',' read -r -a exts <<< "$list"
    for ext in "${exts[@]}"; do
        ext="$(echo "$ext" | xargs)"          # trim
        [ -z "$ext" ] && continue
        local ini="${inidir}/${ext}.ini"
        if [ -f "$ini" ]; then
            mv "$ini" "${ini}.disabled"
            ok "Disabled ${ext}.ini -> ${ext}.ini.disabled  (rename back to re-enable)"
        fi
    done
}

install_apache_proxy_module() {
    if [ ! -e "/usr/local/apache/conf.d/php-fpm.conf" ] && [ -d /usr/local/apache/conf.d ]; then
        cat > /usr/local/apache/conf.d/php-fpm.conf <<'EOF'
<IfModule !proxy_fcgi_module>
    LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
</IfModule>
EOF
        ok "Apache mod_proxy_fcgi loader installed"
    fi
}

integrate_monit() {
    local PHPMAJOR="$1"
    if [ -d /etc/monit.d ] && [ ! -e "/etc/monit.d/php-fpm${PHPMAJOR}" ] && \
       [ -e "/usr/local/cwpsrv/htdocs/resources/conf/monit.d/php-fpm${PHPMAJOR}" ]; then
        cp "/usr/local/cwpsrv/htdocs/resources/conf/monit.d/php-fpm${PHPMAJOR}" /etc/monit.d/ 2>/dev/null \
            && monit reload 2>/dev/null \
            && ok "monit: php-fpm${PHPMAJOR} integrated"
    fi
}

update_csf_pignore() {
    local FPMDIR="$1"
    if ! command -v csf >/dev/null 2>&1; then return 0; fi
    if csf -v 2>&1 | grep -qi disabled; then
        log "CSF disabled — skipping pignore update"
        return 0
    fi
    [ -e /etc/csf/csf.pignore ] || return 0

    local entry
    for entry in \
        "exe:${FPMDIR}/usr/sbin/php-fpm" \
        "exe:${FPMDIR}/usr/bin/php"
    do
        grep -qF "$entry" /etc/csf/csf.pignore || echo "$entry" >> /etc/csf/csf.pignore
    done

    if command -v memcached >/dev/null 2>&1; then
        grep -qF "exe:/usr/bin/memcached" /etc/csf/csf.pignore \
            || echo "exe:/usr/bin/memcached" >> /etc/csf/csf.pignore
    fi
    if command -v redis-server >/dev/null 2>&1; then
        grep -qF "exe:/usr/bin/redis-server" /etc/csf/csf.pignore \
            || echo "exe:/usr/bin/redis-server" >> /etc/csf/csf.pignore
    fi

    csf -r >/dev/null 2>&1 && ok "CSF pignore updated and reloaded"
}
