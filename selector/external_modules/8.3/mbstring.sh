#!/bin/bash

mbstring=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`
rpm -ivh https://github.com/mysterydata/md-disk/raw/main/el8-php83/oniguruma5-el8.x86_64.rpm --force
wget https://github.com/mysterydata/md-disk/raw/main/el8-php83/mbstring.so -P $mbstring
chmod 755 $mbstring/mbstring.so

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/mbstring.so" ];then 
	echo "Creating config file"
	grep "mbstring.so" /opt/alt/php-fpm83/usr/php/php.d/mbstring.ini 2> /dev/null 1> /dev/null|| echo "extension=mbstring.so" > /opt/alt/php-fpm83/usr/php/php.d/mbstring.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/mbstring.so"
fi
