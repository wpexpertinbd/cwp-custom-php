#!/bin/bash
if [ -e "/opt/alt/php-fpm83/usr/bin/php-config" ];then
cd /usr/local/src
rm -rf uploadprogress
curl https://pecl.php.net/get/uploadprogress -o uploadprogress.tgz
tar -xf uploadprogress.tgz
cd uploadprogress-*/
/opt/alt/php-fpm83/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/uploadprogress.so" ];then 
	echo "Creating config file"
	grep "uploadprogress.so" /opt/alt/php-fpm83/usr/php/php.d/uploadprogress.ini 2> /dev/null 1> /dev/null|| echo "extension=uploadprogress.so" > /opt/alt/php-fpm83/usr/php/php.d/uploadprogress.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/uploadprogress.so"
fi
else
echo "Skipping as php build failed"
fi
