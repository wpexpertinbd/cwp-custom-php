#!/bin/bash
set -euo pipefail

echo ""
echo "=== sodium.sh ==="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "No php-fpm84 or php-fpm85 found – skipping sodium."
    exit 0
fi

PHPINIDIR="${PHPFPM}/usr/php/php.d"
SODIUMINI="${PHPINIDIR}/sodium.ini"

echo "PHP-FPM detected: ${PHPFPM}"

# --- libsodium system package (EL9 built-in) ---
dnf -y install libsodium libsodium-devel || true

# --- PHP 8.x FIGYELEM: sodium.so nem létezik külön extensionként ---
PHPBIN="${PHPFPM}/usr/bin/php"
HAS_SODIUM_BUILTIN=$(${PHPBIN} -r "echo function_exists('sodium_crypto_secretbox') ? 1 : 0;")

if [ "$HAS_SODIUM_BUILTIN" = "1" ]; then
    echo "Sodium already built into PHP core — no external module needed."

    # CWP GUI compatibility: create a dummy ini so selector does not complain
    rm -f "${SODIUMINI}"
    echo "; Sodium is built into PHP 8.x core — no extension needed" > "${SODIUMINI}"

    exit 0
fi

# --- If core sodium missing (extremely unlikely on PHP 8.x), fallback to PECL ---
echo "WARNING: PHP sodium extension missing — attempting PECL build."

cd /usr/local/src
rm -rf libsodium-* libsodium.tgz

curl -L https://pecl.php.net/get/libsodium -o libsodium.tgz
tar zxf libsodium.tgz
cd libsodium-*/

${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPFPM}/usr/bin/php-config"
make -j"$(nproc)"
make install

PHPEXTDIR="$(${PHPFPM}/usr/bin/php-config --extension-dir)"

if [ -f "${PHPEXTDIR}/sodium.so" ]; then
    echo "Creating sodium.ini"
    echo "extension=sodium.so" > "${SODIUMINI}"
else
    echo "ERROR: sodium.so missing from ${PHPEXTDIR}"
fi

exit 0
