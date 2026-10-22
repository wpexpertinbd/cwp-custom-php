# cwp-custom-php

Custom PHP-FPM **8.3 / 8.4 / 8.5** installer and updater for **CWP (Control Web Panel)** on **EL8 / EL9** (AlmaLinux, Rocky, CloudLinux, CentOS).

Replaces the multi-step manual guide (copy selector files, fix mbstring, build curl, run builder per version, patch memcache/redis, install imagick/ioncube, reinstall ioncube after every CWP rebuild, etc.) with a **single command**.

## What `install.sh` does

A single auto-detecting script that:

1. Auto-detects **EL8 vs EL9** and picks the right build profile
2. Refreshes `ca-certificates` and **auto-disables the `/etc/ld.so.conf.d/curl-local.conf` trap** that breaks dnf/yum after a manual curl install
3. Deploys CWP GUI scaffolding — `versions.ini`, EL-appropriate `8.3.ini`/`8.4.ini`/`8.5.ini`, all `external_modules/*` and `pre_run/*` — into the right `/usr/local/cwpsrv/htdocs/resources/conf/el${MAJOR}/php-fpm_selector/` path
4. Seeds known-good `php{NN}.conf` / `_pre.conf` / `_external.conf` (EL8 only — fixes the **mbstring missing** bug out of the box)
5. **Builds PHP** with EL-aware compile profile:
   - **EL8**: isolated `curl 8.7.1` under `/opt/curl-8.7.1/` (used only at build-time — never touches `/usr/local/lib`, never breaks dnf), PIE flags, OpenSSL 1.1.1k
   - **EL9**: native OpenSSL 3.x, system curl, no PIE — simpler and faster
6. **Atomic-swap deploy** — core PHP is built into `STAGE_DIR` via `DESTDIR`. Tenants keep serving on the EXISTING `/opt/alt/php-fpmNN` for the entire ~10-15 min compile window. Atomic swap is ~2-5 sec. User pool configs carry over from the old install. **Auto-rollback if the new install fails to start** — old install restored from `.rollback.<stamp>` dir, service brought back online in seconds. Extensions (imagick/redis/memcache/ioncube) build AFTER swap — ~3-5 min degraded window where sites using those extensions error before they finish loading.
7. Builds all the **PECL extensions you actually need** — memcache (websupport-sk fork), memcached, redis (phpredis git), imagick, ioncube, mongodb, apcu, mailparse, xdebug, etc.
8. **Auto-heals ioncube** after every CWP rebuild — fixes the wart where `sh /scripts/update_cwp` or CWP's "Rebuild Apache + PHP-FPM" overwrites `/usr/local/ioncube/` with the stale bundled tarball missing 8.4/8.5 loaders
9. Wires systemd unit, Apache `mod_proxy_fcgi`, monit watcher, CSF `pignore` — all auto-applied
10. Verifies — final table per built version shows PHP version, OpenSSL version, libcurl version, `php-fpm -t` result, service state, key extensions loaded

Works on:
- CWP / CloudLinux EL8
- CWP / CloudLinux EL9
- AlmaLinux / Rocky / CentOS 8 + 9

Idempotent — safe to re-run, safe to upgrade point releases.

## Quick install

```bash
# SSH to target server as root. The safe default rollout below builds PHP
# atomically and never touches CWP's system PHP, /usr/local/lib*/, or
# /usr/local/bin/* — so it's safe on any server.
```

### Recommended fleet rollout (safe defaults)

Run as root on each target server. Each version installs independently with atomic-swap (zero compile-time downtime, auto-rollback on failure):

```bash
for v in 8.5 8.4 8.3 8.2; do
  curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
    | bash -s -- --php $v=latest --force-conf
done
```

Logs are written automatically to `/root/cwp-custom-php-<hostname>-<timestamp>.log` per run. If a build fails, share that file. To disable auto-logging: append `--no-log` or `BH_LOG_FILE=/dev/null bash …`.

This is **all you need on a fresh server**. After it completes:
- PHP 8.2, 8.3, 8.4, 8.5 are built and visible in CWP Admin → PHP-FPM Selector
- CWP's own PHP installs (5.x, 7.x, 8.0, 8.1) are untouched
- `/usr/local/lib*/` and `/usr/local/bin/*` are untouched
- Existing CWP system PHP-CGI (PHP Version Switcher UI) is untouched
- ionCube auto-healed, `mongodb`/`sourceguardian` extensions default-disabled

