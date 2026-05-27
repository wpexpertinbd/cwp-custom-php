#!/bin/bash

cd /usr/local/src
rm -rf xdebug*
wget http://static.cdn-cwp.com/files/php/pecl/xdebug.tgz
tar zxf xdebug.tgz
cd xdebug-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make && make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/xdebug.so" ];then 
	echo "Creating config file"
	grep "xdebug.so" /opt/alt/php-fpm82/usr/php/php.d/xdebug.ini 2> /dev/null 1> /dev/null|| echo "zend_extension=xdebug.so" > /opt/alt/php-fpm82/usr/php/php.d/xdebug.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/xdebug.so"
fi



