#!/bin/bash
# carry-config.sh — carry an existing install's custom PHP configuration across
# the atomic swap in build-php.sh.
#
# The swap replaces /opt/alt/php-fpmNN with a freshly staged tree whose php.ini
# is php.ini-production (+ the four CWP seds) and whose php.d is EMPTY. On
# 2026-10-21, rebuilding the fleet to 8.2.35/8.3.36/8.4.27/8.5.12 silently
# dropped php.d/disabled_function.ini (disable_functions = exec, system, ...),
# zz-opcache-tuned.ini, zz-bh-cve-2026-109619.ini and the big-upload php.ini
# values; a site broke on memory_limit = 128M before anyone noticed.
#
# Order in build_php:
#   atomic_swap       -> carry_over_php_ini + carry_over_settings_inis (before first start)
#   external modules  -> prune_static_extension_inis + carry_over_extension_inis

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Keys whose loss has broken sites or dropped a security control. Every other
# key is carried too when its old value differs from the new stock php.ini;
# these are additionally reported by name when they already match.
BH_PHPINI_CORE_KEYS="upload_max_filesize post_max_size memory_limit max_input_time max_execution_time disable_functions"

# static_modules <php-binary> — modules compiled INTO the binary, lowercased,
# one per line ("Zend OPcache" -> opcache). `php -n` reads no ini at all, so
# every module it lists is built in, never a shared .so.
static_modules() {
    local php="$1"
    [ -x "$php" ] || return 0
    { "$php" -n -m 2>/dev/null || true; } | awk '
        /^\[/ || NF == 0 { next }
        { m = tolower($0); gsub(/[ \t\r]/, "", m); if (m == "zendopcache") m = "opcache"; print m }' | sort -u
}

# ini_loaders <file> — "<directive>\t<value>" for each ACTIVE extension= /
# zend_extension= line.
ini_loaders() {
    awk '
        /^[ \t]*[;#]/ { next }
        /^[ \t]*(zend_)?extension[ \t]*=/ {
            d = $0; sub(/[ \t]*=.*/, "", d); gsub(/[ \t]/, "", d)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); gsub(/"/, "", v)
            print d "\t" v
        }' "$1" 2>/dev/null
}

# loader_module <value> — module name of a loader value:
#   mbstring.so -> mbstring    php_redis.so -> redis    opcache -> opcache
#   /usr/local/ioncube/ioncube_loader_lin_8.3.so -> ioncube_loader_lin_8.3
loader_module() {
    local m="${1##*/}"
    m="${m%.so}"
    m="${m#php_}"
    printf '%s\n' "$m" | tr '[:upper:]' '[:lower:]'
}

# ini_settings <file> — active non-loader lines, whitespace-normalised, sorted.
ini_settings() {
    awk '
        /^[ \t]*([;#]|$)/ { next }
        /^[ \t]*(zend_)?extension[ \t]*=/ { next }
        { l = $0; gsub(/[ \t\r]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l); print l }' "$1" 2>/dev/null | sort -u
}

# carry_over_php_ini <old php.ini> <new php.ini>
# Every active key of the old php.ini whose value differs from (or is absent
# in) the new stock file is written into the new file: in place where the key
# is active, appended in a marked block otherwise. Skipped, with a warning:
# extension=/zend_extension= lines (php.d owns loaders) and [PATH=]/[HOST=]
# sections (per-directory overrides; review by hand).
carry_over_php_ini() {
    local old="$1" new="$2"
    if [ ! -f "$old" ]; then
        log "php.ini carry-over: no previous php.ini (fresh install)"
        return 0
    fi
    if [ ! -f "$new" ]; then
        warn "php.ini carry-over: new php.ini missing at ${new} — nothing to carry into"
        return 0
    fi

    local tmp report
    tmp="$(mktemp "${new}.carry.XXXXXX")"
    report="$(mktemp)"

    if ! awk -v out="$tmp" -v report="$report" -v core=" ${BH_PHPINI_CORE_KEYS} " '
        function key_of(line,   k) {
            if (line ~ /^[ \t]*[;#]/) return ""
            if (line !~ /^[ \t]*[A-Za-z0-9_.-]+[ \t]*=/) return ""
            k = line; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
            return k
        }
        function val_of(line,   v) {
            v = line; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
            return v
        }
        FILENAME == ARGV[1] {
            if ($0 ~ /^[ \t]*\[/) {
                special = ($0 ~ /^[ \t]*\[(PATH|HOST|path|host)=/)
                if (special) { print "SECTION\t" $0 > report; sbuf[++ns] = $0 }
                next
            }
            if (special) { sub(/\r$/, ""); sbuf[++ns] = $0; next }
            k = key_of($0); if (k == "") next
            if (k == "extension" || k == "zend_extension") { print "LOADER\t" $0 > report; next }
            if (!(k in oldv)) order[++n] = k
            oldv[k] = val_of($0)
            next
        }
        {
            lines[++m] = $0
            if ($0 ~ /^[ \t]*\[/) { nspecial = ($0 ~ /^[ \t]*\[(PATH|HOST|path|host)=/); next }
            k = key_of($0); if (k == "" || nspecial) next
            newv[k] = val_of($0); newat[m] = k
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                if (!(k in newv)) { carry[k] = 1; print "CARRY\t" k "\t" oldv[k] "\t<not set>" > report }
                else if (newv[k] != oldv[k]) { carry[k] = 1; print "CARRY\t" k "\t" oldv[k] "\t" newv[k] > report }
                else if (index(core, " " k " ")) print "SAME\t" k "\t" oldv[k] > report
            }
            for (i = 1; i <= m; i++) {
                k = newat[i]
                if (k != "" && (k in carry)) { print k " = " oldv[k] > out; done[k] = 1 }
                else print lines[i] > out
            }
            hdr = 0
            for (i = 1; i <= n; i++) {
                k = order[i]
                if (!(k in carry) || (k in done)) continue
                if (!hdr) { print "" > out; print "; ---- carried over from the previous install by cwp-custom-php ----" > out; hdr = 1 }
                print k " = " oldv[k] > out
            }
            # [PATH=]/[HOST=] sections go LAST, verbatim: every key after such a
            # header belongs to it (per-site open_basedir and the like).
            if (ns) {
                print "" > out
                print "; ---- per-directory/host sections carried over from the previous install by cwp-custom-php ----" > out
                for (i = 1; i <= ns; i++) print sbuf[i] > out
            }
        }' "$old" "$new"; then
        rm -f "$tmp" "$report"
        warn "php.ini carry-over: could not parse ${old} — new php.ini left STOCK, compare by hand"
        return 1
    fi

    local kind k v s n=0
    while IFS=$'\t' read -r kind k v s; do
        case "$kind" in
            CARRY)   ok "php.ini: carried ${k} = ${v}  (stock: ${s})"; n=$((n + 1)) ;;
            SAME)    log "php.ini: ${k} = ${v}  (same as the previous install)" ;;
            LOADER)  log "php.ini: loader '${k}' is handled after the external modules (moved to php.d if the new build has its module)" ;;
            SECTION) ok "php.ini: carried the ${k} section verbatim (at the end of php.ini)" ;;
        esac
    done < "$report"

    cat "$tmp" > "$new"
    rm -f "$tmp" "$report"
    ok "php.ini carry-over: ${n} key(s) restored from the previous install"
}

# carry_over_settings_inis <old php.d> <new php.d>
# Copies every php.d/*.ini (and *.ini.disabled) that loads no extension —
# disabled_function.ini, zz-opcache-tuned.ini, zz-bh-cve-*.ini and the like.
# Loader files are handled after the external modules by carry_over_extension_inis.
carry_over_settings_inis() {
    local old_d="$1" new_d="$2" f base n=0
    [ -d "$old_d" ] || return 0
    mkdir -p "$new_d"
    for f in "$old_d"/*.ini "$old_d"/*.ini.disabled; do
        [ -f "$f" ] || continue
        [ -n "$(ini_loaders "$f")" ] && continue
        base="$(basename "$f")"
        if [ -e "${new_d}/${base}" ]; then
            cmp -s "$f" "${new_d}/${base}" && continue
            warn "php.d: ${base} exists in the new build and differs — kept the new one; the old copy stays with the previous install (see final summary)"
            continue
        fi
        cp -a "$f" "${new_d}/${base}"
        ok "php.d: carried over ${base}  ($(ini_settings "$f" | wc -l | tr -d ' ') setting line(s))"
        n=$((n + 1))
    done
    ok "php.d carry-over: ${n} settings file(s) restored from the previous install"
}

# comment_out_loaders <file> "<mod> <mod>..." <reason> — comments out, in
# place, the active loader lines whose module (loader_module) is listed.
comment_out_loaders() {
    local f="$1" mods="$2" why="$3"
    awk -v mods=" ${mods} " -v why="$why" '
        /^[ \t]*[;#]/ { print; next }
        /^[ \t]*(zend_)?extension[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); gsub(/"/, "", v)
            sub(/.*\//, "", v); sub(/\.so$/, "", v); sub(/^php_/, "", v); v = tolower(v)
            if (index(mods, " " v " ")) { print "; " $0 "   ; cwp-custom-php: " why; next }
        }
        { print }' "$f" > "${f}.tmp" && cat "${f}.tmp" > "$f"
    rm -f "${f}.tmp"
}

# prune_static_extension_inis <fpmdir>
# Comments out extension=/zend_extension= lines for modules compiled into the
# binary (8.3's CWP mbstring.sh writes mbstring.ini for a built-in mbstring ->
# "Module mbstring is already loaded" on every CLI run). A file left with no
# active line is removed. Each touched file is backed up first.
prune_static_extension_inis() {
    local FPMDIR="$1" d="${1}/usr/php/php.d" statics f dir val mod mods
    [ -d "$d" ] || return 0
    statics="$(static_modules "${FPMDIR}/usr/bin/php")"
    if [ -z "$statics" ]; then
        warn "php.d: could not list compiled-in modules (php -n -m) — skipping the static-loader check"
        return 0
    fi
    for f in "$d"/*.ini; do
        [ -f "$f" ] || continue
        mods=""
        while IFS=$'\t' read -r dir val; do
            [ -n "$val" ] || continue
            mod="$(loader_module "$val")"
            printf '%s\n' "$statics" | grep -qxF "$mod" && mods="${mods} ${mod}"
        done <<< "$(ini_loaders "$f")"
        [ -n "$mods" ] || continue

        backup_file "$f"
        comment_out_loaders "$f" "$mods" "compiled in statically"

        if [ -z "$(ini_settings "$f")" ] && [ -z "$(ini_loaders "$f")" ]; then
            rm -f "$f"
            ok "php.d: removed $(basename "$f") —${mods} is compiled in statically (backup kept)"
        else
            ok "php.d: commented out the${mods} loader in $(basename "$f") — compiled in statically (backup kept)"
        fi
    done
}

# carry_over_extension_inis <rollback dir> <fpmdir>
# Old php.d loader files the new build did not recreate are copied when every
# module they load exists for the NEW install (an extension dir .so, or an
# absolute path such as /usr/local/ioncube/...). A module the new build already
# loads (under any file name) or has compiled in is skipped. A loader whose .so
# is missing is NOT copied and is reported loudly instead of silently dropped.
# An old <ext>.ini.disabled re-disables the new build's <ext>.ini.
carry_over_extension_inis() {
    local rb="$1" FPMDIR="$2"
    local old_d="${rb}/usr/php/php.d" new_d="${FPMDIR}/usr/php/php.d"
    [ -d "$old_d" ] || return 0
    mkdir -p "$new_d"

    local extdir statics new_mods f g base stem dir val mod target missing loaded extra n=0
    extdir="$("${FPMDIR}/usr/bin/php-config" --extension-dir 2>/dev/null || true)"
    statics="$(static_modules "${FPMDIR}/usr/bin/php")"
    new_mods="$(for g in "$new_d"/*.ini "$new_d"/*.ini.disabled; do
                    [ -f "$g" ] || continue
                    ini_loaders "$g" | while IFS=$'\t' read -r dir val; do loader_module "$val"; done
                done | sort -u)"

    for f in "$old_d"/*.ini "$old_d"/*.ini.disabled; do
        [ -f "$f" ] || continue
        [ -n "$(ini_loaders "$f")" ] || continue
        base="$(basename "$f")"; stem="${base%.disabled}"; stem="${stem%.ini}"

        # The new build wrote its own loader under the same name: it wins.
        if [ -e "${new_d}/${stem}.ini" ] || [ -e "${new_d}/${stem}.ini.disabled" ]; then
            if [ "$base" = "${stem}.ini.disabled" ] && [ ! -e "${old_d}/${stem}.ini" ] && [ -e "${new_d}/${stem}.ini" ]; then
                mv "${new_d}/${stem}.ini" "${new_d}/${stem}.ini.disabled"
                ok "php.d: ${stem}.ini kept DISABLED, as it was in the previous install"
            fi
            # Settings the old file had beyond the new one (e.g. a tuned
            # opcache.ini) are appended, so on a clash the old value wins.
            g="${new_d}/${stem}.ini"; [ -e "$g" ] || g="${g}.disabled"
            extra="$(comm -23 <(ini_settings "$f") <(ini_settings "$g"))"
            if [ -n "$extra" ]; then
                { echo; echo "; ---- settings carried over from the previous ${base} by cwp-custom-php ----"
                  printf '%s\n' "$extra"; } >> "$g"
                ok "php.d: kept the previous ${base} settings in the new $(basename "$g"): $(printf '%s' "$extra" | tr '\n' ';')"
            fi
            continue
        fi

        missing=""; loaded=""
        while IFS=$'\t' read -r dir val; do
            [ -n "$val" ] || continue
            mod="$(loader_module "$val")"
            if printf '%s\n' "$statics" | grep -qxF "$mod" || printf '%s\n' "$new_mods" | grep -qxF "$mod"; then
                loaded="${loaded} ${mod}"; continue
            fi
            case "$val" in /*) target="$val" ;; *) target="${extdir}/${val}" ;; esac
            case "$target" in *.so) ;; *) target="${target}.so" ;; esac
            [ -f "$target" ] || missing="${missing} ${target}"
        done <<< "$(ini_loaders "$f")"

        if [ -n "$loaded" ] && [ -z "$missing" ]; then
            if [ -n "$(ini_settings "$f")" ]; then
                # e.g. an old opcache.ini on 8.5, where opcache is built in: keep
                # its settings, drop the loader that would now double-load.
                cp -a "$f" "${new_d}/${base}"
                comment_out_loaders "${new_d}/${base}" "$loaded" "already provided by the new build"
                ok "php.d: carried over ${base} with its${loaded} loader commented out (already provided by the new build)"
                n=$((n + 1))
            else
                log "php.d: ${base} not carried —${loaded} already provided by the new build"
            fi
        elif [ -n "$missing" ]; then
            warn "php.d: NOT carried ${base} — the new build has no${missing}. Rebuild that extension for this PHP, then restore ${base} from the previous install (see final summary)"
        else
            cp -a "$f" "${new_d}/${base}"
            ok "php.d: carried over ${base}  (its module exists for the new build)"
            new_mods="${new_mods}"$'\n'"$(ini_loaders "$f" | while IFS=$'\t' read -r dir val; do loader_module "$val"; done)"
            n=$((n + 1))
        fi
    done

    # Loaders that lived in the old php.ini itself (carry_over_php_ini leaves
    # them out of the new php.ini): same checks, written to one php.d file.
    local old_ini="${rb}/usr/php/php.ini" pini="${new_d}/00-carried-from-php-ini.ini"
    if [ -f "$old_ini" ]; then
        while IFS=$'\t' read -r dir val; do
            [ -n "$val" ] || continue
            mod="$(loader_module "$val")"
            if printf '%s\n' "$statics" | grep -qxF "$mod" || printf '%s\n' "$new_mods" | grep -qxF "$mod"; then
                log "php.ini: loader ${dir}=${val} not carried — ${mod} already provided by the new build"
                continue
            fi
            case "$val" in /*) target="$val" ;; *) target="${extdir}/${val}" ;; esac
            case "$target" in *.so) ;; *) target="${target}.so" ;; esac
            if [ -f "$target" ]; then
                printf '%s=%s\n' "$dir" "$val" >> "$pini"
                new_mods="${new_mods}"$'\n'"${mod}"
                ok "php.ini: carried loader ${dir}=${val} -> $(basename "$pini")"
                n=$((n + 1))
            else
                warn "php.ini: NOT carried loader ${dir}=${val} — the new build has no ${target}. Rebuild that extension for this PHP, then re-add the line"
            fi
        done <<< "$(ini_loaders "$old_ini")"
    fi
    ok "php.d carry-over: ${n} extension loader(s) restored from the previous install"
}
