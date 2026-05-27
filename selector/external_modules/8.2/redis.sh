#!/bin/bash
set -euo pipefail

echo ""
echo "=== redis.sh (Auto-detect PHP 8.2 / 8.5, GitHub source) ==="

# ---------------------------------------------------------
# REAL script path (CWP copies to temp folder)
# ---------------------------------------------------------
SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ "$SCRIPT_REAL_PATH" == *"/8.2/"* ]]; then
    PHPFPM="/opt/alt/php-fpm82"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.5/"* ]]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: Script is not inside 8.2 or 8.5 external_modules folder."
    echo "Real path: ${SCRIPT_REAL_PATH}"
    exit 1
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPIZE="${PHPFPM}/usr/bin/phpize"
PHPINIDIR="${PHPFPM}/usr/php/php.d"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP from folder: $PHPFPM"
echo "Extension dir: $PHPEXTDIR"

# ---------------------------------------------------------
# Install redis server (optional)
# ---------------------------------------------------------
dnf -y install redis || true
systemctl enable redis --now || true

# ---------------------------------------------------------
# Build redis extension from GitHub (latest PHP 8.5 compatible)
# ---------------------------------------------------------
cd /usr/local/src
rm -rf phpredis redis* || true

echo "Cloning phpredis from GitHub..."
git clone https://github.com/phpredis/phpredis.git
cd phpredis

echo "Running phpize..."
${PHPIZE}

echo "Configuring redis extension..."
./configure --with-php-config="${PHPCONFIG}"

echo "Compiling redis extension..."
make -j"$(nproc)"
make install

# ---------------------------------------------------------
# Validation
# ---------------------------------------------------------
if [ ! -f "${PHPEXTDIR}/redis.so" ]; then
    echo "ERROR: redis.so was NOT built!"
    exit 1
fi

# ---------------------------------------------------------
# Enable extension
# ---------------------------------------------------------
REDISINI="${PHPINIDIR}/redis.ini"

echo "Creating redis.ini..."
echo "extension=redis.so" > "${REDISINI}"

echo ""
echo "=========================================="
echo " Redis extension installed successfully for"
echo " PHP: ${PHPFPM}"
echo "=========================================="
exit 0
