#!/bin/bash
# main-php.sh — upgrade CWP's MAIN PHP (the suPHP / CLI build in /usr/local) to a
# newer point release of the SAME branch, e.g. 8.3.31 -> 8.3.36.
#
# Why: CWP's own PHP Version Switcher only offers the versions CWP has packaged,
# so security releases arrive late or never. Most sites on a CWP box run on this
# build (every vhost that is not on PHP-FPM), so it matters as much as FPM.
#
# How: rebuild from php.net source with the EXACT configure command of the running
# build (read from `php -i`), so the same extensions are compiled in and the same
# libraries are linked. php.ini, php.d and the PECL/loader .so files are not
# touched (same extension API inside a branch). Everything `make install` replaces
# is tarred first; a failed install or verification restores it automatically.
#
# Sourced by install.sh. Entry point: upgrade_main_php <hint>   (hint: ""|latest|X.Y.Z)

MAIN_PHP=/usr/local/bin/php
MAIN_CGI=/usr/local/bin/php-cgi
MAIN_INI_KEYS="disable_functions memory_limit upload_max_filesize post_max_size max_execution_time session.upload_progress.enabled opcache.enable"

main_php_ini() {   # main_php_ini <key> — effective value from the running main PHP
    "$MAIN_PHP" -i 2>/dev/null | awk -F' => ' -v k="$1" '$1==k{print $2; exit}'
}

main_php_modules() {
    "$MAIN_PHP" -m 2>/dev/null | grep -vE '^\[|^$' | sort
}

# main_php_snapshot <modules file> <ini file> — fails unless both were fully written.
main_php_snapshot() {
    local k n
    main_php_modules > "$1" || return 1
    [ -s "$1" ] || return 1
    for k in $MAIN_INI_KEYS; do echo "${k}=$(main_php_ini "$k")"; done > "$2" || return 1
    n="$(wc -l < "$2")"
    [ "$n" -eq "$(echo $MAIN_INI_KEYS | wc -w)" ]
}

# Every vhost not served by PHP-FPM runs on the main PHP. Prints "<domain> <http code>".
main_php_site_codes() {
    local ip f d c
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    for f in /usr/local/apache/conf.d/vhosts/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in *.ssl.conf) continue ;; esac
        grep -q 'php-fpm' "$f" && continue
        d="$(basename "$f" .conf)"
        c="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' -L --max-redirs 3 \
             --resolve "${d}:443:${ip}" --resolve "${d}:80:${ip}" "https://${d}/" 2>/dev/null || true)"
        echo "$d ${c:-000}"
    done
}

# php.net publishes a sha256 for every release; refuse a tarball that does not match.
main_php_fetch_source() {
    local ver="$1" dir="$2" f="php-${1}.tar.xz" want got
    mkdir -p "$dir"
    curl -fsSL --retry 3 --max-time 300 -o "${dir}/${f}" "https://www.php.net/distributions/${f}" \
        || { err "download failed: https://www.php.net/distributions/${f}"; return 1; }
    want="$(curl -fsSL --max-time 30 "https://www.php.net/releases/index.php?json&version=${ver}" \
        | python3 -c "import sys,json
d=json.load(sys.stdin)
print(next(s['sha256'] for s in d.get('source',[]) if s.get('filename')=='${f}'))" 2>/dev/null)"
    [ -n "$want" ] || { err "php.net published no sha256 for ${f} — refusing to build"; return 1; }
    got="$(sha256sum "${dir}/${f}" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || { err "sha256 mismatch for ${f}: got ${got}, php.net says ${want}"; return 1; }
    ok "source ${f} sha256 verified against php.net"
    tar -xJf "${dir}/${f}" -C "$dir" && [ -d "${dir}/php-${ver}" ] || { err "could not extract ${f}"; return 1; }
}

