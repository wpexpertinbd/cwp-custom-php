#!/bin/bash
# deploy-gui.sh — copy versions.ini, N.ini, external_modules, pre_run into CWP selector

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

deploy_gui() {
    local major="$1"   # 8.3 / 8.4 / 8.5
    local short; short="$(php_short "$major")"
    local repo_sel="${REPO_ROOT}/selector"
    local CWP_SEL="/usr/local/cwpsrv/htdocs/resources/conf/el${BH_EL_MAJOR}/php-fpm_selector"

    section "Deploy GUI scaffolding for PHP $major  (EL${BH_EL_MAJOR})"

    [ -d "$repo_sel" ] || die "Repo selector dir missing: $repo_sel"
    [ -d "$CWP_SEL"   ] || die "CWP selector dir missing: $CWP_SEL"

    # versions.ini — deliberately NOT deployed here.
    #
    # This used to be a blind `install -m 0644 repo/versions.ini -> live`, which
    # overwrote CWP's live catalogue with our repo's FROZEN snapshot. Because that
    # snapshot ages the moment it is committed, every single build silently
    # DOWNGRADED the version list for *every* branch — not just the 8.4/8.5 we
    # manage. Real damage seen on biswashost: live had 8.2.33/8.3.33/8.4.24/8.5.9,
    # a rebuild stamped it back to 8.2.31/8.3.31/8.4.21/8.5.6, so the admin could
    # no longer pick the releases that were actually installed.
    #
    # versions.ini is now owned exclusively by ensure_versions_ini() (see
    # lib/versions-merge.sh), which is ADDITIVE: it inserts the version we truly
    # built and never removes a line CWP shipped.
    log "versions.ini: left to ensure_versions_ini() (additive merge, never overwrites)"

    # N.ini — prefer EL-specific variant (8.4.el8.ini / 8.4.el9.ini), fall back to 8.4.ini
    local ini_src=""
    if [ -f "${repo_sel}/${major}.el${BH_EL_MAJOR}.ini" ]; then
        ini_src="${repo_sel}/${major}.el${BH_EL_MAJOR}.ini"
    elif [ -f "${repo_sel}/${major}.ini" ]; then
        ini_src="${repo_sel}/${major}.ini"
    fi
    if [ -n "$ini_src" ]; then
        backup_file "${CWP_SEL}/${major}.ini"
        install -m 0644 "$ini_src" "${CWP_SEL}/${major}.ini"
        ok "${major}.ini deployed (from $(basename "$ini_src"))"
    else
        warn "${major}.ini not found in repo — skipping"
    fi

    # external_modules/<major>/*
    if [ -d "${repo_sel}/external_modules/${major}" ]; then
        mkdir -p "${CWP_SEL}/external_modules/${major}"
        backup_file "${CWP_SEL}/external_modules/${major}"
        local f
        for f in "${repo_sel}/external_modules/${major}"/*; do
            [ -e "$f" ] || continue
            install -m 0755 "$f" "${CWP_SEL}/external_modules/${major}/$(basename "$f")"
        done
        # normalise CRLF -> LF in case the repo was edited on Windows
        find "${CWP_SEL}/external_modules/${major}" -type f -name '*.sh' \
            -exec dos2unix -q {} \; 2>/dev/null || true
        ok "external_modules/${major}/ deployed ($(ls "${CWP_SEL}/external_modules/${major}" | wc -l) files)"
    fi

    # pre_run/<major>/*
    if [ -d "${repo_sel}/pre_run/${major}" ]; then
        mkdir -p "${CWP_SEL}/pre_run/${major}"
        backup_file "${CWP_SEL}/pre_run/${major}"
        local f
        for f in "${repo_sel}/pre_run/${major}"/*; do
            [ -e "$f" ] || continue
            install -m 0755 "$f" "${CWP_SEL}/pre_run/${major}/$(basename "$f")"
        done
        find "${CWP_SEL}/pre_run/${major}" -type f -name '*.sh' \
            -exec dos2unix -q {} \; 2>/dev/null || true
        ok "pre_run/${major}/ deployed"
    fi
}
