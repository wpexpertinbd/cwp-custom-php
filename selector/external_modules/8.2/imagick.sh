#!/bin/bash
set -euo pipefail

echo ""
echo "=== imagick.sh (git source — works for PHP 8.2 / 8.3 / 8.4 / 8.5) ==="

# ---------------------------------------------------------
# REAL script path even when CWP copies to a temp location
# ---------------------------------------------------------
SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

if   [[ "$SCRIPT_REAL_PATH" == *"/8.2/"* ]]; then PHPFPM="/opt/alt/php-fpm82"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.3/"* ]]; then PHPFPM="/opt/alt/php-fpm83"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.4/"* ]]; then PHPFPM="/opt/alt/php-fpm84"
elif [[ "$SCRIPT_REAL_PATH" == *"/8.5/"* ]]; then PHPFPM="/opt/alt/php-fpm85"
else
    echo "ERROR: imagick.sh not inside 8.2 / 8.3 / 8.4 / 8.5 external_modules folder."
    echo "Real path: $SCRIPT_REAL_PATH"
    exit 1
fi

PHPCONFIG="${PHPFPM}/usr/bin/php-config"
PHPIZE="${PHPFPM}/usr/bin/phpize"
PHPINIDIR="${PHPFPM}/usr/php/php.d"

if [ ! -x "$PHPCONFIG" ]; then
    echo "Skipping Imagick: php-config not found ($PHPCONFIG)"
    exit 0
fi

PHPEXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Detected PHP: $PHPFPM"
echo "Extension dir: $PHPEXTDIR"

# ---------------------------------------------------------
# Install ImageMagick dev headers (PECL build target)
# ---------------------------------------------------------
echo "Installing prerequisites..."
dnf -y install ImageMagick ImageMagick-devel ImageMagick-perl pkgconfig gcc make autoconf || true

# ---------------------------------------------------------
# Build from git (PECL pin 3.7.2 is 404 — git always works)
# ---------------------------------------------------------
cd /usr/local/src
rm -rf imagick imagick-build imagick-*.tgz 2>/dev/null || true

echo "Cloning Imagick/imagick from GitHub..."
git clone --depth 1 https://github.com/Imagick/imagick.git imagick-build
cd imagick-build

echo "phpize..."
${PHPIZE}

echo "Configuring..."
./configure --with-php-config="${PHPCONFIG}"

echo "Compiling..."
make -j"$(nproc)"
make install

# ---------------------------------------------------------
# Enable
# ---------------------------------------------------------
if [ ! -f "${PHPEXTDIR}/imagick.so" ]; then
    echo "ERROR: imagick.so was NOT built (${PHPEXTDIR}/imagick.so)"
    exit 1
fi

echo "extension=imagick.so" > "${PHPINIDIR}/imagick.ini"

echo ""
echo "=========================================="
echo " Imagick installed successfully for $PHPFPM"
echo "=========================================="
exit 0
