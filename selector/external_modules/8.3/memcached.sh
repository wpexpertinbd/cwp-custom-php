#!/bin/bash
set -euo pipefail

echo ""
echo "=== memcached.sh (CWP-safe auto PHP detection) ==="

# ---------------------------------------------------------
# REAL script path even when executed from temp (/tmp)
# ---------------------------------------------------------
SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

if   [[ "$SCRIPT_REAL_PATH" == *"/8.2/"* ]]; then PHPFPM="/opt/alt/php-fpm82"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.3/"* ]]; then PHPFPM="/opt/alt/php-fpm83"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.4/"* ]]; then PHPFPM="/opt/alt/php-fpm84"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.5/"* ]]; then PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: Script not inside 8.2 / 8.3 / 8.4 / 8.5 external_modules folder."
    echo "Real path: $SCRIPT_REAL_PATH"
    exit 1
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPIZE="${PHPFPM}/usr/bin/phpize"
PHPINIDIR="${PHPFPM}/usr/php/php.d"
PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP via folder: $PHPFPM"
echo "Extension dir: $PHPEXTDIR"

# ---------------------------------------------------------
# Dependencies
# ---------------------------------------------------------
dnf -y install \
    memcached \
    libevent \
    libevent-devel \
    zlib-devel \
    openssl-devel \
    cyrus-sasl-devel \
    libmemcached \
    libmemcached-devel \
    || true

systemctl enable memcached --now || true

# ---------------------------------------------------------
# Build php-memcached (GitHub)
# ---------------------------------------------------------
cd /usr/local/src
rm -rf php-memcached || true

git clone https://github.com/php-memcached-dev/php-memcached.git
cd php-memcached

${PHPIZE}

./configure --with-php-config="${PHPCONFIG}" --disable-memcached-sasl
make -j"$(nproc)"
make install

# ---------------------------------------------------------
# Enable extension
# ---------------------------------------------------------
if [ ! -f "${PHPEXTDIR}/memcached.so" ]; then
    echo "ERROR: memcached.so missing from: ${PHPEXTDIR}"
    exit 1
fi

echo "extension=memcached.so" > "${PHPINIDIR}/memcached.ini"

echo ""
echo "==========================================="
echo " memcached installed successfully for $PHPFPM"
echo "==========================================="
exit 0
