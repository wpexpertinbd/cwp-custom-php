#!/bin/bash
set -euo pipefail

echo ""
echo "=== memcache.sh (patched for PHP 8.4 & 8.5) ==="

# -------------------------------------------------------
# Detect PHP-FPM (84 or 85)
# -------------------------------------------------------
if [[ "$0" =~ "8.4" ]] && [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
elif [[ "$0" =~ "8.5" ]] && [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
elif [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm84"
else
    echo "ERROR: No php-fpm84 or php-fpm85 found."
    exit 0
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPIZE="${PHPFPM}/usr/bin/phpize"
PHPINIDIR="${PHPFPM}/usr/php/php.d"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Using PHP: ${PHPFPM}"
echo "Extension dir: ${PHPEXTDIR}"

# -------------------------------------------------------
# Install deps
# -------------------------------------------------------
dnf -y install memcached libmemcached libmemcached-devel || true
systemctl enable memcached --now || true

# -------------------------------------------------------
# Build memcache (patched GitHub version)
# -------------------------------------------------------
cd /usr/local/src
rm -rf memcache* || true

echo "Downloading patched memcache extension..."
git clone https://github.com/websupport-sk/pecl-memcache.git memcache-src
cd memcache-src

echo "Running phpize..."
${PHPIZE}

echo "Configuring..."
./configure --with-php-config="${PHPCONFIG}"

echo "Compiling..."
make -j"$(nproc)"
make install

# -------------------------------------------------------
# Verify extension
# -------------------------------------------------------
if [ ! -f "${PHPEXTDIR}/memcache.so" ]; then
    echo "ERROR: memcache.so was NOT built."
    exit 1
fi

# -------------------------------------------------------
# Enable module
# -------------------------------------------------------
echo "Creating memcache.ini..."
echo "extension=memcache.so" > "${PHPINIDIR}/memcache.ini"

echo ""
echo "==========================================="
echo " memcache extension installed successfully"
echo "==========================================="
exit 0
