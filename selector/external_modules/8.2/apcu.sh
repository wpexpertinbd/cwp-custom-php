#!/bin/bash
if [ -e "/opt/alt/php-fpm82/usr/bin/php-config" ];then
cd /usr/local/src
rm -rf apcu-*
wget http://static.cdn-cwp.com/files/php/pecl/apcu-5.1.19.tgz
tar -xf apcu-5.1.19.tgz
cd apcu-5.1.19
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make && make install
echo ""

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/apcu.so" ];then 
	echo "Creating config file"
	grep "apcu.so" /opt/alt/php-fpm82/usr/php/php.d/apcu.ini 2> /dev/null 1> /dev/null|| echo "extension=apcu.so" > /opt/alt/php-fpm82/usr/php/php.d/apcu.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/apcu.so"
fi
else
echo "Skipping as php build failed"
fi
