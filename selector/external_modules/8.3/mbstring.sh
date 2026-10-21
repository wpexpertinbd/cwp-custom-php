#!/bin/bash

# Our php83.conf builds mbstring in (--enable-mbstring). A shared mbstring.so +
# mbstring.ini on top of that only produces "Module mbstring is already loaded"
# on every CLI run, so do nothing when the binary already has it.
if /opt/alt/php-fpm83/usr/bin/php -n -m 2>/dev/null | grep -qix mbstring; then
	echo "mbstring is compiled into PHP 8.3 — no mbstring.so / mbstring.ini needed"
	exit 0
fi

mbstring=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`
rpm -ivh https://github.com/mysterydata/md-disk/raw/main/el8-php83/oniguruma5-el8.x86_64.rpm --force
wget --tries=3 https://github.com/mysterydata/md-disk/raw/main/el8-php83/mbstring.so -P $mbstring || { echo "ERROR: download failed: https://github.com/mysterydata/md-disk/raw/main/el8-php83/mbstring.so"; exit 1; }
chmod 755 $mbstring/mbstring.so

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/mbstring.so" ];then 
	echo "Creating config file"
	grep "mbstring.so" /opt/alt/php-fpm83/usr/php/php.d/mbstring.ini 2> /dev/null 1> /dev/null|| echo "extension=mbstring.so" > /opt/alt/php-fpm83/usr/php/php.d/mbstring.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/mbstring.so"
fi
