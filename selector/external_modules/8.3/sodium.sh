#!/bin/bash

yum --enablerepo=epel -y install libsodium libsodium-devel
cd /usr/local/src
rm -rf libsodium*
curl https://pecl.php.net/get/libsodium -o libsodium.tgz
tar zxf libsodium.tgz
cd libsodium-*/
/opt/alt/php-fpm83/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/sodium.so" ];then 
	echo "Creating config file"
	grep "sodium.so" /opt/alt/php-fpm83/usr/php/php.d/sodium.ini 2> /dev/null 1> /dev/null|| echo "extension=sodium.so" > /opt/alt/php-fpm83/usr/php/php.d/sodium.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/sodium.so"
fi
