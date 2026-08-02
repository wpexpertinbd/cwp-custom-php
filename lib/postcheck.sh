#!/bin/bash
# postcheck.sh — emit a verification table after a build

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

postcheck() {
    local major="$1"
    local short; short="$(php_short "$major")"
    local php="/opt/alt/php-fpm${short}/usr/bin/php"
    local fpm="/opt/alt/php-fpm${short}/usr/sbin/php-fpm"

    section "Post-check PHP ${major}"

    if [ ! -x "$php" ]; then
        err "PHP binary missing: $php"
        return 1
    fi

    local ver; ver=$("$php" -v 2>/dev/null | head -1)
    local ssl; ssl=$("$php" -i 2>/dev/null | grep -i 'SSL Version' | head -1 | awk -F'=> ' '{print $2}')
    local curl; curl=$("$php" -i 2>/dev/null | grep -i 'cURL Information' | head -1 | awk -F'=> ' '{print $2}')

    printf '  PHP        : %s\n' "$ver"
    printf '  OpenSSL    : %s\n' "${ssl:-?}"
    printf '  libcurl    : %s\n' "${curl:-?}"

    # fpm -t
    if [ -x "$fpm" ]; then
        if "$fpm" -t >/dev/null 2>&1; then
            printf '  fpm -t     : %sOK%s\n' "$C_GRN" "$C_RST"
        else
            printf '  fpm -t     : %sFAILED%s\n' "$C_RED" "$C_RST"
        fi
    fi

    # systemctl
    local state; state=$(systemctl is-active "php-fpm${short}" 2>/dev/null || true)
    if [ "$state" = "active" ]; then
        printf '  service    : %sactive%s\n' "$C_GRN" "$C_RST"
    else
        printf '  service    : %s%s%s\n' "$C_YEL" "${state:-unknown}" "$C_RST"
    fi

    # Every pool's declared listen socket must actually exist.
    #
    # "service active" is NOT proof the pools came up: php-fpm happily starts
    # with whatever pool files it finds, so a pool that got wiped by the tree
    # swap leaves its socket missing while systemd still reports active. That is
    # exactly how the Roundcube 502 on 2026-08-02 stayed invisible through a
    # green build -- webmail's nginx route pointed at /run/rc-php83.sock and
    # nothing ever recreated it.
    local pool_dir="/opt/alt/php-fpm${short}/usr/etc/php-fpm.d"
    if [ -d "$pool_dir" ]; then
        local missing="" sock pf
        for pf in "$pool_dir"/*.conf "$pool_dir"/users/*.conf; do
            [ -f "$pf" ] || continue
            sock=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*(\/[^;[:space:]]+).*/\1/p' "$pf" | head -1)
            [ -n "$sock" ] || continue
            [ -S "$sock" ] || missing="${missing} $(basename "$pf")->${sock}"
        done
        if [ -n "$missing" ]; then
            printf '  pools      : %sMISSING SOCKET(S):%s%s\n' "$C_RED" "$C_RST" "$missing"
            printf '               %sif roundcube.conf is listed, run: /root/rc-upgrade-cwp/rc-upgrade.sh pool%s\n' "$C_YEL" "$C_RST"
        else
            printf '  pools      : %sall declared sockets present%s\n' "$C_GRN" "$C_RST"
        fi
    fi

    # key extensions
    local mods; mods=$("$php" -m 2>/dev/null)
    printf '  modules    :'
    local m
    for m in mbstring openssl curl gd zip intl imagick redis memcached memcache ioncube opcache imap mysqli pdo_mysql; do
        if echo "$mods" | grep -qi "^${m}$" || echo "$mods" | grep -qi "ionCube"; then
            # ioncube shows as "ionCube Loader"
            if [ "$m" = "ioncube" ]; then
                echo "$mods" | grep -qi "ionCube" && printf ' %s%s%s' "$C_GRN" "$m" "$C_RST" || printf ' %s%s%s' "$C_YEL" "$m" "$C_RST"
            else
                printf ' %s%s%s' "$C_GRN" "$m" "$C_RST"
            fi
        else
            printf ' %s%s%s' "$C_YEL" "$m-" "$C_RST"
        fi
    done
    printf '\n'
}
