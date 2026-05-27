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
# SSH to target server as root, then ONE of these:
```

### Build the latest 8.4

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4
```

### Pin a specific version

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4=8.4.21
```

### Build all three at once

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.3,8.4,8.5
```

### Resolve latest at runtime (queries php.net)

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.3=latest,8.4=latest,8.5=latest
```

### Update an existing custom PHP to a newer point release

Same command — the script is idempotent. It will stop the old service, preserve user pool configs, rebuild, restore pools, restart.

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --php 8.4=8.4.22
```

## Pick the command that matches your situation

### Just rebuilt PHP from CWP GUI → ioncube broke?

CWP's own PHP rebuild (and `sh /scripts/update_cwp`) overwrites `/usr/local/ioncube/` with the stale bundled tarball. Loaders for 8.4/8.5 disappear. Fix:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/cwp-custom-php/main/install.sh \
  | bash -s -- --refresh-ioncube
```

This downloads fresh loaders from ioncube.com, fixes perms, re-wires every `/opt/alt/php-fpmNN`, restarts services, runs `/scripts/update_cwp` if present. Safe to run anytime.

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
| `--build-only`        | Skip GUI scaffolding deploy. Use for repeat builds. |
| `--force-conf`        | Overwrite existing `/usr/local/cwp/.conf/php-fpm_conf/php{NN}*.conf` (EL8 only). |
| `--refresh-ioncube`   | Run only the ioncube refresh and exit. |
| `--fix-dnf`           | Run only the curl-trap repair and exit. |
| `--disable-ext=LIST`  | Comma-list of extensions to disable post-build (`.ini` renamed to `.ini.disabled`, `.so` kept). Default: `mongodb,sourceguardian` — both emit noisy deprecation/version warnings every CLI invocation. Pass `--disable-ext=` (empty) to keep everything enabled. |
| `--big-upload=SIZE_MB`| After build, runs CWP's `/scripts/php_big_file_upload SIZE_MB all` — bumps `upload_max_filesize`, `post_max_size`, `memory_limit` (PHP) + `client_max_body_size` (Nginx) + `LimitRequestBody` (Apache) across **all** PHP versions on the box. Default: `2048` (2 GB) — high but matches BiswasHost filemanager use. Pass `--big-upload=0` to skip. |
| `--clean-shadow-libs` | When preflight detects shadow libs/binaries in `/usr/local/lib*/` or `/usr/local/bin/`, auto-quarantine them to `/root/cwp-php-backups/stale-libs/`. Default is **warn-only**. Use this on your fleet after you've confirmed the pattern is safe (saves a manual cleanup step per server). |
| `-h`, `--help`        | Help. |

## Environment overrides

| Variable             | Effect |
|----------------------|--------|
| `BH_SKIP_IONCUBE=1`  | Don't auto-refresh ioncube at end of `--php` flow. |
| `BH_BIG_UPLOAD_MB`   | Default size (MB) for `/scripts/php_big_file_upload`. Default `2048`. Set `0` to skip. |
| `BH_REPO_URL`        | Override the curl\|bash clone source (defaults to this repo). |
| `BH_REPO_BRANCH`     | Branch for curl\|bash mode (default `main`). |

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

## Source

Original manual guide: https://www.alphagnu.com/topic/614-how-to-add-custom-php-fpm-84-85-support-to-cwp-on-almalinux-9x/

## Sibling repos

- **[bh-server-ops](https://github.com/wpexpertinbd/bh-server-ops)** — performance bootstrap, FPM/MPM tuning, monitoring, anti-bot WAF for CWP/Linux web stacks
