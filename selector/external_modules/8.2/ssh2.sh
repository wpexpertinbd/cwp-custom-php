#!/bin/bash

cd /usr/local/src
rm -rf libssh2*
wget https://www.libssh2.org/download/libssh2-1.9.0.tar.gz -O libssh2.tar.gz
tar -zxvf libssh2.tar.gz
cd libssh2-*/
./configure 
make && make install
cd /usr/local/src
rm -rf ssh2*
curl https://pecl.php.net/get/ssh2 -o ssh2.tgz
tar zxf ssh2.tgz
cd ssh2-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/ssh2.so" ];then 
	echo "Creating config file"
	grep "ssh2.so" /opt/alt/php-fpm82/usr/php/php.d/ssh2.ini 2> /dev/null 1> /dev/null|| echo "extension=ssh2.so" > /opt/alt/php-fpm82/usr/php/php.d/ssh2.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/ssh2.so"
fi



