#!/bin/bash
set -euo pipefail

echo ""
echo "=== sourceguardian.sh ==="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
    SG_PHPVER="8.4"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
    SG_PHPVER="8.5"
else
    echo "No PHP-FPM 8.4 or 8.5 found — skipping SourceGuardian."
    exit 0
fi

echo "Detected PHP-FPM: ${PHPFPM} (PHP ${SG_PHPVER})"

# Target directories
SG_DIR="/usr/local/sourceguardian"
INI_FILE="${PHPFPM}/usr/php/php.d/sourceguardian.ini"

# --- Clean old SG loaders for safety ---
rm -rf "${SG_DIR}"
mkdir -p "${SG_DIR}"

# --- Download SourceGuardian loaderek ---
echo "Downloading SourceGuardian loaders..."

cd /usr/local
wget -U 'Mozilla/5.0' \
  https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.zip \
  -O sourceguardian_loaders.zip

unzip -o sourceguardian_loaders.zip -d "${SG_DIR}" >/dev/null 2>&1

# --- Detect correct loader file ---
LOADER_FILE="${SG_DIR}/ixed.${SG_PHPVER}.lin"

if [ ! -f "${LOADER_FILE}" ]; then
    echo "ERROR: Loader file missing: ${LOADER_FILE}"
    echo "Available loaders:"
    ls -1 ${SG_DIR}/ixed* || true
    exit 1
fi

echo "Found loader: ${LOADER_FILE}"

# --- Write INI file ---
rm -f "${INI_FILE}"
echo "zend_extension=${LOADER_FILE}" > "${INI_FILE}"

echo "SourceGuardian loader configured:"
echo "  ${INI_FILE}"
echo "  → zend_extension=${LOADER_FILE}"

echo "Done."
exit 0
