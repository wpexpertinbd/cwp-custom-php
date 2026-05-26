#!/bin/bash
set -euo pipefail

echo ""
echo "===== Building uploadprogress extension ====="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPMAJOR="84"
    PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPMAJOR="85"
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: No PHP 8.4 or 8.5 installation found. Exiting."
    exit 0
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP-FPM ${PHPMAJOR} at: ${PHPFPM}"
echo "Extension dir: ${PHPEXTDIR}"

cd /usr/local/src

# --- uploadprogress PECL extension ---
rm -rf uploadprogress* uploadprogress.tgz

curl -L "https://pecl.php.net/get/uploadprogress" -o uploadprogress.tgz
tar -xf uploadprogress.tgz
cd uploadprogress-*

${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install

# --- creating ini ---
INI_FILE="${PHPFPM}/usr/php/php.d/uploadprogress.ini"

if [ -f "${PHPEXTDIR}/uploadprogress.so" ]; then
    echo "extension=uploadprogress.so" > "${INI_FILE}"
    echo "uploadprogress.so successfully installed."
else
    echo "ERROR: uploadprogress.so missing — build failed."
    exit 1
fi

echo "Uploadprogress extension installed successfully for PHP ${PHPMAJOR}"
echo "=============================================="
