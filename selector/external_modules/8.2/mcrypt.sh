#!/bin/bash
set -euo pipefail

echo ""
echo "=== mcrypt.sh ==="
echo "MCRYPT extension is deprecated and removed from PHP 8.2 and above."
echo "Skipping mcrypt installation."

# Detect PHP version
if [ -x /opt/alt/php-fpm82/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm82"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
    PHPFPM="/opt/alt/php-fpm85"
else
    echo "No compatible php-fpm (84/85) found. Exiting."
    exit 0
fi

PHPINIDIR="${PHPFPM}/usr/php/php.d"

# Remove old/broken INI if exists
if [ -f "${PHPINIDIR}/mcrypt.ini" ]; then
    echo "Removing existing mcrypt.ini (not supported on PHP 8.2+)"
    rm -f "${PHPINIDIR}/mcrypt.ini"
fi

echo "Mcrypt skipped successfully."
exit 0
