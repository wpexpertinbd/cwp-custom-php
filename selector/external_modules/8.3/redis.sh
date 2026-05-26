#!/bin/bash
if [ -e "/opt/alt/php-fpm83/usr/bin/php-config" ];then
cd /usr/local/src
yum -y install epel-release
yum -y install redis
systemctl start redis
systemctl enable redis
rm -rf redis-*
rm -rf redis*
curl https://pecl.php.net/get/redis -o redis.tgz
tar -xf redis.tgz
cd redis-*/
/opt/alt/php-fpm83/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make && make install
echo ""

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/redis.so" ];then 
	echo "Creating config file"
	grep "redis.so" /opt/alt/php-fpm83/usr/php/php.d/redis.ini 2> /dev/null 1> /dev/null|| echo "extension=redis.so" > /opt/alt/php-fpm83/usr/php/php.d/redis.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/redis.so"
fi
else
echo "Skipping as php build failed"
fi
