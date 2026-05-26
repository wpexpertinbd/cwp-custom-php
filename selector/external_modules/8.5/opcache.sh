#!/bin/bash
set -euo pipefail

echo ""
echo "=== opcache.sh ==="

# ---- Detect target PHP version ----
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "No php-fpm84 or php-fpm85 found. Skipping."
    exit 0
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPINIDIR="${PHPFPM}/usr/php/php.d"

PHPEXTDIR="$($PHPCONFIG --extension-dir)"
OPCACHEINI="${PHPINIDIR}/opcache.ini"

echo "Using PHP from: ${PHPFPM}"
echo "Extension dir: ${PHPEXTDIR}"

# ---- Check opcache.so ----
if [ ! -f "${PHPEXTDIR}/opcache.so" ]; then
    echo "ERROR: Missing ${PHPEXTDIR}/opcache.so"
    exit 0
fi

echo "Creating opcache.ini..."

# ---- Recreate opcache.ini cleanly ----
rm -f "${OPCACHEINI}"
touch "${OPCACHEINI}"

# ---- Write recommended modern settings ----
cat > "${OPCACHEINI}" <<EOF
zend_extension=${PHPEXTDIR}/opcache.so

; --- OPcache Recommended Settings (PHP 8.2+) ---
opcache.enable=1
opcache.enable_cli=1

opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000

; file revalidation every 60s
opcache.revalidate_freq=60

; enable fast opcache restart
opcache.fast_shutdown=1

; huge_pages OFF (EL9 kernel defaults, safer)
opcache.huge_code_pages=0

; Preloading is off by default (Joomla/WordPress safe)
opcache.preload=

; Allow file overrides
opcache.validate_timestamps=1
EOF

echo "opcache.ini created successfully."
exit 0
