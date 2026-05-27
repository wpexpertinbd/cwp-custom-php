#!/bin/bash
set -euo pipefail

echo ""
echo "===== Building YAZ extension ====="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm82/usr/bin/php-config ]; then
    PHPMAJOR="84"
    PHPFPM="/opt/alt/php-fpm82"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPMAJOR="85"
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: Neither php-fpm82 nor php-fpm85 found. Skipping YAZ."
    exit 0
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP ${PHPMAJOR}"
echo "Extension dir: $PHPEXTDIR"

cd /usr/local/src

# --- Cleaning ---
rm -rf yaz* yaz.tar.gz yaz.tgz

# ---- Getting the latest YAZ library ----
# (Indexdata official repo)
curl -L https://ftp.indexdata.com/pub/yaz/yaz-5.34.0.tar.gz -o yaz.tar.gz || \
curl -L http://ftp.indexdata.dk/pub/yaz/yaz-5.34.0.tar.gz -o yaz.tar.gz

tar -zxvf yaz.tar.gz
cd yaz-*/
./configure
make -j"$(nproc)"
make install

ldconfig 2>/dev/null || true

cd /usr/local/src

# ---- Downloading PHP YAZ extension (PECL) ----
curl -L https://pecl.php.net/get/yaz -o yaz.tgz
tar -zxvf yaz.tgz
cd yaz-*/

${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install

# --- Creating INI file ---
INI_FILE="${PHPFPM}/usr/php/php.d/yaz.ini"

if [ -f "${PHPEXTDIR}/yaz.so" ]; then
    echo "extension=yaz.so" > "${INI_FILE}"
    echo "YAZ extension successfully installed for PHP ${PHPMAJOR}"
else
    echo "ERROR: yaz.so missing — build failed."
fi

echo "=============================================="
echo ""
