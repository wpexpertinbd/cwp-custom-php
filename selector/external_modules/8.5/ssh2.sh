#!/bin/bash
set -euo pipefail

echo ""
echo "===== Building ssh2 extension ====="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPMAJOR="84"
    PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPMAJOR="85"
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: Neither PHP 8.4 nor 8.5 environment found. Exiting."
    exit 0
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP-FPM ${PHPMAJOR} at: ${PHPFPM}"
echo "Extension dir: ${PHPEXTDIR}"

cd /usr/local/src

# --- libssh2 latest ---
LIBSSH2_VER="1.11.0"

rm -rf libssh2-* libssh2.tar.gz
curl -L "https://www.libssh2.org/download/libssh2-${LIBSSH2_VER}.tar.gz" -o libssh2.tar.gz
tar -xzf libssh2.tar.gz
cd "libssh2-${LIBSSH2_VER}"

./configure --with-openssl
make -j"$(nproc)"
make install

ldconfig || true   # updating linker cache

cd /usr/local/src

# --- ssh2 PECL extension ---
rm -rf ssh2-* ssh2.tgz
curl -L "https://pecl.php.net/get/ssh2" -o ssh2.tgz
tar -xzf ssh2.tgz
cd ssh2-*

${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install

# --- creating ini ---
INI_FILE="${PHPFPM}/usr/php/php.d/ssh2.ini"

if [ -f "${PHPEXTDIR}/ssh2.so" ]; then
    echo "extension=ssh2.so" > "${INI_FILE}"
    echo "ssh2.so successfully installed."
else
    echo "ERROR: ssh2.so missing — build failed."
    exit 1
fi

echo "SSH2 extension installed successfully for PHP ${PHPMAJOR}"
echo "=============================================="
