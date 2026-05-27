#!/bin/bash
set -euo pipefail

echo ""
echo "===== Building Xdebug extension ====="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm82/usr/bin/php-config ]; then
    PHPMAJOR="84"
    PHPFPM="/opt/alt/php-fpm82"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPMAJOR="85"
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: Neither PHP 8.2 nor 8.5 found. Exiting."
    exit 0
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP-FPM ${PHPMAJOR}"
echo "Extension dir: ${PHPEXTDIR}"

cd /usr/local/src

# --- Cleaning ---
rm -rf xdebug* xdebug.tgz

# --- Getting the latest Xdebug ---
curl -L https://pecl.php.net/get/xdebug -o xdebug.tgz
tar zxf xdebug.tgz
cd xdebug-*

# --- Build ---
${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install

# --- Creating INI file ---
INI_FILE="${PHPFPM}/usr/php/php.d/xdebug.ini"

if [ -f "${PHPEXTDIR}/xdebug.so" ]; then
    cat > "${INI_FILE}" <<EOF
zend_extension=${PHPEXTDIR}/xdebug.so

[xdebug]
xdebug.mode=develop,debug
xdebug.start_with_request=yes
xdebug.client_port=9003
xdebug.log_level=7
EOF

    echo "Xdebug successfully installed for PHP ${PHPMAJOR}"
else
    echo "ERROR: xdebug.so missing — build failed."
    exit 1
fi

echo "=============================================="
