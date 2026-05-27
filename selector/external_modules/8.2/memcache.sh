#!/bin/bash
if [ -e "/opt/alt/php-fpm82/usr/bin/php-config" ];then
yum -y install memcached
systemctl enable memcached
systemctl restart memcached
cd /usr/local/src
rm -rf memcache*
curl https://pecl.php.net/get/memcache-8.0.tgz -o memcache.tgz
tar -xf memcache.tgz
cd memcache-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/memcache.so" ];then 
	echo "Creating config file"
	grep "memcache.so" /opt/alt/php-fpm82/usr/php/php.d/memcache.ini 2> /dev/null 1> /dev/null|| echo "extension=memcache.so" > /opt/alt/php-fpm82/usr/php/php.d/memcache.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/memcache.so"
fi
else
echo "Skipping as php build failed"
fi
