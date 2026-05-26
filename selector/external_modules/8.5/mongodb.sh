#!/bin/bash
set -euo pipefail

echo ""
echo "=== mongodb.sh ==="

# ---- Detect target PHP version (84 or 85) ----
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "No php-fpm84 or php-fpm85 found. Skipping."
    exit 0
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPIZE="${PHPFPM}/usr/bin/phpize"
PHPINIDIR="${PHPFPM}/usr/php/php.d"

echo "Using PHP from: ${PHPFPM}"

# ---- Required system libs ----
dnf -y install openssl-devel || true

# ---- Prepare sources ----
cd /usr/local/src
rm -rf mongodb* || true

echo "Downloading latest MongoDB driver from PECL..."
curl -L https://pecl.php.net/get/mongodb -o mongodb.tgz

tar -xzf mongodb.tgz
cd mongodb-*/

# ---- Build ----
echo "Running phpize..."
$PHPIZE

echo "Configuring MongoDB extension..."
./configure --with-php-config="$PHPCONFIG"

echo "Compiling..."
make -j"$(nproc)"
make install

# ---- Extension dir detection ----
PHPEXTDIR="$($PHPCONFIG --extension-dir)"

# ---- Check if .so exists ----
if [ ! -e "$PHPEXTDIR/mongodb.so" ]; then
    echo "ERROR: mongodb.so not found in $PHPEXTDIR"
    exit 0
fi

# ---- Create INI ----
echo "Enabling mongodb extension..."
rm -f "${PHPINIDIR}/mongodb.ini" 2>/dev/null || true
echo "extension=mongodb.so" > "${PHPINIDIR}/mongodb.ini"

echo "MongoDB extension installation complete."
exit 0
