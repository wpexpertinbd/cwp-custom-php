#!/bin/bash

# Automated PHP FPM prefix recognition
PHPFPM="/opt/alt/php-fpm84"
if [ ! -e "${PHPFPM}/usr/bin/php-config" ]; then
    # If not 8.4, then 8.5
    PHPFPM="/opt/alt/php-fpm85"
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPINI_DIR="${PHPFPM}/usr/php/php.d"

if [ ! -x "${PHPCONFIG}" ]; then
    echo "Skipping: PHP build missing (${PHPCONFIG})"
    exit 0
fi

cd /usr/local/src
rm -rf apcu-*

echo "Downloading APCu 5.1.27..."
wget --tries=3 https://pecl.php.net/get/apcu-5.1.27.tgz -O apcu.tgz || { echo "ERROR: download failed: https://pecl.php.net/get/apcu-5.1.27.tgz"; exit 1; }

tar -xf apcu.tgz
cd apcu-5.1.27

${PHPFPM}/usr/bin/phpize
./configure --with-php-config=${PHPCONFIG}
make -j"$(nproc)" && make install

PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

if [ -e "${PHPEXTDIR}/apcu.so" ]; then
    echo "Creating apcu.ini"
    echo "extension=apcu.so" > "${PHPINI_DIR}/apcu.ini"
else
    echo "ERROR: Missing APCu extension file → ${PHPEXTDIR}/apcu.so"
fi
