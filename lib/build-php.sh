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

    section "Build PHP ${PHPVER}  (php-fpm${PHPMAJOR})"

    local FPMDIR="/opt/alt/php-fpm${PHPMAJOR}"
    local CONFBASE="/usr/local/cwp/.conf/php-fpm_conf"

    [ -f "${CONFBASE}/php${PHPMAJOR}.conf" ] || \
        die "Missing build recipe: ${CONFBASE}/php${PHPMAJOR}.conf  (run deploy-conf first)"

    # ---- Stop existing service, preserve user pools ----
    stop_and_backup_pools "$PHPMAJOR" "$FPMDIR"

    # ---- Build dependencies ----
    install_build_deps

    # ---- Compiler env (build-time only) — branched by EL major ----
    export OPENSSL_CFLAGS="-I/usr/include"
    export OPENSSL_LIBS="-L/usr/lib64"

    if [ "${BH_EL_MAJOR:-8}" -eq 9 ]; then
        # EL9: native OpenSSL 3.x, modern curl already present, no PIE workaround needed
        log "EL9 build profile: native OpenSSL 3.x, system curl, no PIE flags"
        export PKG_CONFIG_PATH="/usr/lib64/pkgconfig"
        export LDFLAGS="-lssl -lcrypto"
    else
        # EL8: isolated curl 8.7.1, OpenSSL 1.1.1k, PIE flags for GCC 8.x
        log "EL8 build profile: isolated curl, PIE flags, OpenSSL 1.1.1k"
        setup_isolated_curl
        export PKG_CONFIG_PATH="/opt/curl-8.7.1/lib/pkgconfig:/usr/lib64/pkgconfig"
        export CPPFLAGS="-I/opt/curl-8.7.1/include -I/usr/include"
        export LDFLAGS="-L/opt/curl-8.7.1/lib -L/usr/lib64 -lssl -lcrypto"
        export CFLAGS="${CFLAGS:-} -fPIE"
        export CXXFLAGS="${CXXFLAGS:-} -fPIE"
        export LDFLAGS="${LDFLAGS} -pie"
    fi

    # ---- CWP pre-conf (pcre2, etc.) ----
    if [ -e "${CONFBASE}/php${PHPMAJOR}_pre.conf" ]; then
        log "Running php${PHPMAJOR}_pre.conf"
        bash "${CONFBASE}/php${PHPMAJOR}_pre.conf"
    fi

    # ---- Resolve + download PHP source ----
    download_php_source "$PHPVER"

    # ---- Configure via CWP-generated recipe ----
    cd "/usr/local/src/php-build/php-${PHPVER}"
    chmod +x "${CONFBASE}/php${PHPMAJOR}.conf" 2>/dev/null || true
    log "Running php${PHPMAJOR}.conf (./configure)"
    bash "${CONFBASE}/php${PHPMAJOR}.conf"

    # ---- Compile ----
    log "Compiling PHP ${PHPVER} (this takes 5-15 minutes)"
    if command -v nproc >/dev/null 2>&1; then
        make -j"$(nproc)"
    else
        make
    fi
    make install
    ok "PHP ${PHPVER} compiled and installed"

    # ---- php.ini + FPM scaffolding ----
    setup_fpm_scaffolding "$PHPMAJOR" "$FPMDIR"

    # ---- Systemd service ----
    install_systemd_service "$PHPMAJOR" "$FPMDIR"

    # ---- Apache FPM proxy module ----
    install_apache_proxy_module

    # ---- External modules (imagick, redis, etc.) ----
    if [ -e "${CONFBASE}/php${PHPMAJOR}_external.conf" ]; then
        log "Running php${PHPMAJOR}_external.conf (external modules)"
        bash "${CONFBASE}/php${PHPMAJOR}_external.conf" || warn "Some external modules failed (non-fatal)"
    fi

    # ---- Restore preserved user pools ----
    restore_pools "$PHPMAJOR" "$FPMDIR"

    # ---- Monit integration ----
    integrate_monit "$PHPMAJOR"

    # ---- Restart service ----
    systemctl restart "php-fpm${PHPMAJOR}" || warn "php-fpm${PHPMAJOR} did not start cleanly"

    # ---- CSF pignore ----
    update_csf_pignore "$FPMDIR"

    # ---- Cleanup ----
    rm -rf /usr/local/src/php-build /usr/local/src/build-dir
    ok "PHP ${PHPVER} (php-fpm${PHPMAJOR}) build finished"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

stop_and_backup_pools() {
    local PHPMAJOR="$1" FPMDIR="$2"
    if systemctl list-unit-files 2>/dev/null | grep -q "php-fpm${PHPMAJOR}.service"; then
        log "Stopping php-fpm${PHPMAJOR}"
        systemctl stop "php-fpm${PHPMAJOR}" || true
    fi
    if [ -d "${FPMDIR}/usr/etc/php-fpm.d/users" ]; then
        local stash="/root/cwp-php-backups/${BH_RUN_STAMP}/php-fpm${PHPMAJOR}-users"
        mkdir -p "$stash"
        if compgen -G "${FPMDIR}/usr/etc/php-fpm.d/users/*.conf" > /dev/null; then
            cp -a "${FPMDIR}/usr/etc/php-fpm.d/users/." "$stash/"
            ok "Preserved $(ls "$stash" | wc -l) user pool configs at $stash"
        fi
    fi
    if [ -d "$FPMDIR" ]; then
        log "Removing old ${FPMDIR}"
        rm -rf "$FPMDIR"
    fi
}

restore_pools() {
    local PHPMAJOR="$1" FPMDIR="$2"
    local stash="/root/cwp-php-backups/${BH_RUN_STAMP}/php-fpm${PHPMAJOR}-users"
    if [ -d "$stash" ] && compgen -G "${stash}/*.conf" > /dev/null; then
        mkdir -p "${FPMDIR}/usr/etc/php-fpm.d/users"
        cp -a "${stash}/." "${FPMDIR}/usr/etc/php-fpm.d/users/"
        ok "Restored $(ls "$stash" | wc -l) user pool configs"
    fi
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
    local PHPMAJOR="$1" FPMDIR="$2"

    mkdir -p "${FPMDIR}/usr/php/php.d" \
             "${FPMDIR}/usr/var/sockets" \
             "${FPMDIR}/usr/etc/php-fpm.d" \
             "${FPMDIR}/usr/etc/php-fpm.d/users"

    rsync php.ini-production "${FPMDIR}/usr/php/php.ini"

    sed -i 's/^short_open_tag.*/short_open_tag = On/'                            "${FPMDIR}/usr/php/php.ini"
    sed -i 's/^;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=1/'                         "${FPMDIR}/usr/php/php.ini"
    sed -i 's/.*mail.add_x_header.*/mail.add_x_header = On/'                    "${FPMDIR}/usr/php/php.ini"
    sed -i 's@.*mail.log.*@mail.log = /usr/local/apache/logs/phpmail.log@'      "${FPMDIR}/usr/php/php.ini"

    echo "include=${FPMDIR}/usr/etc/php-fpm.d/users/*.conf" > "${FPMDIR}/usr/etc/php-fpm.d/users.conf"
    echo "include=${FPMDIR}/usr/etc/php-fpm.d/*.conf"      > "${FPMDIR}/usr/etc/php-fpm.conf"

    cat > "${FPMDIR}/usr/etc/php-fpm.d/cwpsvc.conf" <<EOF
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

    ok "FPM scaffolding written"
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
