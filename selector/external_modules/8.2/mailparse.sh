#!/bin/bash

cd /usr/local/src
rm -rf mailparse*
curl https://pecl.php.net/get/mailparse -o mailparse.tgz
tar zxf mailparse.tgz
cd mailparse-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make && make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/mailparse.so" ];then 
	echo "Creating config file"
	grep "mailparse.so" /opt/alt/php-fpm82/usr/php/php.d/mailparse.ini 2> /dev/null 1> /dev/null|| echo "extension=mailparse.so" > /opt/alt/php-fpm82/usr/php/php.d/mailparse.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/mailparse.so"
fi



