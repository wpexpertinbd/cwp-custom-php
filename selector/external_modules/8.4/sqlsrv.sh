#!/bin/bash
set -euo pipefail

echo ""
echo "=== sqlsrv.sh (PHP 8.4 / 8.5) ==="

# --- Detect PHP version (84 / 85) ---
if [ -x /opt/alt/php-fpm84/usr/bin/php-config ]; then
  PHPVER="8.4"
  PHPFPM="/opt/alt/php-fpm84"
elif [ -x /opt/alt/php-fpm85/usr/bin/php-config ]; then
  PHPVER="8.5"
  PHPFPM="/opt/alt/php-fpm85"
else
  echo "ERROR: No php-fpm84 or php-fpm85 found. Exiting."
  exit 0
fi

PHPBIN="${PHPFPM}/usr/bin/php"
PHPCONFIG="${PHPFPM}/usr/bin/php-config"
EXTDIR="$(${PHPCONFIG} --extension-dir)"

echo "Using PHP ${PHPVER} at ${PHPFPM}"

# --- sqlsrv / pdo_sqlsrv versions ---
if [[ "$PHPVER" == "8.4" ]]; then
  SQLSRV_VER="5.13.0"
elif [[ "$PHPVER" == "8.5" ]]; then
  SQLSRV_VER="5.14.0beta1"
fi

echo "Selected PECL version: sqlsrv-${SQLSRV_VER}"

# --- ODBC ---
dnf install -y unixODBC unixODBC-devel

cd /usr/local/src

### Cleanup
rm -rf sqlsrv-* pdo_sqlsrv-* sqlsrv.tgz pdo_sqlsrv.tgz

### Download PECL sources
curl -L "https://pecl.php.net/get/sqlsrv-${SQLSRV_VER}.tgz" -o sqlsrv.tgz
curl -L "https://pecl.php.net/get/pdo_sqlsrv-${SQLSRV_VER}.tgz" -o pdo_sqlsrv.tgz

# --- Build sqlsrv ---
tar -xzf sqlsrv.tgz
cd sqlsrv-*
${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install
cd ..

# --- ini file ---
if [ -f "${EXTDIR}/sqlsrv.so" ]; then
  echo "extension=sqlsrv.so" > "${PHPFPM}/usr/php/php.d/sqlsrv.ini"
  echo "Installed sqlsrv.so"
else
  echo "ERROR: sqlsrv.so not found! Build failed."
fi

# --- Build pdo_sqlsrv ---
tar -xzf pdo_sqlsrv.tgz
cd pdo_sqlsrv-*
${PHPFPM}/usr/bin/phpize
./configure --with-php-config="${PHPCONFIG}"
make -j"$(nproc)"
make install
cd ..

# --- ini file ---
if [ -f "${EXTDIR}/pdo_sqlsrv.so" ]; then
  echo "extension=pdo_sqlsrv.so" > "${PHPFPM}/usr/php/php.d/pdo_sqlsrv.ini"
  echo "Installed pdo_sqlsrv.so"
else
  echo "ERROR: pdo_sqlsrv.so not found! Build failed."
fi

echo ""
echo "SQLSRV + PDO_SQLSRV installation finished for PHP ${PHPVER}"