### Build a single version

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4=latest
```

### Pin a specific version

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4=8.4.21
```

### Update an existing custom PHP to a newer point release

Same command — the script is idempotent. Atomic-swap means tenants serve on the existing PHP throughout the build; the swap is ~2-5 sec.

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4=latest
```

### Upgrade CWP's main PHP (suPHP / CLI) — `--main`

Every site that is **not** on PHP-FPM runs on CWP's main PHP (`/usr/local/bin/php` + `php-cgi`), and CWP's PHP Version Switcher only offers the releases CWP has packaged. `--main` rebuilds it to the newest php.net release **of the branch it already runs** (8.2–8.5):

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --main

# everything at once: PHP-FPM 8.2-8.5 and the main PHP
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.2=latest,8.3=latest,8.4=latest,8.5=latest --force-conf --main
```

- Uses the **exact configure options of the running build** (read from `php -i`), so the same extensions are compiled in and the same libraries linked.
- The source tarball is checked against the **sha256 php.net publishes**; a mismatch stops the run.
- `php.ini`, `php.d/` and the PECL / ionCube / SourceGuardian `.so` files are not touched (same extension API inside a branch).
- Everything `make install` replaces is tarred to `/root/cwp-php-backups/<stamp>/main-php/` first. The run **rolls back automatically** if the new binary is not the target version, a module disappeared, a setting changed, or PHP prints a startup warning.
- Every site on the main PHP is fetched before and after; any site that answers differently is listed with the rollback command.
- `--main=8.3.36` pins a version. It never changes the branch (8.3 stays 8.3) and never downgrades. Already current = nothing to do (`BH_MAIN_FORCE=1` rebuilds anyway).
- On 7.x / 8.0 / 8.1 it does nothing: php.net no longer releases fixes for those branches.

**`--selector[=8.2,8.3]`** does the same for CWP's **PHP Selector** builds in `/opt/alt/phpNN` (not the `/opt/alt/php-fpmNN` FPM builds): a suPHP site picks one with `AddHandler application/x-httpd-phpNN` in its `.htaccess`, so these serve sites too and need the same security releases. Each 8.2–8.5 build present is upgraded within its branch; the whole `/opt/alt/phpNN` tree is backed up first, and the configure prefix must be that build's own (`/opt/alt/phpNN/usr`) or it refuses. Selector builds often already print startup warnings (an old SourceGuardian / mongodb loader), so the check there is "no NEW warnings".

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.2=latest,8.3=latest,8.4=latest,8.5=latest --force-conf --main --selector
```

### ⚠️ Advanced flags — only use after reading the warnings

`--clean-shadow-libs` and `--system-php=X.Y` exist for specific repair scenarios but **caused tenant outages on s1 (2026-05-27)** when used as part of the default rollout. They override CWP's behaviour for `/usr/local/bin/php*` and `/usr/local/lib*/`. Don't include them in fleet rollout commands unless you have a specific known problem and have read what they do in the [Options reference](#options-reference) below.

## Pick the command that matches your situation

### After ANY CWP UI rebuild — `--refresh-ioncube` (canonical recovery command)

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --refresh-ioncube
```

**When to run it:**
- After clicking **Rebuild Apache + PHP** in CWP Admin
- After **PHP Version Switcher → Build** in CWP Admin
- After **PHP Selector → install/rebuild** any per-user PHP-CGI version
- After **PHP-FPM Selector → install/rebuild** any CWP-managed (5.x–8.1) version
- After CWP's auto-update runs (often at midnight)
- Any time `/scripts/update_cwp` runs (manually or via cron)
- Any time `php -v` on a custom version says `libzip.so.5: cannot open shared object file` or `ionCube loader: No such file or directory`

**What it does (in this exact order):**

1. **`check_libzip`** — Detects whether the `libzip` RPM is installed and `/usr/lib64/libzip.so.5` exists. CWP UI rebuilds frequently REMOVE the libzip RPM entirely (real incidents on s1 + s4 — happened twice). When this happens, every PHP binary segfaults with `libzip.so.5: cannot open shared object file`. This step auto-reinstalls `libzip` + `libzip-devel` via `dnf` and runs `ldconfig`.

