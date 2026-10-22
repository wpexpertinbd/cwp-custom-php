#!/bin/bash
# main-php.sh — upgrade CWP's suPHP PHP builds to a newer point release of the SAME
# branch, e.g. 8.3.31 -> 8.3.36:
#   --main      the MAIN build in /usr/local (/usr/local/bin/php + php-cgi): every
#               vhost that is not on PHP-FPM runs on it
#   --selector  CWP's "PHP Selector" builds in /opt/alt/phpNN, which a suPHP site picks
#               with `AddHandler application/x-httpd-phpNN` in its .htaccess
#
# Why: CWP's own PHP Version Switcher / Selector only offer the versions CWP has
# packaged, so security releases arrive late or never.
#
# How: rebuild from php.net source with the EXACT configure command of the running
# build (read from `php -i`), so the same prefix is used, the same extensions are
# compiled in and the same libraries linked. php.ini, php.d and the PECL/loader .so
# files are not touched (same extension API inside a branch). Everything
# `make install` replaces is tarred first; a failed install or verification restores
# it automatically.
#
# Sourced by install.sh. Entry points:
#   upgrade_main_php <hint>              (hint: ""|latest|X.Y.Z)
#   upgrade_selector_php <branch list>   (""=every 8.2-8.5 selector build present)

SU_INI_KEYS="disable_functions memory_limit upload_max_filesize post_max_size max_execution_time session.upload_progress.enabled opcache.enable"
SU_PHP=""      # CLI binary of the build being upgraded (set by upgrade_suphp_build)
MAIN_RESULT=""
SELECTOR_RESULTS=()

su_php_ini() {   # su_php_ini <key> — effective value from the build being upgraded
    "$SU_PHP" -i 2>/dev/null | awk -F' => ' -v k="$1" '$1==k{print $2; exit}'
}

su_php_modules() {
    "$SU_PHP" -m 2>/dev/null | grep -vE '^\[|^$' | sort
}

su_php_warnings() {   # the warning lines PHP prints at startup, sorted
    "$SU_PHP" -v 2>&1 | grep -iE 'warning|already loaded|unable to load|requires zend' | sort -u || true
}

