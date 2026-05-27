#!/bin/bash
# IonCube Loader installer for CWP alt-PHP
# Works for PHP 8.3, 8.2, 8.5
set -euo pipefail

# Detect PHP major
PHPMAJOR="${PHPMAJOR:-84}"    # it is 83 or 84 or 85
PHPVERSION="8.2"
FPMDIR="/opt/alt/php-fpm${PHPMAJOR}"
PHPBIN="${FPMDIR}/usr/bin/php"

echo "Detected PHP: ${PHPBIN}"

# Determine loader version
if [ "$PHPMAJOR" = "85" ]; then
    LOADER="ioncube_loader_lin_${PHPVERSION}.so"
    URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64_beta.tar.gz"
else
    LOADER="ioncube_loader_lin_${PHPVERSION}.so"
    URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
fi

echo "Downloading IonCube Loader: $LOADER"
echo "URL: $URL"

# Clean + target directory
rm -f ioncube.tar.gz
cd /usr/local
rm -rf ioncube
mkdir -p ioncube

wget -q "$URL" -O ioncube.tar.gz
tar -xf ioncube.tar.gz -C ioncube --strip-components=1
rm -f ioncube.tar.gz

if [ ! -f "/usr/local/ioncube/${LOADER}" ]; then
    echo "ERROR: Loader file not found: /usr/local/ioncube/${LOADER}"
    exit 1
fi

# Create .ini file
INI="${FPMDIR}/usr/php/php.d/ioncube.ini"
rm -f "$INI"
echo "zend_extension=/usr/local/ioncube/${LOADER}" > "$INI"

chmod 644 "$INI"

echo "IonCube Loader installed for PHP ${PHPMAJOR}."
echo "Loader path: /usr/local/ioncube/${LOADER}"
echo "INI: ${INI}"