2. **`refresh_ioncube`** — Downloads the latest ionCube loader tarball from `ioncube.com` (29 MB, ~5 sec), extracts to `/usr/local/ioncube/`, fixes permissions (root:root, 755 dirs / 644 files), then for every detected `/opt/alt/php-fpmNN`:
   - Writes `php.d/ioncube.ini` pointing at the matching `ioncube_loader_lin_<X.Y>.so`
   - Verifies the loader actually loads via `php -v` (looks for "ionCube" in output)
   - Restarts `php-fpm<NN>` service so live workers pick up the new loader
   - Skips PHP 8.0 (ionCube never released a loader for 8.0 — by design, not a bug)
   - Skips `.rollback.*` / `.failed.*` backup dirs from atomic-swap builds
   - Auto-removes `chattr +i` immutable bit on `/usr/local/ioncube/` if present

3. **`ensure_versions_ini`** — Detects which `/opt/alt/php-fpm{82,83,84,85}` dirs exist with working binaries. Reads `/usr/local/cwpsrv/htdocs/resources/conf/el${MAJOR}/php-fpm_selector/versions.ini`. For each installed major:
   - If `[X.Y]` section MISSING (CWP wiped it during their update) → appends our whole section block (all point releases, latest first)
   - If section EXISTS but our LATEST point release isn't listed → inserts the `version[]=X.Y.Z` line right after the `[X.Y]` header (shows first in CWP UI dropdown)
   - If section exists and latest is listed → no-op
   - Sections for versions we DON'T manage (5.x, 7.x, 8.0, 8.1) are **never touched** — CWP's updates to those flow through cleanly
   - Always backs up the live file to `/root/cwp-php-backups/<stamp>/` first

4. **Service restart loop** — Iterates every `/opt/alt/php-fpm*` (skipping `.rollback/.failed/.bak/.old` dirs), runs `systemctl restart php-fpm<NN>` for each one that has a systemd unit. Prints the version banner per service for confirmation.

