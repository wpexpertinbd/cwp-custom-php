#!/bin/bash

# Detect PHP FPM version
PHPFPM="/opt/alt/php-fpm84"
if [ ! -e "${PHPFPM}/usr/bin/php-config" ]; then
    PHPFPM="/opt/alt/php-fpm85"
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPINIDIR="${PHPFPM}/usr/php/php.d"

if [ ! -x "${PHPCONFIG}" ]; then
    echo "Skipping Imagick: php-config not found (${PHPCONFIG})"
    exit 0
fi

echo "Installing prerequisites..."
dnf -y install ImageMagick ImageMagick-devel ImageMagick-perl pkgconfig

cd /usr/local/src
rm -rf imagick-*

echo "Downloading imagick-3.7.2..."
wget https://pecl.php.net/get/imagick-3.7.2.tgz -O imagick.tgz

tar -xf imagick.tgz
cd imagick-3.7.2

echo "phpize..."
${PHPFPM}/usr/bin/phpize

echo "Configuring..."
./configure --with-php-config=${PHPCONFIG}

echo "Compiling..."
make -j"$(nproc)" && make install

EXTDIR="$(${PHPCONFIG} --extension-dir)"

if [ -e "${EXTDIR}/imagick.so" ]; then
    echo "Creating imagick.ini"
    echo "extension=imagick.so" > "${PHPINIDIR}/imagick.ini"
    echo "Imagick installation OK."
else
    echo "ERROR: imagick.so missing: ${EXTDIR}/imagick.so"
fi
