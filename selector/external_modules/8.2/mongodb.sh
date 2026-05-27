#!/bin/bash
if [ -e "/opt/alt/php-fpm82/usr/bin/php-config" ];then
cd /usr/local/src
yum -y install openssl-devel
rm -rf mongodb-*
rm -rf mongodb-*
wget http://static.cdn-cwp.com/files/php/pecl/mongodb-1.11.1.tgz
tar -zxvf mongodb-1.11.1.tgz
cd mongodb-1.11.1
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/mongodb.so" ];then 
	echo "Creating config file"
	grep "mongodb.so" /opt/alt/php-fpm82/usr/php/php.d/mongodb.ini 2> /dev/null 1> /dev/null|| echo "extension=mongodb.so" > /opt/alt/php-fpm82/usr/php/php.d/mongodb.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/mongodb.so"
fi
else
echo "Skipping as php build failed"
fi
