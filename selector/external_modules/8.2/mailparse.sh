#!/bin/bash
set -euo pipefail

# --- Detect PHP-FPM version (8.2 or 8.5) ---
if [ -x /opt/alt/php-fpm82/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm82"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: No php-fpm82 or php-fpm85 found."
    exit 1
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPINIDIR="${PHPFPM}/usr/php/php.d"

echo "Detected PHP: ${PHPBIN}"

# --- Install dependencies ---
dnf -y install re2c file

cd /usr/local/src
rm -rf mailparse* mailparse.tgz

# --- Stable version: mailparse 3.1.6 ---
MAILPARSE_VERSION="3.1.6"
MAILPARSE_URL="https://pecl.php.net/get/mailparse-${MAILPARSE_VERSION}.tgz"

echo "Downloading mailparse ${MAILPARSE_VERSION}..."
wget -q "${MAILPARSE_URL}" -O mailparse.tgz

tar -xf mailparse.tgz
cd "mailparse-${MAILPARSE_VERSION}"

# --- Build ---
echo "Running phpize..."
"${PHPFPM}/usr/bin/phpize"

echo "Configuring..."
./configure --with-php-config="${PHPCONFIG}"

echo "Compiling..."
make -j"$(nproc)"
make install

# --- Check extension installation ---
EXTDIR="$(${PHPCONFIG} --extension-dir)"

if [ -f "${EXTDIR}/mailparse.so" ]; then
    echo "Creating mailparse.ini"
    echo "extension=mailparse.so" > "${PHPINIDIR}/mailparse.ini"
    echo "mailparse installed successfully."
else
    echo "ERROR: mailparse.so was not found in ${EXTDIR}"
    exit 1
fi