**What it does NOT do:**
- Does NOT rebuild PHP from source
- Does NOT change PHP versions
- Does NOT touch `/usr/local/lib*/` shadow libs
- Does NOT touch `/usr/local/bin/php*` system symlinks
- Does NOT run `/scripts/update_cwp` (used to — that was self-defeating since CWP's script wipes ionCube; removed in commit `333f8ab`)

**Runtime:** ~30-90 seconds total. Atomic — services briefly cycle but no rebuilding.

**Safe to run:**
- Anytime, idempotent
- Pre-flight to confirm a server is healthy after CWP-side operations
- As part of a cron / monitoring script if you want it automated

**Auto-log:** `/root/cwp-custom-php-<host>-<stamp>.log`. Share this file if anything fails.

### Manual curl install broke `dnf` / `yum` / nginx repo?

You hit the `/etc/ld.so.conf.d/curl-local.conf` trap. Fix:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --fix-dnf
```

### Repeat build, scaffolding already in place

Skip the GUI deploy to save 10 seconds:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4 --build-only
```

### Overwrite existing `php{NN}.conf` build recipe (EL8)

If your existing `/usr/local/cwp/.conf/php-fpm_conf/php84.conf` is an old one missing `--enable-mbstring`, force-replace it with the repo's known-good copy:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4 --force-conf
```

### Offline / air-gapped install

```bash
git clone https://github.com/wpexpertinbd/cwp-custom-php.git /root/cwp-custom-php
cd /root/cwp-custom-php
bash install.sh --php 8.4
```

## Verify after a build

```bash
# Custom PHP works?
/opt/alt/php-fpm84/usr/bin/php -v

# All expected modules loaded?
/opt/alt/php-fpm84/usr/bin/php -m

# FPM config sane?
/opt/alt/php-fpm84/usr/sbin/php-fpm -t

# Service up?
systemctl status php-fpm84

# OpenSSL + curl actually wired into PHP?
/opt/alt/php-fpm84/usr/bin/php -i | grep -iE 'SSL Version|cURL Information'

# Ioncube loaded?
/opt/alt/php-fpm84/usr/bin/php -v | grep -i ioncube
```

## Options reference

| Flag                  | What it does |
|-----------------------|--------------|
| `--php X.Y[=VER]`     | PHP majors to install/update. Accepts `8.4`, `8.4=8.4.21`, `8.4=latest`, comma-list `8.3,8.4,8.5`. |
| `--main[=VER]`        | Also upgrade CWP's main (suPHP / CLI) PHP to the newest release of its own branch, or to `VER` in that branch. Backed up first, rolled back automatically on any difference. See [Upgrade CWP's main PHP](#upgrade-cwps-main-php-suphp--cli----main). `--php` becomes optional. |
| `--selector[=LIST]`   | Also upgrade CWP's PHP Selector builds (`/opt/alt/phpNN`) of 8.2–8.5 within their branch, the same way as `--main`. `LIST` limits it (`--selector=8.2,8.3`). |
| `--build-only`        | Skip GUI scaffolding deploy. Use for repeat builds. |
| `--force-conf`        | Overwrite existing `/usr/local/cwp/.conf/php-fpm_conf/php{NN}*.conf` (EL8 only). |
| `--refresh-ioncube`   | Post-CWP-rebuild recovery (libzip + ioncube + versions.ini merge + restart all custom php-fpm). **Also re-asserts the big-upload limit** (CWP rebuilds reset it to 64 MB) — honors `--big-upload` / `BH_BIG_UPLOAD_MB` (default 2048, `0` to skip). Run after ANY CWP UI rebuild. |
| `--fix-dnf`           | Run only the curl-trap repair and exit. |
| `--disable-ext=LIST`  | Comma-list of extensions to disable post-build (`.ini` renamed to `.ini.disabled`, `.so` kept). Default: `mongodb,sourceguardian` — both emit noisy deprecation/version warnings every CLI invocation. An extension the previous install had enabled stays enabled. Pass `--disable-ext=` (empty) to keep everything enabled. |
| `--big-upload=SIZE_MB`| After build, runs CWP's `/scripts/php_big_file_upload SIZE_MB all` — bumps `upload_max_filesize`, `post_max_size`, `memory_limit` (PHP) + `client_max_body_size` (Nginx) + `LimitRequestBody` (Apache) across **all** PHP versions on the box. Default: `2048` (2 GB) — high but matches BiswasHost filemanager use. Pass `--big-upload=0` to skip. |
| `--clean-shadow-libs` | ⚠️ **Advanced — opt-in only**. Quarantines shadow libs (`/usr/local/lib*/`) and a narrow allowlist of non-PHP binaries (`/usr/local/bin/curl`, `pcre2grep`, `zipcmp`, etc.) to `/root/cwp-php-backups/stale-libs/`. **Skips** `/usr/local/bin/{php,php-cgi,phpdbg,lsphp}` because those are CWP system PHP binaries (use CWP's PHP Version Switcher UI to rebuild them, not this flag). Default is warn-only — recommended unless you have a specific known conflict. |
| `--system-php=X.Y`    | ⚠️ **Advanced — opt-in only**. After build, symlink `/usr/local/bin/{php,php-cgi,phpdbg,php-config,phpize}` → `/opt/alt/php-fpmXY/usr/bin/`. Bypasses CWP's "PHP Version Switcher" UI — the dashboard will show whatever the symlink resolves to. Replaces the manual `ln -sfn` ritual. Example: `--system-php=8.3`. |
| `-h`, `--help`        | Help. |

## Environment overrides

| Variable             | Effect |
|----------------------|--------|
| `BH_SKIP_IONCUBE=1`  | Don't auto-refresh ioncube at end of `--php` flow. |
| `BH_BIG_UPLOAD_MB`   | Default size (MB) for `/scripts/php_big_file_upload`. Default `2048`. Set `0` to skip. |
| `BH_REPO_URL`        | Override the curl\|bash clone source (defaults to this repo). |
| `BH_REPO_BRANCH`     | Branch for curl\|bash mode (default `main`). |
| `BH_ALLOW_EXTERNAL_PCRE=1` | Build even though the existing EL8 `php{NN}.conf` has `--with-external-pcre` (links the system PCRE2 10.32). Default: refuse; the fix is `--force-conf`. |
| `BH_MAIN_FORCE=1`    | With `--main`: rebuild the main PHP even when it already runs the target version. |
| `BH_KEEP_ROLLBACKS`  | How many of the newest backup snapshots keep the whole previous install (`rollback/`, ~150-250 MB per PHP version). Default `2`. |

## EL8 vs EL9 (auto-detected)

| Concern                | EL8                              | EL9                          |
|------------------------|----------------------------------|------------------------------|
| Curl during PHP build  | Isolated `/opt/curl-8.7.1/`      | System curl (already 8.x)    |
| PIE flags              | Added                            | Not needed                   |
| OpenSSL                | 1.1.1k + env-wired               | 3.x native                   |
| Selector path          | `.../el8/php-fpm_selector/`      | `.../el9/php-fpm_selector/`  |
| Seeded `php-fpm_conf`  | Yes (fixes mbstring)             | Skipped (CWP generates)      |
| Build-deps install     | Looped (libavif may be absent)   | Single `dnf install`         |
| `8.4.ini` pcre option  | (default)                        | `--with-external-pcre`       |
| Building 8.3/8.4/8.5   | All supported                    | All supported                |

## Backups

Every run creates `/root/cwp-php-backups/<YYYYMMDD-HHMMSS>/` with:
- Previous versions of overwritten scaffolding files
- Stashed `/opt/alt/php-fpmNN/usr/etc/php-fpm.d/users/*.conf` before rebuild
- Previous `/usr/local/ioncube/` if it was refreshed
- Renamed `curl-local.conf.disabled.<stamp>` if the trap was triggered
- `rollback/php-fpmNN/` — the **whole previous install** (its `php.ini`, `php.d/`, extensions), moved out of `/opt/alt` at the end of a successful run and named in the final summary. A failed run leaves it at `/opt/alt/php-fpmNN.rollback.<stamp>` and says so on exit.
- Every `php.d/*.ini` the installer edited or removed (static-module loaders)
- `main-php/` (with `--main`) — `main-php-<old version>.tgz` of everything the main-PHP install replaced (restore: `tar -xzf <file> -C /`), plus the module / setting / site-status snapshots taken before and after

Safe to delete after a successful build.

## Layout

```
cwp-custom-php/
├── install.sh                                    # single entry point
├── lib/
│   ├── helpers.sh                                # logging, version compare, backup, version resolver
│   ├── preflight.sh                              # OS/CWP/arch checks, ca-cert, curl-trap fix, EL8/EL9 detect
│   ├── deploy-gui.sh                             # versions.ini, N.ini, external_modules/, pre_run/
│   ├── deploy-conf.sh                            # /usr/local/cwp/.conf/php-fpm_conf/ seeding (EL8 only)
│   ├── build-php.sh                              # unified builder with EL-aware profiles
│   ├── carry-config.sh                           # carries php.ini values + php.d/*.ini across a rebuild
│   ├── main-php.sh                               # --main / --selector: upgrade CWP's suPHP builds (/usr/local, /opt/alt/phpNN)
│   ├── ioncube.sh                                # refresh loaders + stale-check + auto-heal
│   └── postcheck.sh                              # verification table
├── selector/
│   ├── versions.ini
│   ├── 8.3.el8.ini  8.3.el9.ini
│   ├── 8.4.el8.ini  8.4.el9.ini
│   ├── 8.5.el8.ini  8.5.el9.ini
│   ├── external_modules/{8.3,8.4,8.5}/*.sh       # identical EL8/EL9
│   ├── pre_run/{8.3,8.4,8.5}/*.sh                # identical
│   └── php-fpm_conf/php{83,84,85}{,_pre,_external}.conf  # EL8 only
└── README.md
```

## Troubleshooting

**`cURL error 60: SSL certificate problem`** — `dnf reinstall -y ca-certificates && update-ca-trust force-enable && update-ca-trust extract`. If dnf itself is broken: `bash install.sh --fix-dnf`.

**`mbstring` not loaded after build (EL8)** — your old `/usr/local/cwp/.conf/php-fpm_conf/php{NN}.conf` is probably missing `--enable-mbstring`. Re-run with `--force-conf` and the repo's known-good config replaces it.

**ioncube missing after CWP rebuild** — `bash install.sh --refresh-ioncube`. This is the canonical fix.

**Build seems to hang** — that's normal. `make -j$(nproc)` on PHP source takes 5-15 minutes depending on CPU.

## Changelog

### 2026-10-22 — `--selector`: upgrade CWP's PHP Selector builds too
A follow-up audit found a third PHP family the CVE rollout had missed: CWP's PHP Selector CGI builds in `/opt/alt/phpNN`, chosen per site in `.htaccess` (8.2.28–8.2.31 and 8.3.21–8.3.31 across five servers). `--selector` upgrades them with the same routine as `--main` (`lib/main-php.sh` now handles both): the running build's configure options, sha256-checked php.net source, whole-tree backup, verification and automatic rollback, before/after site check.

### 2026-10-22 — `--main`: upgrade CWP's main (suPHP / CLI) PHP too
The CVE-2026-109618/109619 rollout patched every PHP-FPM build, but most sites on a CWP box run on the main PHP, which CWP's switcher could only move to CWP's own (unpatched) packages. `--main` rebuilds it from php.net source with the running build's own configure options, keeps `php.ini`/`php.d`/extensions, verifies modules, settings and startup, checks every site before and after, and rolls back on any difference. Used on six production servers (8.3.31 → 8.3.36, 8.2.31 → 8.2.35) with every site answering exactly as before.

### 2026-10-21 — a rebuild never loses the existing configuration
Rebuilding the fleet to the CVE-2026-109618/109619 releases (8.2.35 / 8.3.36 / 8.4.27 / 8.5.12) showed every atomic swap installing a **stock `php.ini` and an empty `php.d/`**: `disabled_function.ini` (`disable_functions = exec, system, …`), `zz-opcache-tuned.ini`, `zz-bh-cve-2026-109619.ini` and the CWP big-upload values were silently dropped, and a site broke on `memory_limit = 128M`.
- **php.ini carry-over** — every key whose value in the previous install differs from the new stock file (`memory_limit`, `upload_max_filesize`, `post_max_size`, `max_input_time`, `max_execution_time`, `disable_functions`, `max_input_vars`, …) is written into the new `php.ini` before the first start, and each one is logged. `[PATH=]`/`[HOST=]` sections are copied verbatim to the end of the file. `extension=`/`zend_extension=` lines from the old `php.ini` go to `php.d/00-carried-from-php-ini.ini` once the external modules are built, if the new build has that module and does not already load it.
- **php.d carry-over** — every settings-only `php.d/*.ini` (no `extension=` line) is copied before the first start. After the external modules are built, old loader files the new build did not recreate are copied when their `.so` exists for the new build; a missing `.so` is reported loudly instead of dropped. When the new build recreated a file under the same name (e.g. `imagick.ini`, `opcache.ini`), the old file's extra settings are appended to it, so the old values win. An old `<ext>.ini.disabled` keeps `<ext>` disabled.
- **Rollback really runs** — a failed `systemctl start` after the swap no longer ends the run under `set -e` before the automatic rollback (this bug was there before this change).
- **No `.ini` for compiled-in modules** — loaders for modules `php -n -m` already lists (8.3's `mbstring`, built-in `opcache`) are commented out, or the file removed if nothing else is left in it (backed up first). The repo's `8.3/mbstring.sh` now does nothing when mbstring is built in.
- **`--with-external-pcre` gate (EL8)** — an existing `php{NN}.conf` with that flag (links the system PCRE2 10.32) now stops the run before anything is built. Fix with `--force-conf`; override with `BH_ALLOW_EXTERNAL_PCRE=1`.
- **Downloads fail closed** — every `curl` in `external_modules/` is `curl -fsSL --retry 3`, every `wget` has `--tries=3`, and a failed download stops that module with `ERROR: download failed: <url>` instead of untarring an HTML error page.
- **Rollback kept** — the previous install stays at `/opt/alt/php-fpmNN.rollback.<stamp>` until the whole run succeeds, then moves to `/root/cwp-php-backups/<stamp>/rollback/` (out of `/opt/alt`, so CWP's PHP Selector keeps working) and is named in the final summary.

## Source

Original manual guide: https://www.alphagnu.com/topic/614-how-to-add-custom-php-fpm-84-85-support-to-cwp-on-almalinux-9x/

## Sibling repos

- **[bh-server-ops](https://github.com/wpexpertinbd/bh-server-ops)** — performance bootstrap, FPM/MPM tuning, monitoring, anti-bot WAF for CWP/Linux web stacks