# su_php_check_install_paths <expected prefix> <configure args...>
# make install writes wherever the configure line says. Every install location
# must resolve inside the build being upgraded: the LAST --prefix wins (default
# /usr/local), and every explicit install-dir option must lie under it.
su_php_check_install_paths() {
    local want="$1" a eff="/usr/local" opt val; shift
    for a in "$@"; do
        case "$a" in --prefix=*) eff="${a#--prefix=}" ;; esac
    done
    eff="${eff%/}"
    [ "$eff" = "$want" ] || { err "configure installs into '${eff}', not '${want}' — refusing"; return 1; }
    for a in "$@"; do
        case "$a" in
            --exec-prefix=*|--bindir=*|--sbindir=*|--libexecdir=*|--libdir=*|--includedir=*|--datarootdir=*|--datadir=*|--sysconfdir=*|--localstatedir=*|--sharedstatedir=*|--mandir=*|--infodir=*|--docdir=*|--with-pear=*)
                opt="${a%%=*}"; val="${a#*=}"
                case "$val" in
                    "$want"|"$want"/*) ;;
                    *) err "configure option ${opt}=${val} installs outside ${want} — refusing"; return 1 ;;
                esac ;;
        esac
    done
}

# su_php_snapshot <modules file> <ini file> — fails unless both were fully written.
su_php_snapshot() {
    local k n
    su_php_modules > "$1" || return 1
    [ -s "$1" ] || return 1
    for k in $SU_INI_KEYS; do echo "${k}=$(su_php_ini "$k")"; done > "$2" || return 1
    n="$(wc -l < "$2")"
    [ "$n" -eq "$(echo $SU_INI_KEYS | wc -w)" ]
}

# Every vhost not served by PHP-FPM runs on a suPHP build (main or selector).
# Prints "<domain> <http code>".
su_php_site_codes() {
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
su_php_fetch_source() {
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

# su_php_restore <backup tgz> <backed-up path>...
# Directories are moved aside before the extract, so files the failed install ADDED
# do not survive the rollback; if the extract fails they are moved back.
su_php_restore() {
    local b="$1" p moved=(); shift
    warn "restoring the previous build from $b"
    for p in "$@"; do
        if [ -d "$p" ] && [ ! -L "$p" ] && mv "$p" "${p}.bh-undo.$$"; then moved+=("$p"); fi
    done
    if tar -xzf "$b" -C /; then
        for p in "${moved[@]}"; do rm -rf -- "${p}.bh-undo.$$"; done
        ok "restored: $SU_PHP is $("$SU_PHP" -r 'echo PHP_VERSION;' 2>/dev/null | tail -1) again"
    else
        for p in "${moved[@]}"; do rm -rf -- "$p"; mv "${p}.bh-undo.$$" "$p"; done
        err "RESTORE FAILED — the failed install is still in place; extract by hand: tar -xzf $b -C /"
    fi
}

# upgrade_suphp_build <label> <bin dir> <expected prefix> <hint> <backup path>...
# Sets SU_RESULT. Returns 1 on failure (the previous build is back in place).
upgrade_suphp_build() {
    local label="$1" bindir="$2" prefix="$3" hint="$4"; shift 4
    local cgi="${bindir}/php-cgi" lsphp="${bindir}/lsphp"
    SU_PHP="${bindir}/php"; SU_RESULT=""

    [ -x "$SU_PHP" ] && [ -x "$cgi" ] || { err "${label}: no php / php-cgi in ${bindir}"; return 1; }
    if [ -L "$SU_PHP" ]; then
        err "${label}: $SU_PHP is a symlink to $(readlink -f "$SU_PHP") (--system-php?) — not a CWP build, refusing"
        return 1
    fi

    local cur branch target
    cur="$("$SU_PHP" -r 'echo PHP_VERSION;' 2>/dev/null | tail -1)"
    [[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "${label}: PHP does not run"; return 1; }
    branch="${cur%.*}"
    if ! valid_major "$branch"; then
        warn "${label} is ${cur}: php.net no longer releases fixes for ${branch}, so there is nothing to upgrade to."
        SU_RESULT="${label} ${cur} (branch no longer supported upstream — not changed)"
        return 0
    fi
    if [ -n "$hint" ] && [ "$hint" != "latest" ]; then
        target="$hint"
    else
        target="$(resolve_php_version "$branch" latest)"
    fi
    if ! [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "${target%.*}" != "$branch" ]; then
        err "${label}: target '${target}' is not a ${branch}.x release (the branch cannot change: extensions would break)"
        return 1
    fi
    if [ "$target" = "$cur" ] && [ "${BH_MAIN_FORCE:-0}" != "1" ]; then
        ok "${label} is already ${cur} — nothing to do (BH_MAIN_FORCE=1 rebuilds anyway)"
        SU_RESULT="${label} ${cur} (already current)"
        return 0
    fi
    if version_lt "$target" "$cur"; then
        err "${label}: target ${target} is OLDER than the running ${cur} — refusing to downgrade"; return 1
    fi
    log "${label}: ${cur} -> ${target}"

    local args
    args="$("$SU_PHP" -i 2>/dev/null | grep -m1 '^Configure Command' \
        | sed -E "s/^Configure Command =>[[:space:]]*//; s/^'\\.\\/configure'[[:space:]]*//")"
    [ -n "$args" ] || { err "${label}: could not read the running build's Configure Command"; return 1; }
    # The configure line decides where make install writes. It must be the build we
    # are upgrading, never another one (checked on the parsed words, not the string).
    local cfg=()
    eval "cfg=( $args )" || { err "${label}: could not parse the Configure Command"; return 1; }
    su_php_check_install_paths "$prefix" "${cfg[@]}" || { err "${label}: refusing to build"; return 1; }

    local snap; snap="$(backup_root)/suphp-${label// /-}"
    mkdir -p "$snap"
    su_php_snapshot "${snap}/modules-before.txt" "${snap}/ini-before.txt" \
        || { err "${label}: could not record the current modules/settings in ${snap} (disk full?) — nothing was changed"; return 1; }
    su_php_warnings > "${snap}/warnings-before.txt"
    local had_lsphp=0; [ -x "$lsphp" ] && had_lsphp=1

    local src="/usr/local/src/bh-suphp-${label// /-}-${target}"
    rm -rf "$src"
    su_php_fetch_source "$target" "$src" || return 1

    local nicep jobs; nicep="$(build_nice_prefix)"; jobs="$(build_jobs)"
    # A bare --with-pgsql / --with-pdo-pgsql only looks in fixed places
    # (/usr/local/pgsql, /usr/bin/pg_config, ...), so a PGDG PostgreSQL in
    # /usr/pgsql-N is not found. When the running build links that libpq, point
    # both options at the same install: the new build links the same library.
    local pgbase="" pqlib i
    pqlib="$(ldd "$SU_PHP" 2>/dev/null | awk '$1 ~ /^libpq\.so/ && $2 == "=>" {print $3; exit}')"
    case "$pqlib" in
        /usr/pgsql-*/lib/*) [ -x "${pqlib%/lib/*}/bin/pg_config" ] && pgbase="${pqlib%/lib/*}" ;;
    esac
    if [ -n "$pgbase" ]; then
        for i in "${!cfg[@]}"; do
            case "${cfg[$i]}" in --with-pgsql|--with-pdo-pgsql) cfg[$i]="${cfg[$i]}=${pgbase}" ;; esac
        done
        log "PostgreSQL: the running build links ${pqlib}; building against ${pgbase}"
    fi
    log "configure with the running build's options (log: ${src}/configure.log)"
    ( cd "${src}/php-${target}" && PATH="${pgbase:+${pgbase}/bin:}${PATH}" \
        PKG_CONFIG_PATH="${pgbase:+${pgbase}/lib/pkgconfig:}${PKG_CONFIG_PATH:-}" \
        $nicep ./configure "${cfg[@]}" ) > "${src}/configure.log" 2>&1 \
        || { err "${label}: configure failed — tail ${src}/configure.log"; return 1; }
    log "make -j${jobs} (log: ${src}/make.log)"
    ( cd "${src}/php-${target}" && $nicep make -j"$jobs" ) > "${src}/make.log" 2>&1 \
        || { err "${label}: make failed — tail ${src}/make.log"; return 1; }
    "${src}/php-${target}/sapi/cli/php" -v 2>/dev/null | grep -q "^PHP ${target} " \
        || { err "${label}: the freshly built binary is not ${target}"; return 1; }
    ok "PHP ${target} built"

    log "checking every suPHP site before the swap"
    su_php_site_codes > "${snap}/sites-before.txt"
    log "  $(wc -l < "${snap}/sites-before.txt") site(s)"

    local b="${snap}/php-${cur}.tgz" p existing=""
    for p in "$@"; do [ -e "$p" ] && existing="$existing $p"; done
    # shellcheck disable=SC2086
    tar -czf "$b" $existing 2>/dev/null \
        || { err "${label}: backup of the current build failed — nothing was changed"; return 1; }
    ok "backup: $b ($(du -h "$b" | cut -f1))"

    if ! ( cd "${src}/php-${target}" && make install ) > "${src}/install.log" 2>&1; then
        err "${label}: make install failed — tail ${src}/install.log"
        su_php_restore "$b" "$@"; return 1
    fi

    local v c l="-" w lost new inidiff
    v="$("$SU_PHP" -r 'echo PHP_VERSION;' 2>/dev/null | tail -1)"
    c="$("$cgi" -v 2>/dev/null | grep -m1 '^PHP ' | cut -d' ' -f2)"
    [ "$had_lsphp" = 1 ] && l="$("$lsphp" -v 2>/dev/null | grep -m1 '^PHP ' | cut -d' ' -f2)"
    # A snapshot that could not be written must FAIL the check, never compare as "no difference".
    if ! su_php_snapshot "${snap}/modules-after.txt" "${snap}/ini-after.txt" \
       || ! su_php_warnings > "${snap}/warnings-after.txt"; then
        err "${label}: could not record the new modules/settings (disk full?)"
        su_php_restore "$b" "$@"; return 1
    fi
    # Any warning line that was not there before is a new fault, even if an old one went away.
    w="$(comm -13 "${snap}/warnings-before.txt" "${snap}/warnings-after.txt")"
    lost="$(comm -23 "${snap}/modules-before.txt" "${snap}/modules-after.txt" | tr '\n' ' ')"
    new="$(comm -13 "${snap}/modules-before.txt" "${snap}/modules-after.txt" | tr '\n' ' ')"
    inidiff="$(diff "${snap}/ini-before.txt" "${snap}/ini-after.txt" | grep '^[<>]' | tr '\n' ' ' || true)"
    log "cli ${v:-?} | cgi ${c:-?} | lsphp ${l:-?} | new startup warnings [${w:-none}] | modules lost [${lost:-none}] new [${new:-none}] | ini changes [${inidiff:-none}]"
    if [ "$v" != "$target" ] || [ "$c" != "$target" ] || { [ "$had_lsphp" = 1 ] && [ "$l" != "$target" ]; } \
       || [ -n "$w" ] || [ -n "$lost" ] || [ -n "$inidiff" ]; then
        err "${label}: verification failed"
        su_php_restore "$b" "$@"; return 1
    fi
    ok "${label} ${cur} -> ${target}: same modules, same settings, no new startup warnings"

    log "re-checking every suPHP site"
    su_php_site_codes > "${snap}/sites-after.txt"
    local changed
    changed="$(diff "${snap}/sites-before.txt" "${snap}/sites-after.txt" | grep '^[<>]' || true)"
    if [ -z "$changed" ]; then
        ok "all $(wc -l < "${snap}/sites-after.txt") site(s) answer exactly as before"
    else
        warn "these sites answer differently than before the upgrade (< before, > after):"
        printf '%s\n' "$changed" | sed 's/^/[WARN]     /' >&2
        warn "check them; to go back: tar -xzf $b -C /"
    fi
    SU_RESULT="${label} ${cur} -> ${target} (rollback: tar -xzf $b -C /)"
    rm -rf "$src"
}

upgrade_main_php() {
    section "Main PHP (suPHP / CLI in /usr/local)"
    local f extra=""
    for f in phpdbg lsphp pear peardev pecl phar.phar phar; do extra="$extra /usr/local/bin/$f"; done
    # shellcheck disable=SC2086
    upgrade_suphp_build "main PHP" /usr/local/bin /usr/local "$1" \
        /usr/local/bin/php /usr/local/bin/php-cgi /usr/local/bin/phpize /usr/local/bin/php-config $extra \
        /usr/local/lib/php /usr/local/include/php /usr/local/php
    local rc=$?
    MAIN_RESULT="$SU_RESULT"
    return $rc
}

# upgrade_selector_php <comma list of branches, e.g. "8.2,8.3"; empty = every 8.2-8.5 present>
upgrade_selector_php() {
    local want="${1// /}" d nn br ver failed=0 done_list=","
    section "PHP Selector builds (/opt/alt/phpNN)"
    for d in /opt/alt/php[0-9][0-9]; do
        [ -d "$d" ] && [ -x "${d}/usr/bin/php" ] || continue
        nn="${d##*/php}"; br="${nn:0:1}.${nn:1:1}"
        valid_major "$br" || continue
        if [ -n "$want" ]; then
            case ",${want}," in *",${br},"*) ;; *) continue ;; esac
        fi
        # The directory name says which branch CWP serves from it; the binary must agree.
        ver="$("${d}/usr/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null | tail -1)"
        if [ "${ver%.*}" != "$br" ]; then
            SELECTOR_RESULTS+=("fail:${d} holds PHP '${ver:-?}', not ${br}.x — left alone")
            failed=1; continue
        fi
        done_list="${done_list}${br},"
        # The whole build lives under its prefix: back it up as one tree.
        if upgrade_suphp_build "selector ${br}" "${d}/usr/bin" "${d}/usr" "" "$d"; then
            SELECTOR_RESULTS+=("ok:${SU_RESULT}")
        else
            SELECTOR_RESULTS+=("fail:selector ${br} upgrade FAILED — the previous build is in place")
            failed=1
        fi
    done
    if [ -n "$want" ]; then
        for br in ${want//,/ }; do
            case "$done_list" in *",${br},"*) ;; *)
                SELECTOR_RESULTS+=("fail:selector ${br} was requested but /opt/alt/php${br//./} is not a ${br}.x build on this server")
                failed=1 ;;
            esac
        done
    elif [ "$done_list" = "," ]; then
        warn "no PHP Selector build of 8.2-8.5 found in /opt/alt/phpNN — nothing to do"
    fi
    return $failed
}