main_php_restore() {   # main_php_restore <backup tgz>
    warn "restoring the previous main PHP from $1"
    if tar -xzf "$1" -C /; then
        ok "restored: main PHP is $("$MAIN_PHP" -r 'echo PHP_VERSION;' 2>/dev/null || echo '?') again"
    else
        err "RESTORE FAILED — extract by hand: tar -xzf $1 -C /"
    fi
}

upgrade_main_php() {
    local hint="$1"
    section "Main PHP (suPHP / CLI in /usr/local)"

    [ -x "$MAIN_PHP" ] && [ -x "$MAIN_CGI" ] || { err "no main PHP at $MAIN_PHP / $MAIN_CGI"; return 1; }
    if [ -L "$MAIN_PHP" ]; then
        err "$MAIN_PHP is a symlink to $(readlink -f "$MAIN_PHP") (--system-php?) — not a CWP main build, refusing"
        return 1
    fi

    local cur branch target
    cur="$("$MAIN_PHP" -r 'echo PHP_VERSION;' 2>/dev/null)" || { err "main PHP does not run"; return 1; }
    branch="${cur%.*}"
    if ! valid_major "$branch"; then
        warn "main PHP is ${cur}: php.net no longer releases fixes for ${branch}, so there is nothing to upgrade to."
        warn "Move the sites to a supported branch, or apply the vendor's mitigation in php.ini."
        return 0
    fi
    if [ -n "$hint" ] && [ "$hint" != "latest" ]; then
        target="$hint"
    else
        target="$(resolve_php_version "$branch" latest)"
    fi
    if ! [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "${target%.*}" != "$branch" ]; then
        err "--main target '${target}' is not a ${branch}.x release (the branch cannot change: extensions would break)"
        return 1
    fi
    if [ "$target" = "$cur" ] && [ "${BH_MAIN_FORCE:-0}" != "1" ]; then
        ok "main PHP is already ${cur} — nothing to do (BH_MAIN_FORCE=1 rebuilds anyway)"
        MAIN_RESULT="main PHP ${cur} (already current)"
        return 0
    fi
    if version_lt "$target" "$cur"; then
        err "--main target ${target} is OLDER than the running ${cur} — refusing to downgrade"; return 1
    fi
    log "main PHP: ${cur} -> ${target}"

    local args
    args="$("$MAIN_PHP" -i 2>/dev/null | grep -m1 '^Configure Command' \
        | sed -E "s/^Configure Command =>[[:space:]]*//; s/^'\\.\\/configure'[[:space:]]*//")"
    [ -n "$args" ] || { err "could not read the running build's Configure Command"; return 1; }

    local snap; snap="$(backup_root)/main-php"
    mkdir -p "$snap"
    main_php_snapshot "${snap}/modules-before.txt" "${snap}/ini-before.txt" \
        || { err "could not record the current modules/settings in ${snap} (disk full?) — nothing was changed"; return 1; }
    local had_lsphp=0; [ -x /usr/local/bin/lsphp ] && had_lsphp=1

    local src="/usr/local/src/bh-main-php-${target}"
    rm -rf "$src"
    main_php_fetch_source "$target" "$src" || return 1

    local nicep jobs; nicep="$(build_nice_prefix)"; jobs="$(build_jobs)"
    log "configure with the running build's options (log: ${src}/configure.log)"
    ( cd "${src}/php-${target}" && eval "set -- $args" && $nicep ./configure "$@" ) > "${src}/configure.log" 2>&1 \
        || { err "configure failed — tail ${src}/configure.log"; return 1; }
    log "make -j${jobs} (log: ${src}/make.log)"
    ( cd "${src}/php-${target}" && $nicep make -j"$jobs" ) > "${src}/make.log" 2>&1 \
        || { err "make failed — tail ${src}/make.log"; return 1; }
    "${src}/php-${target}/sapi/cli/php" -v 2>/dev/null | head -1 | grep -q "PHP ${target} " \
        || { err "the freshly built binary is not ${target}"; return 1; }
    ok "PHP ${target} built"

    log "checking every site on the main PHP before the swap"
    main_php_site_codes > "${snap}/sites-before.txt"
    log "  $(wc -l < "${snap}/sites-before.txt") site(s)"

    local b="${snap}/main-php-${cur}.tgz" f extra=""
    for f in /usr/local/bin/phpdbg /usr/local/bin/lsphp /usr/local/bin/pear /usr/local/bin/peardev /usr/local/bin/pecl /usr/local/bin/phar.phar /usr/local/bin/phar; do
        [ -e "$f" ] && extra="$extra $f"
    done
    # shellcheck disable=SC2086
    tar -czf "$b" /usr/local/bin/php /usr/local/bin/php-cgi /usr/local/bin/phpize /usr/local/bin/php-config \
        $extra /usr/local/lib/php /usr/local/include/php /usr/local/php 2>/dev/null \
        || { err "backup of the current main PHP failed — nothing was changed"; return 1; }
    ok "backup: $b ($(du -h "$b" | cut -f1))"

    if ! ( cd "${src}/php-${target}" && make install ) > "${src}/install.log" 2>&1; then
        err "make install failed — tail ${src}/install.log"
        main_php_restore "$b"; return 1
    fi

    local v c l="-" w lost new inidiff
    v="$("$MAIN_PHP" -r 'echo PHP_VERSION;' 2>/dev/null)"
    c="$("$MAIN_CGI" -v 2>/dev/null | head -1 | cut -d' ' -f2)"
    [ "$had_lsphp" = 1 ] && l="$(/usr/local/bin/lsphp -v 2>/dev/null | head -1 | cut -d' ' -f2)"
    w="$("$MAIN_PHP" -v 2>&1 | grep -ciE 'warning|already loaded|unable to load' || true)"
    # A snapshot that could not be written must FAIL the check, never compare as "no difference".
    if ! main_php_snapshot "${snap}/modules-after.txt" "${snap}/ini-after.txt"; then
        err "could not record the new modules/settings (disk full?)"
        main_php_restore "$b"; return 1
    fi
    lost="$(comm -23 "${snap}/modules-before.txt" "${snap}/modules-after.txt" | tr '\n' ' ')"
    new="$(comm -13 "${snap}/modules-before.txt" "${snap}/modules-after.txt" | tr '\n' ' ')"
    inidiff="$(diff "${snap}/ini-before.txt" "${snap}/ini-after.txt" | grep '^[<>]' | tr '\n' ' ' || true)"
    log "cli ${v:-?} | cgi ${c:-?} | lsphp ${l:-?} | startup warnings ${w} | modules lost [${lost:-none}] new [${new:-none}] | ini changes [${inidiff:-none}]"
    if [ "$v" != "$target" ] || [ "$c" != "$target" ] || { [ "$had_lsphp" = 1 ] && [ "$l" != "$target" ]; } \
       || [ "$w" != "0" ] || [ -n "$lost" ] || [ -n "$inidiff" ]; then
        err "verification failed"
        main_php_restore "$b"; return 1
    fi
    ok "main PHP ${cur} -> ${target}: same modules, same settings, no startup warnings"

    log "re-checking every site on the main PHP"
    main_php_site_codes > "${snap}/sites-after.txt"
    local changed
    changed="$(diff "${snap}/sites-before.txt" "${snap}/sites-after.txt" | grep '^[<>]' || true)"
    if [ -z "$changed" ]; then
        ok "all $(wc -l < "${snap}/sites-after.txt") site(s) answer exactly as before"
    else
        warn "these sites answer differently than before the upgrade (< before, > after):"
        printf '%s\n' "$changed" | sed 's/^/[WARN]     /' >&2
        warn "check them; to go back: tar -xzf $b -C /"
    fi
    MAIN_RESULT="main PHP ${cur} -> ${target} (rollback: tar -xzf $b -C /)"
    rm -rf "$src"
}
